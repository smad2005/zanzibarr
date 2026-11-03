import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'rss_feed.dart';

class RssStore {
  RssStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kFeeds = 'rss.feeds';
  static const _kTags = 'rss.tags';

  Future<List<RssFeed>> loadFeeds() async =>
      _decodeList(await _storage.read(key: _kFeeds), RssFeed.fromJson);

  Future<List<RssTag>> loadTags() async =>
      _decodeList(await _storage.read(key: _kTags), RssTag.fromJson);

  Future<void> saveFeeds(List<RssFeed> feeds) => _storage.write(
    key: _kFeeds,
    value: jsonEncode([for (final feed in feeds) feed.toJson()]),
  );

  Future<void> saveTags(List<RssTag> tags) => _storage.write(
    key: _kTags,
    value: jsonEncode([for (final tag in tags) tag.toJson()]),
  );

  static List<T> _decodeList<T>(String? raw, T? Function(Object?) fromJson) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.map(fromJson).whereType<T>().toList();
    } on FormatException {
      return [];
    }
  }
}
