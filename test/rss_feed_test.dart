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
}
