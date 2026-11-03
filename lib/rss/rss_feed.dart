import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class RssFeed {
  const RssFeed({required this.id, required this.name, required this.url});

  final String id;
  final String name;

  final String url;

  RssFeed copyWith({String? name, String? url}) =>
      RssFeed(id: id, name: name ?? this.name, url: url ?? this.url);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': url};

  static RssFeed? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final url = value['url'];
    if (id is! String || name is! String || url is! String) return null;
    return RssFeed(id: id, name: name, url: url);
  }
}

class RssTag {
  const RssTag({
    required this.id,
    required this.name,
    required this.pattern,
    this.isRegex = false,
    this.feedIds = const [],
  });

  final String id;
  final String name;

  final String pattern;

  final bool isRegex;

  final List<String> feedIds;

  bool get appliesToAllFeeds => feedIds.isEmpty;

  List<RssFeed> feedsFrom(List<RssFeed> feeds) => appliesToAllFeeds
      ? feeds
      : feeds.where((feed) => feedIds.contains(feed.id)).toList();

  bool matches(String title) {
    if (pattern.isEmpty) return true;
    if (!isRegex) return title.toLowerCase().contains(pattern.toLowerCase());
    final regex = tryCompileRegex(pattern);
    return regex != null && regex.hasMatch(title);
  }

  static RegExp? tryCompileRegex(String pattern) {
    try {
      return RegExp(pattern, caseSensitive: false);
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'isRegex': isRegex,
    'feedIds': feedIds,
  };

  static RssTag? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final pattern = value['pattern'];
    if (id is! String || name is! String || pattern is! String) return null;
    final feedIds = value['feedIds'];
    return RssTag(
      id: id,
      name: name,
      pattern: pattern,
      isRegex: value['isRegex'] == true,
      feedIds: feedIds is List ? feedIds.whereType<String>().toList() : const [],
    );
  }
}

DateTime? newestTagMatch(
  RssTag tag,
  List<RssFeed> feeds,
  Map<String, List<RssItem>> itemsByFeed,
) {
  DateTime? newest;
  for (final feed in tag.feedsFrom(feeds)) {
    for (final item in itemsByFeed[feed.id] ?? const <RssItem>[]) {
      final published = item.published;
      if (published == null || !tag.matches(item.title)) continue;
      if (newest == null || published.isAfter(newest)) newest = published;
    }
  }
  return newest;
}

List<RssTag> sortTagsByFreshness(
  List<RssTag> tags,
  Map<String, DateTime> newestByTag,
  DateTime now,
) {
  int? ageHours(RssTag tag) {
    final newest = newestByTag[tag.id];
    return newest == null ? null : now.difference(newest).inHours;
  }

  return [...tags]..sort((a, b) {
    final ageA = ageHours(a), ageB = ageHours(b);
    if (ageA != ageB) {
      if (ageA == null) return 1;
      if (ageB == null) return -1;
      return ageA.compareTo(ageB);
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

List<RssTag> keepTagOrder(List<RssTag> tags, List<RssTag> previous) {
  final byId = {for (final tag in tags) tag.id: tag};
  final kept = [for (final tag in previous) ?byId.remove(tag.id)];
  return [...kept, ...byId.values];
}

String formatRssAge(DateTime published, DateTime now) {
  final age = now.difference(published);
  if (age.inMinutes < 60) return '${age.inMinutes.clamp(0, 59)}m';
  if (age.inHours < 48) return '${age.inHours}h';
  return '${age.inDays}d';
}

class RssItem {
  const RssItem({
    required this.title,
    required this.nzbUrl,
    required this.feedId,
    this.sizeBytes,
    this.published,
    this.category,
  });

  final String title;
  final String nzbUrl;

  final String feedId;
  final int? sizeBytes;
  final DateTime? published;
  final String? category;
}

List<RssItem> parseRssItems(String body, {required String feedId}) {
  final document = XmlDocument.parse(body);
  final items = <RssItem>[];
  for (final item in document.findAllElements('item')) {
    final title = _childText(item, 'title');
    final enclosure = item.findElements('enclosure').firstOrNull;
    final nzbUrl =
        _nonEmpty(enclosure?.getAttribute('url')) ?? _childText(item, 'link');
    if (title == null || nzbUrl == null) continue;

    int? size;
    for (final attr in item.childElements.where(
      (e) => e.name.local == 'attr',
    )) {
      if (attr.getAttribute('name') == 'size') {
        size = int.tryParse(attr.getAttribute('value') ?? '');
      }
    }
    size ??= int.tryParse(enclosure?.getAttribute('length') ?? '');

    final pubDate = _childText(item, 'pubDate');
    items.add(
      RssItem(
        title: title,
        nzbUrl: nzbUrl,
        feedId: feedId,
        sizeBytes: size != null && size > 0 ? size : null,
        published: pubDate == null ? null : parseRfc822Date(pubDate),
        category: _childText(item, 'category'),
      ),
    );
  }
  return items;
}

String? _childText(XmlElement parent, String name) =>
    _nonEmpty(parent.findElements(name).firstOrNull?.innerText);

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

DateTime? parseRfc822Date(String value) {
  final match = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]+)?',
  ).firstMatch(value);
  if (match == null) return null;
  final month = _months[match.group(2)!.toLowerCase()];
  if (month == null) return null;
  final utc = DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6) ?? '0'),
  );
  final zone = match.group(7);
  if (zone == null || !RegExp(r'^[+-]\d{4}$').hasMatch(zone)) return utc;
  final sign = zone.startsWith('-') ? -1 : 1;
  final offset = Duration(
    hours: int.parse(zone.substring(1, 3)),
    minutes: int.parse(zone.substring(3, 5)),
  );
  return utc.subtract(offset * sign);
}

