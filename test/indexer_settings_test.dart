import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/settings/indexer_settings.dart';
import 'package:zanzibarr/settings/opensubtitles_settings.dart';
import 'package:zanzibarr/settings/provider_settings.dart';
import 'package:zanzibarr/settings/settings_screen.dart';
import 'package:zanzibarr/src/rust/api/search.dart';

import 'l10n_test_helper.dart';

/// Secure storage method channel'ını bellek içi haritayla taklit eder;
/// böylece [IndexerSettingsStore] gerçek kod yoluyla sınanır.
const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final _memoryStorage = <String, String>{};

void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return _memoryStorage[key];
          case 'write':
            _memoryStorage[key!] = args['value'] as String;
            return null;
          case 'delete':
            _memoryStorage.remove(key);
            return null;
          case 'deleteAll':
            _memoryStorage.clear();
            return null;
        }
        return null;
      });
}

/// Ayar ekranı testlerinde gerçek secure storage yerine bellek içi sahte depo.
class _FakeIndexerStore extends IndexerSettingsStore {
  IndexerSettings saved = const IndexerSettings();
  List<IndexerProfile> profiles = const [];

  @override
  Future<List<IndexerProfile>> loadProfiles() async => profiles;

  @override
  Future<void> saveProfile(IndexerProfile profile) async {
    final index = profiles.indexWhere((p) => p.id == profile.id);
    final updated = profiles.toList();
    if (index >= 0) {
      updated[index] = profile;
    } else {
      updated.add(profile);
    }
    profiles = updated;
    saved = profile.settings;
  }

  @override
  Future<void> deleteProfile(String id) async {
    profiles = profiles.where((p) => p.id != id).toList();
  }

  @override
  Future<IndexerSettings> load() async => saved;
}

/// NNTP bölümü de ekran açılışında depo okur; kanala düşmemesi için sahte.
class _FakeProviderStore extends ProviderSettingsStore {
  @override
  Future<List<ProviderProfile>> loadProfiles() async => const [];

  @override
  Future<ProviderSettings> load() async => const ProviderSettings();
}

/// ListView tembel kurulduğundan alt bölümler ancak kaydırınca ağaca girer;
/// scrollUntilVisible cacheExtent'te durabildiği için ensureVisible ile
/// öğe tamamen görünür alana çekilir ve sonraki tap'in doğru koordinatı
/// görmesi için settle edilir. (Metin alanları da Scrollable taşıdığı için
/// en dıştaki seçilir.)
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}


/// OpenSubtitles bölümü: bellek içi sahte depoyla sınanır.
class _FakeOpenSubtitlesStore extends OpenSubtitlesSettingsStore {
  OpenSubtitlesSettings saved = const OpenSubtitlesSettings();

  @override
  Future<OpenSubtitlesSettings> load() async => saved;

  @override
  Future<void> save(OpenSubtitlesSettings settings) async => saved = settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IndexerSettingsStore', () {
    setUp(() {
      _memoryStorage.clear();
      _mockSecureStorage();
    });

    test('Boş depoda varsayılan (boş) ayarlar döner', () async {
      final settings = await IndexerSettingsStore().load();
      expect(settings.baseUrl, isEmpty);
      expect(settings.apiKey, isEmpty);
      expect(settings.isComplete, isFalse);
    });

    test('Kaydedilen ayarlar geri okunur', () async {
      final store = IndexerSettingsStore();
      await store.save(
        const IndexerSettings(
          baseUrl: 'https://indexer.example',
          apiKey: 'gizli-anahtar',
        ),
      );
      final settings = await store.load();
      expect(settings.baseUrl, 'https://indexer.example');
      expect(settings.apiKey, 'gizli-anahtar');
      expect(settings.isComplete, isTrue);
    });

    test('clear anahtarları siler', () async {
      final store = IndexerSettingsStore();
      await store.save(
        const IndexerSettings(baseUrl: 'https://indexer.example', apiKey: 'k'),
      );
      await store.clear();
      final settings = await store.load();
      expect(settings.isComplete, isFalse);
    });

