import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/search/search_history.dart';

/// Secure storage method channel'ını bellek içi haritayla taklit eder.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _memoryStorage.clear();
    _mockSecureStorage();
  });

  test('Bos depoda son ve kayitli listeler bos doner', () async {
    final store = SearchHistoryStore();
    expect(await store.loadRecent(), isEmpty);
    expect(await store.loadSaved(), isEmpty);
  });

  test('Aramalar en one eklenir, tekrarlar one tasinir, ust sinir kirpilir', () async {
    final store = SearchHistoryStore();
    await store.recordSearch('bir film');
    await store.recordSearch('dizi s01');
    await store.recordSearch('bir film'); // tekrar: en one tasinir
    var recent = await store.loadRecent();
    expect(recent, ['bir film', 'dizi s01']);

    for (var i = 0; i < 30; i++) {
      await store.recordSearch('sorgu $i');
    }
    recent = await store.loadRecent();
    expect(recent.length, SearchHistoryStore.maxEntries);
    expect(recent.first, 'sorgu 29');
    // En eski iki giris sinir disi kaldi.
    expect(recent, isNot(contains('bir film')));
    expect(recent, isNot(contains('dizi s01')));
  });

  test('Kayitli aramalar elle eklenir ve kaldirilir', () async {
    final store = SearchHistoryStore();
    await store.saveSearch('favori yayin');
    await store.saveSearch('diger arama');
    // Kayitmanda her yeni giris en one eklenir.
    expect(await store.loadSaved(), ['diger arama', 'favori yayin']);

    // Kayitlama tekrarini one tasir.
    await store.saveSearch('favori yayin');
    expect(await store.loadSaved(), ['favori yayin', 'diger arama']);

    await store.removeSaved('favori yayin');
    expect(await store.loadSaved(), ['diger arama']);
    // Kayıtlı arama son aramalara dokunmaz.
    expect(await store.loadRecent(), isEmpty);
  });

  test('Son aramalar temizlenebilir, kayitlilar etkilenmeden kalir', () async {
    final store = SearchHistoryStore();
    await store.recordSearch('gecmis');
    await store.saveSearch('kalici');
    await store.clearRecent();
    expect(await store.loadRecent(), isEmpty);
    expect(await store.loadSaved(), ['kalici']);
  });

  test('Sorgular normalize edilir: kisa, sikistirilmis, ust uzunluklu', () async {
    expect(SearchHistoryStore.normalizeQuery('  cok     bosluklu  '), 'cok bosluklu');
    expect(SearchHistoryStore.normalizeQuery('   '), '');
    expect(
      SearchHistoryStore.normalizeQuery('x' * 250).length,
      100,
    );
    // Normalizasyon kayitta da uygulanir.
    final store = SearchHistoryStore();
    await store.recordSearch('  SPOR   maçı  ');
    expect(await store.loadRecent(), ['SPOR maçı']);
  });

  test('Bozuk JSON sessizce bos liste dondurur', () async {
    _memoryStorage['search.recentQueries'] = '[1, 2, {';
    final store = SearchHistoryStore();
    expect(await store.loadRecent(), isEmpty);
  });
}