class RssFeedCache extends ChangeNotifier {
  RssFeedCache({http.Client? client, DateTime Function()? clock})
    : _client = client ?? http.Client(),
      _clock = clock ?? DateTime.now;

  static final shared = RssFeedCache();

  static const ttl = Duration(minutes: 10);
  static const _timeout = Duration(seconds: 20);

  final http.Client _client;
  final DateTime Function() _clock;
  final _entries = <String, ({DateTime fetchedAt, List<RssItem> items})>{};

  Future<List<RssItem>> fetch(RssFeed feed) async {
    final cached = _entries[feed.url];
    if (cached != null && _clock().difference(cached.fetchedAt) < ttl) {
      return _withFeedId(cached.items, feed.id);
    }
    final response = await _client
        .get(Uri.parse(feed.url))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw RssFetchException('HTTP ${response.statusCode}');
    }
    final items = parseRssItems(response.body, feedId: feed.id);
    _entries[feed.url] = (fetchedAt: _clock(), items: items);
    notifyListeners();
    return items;
  }

  List<RssItem>? peek(RssFeed feed) {
    final cached = _entries[feed.url];
    return cached == null ? null : _withFeedId(cached.items, feed.id);
  }

  void invalidate([Iterable<RssFeed>? feeds]) {
    if (feeds == null) {
      _entries.clear();
    } else {
      for (final feed in feeds) {
        _entries.remove(feed.url);
      }
    }
  }

  static List<RssItem> _withFeedId(List<RssItem> items, String feedId) {
    if (items.isEmpty || items.first.feedId == feedId) return items;
    return [
      for (final item in items)
        RssItem(
          title: item.title,
          nzbUrl: item.nzbUrl,
          feedId: feedId,
          sizeBytes: item.sizeBytes,
          published: item.published,
          category: item.category,
        ),
    ];
  }
}

class RssFetchException implements Exception {
  const RssFetchException(this.message);
  final String message;

  @override
  String toString() => message;
}

const _maxFileNameBytes = 200;

const _windowsReservedNames = {
  'con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

String safeNzbFileName(String title, {String suffix = ''}) {
  var name = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  if (name.isEmpty) name = 'download';
  if (_windowsReservedNames.contains(name.split('.').first.toLowerCase())) {
    name = '_$name';
  }
  final limit = _maxFileNameBytes - utf8.encode('$suffix.nzb').length;
  if (utf8.encode(name).length > limit) {
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in name.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (bytes + size > limit) break;
      buffer.write(char);
      bytes += size;
    }
    name = buffer.toString().replaceAll(RegExp(r'[\s.]+$'), '');
  }
  return '$name$suffix.nzb';
}
