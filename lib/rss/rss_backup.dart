import 'dart:convert';

import 'rss_feed.dart';

class RssBackup {
  const RssBackup({
    this.feeds = const [],
    this.tags = const [],
    this.favorites = const [],
  });

  final List<RssFeed> feeds;
  final List<RssTag> tags;
  final List<RssItem> favorites;

  static const format = 'zanzibarr-rss';
  static const version = 1;

  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'feeds': [for (final feed in feeds) feed.toJson()],
    'tags': [for (final tag in tags) tag.toJson()],
    'favorites': [for (final item in favorites) item.toJson()],
  };

  static RssBackup? fromJson(Object? value) {
    if (value is! Map) return null;
    final feeds = _decode(value['feeds'], RssFeed.fromJson);
    final tags = _decode(value['tags'], RssTag.fromJson);
    final favorites = _decode(value['favorites'], RssItem.fromJson);
    if (feeds == null && tags == null && favorites == null) return null;
    return RssBackup(
      feeds: feeds ?? const [],
      tags: tags ?? const [],
      favorites: favorites ?? const [],
    );
  }

  static List<T>? _decode<T>(Object? value, T? Function(Object?) fromJson) {
    if (value is! List) return null;
    return value.map(fromJson).whereType<T>().toList(growable: false);
  }

  static String encode(RssBackup backup) =>
      const JsonEncoder.withIndent('  ').convert(backup.toJson());

  static RssBackup? decode(String raw) {
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }
}
