class Chapter {
  const Chapter({required this.start, required this.title});

  final Duration start;
  final String title;
}

Future<List<Chapter>> parseChapters({
  required int count,
  required Future<String> Function(String name) chapterProperty,
}) async {
  final chapters = <Chapter>[];
  for (var i = 0; i < count; i++) {
    try {
      final timeRaw = await chapterProperty('chapter-list/$i/time');
      final titleRaw = await chapterProperty('chapter-list/$i/title');
      final time = double.tryParse(timeRaw.trim()) ?? 0.0;
      final title = titleRaw.trim();
      chapters.add(
        Chapter(start: Duration(seconds: time.round()), title: title),
      );
    } catch (_) {}
  }
  return chapters;
}
