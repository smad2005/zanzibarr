import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/player/subtitle_search_dialog.dart';
import 'package:zanzibarr/src/rust/api/subtitles.dart';

import 'l10n_test_helper.dart';

const _config = OpenSubtitlesConfigDto(
  baseUrl: '',
  apiKey: 'anahtar',
  username: '',
  password: '',
);

List<SubtitleDto> _results({String language = 'tr'}) => [
  SubtitleDto(
    fileId: BigInt.from(101),
    fileName: 'Dizi.S01E01.1080p.TR.srt',
    language: language,
    release: 'Dizi.S01E01.1080p-GRP',
    downloadCount: BigInt.from(5000),
    matchedByHash: true,
    hearingImpaired: false,
  ),
  SubtitleDto(
    fileId: BigInt.from(102),
    fileName: 'Dizi.S01E01.720p.TR.srt',
    language: language,
    release: '',
    downloadCount: BigInt.from(12),
    matchedByHash: false,
    hearingImpaired: true,
  ),
];

Widget _host(
  OpenSubtitlesSearchFn searchFn,
  OpenSubtitlesDownloadFn downloadFn, {
  void Function(List<String> languages)? onLanguagesChanged,
  void Function(String path, String language)? onSelected,
  OpenSubtitlesHashFn? hashFn,
  List<String> initialLanguages = const ['tr', 'en'],
}) =>
    l10nTestApp(
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => SubtitleSearchDialog(
                  config: _config,
                  filename: 'Dizi.S01E01.1080p.mkv',
                  streamUrl: 'http://127.0.0.1:9/video.mkv',
                  streamSize: 128,
                  downloadDir: '/tmp/altdizi',
                  initialLanguages: initialLanguages,
                  searchFn: searchFn,
                  downloadFn: downloadFn,
                  hashFn: hashFn ?? ((_, _) async => null),
                  onSelected: onSelected ?? (_, _) {},
                  onLanguagesChanged: onLanguagesChanged ?? (_) {},
                ),
              ),
              child: const Text('diyalogu-ac'),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('diyalogu-ac'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Arama sonuçları dil etiketi ve hash eşleşmesiyle listelenir',
      (tester) async {
    var searchCalls = 0;
    String? hashArg;
    BigInt? sizeArg;
    List<String>? languagesArg;
    await tester.pumpWidget(
      _host(
        (config, query, languages, hash, size) async {
          searchCalls++;
          hashArg = hash;
          sizeArg = size;
          languagesArg = languages;
          return _results();
        },
        (_, _, _) async => '/tmp/altdizi/101.srt',
        hashFn: (_, _) async => 'aabbccdd00112233',
      ),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    expect(find.text('Dizi.S01E01.1080p.TR.srt'), findsOneWidget);
    // İki sonuç satırı: her ikisi de dosya adını taşır.
    expect(find.textContaining('.srt'), findsNWidgets(2));
    // hash + boyut aramaya taşınır; dil listesi ayarla gelir.
    expect(searchCalls, 1);
    expect(hashArg, 'aabbccdd00112233');
    expect(sizeArg, BigInt.from(128));
    expect(languagesArg, ['tr', 'en']);
    // Dosya eşleşmesi işareti ve indirme sayısı görünür.
    expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
    expect(find.text('Dosya eşleşmesi'), findsOneWidget);
    expect(find.text('5000 indirme'), findsOneWidget);
    expect(find.text('HI'), findsOneWidget);
    // Dil çipleri mevcut tercihle işaretli.
    expect(find.text('Türkçe'), findsOneWidget);
  });

  testWidgets('Hash bir kez hesaplanır; yeniden arama yeniden hesaplamaz',
      (tester) async {
    var hashCalls = 0;
    var searchCalls = 0;
    await tester.pumpWidget(
      _host(
        (config, query, languages, hash, size) async {
          searchCalls++;
          return _results();
        },
        (_, _, _) async => '/tmp/altdizi/101.srt',
        hashFn: (_, _) async {
          hashCalls++;
          return null;
        },
      ),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    // Dil çipi değişimi yeni arama tetikler ama hash yeniden hesaplanmaz.
    await tester.tap(find.text('Español'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Español'));
    await tester.pumpAndSettle();

    expect(hashCalls, 1);
    expect(searchCalls, 3);
  });

  testWidgets('Sonuca dokununca indirilir ve onSelected diyalog kapanır',
      (tester) async {
    BigInt? downloadedId;
    String? selectedPath;
    String? selectedLanguage;
    await tester.pumpWidget(
      _host(
        (_, _, _, _, _) async => _results(),
        (config, fileId, dir) async {
          downloadedId = fileId;
          return '/tmp/altdizi/101-Dizi.srt';
        },
        onSelected: (path, language) {
          selectedPath = path;
          selectedLanguage = language;
        },
      ),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dizi.S01E01.1080p.TR.srt'));
    await tester.pumpAndSettle();

    expect(downloadedId, BigInt.from(101));
    expect(selectedPath, '/tmp/altdizi/101-Dizi.srt');
    expect(selectedLanguage, 'tr');
    // Diyalog kapandı.
    expect(find.byType(SubtitleSearchDialog), findsNothing);
  });

  testWidgets('İndirme hatası hata görünüme düşer, snackbar üretmez',
      (tester) async {
    await tester.pumpWidget(
      _host(
        (_, _, _, _, _) async => _results(),
        (config, fileId, dir) async => throw Exception('kota bitti'),
      ),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dizi.S01E01.1080p.TR.srt'));
    await tester.pumpAndSettle();

    expect(find.text('Altyazı araması başarısız.'), findsOneWidget);
    expect(find.textContaining('kota bitti'), findsOneWidget);
    expect(find.byType(SubtitleSearchDialog), findsOneWidget);
  });

  testWidgets('Arama hatasında yeniden dene akışı çalışır', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      _host(
        (config, query, languages, hash, size) async {
          attempts++;
          if (attempts == 1) throw Exception('api kızgın');
          return _results();
        },
        (_, _, _) async => '/tmp/altdizi/x.srt',
      ),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    expect(find.text('Altyazı araması başarısız.'), findsOneWidget);
    await tester.tap(find.text('Yeniden dene'));
    await tester.pumpAndSettle();
    expect(find.text('Dizi.S01E01.1080p.TR.srt'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('Sonuç yoksa bilgi görünümü gösterilir', (tester) async {
    await tester.pumpWidget(
      _host((_, _, _, _, _) async => [], (_, _, _) async => '/x'),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    expect(find.text('Bu yayın için altyazı bulunamadı.'), findsOneWidget);
  });

  testWidgets('Son dil çipi kapatılamaz', (tester) async {
    final languages = <List<String>>[];
    await tester.pumpWidget(
      _host(
        (_, _, _, _, _) async => _results(),
        (_, _, _) async => '/x',
        onLanguagesChanged: languages.add,
        initialLanguages: const ['tr'],
      ),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    // Tek seçili dil kapalılamaz: bırakılırsa arama boş dil listesiyle
    // çağırılırdı.
    await tester.tap(find.text('Türkçe'));
    await tester.pumpAndSettle();
    expect(languages, isEmpty);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(languages, [
      ['tr', 'en'],
    ]);
  });

  testWidgets('Sıfır sonuçlu dil seçimi boş arama yapmaz', (tester) async {
    // initialLanguages boş → arama yapılmadan "en az bir dil seçin" kalır.
    var searchCalls = 0;
    await tester.pumpWidget(
      _host(
        (_, _, _, _, _) async {
          searchCalls++;
          return _results();
        },
        (_, _, _) async => '/x',
        initialLanguages: const [],
      ),
    );
    await _open(tester);
    await tester.pumpAndSettle();

    expect(searchCalls, 0);
    expect(find.text('En az bir dil seçin.'), findsOneWidget);
  });
}
