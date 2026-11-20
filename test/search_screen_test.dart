import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/search/search_screen.dart';
import 'package:zanzibarr/settings/indexer_settings.dart';
import 'package:zanzibarr/settings/provider_settings.dart';
import 'package:zanzibarr/src/rust/api/health.dart';
import 'package:zanzibarr/src/rust/api/search.dart';
import 'package:zanzibarr/src/rust/api/streaming.dart' show ProviderConfigDto;

import 'l10n_test_helper.dart';

/// Gerçek secure storage yerine sabit ayar döndüren sahte depo.
class _FakeIndexerStore extends IndexerSettingsStore {
  _FakeIndexerStore(this.settings);

  final IndexerSettings settings;

  @override
  Future<IndexerSettings> load() async => settings;
}

/// Sağlayıcı ayarları için aynı desenli sahte depo (ön kontrol testleri).
class _FakeProviderStore extends ProviderSettingsStore {
  _FakeProviderStore(this.settings);

  final ProviderSettings settings;

  @override
  Future<ProviderSettings> load() async => settings;
}

final _completeStore = _FakeIndexerStore(
  const IndexerSettings(baseUrl: 'https://indexer.example', apiKey: 'anahtar'),
);

final _completeProviderStore = _FakeProviderStore(
  const ProviderSettings(
    host: 'news.example.com',
    username: 'kullanici',
    password: 'TESTPASS123',
    maxConnections: 10,
  ),
);

SearchItemDto _movieItem() => SearchItemDto(
  title: 'Bir.Film.2024.2160p.WEB-DL.DV.HEVC-GRP',
  nzbUrl: 'https://indexer.example/getnzb/1',
  sizeBytes: BigInt.from(6979321856), // 6,5 GB
  publishedEpochSecs:
      DateTime.now().subtract(const Duration(days: 10)).millisecondsSinceEpoch ~/
      1000,
  badges: const ['2160p', 'HEVC', 'DV'],
  mediaKind: 'movie',
  year: 2024,
);

SearchItemDto _tvItem() => SearchItemDto(
  title: 'Bir.Dizi.S01E02.1080p.WEB-GRP',
  nzbUrl: 'https://indexer.example/getnzb/2',
  sizeBytes: BigInt.from(734003200), // 700 MB
  badges: const ['1080p'],
  mediaKind: 'tv',
  season: 1,
  episode: 2,
);

/// Sabit iki sonuç döndüren sahte arama.
Future<SearchPageDto> _fakeSearch(
  IndexerConfigDto config,
  String query,
  int limit,
  int offset,
) async => SearchPageDto(total: BigInt.from(2), items: [_movieItem(), _tvItem()]);

