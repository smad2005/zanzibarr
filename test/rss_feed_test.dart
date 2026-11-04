import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zanzibarr/rss/rss_feed.dart';

const _newznabFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
<channel><title>usenet-crawler</title>
<item>
<title>Mathew Jonson-Typerope EP-IIWII007-16BIT-WEB-FLAC-2003-BABAS-FTP</title><guid isPermaLink="true">https://www.usenet-crawler.com/details/02f447f0a995da75cc0f17c7f2023e53</guid><link>https://www.usenet-crawler.com/getnzb/02f447f0a995da75cc0f17c7f2023e53.nzb</link><pubDate>Tue, 03 Nov 2026 04:38:49 +0100</pubDate><category>Console &gt; Wii</category><description><![CDATA[ <div>Size: 117.17 MB</div> ]]></description><enclosure url="https://www.usenet-crawler.com/getnzb/02f447f0a995da75cc0f17c7f2023e53.nzb" length="122862488" type="application/x-nzb"/><newznab:attr name="category" value="1030"/><newznab:attr name="size" value="122862488"/>
</item>
</channel></rss>''';

const _enclosureOnlyFeed = '''<?xml version="1.0"?>
<rss version="2.0"><channel>
<item><title>[Group] Show - 01 [1080p]</title><link>https://example.org/view/1</link>
<enclosure url="https://example.org/1.nzb" length="1500000000" type="application/x-nzb"/>
<pubDate>Mon, 02 Nov 2026 22:00:00 GMT</pubDate></item>
<item><title>No NZB here</title></item>
</channel></rss>''';

void main() {
  group('parseRssItems', () {
    test('newznab RSS: enclosure, boyut, tarih, kategori', () {
      final items = parseRssItems(_newznabFeed, feedId: 'f1');
      expect(items, hasLength(1));
      final item = items.single;
      expect(item.title, startsWith('Mathew Jonson-Typerope'));
      expect(
        item.nzbUrl,
        'https://www.usenet-crawler.com/getnzb/02f447f0a995da75cc0f17c7f2023e53.nzb',
      );
      expect(item.sizeBytes, 122862488);
      expect(item.published, DateTime.utc(2026, 11, 3, 3, 38, 49));
      expect(item.category, 'Console > Wii');
      expect(item.feedId, 'f1');
    });

    test('enclosure boyutu kullanılır, NZB adresi olmayan öğe atlanır', () {
      final items = parseRssItems(_enclosureOnlyFeed, feedId: 'f2');
      expect(items, hasLength(1));
      expect(items.single.nzbUrl, 'https://example.org/1.nzb');
      expect(items.single.sizeBytes, 1500000000);
      expect(items.single.published, DateTime.utc(2026, 11, 2, 22));
    });
  });

  group('RssTag.matches', () {
    test('alt dize araması büyük/küçük harf duyarsız', () {
      const tag = RssTag(id: 't', name: 'flac', pattern: 'FLAC');
      expect(tag.matches('Album-WEB-flac-2003'), isTrue);
      expect(tag.matches('Album-WEB-MP3'), isFalse);
    });

    test('regex araması', () {
      const tag = RssTag(
        id: 't',
        name: '1080p',
        pattern: r'\b(1080p|2160p)\b',
        isRegex: true,
      );
      expect(tag.matches('[Group] Show - 01 [1080p]'), isTrue);
      expect(tag.matches('[Group] Show - 01 [720p]'), isFalse);
    });

    test('geçersiz regex hiçbir şeyle eşleşmez', () {
      const tag = RssTag(id: 't', name: 'bad', pattern: '(', isRegex: true);
      expect(RssTag.tryCompileRegex('('), isNull);
      expect(tag.matches('anything'), isFalse);
    });

    test('feedsFrom: boş liste tüm beslemeler demektir', () {
      const a = RssFeed(id: 'a', name: 'A', url: 'https://a');
      const b = RssFeed(id: 'b', name: 'B', url: 'https://b');
      const all = RssTag(id: 't', name: 'x', pattern: 'x');
      const onlyB = RssTag(id: 't', name: 'x', pattern: 'x', feedIds: ['b']);
      expect(all.feedsFrom([a, b]), [a, b]);
      expect(onlyB.feedsFrom([a, b]), [b]);
    });
  });

  group('RssFeedCache', () {
    const feed = RssFeed(id: 'f', name: 'F', url: 'https://feed.example/rss');

    test('10 dakika içinde ağ isteği tekrarlanmaz, sonra yenilenir', () async {
      var requests = 0;
      var now = DateTime(2026, 11, 3, 12);
      final cache = RssFeedCache(
        client: MockClient((_) async {
          requests++;
          return http.Response(_enclosureOnlyFeed, 200);
        }),
        clock: () => now,
      );

      await cache.fetch(feed);
      now = now.add(const Duration(minutes: 9));
      await cache.fetch(feed);
      expect(requests, 1);

      now = now.add(const Duration(minutes: 2));
      await cache.fetch(feed);
      expect(requests, 2);
    });

    test('invalidate önbelleği hemen düşürür', () async {
      var requests = 0;
      final cache = RssFeedCache(
        client: MockClient((_) async {
          requests++;
          return http.Response(_enclosureOnlyFeed, 200);
        }),
      );
      await cache.fetch(feed);
      cache.invalidate([feed]);
      await cache.fetch(feed);
      expect(requests, 2);
    });

    test('HTTP hatası istisna olarak döner', () async {
      final cache = RssFeedCache(
        client: MockClient((_) async => http.Response('nope', 503)),
      );
      expect(cache.fetch(feed), throwsA(isA<RssFetchException>()));
    });

    test('notifies only on fresh network data, peek makes no request', () async {
      var requests = 0;
      var notifications = 0;
      final cache = RssFeedCache(
        client: MockClient((_) async {
          requests++;
          return http.Response(_enclosureOnlyFeed, 200);
        }),
      )..addListener(() => notifications++);

      expect(cache.peek(feed), isNull);
      await cache.fetch(feed);
      await cache.fetch(feed);
      expect(notifications, 1);

      const renamed = RssFeed(id: 'g', name: 'G', url: 'https://feed.example/rss');
      expect(cache.peek(renamed)!.single.feedId, 'g');
      expect(requests, 1);
    });
  });

  group('safeNzbFileName', () {
    test('запрещённые символы заменяются', () {
      expect(
        safeNzbFileName(r'AC/DC: Back\In*Black? "Live" <1980>|'),
        'AC_DC_ Back_In_Black_ _Live_ _1980__.nzb',
      );
    });

    test('точки и пробелы по краям убираются, пустое имя заменяется', () {
      expect(safeNzbFileName('  ..Show.  '), 'Show.nzb');
      expect(safeNzbFileName(' / '), '_.nzb');
      expect(safeNzbFileName('...'), 'download.nzb');
    });

    test('зарезервированные имена Windows', () {
      expect(safeNzbFileName('CON'), '_CON.nzb');
      expect(safeNzbFileName('nul.txt'), '_nul.txt.nzb');
      expect(safeNzbFileName('Console'), 'Console.nzb');
    });

    test('длина ограничена в байтах UTF-8, суррогатные пары не режутся', () {
      final japanese = safeNzbFileName('進撃の巨人' * 60);
      expect(utf8.encode(japanese).length, lessThanOrEqualTo(200));
      expect(japanese, endsWith('.nzb'));

      final emoji = safeNzbFileName('a${'😀' * 100}');
      expect(utf8.encode(emoji).length, lessThanOrEqualTo(200));
      expect(emoji.runes.where((r) => r >= 0xD800 && r <= 0xDFFF), isEmpty);
    });

    test('суффикс для одинаковых имён помещается в лимит', () {
      final name = safeNzbFileName('x' * 300, suffix: ' (12)');
      expect(name, endsWith(' (12).nzb'));
      expect(utf8.encode(name).length, lessThanOrEqualTo(200));
    });
  });

  group('tag freshness', () {
    RssItem item(String title, String feedId, DateTime? published) => RssItem(
      title: title,
      nzbUrl: 'https://example.org/$title.nzb',
      feedId: feedId,
      published: published,
    );

    const feeds = [
      RssFeed(id: 'a', name: 'A', url: 'https://a'),
      RssFeed(id: 'b', name: 'B', url: 'https://b'),
    ];

    test('newestTagMatch picks the newest matching item from the tag feeds', () {
      final itemsByFeed = {
        'a': [
          item('Show 01', 'a', DateTime.utc(2026, 11, 1, 10)),
          item('Show 02', 'a', DateTime.utc(2026, 11, 3, 10)),
          item('Other', 'a', DateTime.utc(2026, 11, 4, 10)),
        ],
        'b': [item('Show 03', 'b', DateTime.utc(2026, 11, 4, 9))],
      };
      const all = RssTag(id: 't1', name: 'show', pattern: 'show');
      const onlyA = RssTag(id: 't2', name: 'show', pattern: 'show', feedIds: ['a']);
      const none = RssTag(id: 't3', name: 'none', pattern: 'zzz');

      expect(newestTagMatch(all, feeds, itemsByFeed), DateTime.utc(2026, 11, 4, 9));
      expect(newestTagMatch(onlyA, feeds, itemsByFeed), DateTime.utc(2026, 11, 3, 10));
      expect(newestTagMatch(none, feeds, itemsByFeed), isNull);
    });

    test('sortTagsByFreshness puts fresh tags first, ties and undated by name', () {
      final now = DateTime.utc(2026, 11, 4, 12);
      const tags = [
        RssTag(id: '1', name: 'zeta', pattern: 'z'),
        RssTag(id: '2', name: 'Alpha', pattern: 'a'),
        RssTag(id: '3', name: 'old', pattern: 'o'),
        RssTag(id: '4', name: 'beta', pattern: 'b'),
        RssTag(id: '5', name: 'empty-b', pattern: 'e'),
        RssTag(id: '6', name: 'empty-a', pattern: 'e'),
      ];
      final newest = {
        '1': now.subtract(const Duration(minutes: 10)),
        '2': now.subtract(const Duration(minutes: 50)),
        '3': now.subtract(const Duration(days: 3)),
        '4': now.subtract(const Duration(hours: 2)),
      };

      final sorted = sortTagsByFreshness(tags, newest, now);

      expect(
        sorted.map((t) => t.name),
        ['Alpha', 'zeta', 'beta', 'old', 'empty-a', 'empty-b'],
      );
      expect(tags.first.name, 'zeta');
    });

    test('keepTagOrder keeps previous order, appends new, drops removed', () {
      const a = RssTag(id: 'a', name: 'a', pattern: 'a');
      const b = RssTag(id: 'b', name: 'b', pattern: 'b');
      const c = RssTag(id: 'c', name: 'c', pattern: 'c');
      const bRenamed = RssTag(id: 'b', name: 'b2', pattern: 'b');
      const d = RssTag(id: 'd', name: 'd', pattern: 'd');

      final kept = keepTagOrder([a, bRenamed, d], [c, b, a]);

      expect(kept.map((t) => t.name), ['b2', 'a', 'd']);
    });

    test('formatRssAge uses minutes, hours up to 48, then days', () {
      final now = DateTime.utc(2026, 11, 4, 12);
      expect(formatRssAge(now.subtract(const Duration(minutes: 5)), now), '5m');
      expect(formatRssAge(now.subtract(const Duration(hours: 47)), now), '47h');
      expect(formatRssAge(now.subtract(const Duration(days: 3)), now), '3d');
      expect(formatRssAge(now.add(const Duration(minutes: 5)), now), '0m');
    });
  });

  group('favorites', () {
    RssItem item(String title, {String feedId = 'a', String url = 'u'}) =>
        RssItem(title: title, nzbUrl: url, feedId: feedId);

    test('item survives a JSON round trip', () {
      final original = RssItem(
        title: 'Show.S01E01.1080p',
        nzbUrl: 'https://example.test/getnzb/1.nzb',
        feedId: 'feed-1',
        sizeBytes: 1503238553,
        published: DateTime.utc(2026, 11, 3, 4, 38, 49),
        category: 'TV > HD',
      );
      final restored = RssItem.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      )!;
      expect(restored.title, original.title);
      expect(restored.nzbUrl, original.nzbUrl);
      expect(restored.feedId, original.feedId);
      expect(restored.sizeBytes, original.sizeBytes);
      expect(restored.published, original.published);
      expect(restored.category, original.category);
    });

    test('item without optional fields round trips and bad input is rejected',
        () {
      final restored = RssItem.fromJson(item('Bare').toJson())!;
      expect(restored.sizeBytes, isNull);
      expect(restored.published, isNull);
      expect(restored.category, isNull);
      expect(RssItem.fromJson({'title': 'x'}), isNull);
      expect(RssItem.fromJson('nope'), isNull);
    });

    test('toggle adds new favorites first', () {
      final first = toggleRssFavorite(const [], item('One', url: '1'));
      final second = toggleRssFavorite(first, item('Two', url: '2'));
      expect(second.map((e) => e.title), ['Two', 'One']);
    });

    test('toggle removes an existing favorite', () {
      final favorites = [item('One', url: '1'), item('Two', url: '2')];
      expect(
        toggleRssFavorite(favorites, item('One', url: '1')).map((e) => e.title),
        ['Two'],
      );
    });

    test('same NZB link from the same feed is a duplicate', () {
      final favorites = [item('Old title', feedId: 'a', url: 'x')];
      expect(
        toggleRssFavorite(favorites, item('New title', feedId: 'a', url: 'x')),
        isEmpty,
      );
    });

    test('same NZB link from another feed is a separate favorite', () {
      final favorites = [item('Show', feedId: 'a', url: 'x')];
      final toggled = toggleRssFavorite(
        favorites,
        item('Show', feedId: 'b', url: 'x'),
      );
      expect(toggled.map((e) => e.feedId), ['b', 'a']);
    });

    test('same title with another NZB link is a separate favorite', () {
      final favorites = [item('Show', feedId: 'a', url: 'x')];
      expect(
        toggleRssFavorite(favorites, item('Show', feedId: 'a', url: 'y')),
        hasLength(2),
      );
    });
  });
}
