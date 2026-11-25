import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/rss/rss_backup.dart';
import 'package:zanzibarr/rss/rss_feed.dart';
import 'package:zanzibarr/rss/rss_import_export_card.dart';
import 'package:zanzibarr/rss/rss_store.dart';

import 'l10n_test_helper.dart';

class _FakeRssStore extends RssStore {
  _FakeRssStore({List<RssFeed>? feeds, List<RssTag>? tags, List<RssItem>? favorites})
    : feeds = feeds ?? const [],
      tags = tags ?? const [],
      favorites = favorites ?? const [];

  List<RssFeed> feeds;
  List<RssTag> tags;
  List<RssItem> favorites;

  @override
  Future<List<RssFeed>> loadFeeds() async => feeds;

  @override
  Future<List<RssTag>> loadTags() async => tags;

  @override
  Future<List<RssItem>> loadFavorites() async => favorites;

  @override
  Future<void> saveFeeds(List<RssFeed> value) async => feeds = value;

  @override
  Future<void> saveTags(List<RssTag> value) async => tags = value;

  @override
  Future<void> saveFavorites(List<RssItem> value) async => favorites = value;
}

void main() {
  final oldFeed = RssFeed(id: 'old-feed', name: 'Old', url: 'https://old/rss');
  final oldTag = RssTag(id: 'old-tag', name: 'old', pattern: 'old');
  final oldFavorite = RssItem(
    title: 'Old favorite',
    nzbUrl: 'https://old/nzb',
    feedId: 'old-feed',
  );

  final newFeed = RssFeed(id: 'new-feed', name: 'New', url: 'https://new/rss');
  final newTagA = RssTag(id: 'a', name: 'a', pattern: 'a');
  final newTagB = RssTag(id: 'b', name: 'b', pattern: 'b');
  final newFavorite = RssItem(
    title: 'New favorite',
    nzbUrl: 'https://new/nzb',
    feedId: 'new-feed',
  );

  RssBackup makeBackup() => RssBackup(
    feeds: [newFeed],
    tags: [newTagA, newTagB],
    favorites: [newFavorite],
  );

  Future<void> pumpCard(
    WidgetTester tester, {
    required _FakeRssStore store,
    Future<String?> Function()? pickFile,
    Future<String?> Function(String)? saveFile,
  }) async {
    await tester.pumpWithL10n(
      Scaffold(
        body: SingleChildScrollView(
          child: RssImportExportCard(
            store: store,
            pickFile: pickFile,
            saveFile: saveFile,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('export writes all three lists as JSON', (tester) async {
    final store = _FakeRssStore(
      feeds: [oldFeed],
      tags: [oldTag],
      favorites: [oldFavorite],
    );
    String? written;
    await pumpCard(
      tester,
      store: store,
      saveFile: (content) async {
        written = content;
        return '/tmp/rss.json';
      },
    );

    await tester.tap(find.text('JSON olarak dışa aktar'));
    await tester.pumpAndSettle();

    expect(written, isNotNull);
    final decoded = jsonDecode(written!) as Map<String, dynamic>;
    expect((decoded['feeds'] as List).single, oldFeed.toJson());
    expect((decoded['tags'] as List).single, oldTag.toJson());
    expect((decoded['favorites'] as List).single, oldFavorite.toJson());
    expect(find.text('/tmp/rss.json konumuna aktarıldı'), findsOneWidget);
  });

  testWidgets('import asks with checkboxes and replaces only checked groups', (
    tester,
  ) async {
    final store = _FakeRssStore(
      feeds: [oldFeed],
      tags: [oldTag],
      favorites: [oldFavorite],
    );
    await pumpCard(
      tester,
      store: store,
      pickFile: () async => RssBackup.encode(makeBackup()),
    );

    await tester.tap(find.text("JSON'dan içe aktar"));
    await tester.pumpAndSettle();

    expect(find.text('Beslemeler (1)'), findsOneWidget);
    expect(find.text('Etiketler (2)'), findsOneWidget);
    expect(find.text('Favoriler (1)'), findsOneWidget);

    await tester.tap(find.text('Etiketler (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('İçe aktar'));
    await tester.pumpAndSettle();

    expect(store.feeds.single.id, 'new-feed');
    expect(store.tags.single.id, 'old-tag');
    expect(store.favorites.single.title, 'New favorite');
    expect(find.text('RSS verileri içe aktarıldı'), findsOneWidget);
  });

  testWidgets('import cancel leaves data untouched', (tester) async {
    final store = _FakeRssStore(feeds: [oldFeed], tags: [oldTag]);
    await pumpCard(
      tester,
      store: store,
      pickFile: () async => RssBackup.encode(makeBackup()),
    );

    await tester.tap(find.text("JSON'dan içe aktar"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(store.feeds.single.id, 'old-feed');
    expect(store.tags.single.id, 'old-tag');
    expect(store.favorites, isEmpty);
  });

  testWidgets('invalid JSON shows an error and keeps data', (tester) async {
    final store = _FakeRssStore(feeds: [oldFeed]);
    await pumpCard(
      tester,
      store: store,
      pickFile: () async => jsonEncode({'hello': 'world'}),
    );

    await tester.tap(find.text("JSON'dan içe aktar"));
    await tester.pumpAndSettle();

    expect(
      find.text('Dosya geçerli bir RSS yedeği değil'),
      findsOneWidget,
    );
    expect(store.feeds.single.id, 'old-feed');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('confirm is disabled when every checkbox is cleared', (
    tester,
  ) async {
    final store = _FakeRssStore();
    await pumpCard(
      tester,
      store: store,
      pickFile: () async => RssBackup.encode(makeBackup()),
    );

    await tester.tap(find.text("JSON'dan içe aktar"));
    await tester.pumpAndSettle();
    for (final label in ['Beslemeler (1)', 'Etiketler (2)', 'Favoriler (1)']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'İçe aktar'),
    );
    expect(confirm.onPressed, isNull);
  });

  test('mobile backup file name carries local date, time and milliseconds', () {
    expect(
      RssImportExportCard.stampedBackupName(
        DateTime(2026, 11, 25, 6, 2, 3, 456),
      ),
      'zanzibarr-rss-backup-20261125_060203-456.json',
    );
  });
}