Future<void> _enterQueryAndSearch(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.tap(find.widgetWithIcon(IconButton, Icons.search_rounded));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Arama sonuçları rozet, boyut, yaş ve toplam ile listeleniyor', (
    tester,
  ) async {
    await tester.pumpWithL10n(
      SearchScreen(store: _completeStore, searchFn: _fakeSearch),
    );
    await tester.pumpAndSettle();

    // Henüz arama yapılmadan ipucu görünür.
    expect(
      find.text("Indexer'ınızda aramak için bir sürüm adı yazın."),
      findsOneWidget,
    );

    await _enterQueryAndSearch(tester, 'film');

    expect(
      find.text('Bir.Film.2024.2160p.WEB-DL.DV.HEVC-GRP'),
      findsOneWidget,
    );
    expect(find.text('Bir.Dizi.S01E02.1080p.WEB-GRP'), findsOneWidget);
    expect(find.text('2160p'), findsOneWidget);
    expect(find.text('HEVC'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('6.5 GB'), findsOneWidget);
    expect(find.text('700 MB'), findsOneWidget);
    expect(find.text('10 g'), findsOneWidget);
    expect(find.text('2024'), findsOneWidget);
    expect(find.text('2 sonuç'), findsOneWidget);
  });

  testWidgets('Öğeye dokununca downloadFn çağrılır ve onDownloaded tetiklenir', (
    tester,
  ) async {
    IndexerConfigDto? usedConfig;
    String? usedUrl;
    String? usedName;
    String? downloadedPath;
    await tester.pumpWithL10n(
      SearchScreen(
        store: _completeStore,
        searchFn: _fakeSearch,
        downloadFn: (config, nzbUrl, suggestedName) async {
          usedConfig = config;
          usedUrl = nzbUrl;
          usedName = suggestedName;
          return '/tmp/indirilen.nzb';
        },
        onDownloaded: (path) => downloadedPath = path,
      ),
    );
    await tester.pumpAndSettle();
    await _enterQueryAndSearch(tester, 'film');

    await tester.tap(find.text('Bir.Film.2024.2160p.WEB-DL.DV.HEVC-GRP'));
    await tester.pumpAndSettle();

    expect(usedConfig?.baseUrl, 'https://indexer.example');
    expect(usedConfig?.apiKey, 'anahtar');
    expect(usedUrl, 'https://indexer.example/getnzb/1');
    expect(usedName, 'Bir.Film.2024.2160p.WEB-DL.DV.HEVC-GRP');
    expect(downloadedPath, '/tmp/indirilen.nzb');
  });

  testWidgets('İndirme hatası SnackBar ile gösterilir', (tester) async {
    await tester.pumpWithL10n(
      SearchScreen(
        store: _completeStore,
        searchFn: _fakeSearch,
        downloadFn: (config, nzbUrl, suggestedName) async =>
            throw Exception('disk dolu'),
        onDownloaded: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await _enterQueryAndSearch(tester, 'film');

    await tester.tap(find.text('Bir.Dizi.S01E02.1080p.WEB-GRP'));
    await tester.pumpAndSettle();

    expect(
      find.text('NZB indirilemedi: Exception: disk dolu'),
      findsOneWidget,
    );
  });

  testWidgets('Arama hatası yeniden deneme görünümüne düşer', (tester) async {
    await tester.pumpWithL10n(
      SearchScreen(
        store: _completeStore,
        searchFn: (config, query, limit, offset) async =>
            throw Exception('Indexer yanıt vermiyor'),
      ),
    );
    await tester.pumpAndSettle();
    await _enterQueryAndSearch(tester, 'film');

    expect(find.textContaining('Indexer yanıt vermiyor'), findsOneWidget);
    expect(find.text('Yeniden dene'), findsOneWidget);
  });

  testWidgets('Sonuç yoksa bilgi görünümü gösterilir', (tester) async {
    await tester.pumpWithL10n(
      SearchScreen(
        store: _completeStore,
        searchFn: (config, query, limit, offset) async =>
            SearchPageDto(total: BigInt.zero, items: const []),
      ),
    );
    await tester.pumpAndSettle();
    await _enterQueryAndSearch(tester, 'olmayan');

    expect(find.text('Sonuç bulunamadı'), findsOneWidget);
  });

  testWidgets('Indexer ayarları eksikse ayarlara yönlendirme gösterilir', (
    tester,
  ) async {
    await tester.pumpWithL10n(
      SearchScreen(store: _FakeIndexerStore(const IndexerSettings())),
    );
    await tester.pumpAndSettle();

    expect(
      find.text("Önce ayarlardan indexer URL'sini ve API anahtarını girin."),
      findsOneWidget,
    );
    expect(find.text('Ayarlara git'), findsOneWidget);
  });

  group('NZB sağlık ön kontrolü', () {
    /// Sağlık raporu üretme yardımcısı (varsayılanlar "temiz" durumu).
    NzbHealthDto healthReport(
      String status, {
      int missing = 0,
      int sampled = 3,
      int par2Blocks = 0,
      bool par2Present = false,
    }) => NzbHealthDto(
      status: status,
      sampledArticles: sampled,
      missingArticles: missing,
      erroredSamples: 0,
      estimatedMissingArticles:
          missing > 0 ? BigInt.from(missing * 2) : BigInt.zero,
      targetArticleCount: BigInt.from(6),
      targetFileCount: 1,
      archiveVolumes: 0,
      volumeGaps: 0,
      headMissing: false,
      par2Present: par2Present,
      par2RecoveryBlocks: par2Blocks,
    );

    /// pumpAndSettle'e gerek duymadan arama başlatır: askıda kalan healthFn'i
    /// olan testlerde sonsuz spinner pumpAndSettle'ı öldürür (deneyimle
    /// öğrenildi — karttaki kontrol rozeti bir animasyondur).
    Future<void> searchWithoutSettle(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField), query);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.search_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('iyi ve eksik sonuçlar renkli rozetle belirtilir', (
      tester,
    ) async {
      ProviderConfigDto? healthConfig;
      await tester.pumpWithL10n(
        SearchScreen(
          store: _completeStore,
          searchFn: _fakeSearch,
          providerStore: _completeProviderStore,
          downloadFn: (config, nzbUrl, suggestedName) async =>
              nzbUrl.contains('getnzb/1') ? '/tmp/bir-film.nzb' : '/tmp/bir-dizi.nzb',
          healthFn: (config, nzbPath) async {
            healthConfig ??= config;
            return nzbPath.contains('bir-film')
                ? healthReport('good')
                : healthReport('missing', missing: 1);
          },
        ),
      );
      await tester.pumpAndSettle();
      await _enterQueryAndSearch(tester, 'film');

      // Tarama bitti: ilk sonuç sağlam, ikincisi eksik.
      expect(find.text('İyi'), findsOneWidget);
      expect(find.text('Eksik'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      // Sağlayıcı yapılandırması ön kontrole eksiksiz taşınır.
      expect(healthConfig?.host, 'news.example.com');
      expect(healthConfig?.username, 'kullanici');
      // Eksik rozetinin açıklaması: örnekleme + PAR2 yok bilgisi.
      expect(
        find.byTooltip(
          "3 örneklem article'dan 1 tanesi eksik\n"
          'Bu yayında PAR2 onarım verisi yok',
        ),
        findsOneWidget,
      );
    });

    testWidgets('onarılabilir rozeti PAR2 bilgisini taşır', (tester) async {
      await tester.pumpWithL10n(
        SearchScreen(
          store: _completeStore,
          searchFn: _fakeSearch,
          providerStore: _completeProviderStore,
          downloadFn: (config, nzbUrl, suggestedName) async => '/tmp/a.nzb',
          healthFn: (config, nzbPath) async => healthReport(
            'repairable',
            missing: 1,
            par2Present: true,
            par2Blocks: 9,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _enterQueryAndSearch(tester, 'film');

      expect(find.text('Onarılabilir'), findsNWidgets(2));
      expect(find.byIcon(Icons.healing_rounded), findsNWidgets(2));
      expect(
        find.byTooltip(
          "3 örneklem article'dan 1 tanesi eksik\n"
          '9 PAR2 onarım bloğu mevcut',
        ),
        findsNWidgets(2),
      );
    });

    testWidgets('denetim sırasında spinner, bitince rozet gelir', (tester) async {
      final gate = Completer<void>();
      var healthCalls = 0;
      await tester.pumpWithL10n(
        SearchScreen(
          store: _completeStore,
          searchFn: _fakeSearch,
          providerStore: _completeProviderStore,
          downloadFn: (config, nzbUrl, suggestedName) async => '/tmp/a.nzb',
          healthFn: (config, nzbPath) async {
            healthCalls++;
            await gate.future;
            return healthReport('good');
          },
        ),
      );
      await tester.pumpAndSettle();
      await searchWithoutSettle(tester, 'film');

      // İlk öğenin denetimi askıda: kart spinner taşıyor.
      expect(healthCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('İyi'), findsNWidgets(2));
    });

    testWidgets('denetim başarısızsa rozet gösterilmez', (tester) async {
      await tester.pumpWithL10n(
        SearchScreen(
          store: _completeStore,
          searchFn: _fakeSearch,
          providerStore: _completeProviderStore,
          downloadFn: (config, nzbUrl, suggestedName) async => '/tmp/a.nzb',
          healthFn: (config, nzbPath) async => throw Exception('sunucu yok'),
        ),
      );
      await tester.pumpAndSettle();
      await _enterQueryAndSearch(tester, 'film');

      expect(find.text('İyi'), findsNothing);
      expect(find.text('Eksik'), findsNothing);
      expect(find.text('Onarılabilir'), findsNothing);
      expect(find.text('Riskli'), findsNothing);
    });

    testWidgets('sağlayıcı ayarları yoksa ön kontrol hiç başlamaz', (
      tester,
    ) async {
      var downloadCalls = 0;
      await tester.pumpWithL10n(
        SearchScreen(
          store: _completeStore,
          searchFn: _fakeSearch,
          providerStore: _FakeProviderStore(const ProviderSettings()),
          downloadFn: (config, nzbUrl, suggestedName) async {
            downloadCalls++;
            return '/tmp/a.nzb';
          },
          healthFn: (config, nzbPath) async => healthReport('good'),
        ),
      );
      await tester.pumpAndSettle();
      await _enterQueryAndSearch(tester, 'film');

      // Sağlayıcı olmadan ne indirme ne denetim yapılır.
      expect(downloadCalls, 0);
      expect(find.text('İyi'), findsNothing);
    });

    testWidgets('denetimde indirilen NZB oynatımda yeniden indirilmez', (
      tester,
    ) async {
      var downloadCalls = 0;
      String? playedPath;
      await tester.pumpWithL10n(
        SearchScreen(
          store: _completeStore,
          searchFn: _fakeSearch,
          providerStore: _completeProviderStore,
          downloadFn: (config, nzbUrl, suggestedName) async {
            downloadCalls++;
            return nzbUrl.contains('getnzb/1')
                ? '/tmp/bir-film.nzb'
                : '/tmp/bir-dizi.nzb';
          },
          healthFn: (config, nzbPath) async => healthReport('good'),
          onDownloaded: (path) => playedPath = path,
        ),
      );
      await tester.pumpAndSettle();
      await _enterQueryAndSearch(tester, 'film');

      // Tarama her sonuç için bir kez indirdi.
      expect(downloadCalls, 2);

      await tester.tap(find.text('Bir.Film.2024.2160p.WEB-DL.DV.HEVC-GRP'));
      await tester.pumpAndSettle();

      // Oynatma aynı yolu yeniden kullandı: ek indirme yok.
      expect(downloadCalls, 2);
      expect(playedPath, '/tmp/bir-film.nzb');
    });

    testWidgets('yeni arama gecikmiş eski denetimi geçersiz kılar', (
      tester,
    ) async {
      final firstGate = Completer<void>();
      var healthCalls = 0;
      await tester.pumpWithL10n(
        SearchScreen(
          store: _completeStore,
          searchFn: _fakeSearch,
          providerStore: _completeProviderStore,
          downloadFn: (config, nzbUrl, suggestedName) async => '/tmp/a.nzb',
          healthFn: (config, nzbPath) async {
            healthCalls++;
            // Yalnız ilk aramanın İLK denetimi askıda: "eksik" raporuyla
            // dönecek; yeni kuşağa yazması engellenmeli.
            if (healthCalls == 1) {
              await firstGate.future;
              return healthReport('missing', missing: 1);
            }
            return healthReport('good');
          },
        ),
      );
      await tester.pumpAndSettle();
      await searchWithoutSettle(tester, 'film');

      // İlk denetim askında: spinner var, rozet yok.
      expect(find.text('İyi'), findsNothing);
      expect(find.text('Eksik'), findsNothing);

      // Yeni arama: kuşak geçersiz; yeni tarama hızlı raporlarla biter.
      await searchWithoutSettle(tester, 'yeni sorgu');
      await tester.pumpAndSettle();
      expect(find.text('İyi'), findsNWidgets(2));
      expect(find.text('Eksik'), findsNothing);

      // Gecikmiş eski görev açılırsa da yeni listeye yazamaz.
      firstGate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Eksik'), findsNothing);
      expect(find.text('İyi'), findsNWidgets(2));
    });
  });
}