    test('isComplete yalnızca iki alan da doluyken true olur', () {
      expect(const IndexerSettings().isComplete, isFalse);
      expect(
        const IndexerSettings(baseUrl: 'https://x.example').isComplete,
        isFalse,
      );
      expect(const IndexerSettings(apiKey: 'k').isComplete, isFalse);
      expect(
        const IndexerSettings(baseUrl: 'https://x.example', apiKey: 'k')
            .isComplete,
        isTrue,
      );
    });
  });

  group('IndexerSettingsStore çoklu profil', () {
    setUp(() {
      _memoryStorage.clear();
      _mockSecureStorage();
    });

    test('Eski tek indexer anahtarları ilk açılışta profile taşınır', () async {
      _memoryStorage['indexer.baseUrl'] = 'https://indexer.example';
      _memoryStorage['indexer.apiKey'] = 'gizli-anahtar';

      final store = IndexerSettingsStore();
      final profiles = await store.loadProfiles();
      expect(profiles.length, 1);
      expect(profiles.first.id, 'default');
      expect(profiles.first.baseUrl, 'https://indexer.example');
      expect(profiles.first.enabled, isTrue);
      // Geriye uyumlu load() aynı ayarları döner.
      expect((await store.load()).baseUrl, 'https://indexer.example');
    });

    test('saveProfile hesap ekler/günceller; enabled kapatınca aramaya katılmaz',
        () async {
      final store = IndexerSettingsStore();
      final first = IndexerProfile(
        id: 'a',
        label: 'Miatrix',
        baseUrl: 'https://idx1.example',
        apiKey: 'k1',
      );
      await store.saveProfile(first);
      expect((await store.loadProfiles()).length, 1);

      final second = IndexerProfile(
        id: 'b',
        label: 'Prowlarr proxy',
        baseUrl: 'http://prowlarr:9696/prowlarr/12/api',
        apiKey: 'k2',
      );
      await store.saveProfile(second);
      final profiles = await store.loadProfiles();
      expect(profiles.map((p) => p.id), containsAll(['a', 'b']));

      // load() aramaya katılabilen ilk profili döner.
      expect((await store.load()).baseUrl, 'https://idx1.example');

      // 'a' kapatılınca aramaya yalnız 'b' katılır.
      await store.saveProfile(
        IndexerProfile(
          id: 'a',
          label: 'Miatrix',
          baseUrl: 'https://idx1.example',
          apiKey: 'k1',
          enabled: false,
        ),
      );
      expect((await store.load()).baseUrl, 'http://prowlarr:9696/prowlarr/12/api');
      // Kapalı profil listede durur.
      expect(
        (await store.loadProfiles()).any((p) => p.id == 'a' && !p.enabled),
        isTrue,
      );
    });

    test('deleteProfile hesabı kaldırır', () async {
      final store = IndexerSettingsStore();
      await store.saveProfile(
        IndexerProfile(id: 'a', baseUrl: 'https://idx.example', apiKey: 'k'),
      );
      await store.saveProfile(
        IndexerProfile(id: 'b', baseUrl: 'https://idx2.example', apiKey: 'k2'),
      );
      await store.deleteProfile('a');
      expect((await store.loadProfiles()).map((p) => p.id), ['b']);
      await store.deleteProfile('b');
      expect(await store.loadProfiles(), isEmpty);
      expect((await store.load()).isComplete, isFalse);
    });

    test('Görünüm adı: etiket → URL host → ham URL', () {
      expect(
        IndexerProfile(id: 'a', label: 'Hydra', baseUrl: 'http://x:5075/api')
            .displayName,
        'Hydra',
      );
      expect(
        IndexerProfile(id: 'b', baseUrl: 'https://idx.example/api')
            .displayName,
        'idx.example',
      );
      expect(
        IndexerProfile(id: 'c', baseUrl: 'düz-metin').displayName,
        'düz-metin',
      );
    });
  });

  group('SettingsScreen indexer bölümü', () {
    testWidgets('Indexer bölümü görünür ve sahte depoya kaydeder', (
      tester,
    ) async {
      final store = _FakeIndexerStore();
      await tester.pumpWithL10n(
        SettingsScreen(store: _FakeProviderStore(), indexerStore: store),
      );
      await tester.pumpAndSettle();

      await _reveal(tester, find.text('Indexer (Newznab)'));
      await tester.pumpAndSettle();
      expect(find.text('Indexer (Newznab)'), findsOneWidget);
      expect(find.text("Indexer URL'si"), findsOneWidget);
      expect(find.text('API anahtarı'), findsOneWidget);

      await _reveal(tester, find.widgetWithText(TextFormField, "Indexer URL'si"));
      await tester.enterText(
        find.widgetWithText(TextFormField, "Indexer URL'si"),
        'https://indexer.example',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API anahtarı'),
        'cok-gizli',
      );

      await _reveal(tester, find.text("Indexer'ı kaydet"));
      await tester.tap(find.text("Indexer'ı kaydet"));
      await tester.pumpAndSettle();

      expect(store.saved.baseUrl, 'https://indexer.example');
      expect(store.saved.apiKey, 'cok-gizli');
      expect(store.saved.isComplete, isTrue);
      expect(find.text('Ayarlar güvenli depoya kaydedildi.'), findsOneWidget);
    });

    testWidgets('Geçersiz URL kaydı engelliyor', (tester) async {
      final store = _FakeIndexerStore();
      await tester.pumpWithL10n(
        SettingsScreen(store: _FakeProviderStore(), indexerStore: store),
      );
      await tester.pumpAndSettle();

      await _reveal(tester, find.widgetWithText(TextFormField, "Indexer URL'si"));
      await tester.enterText(
        find.widgetWithText(TextFormField, "Indexer URL'si"),
        'ftp://indexer.example',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API anahtarı'),
        'anahtar',
      );

      await _reveal(tester, find.text("Indexer'ı kaydet"));
      await tester.tap(find.text("Indexer'ı kaydet"));
      await tester.pumpAndSettle();

      expect(
        find.text('http:// veya https:// ile başlayan geçerli bir URL girin'),
        findsOneWidget,
      );
      expect(store.saved.isComplete, isFalse);
    });

    testWidgets('URL doluyken API anahtarı zorunlu', (tester) async {
      final store = _FakeIndexerStore();
      await tester.pumpWithL10n(
        SettingsScreen(store: _FakeProviderStore(), indexerStore: store),
      );
      await tester.pumpAndSettle();

      await _reveal(tester, find.widgetWithText(TextFormField, "Indexer URL'si"));
      await tester.enterText(
        find.widgetWithText(TextFormField, "Indexer URL'si"),
        'https://indexer.example',
      );

      await _reveal(tester, find.text("Indexer'ı kaydet"));
      await tester.tap(find.text("Indexer'ı kaydet"));
      await tester.pumpAndSettle();

      expect(find.text('API anahtarı gerekli'), findsOneWidget);
      expect(store.saved.isComplete, isFalse);
    });

    testWidgets('Boş URL geçerli sayılır (indexer kapalı)', (tester) async {
      final store = _FakeIndexerStore();
      await tester.pumpWithL10n(
        SettingsScreen(store: _FakeProviderStore(), indexerStore: store),
      );
      await tester.pumpAndSettle();

      await _reveal(tester, find.text("Indexer'ı kaydet"));
      await tester.tap(find.text("Indexer'ı kaydet"));
      await tester.pumpAndSettle();

      expect(store.saved.baseUrl, isEmpty);
      expect(store.saved.apiKey, isEmpty);
      expect(find.text('Ayarlar güvenli depoya kaydedildi.'), findsOneWidget);
    });

    testWidgets('Bağlantıyı sına caps sonucunu SnackBar ile gösterir', (
      tester,
    ) async {
      final store = _FakeIndexerStore();
      IndexerConfigDto? capsConfig;
      await tester.pumpWithL10n(
        SettingsScreen(
          store: _FakeProviderStore(),
          indexerStore: store,
          capsFn: (config) async {
            capsConfig = config;
            return const IndexerCapsDto(
              serverTitle: 'Miatrix',
              searchAvailable: true,
              tvSearchAvailable: true,
              movieSearchAvailable: true,
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      await _reveal(tester, find.widgetWithText(TextFormField, "Indexer URL'si"));
      await tester.enterText(
        find.widgetWithText(TextFormField, "Indexer URL'si"),
        'https://indexer.example',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API anahtarı'),
        'anahtar',
      );

      await _reveal(tester, find.text('Bağlantıyı sına'));
      await tester.tap(find.text('Bağlantıyı sına'));
      await tester.pumpAndSettle();

      expect(capsConfig?.baseUrl, 'https://indexer.example');
      expect(find.text('Bağlandı: Miatrix'), findsOneWidget);
    });
  });
  group('SettingsScreen OpenSubtitles bolumu', () {
    testWidgets('bolum gorunur, kimlik bilgileri kaydedilir', (tester) async {
      final store = _FakeOpenSubtitlesStore();
      await tester.pumpWithL10n(
        SettingsScreen(
          store: _FakeProviderStore(),
          indexerStore: _FakeIndexerStore(),
          osStore: store,
        ),
      );
      await tester.pumpAndSettle();

      await _reveal(tester, find.text('OpenSubtitles'));
      expect(find.text('OpenSubtitles'), findsOneWidget);
      expect(find.text('OpenSubtitles API anahtarı'), findsOneWidget);
      expect(find.text('Kullanıcı adı (isteğe bağlı)'), findsOneWidget);

      await _reveal(
        tester,
        find.widgetWithText(TextFormField, 'OpenSubtitles API anahtarı'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'OpenSubtitles API anahtarı'),
        'os-anahtari',
      );
      await _reveal(tester, find.text('Altyazı ayarlarını kaydet'));
      await tester.tap(find.text('Altyazı ayarlarını kaydet'));
      await tester.pumpAndSettle();

      expect(store.saved.apiKey, 'os-anahtari');
      expect(store.saved.canSearch, isTrue);
      expect(store.saved.languages, OpenSubtitlesSettings.defaultLanguages);
      expect(find.text('Ayarlar güvenli depoya kaydedildi.'), findsOneWidget);
    });

    testWidgets('gecersiz URL kaydi engelliyor', (tester) async {
      final store = _FakeOpenSubtitlesStore();
      await tester.pumpWithL10n(
        SettingsScreen(
          store: _FakeProviderStore(),
          indexerStore: _FakeIndexerStore(),
          osStore: store,
        ),
      );
      await tester.pumpAndSettle();

      await _reveal(
        tester,
        find.widgetWithText(TextFormField, 'API kök adresi'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API kök adresi'),
        'ftp://api.example.com',
      );
      await _reveal(tester, find.text('Altyazı ayarlarını kaydet'));
      await tester.tap(find.text('Altyazı ayarlarını kaydet'));
      await tester.pumpAndSettle();

      expect(
        find.text('http:// veya https:// ile başlayan geçerli bir URL girin'),
        findsOneWidget,
      );
      expect(store.saved.canSearch, isFalse);
    });

    testWidgets('RSS yedek bölümü OpenSubtitles ayarlarından sonra görünür', (
      tester,
    ) async {
      await tester.pumpWithL10n(
        SettingsScreen(
          store: _FakeProviderStore(),
          indexerStore: _FakeIndexerStore(),
          osStore: _FakeOpenSubtitlesStore(),
        ),
      );
      await tester.pumpAndSettle();

      await _reveal(tester, find.text('RSS içe / dışa aktar'));
      expect(find.text('JSON olarak dışa aktar'), findsOneWidget);
      expect(find.text("JSON'dan içe aktar"), findsOneWidget);
    });
  });
}
