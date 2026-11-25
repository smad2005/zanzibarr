import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/rss/rss_backup.dart';
import 'package:zanzibarr/rss/rss_feed.dart';

void main() {
  final feed = RssFeed(id: 'f1', name: 'Feed', url: 'https://example.com/rss');
  final tag = RssTag(
    id: 't1',
    name: '1080p',
    pattern: '1080p',
    feedIds: ['f1'],
  );
  final favorite = RssItem(
    title: 'Release',
    nzbUrl: 'https://example.com/nzb/1',
    feedId: 'f1',
    sizeBytes: 1234,
    published: DateTime.utc(2026, 11, 25, 10, 30),
    category: 'TV',
  );

  group('RssBackup', () {
    test('round-trips feeds, tags and favorites', () {
      final backup = RssBackup(
        feeds: [feed],
        tags: [tag],
        favorites: [favorite],
      );
      final raw = RssBackup.encode(backup);
      final decoded = RssBackup.decode(raw);

      expect(decoded, isNotNull);
      expect(decoded!.feeds.single.toJson(), feed.toJson());
      expect(decoded.tags.single.toJson(), tag.toJson());
      expect(decoded.favorites.single.toJson(), favorite.toJson());
      expect(decoded.favorites.single.published, favorite.published);
      expect(decoded.favorites.single.sizeBytes, 1234);
    });

    test('writes a versioned, human-readable envelope', () {
      final decoded = jsonDecode(
        RssBackup.encode(RssBackup(feeds: [feed])),
      ) as Map<String, dynamic>;

      expect(decoded['format'], 'zanzibarr-rss');
      expect(decoded['version'], 1);
      expect(decoded['feeds'], isA<List>());
      expect(decoded['tags'], isEmpty);
      expect(decoded['favorites'], isEmpty);
    });

    test('skips broken entries and ignores unknown keys', () {
      final decoded = RssBackup.decode(
        jsonEncode({
          'format': 'zanzibarr-rss',
          'version': 1,
          'unknown': 'ignored',
          'feeds': [
            feed.toJson(),
            {'id': 5, 'name': 'bad', 'url': 'x'},
          ],
          'tags': [
            tag.toJson(),
            const {'id': 'bad'},
          ],
          'favorites': [
            favorite.toJson(),
            {'title': 'bad'},
          ],
        }),
      );

      expect(decoded!.feeds.single.toJson(), feed.toJson());
      expect(decoded.tags.single.toJson(), tag.toJson());
      expect(decoded.favorites.single.toJson(), favorite.toJson());
    });

    test('accepts a partial backup (only selected lists present)', () {
      final decoded = RssBackup.decode(
        jsonEncode({'favorites': [favorite.toJson()]}),
      );

      expect(decoded!.feeds, isEmpty);
      expect(decoded.tags, isEmpty);
      expect(decoded.favorites.single.toJson(), favorite.toJson());
    });

    test('rejects invalid JSON, non-objects and files without lists', () {
      expect(RssBackup.decode('{not json'), isNull);
      expect(RssBackup.decode('[]'), isNull);
      expect(RssBackup.decode('"text"'), isNull);
      expect(RssBackup.decode(jsonEncode({'hello': 'world'})), isNull);
      expect(RssBackup.fromJson(null), isNull);
    });
  });
}
