import 'package:flutter_test/flutter_test.dart';

import 'package:zanzibarr/player/chapter.dart';

void main() {
  test('parseChapters parses the chapter list from mpv properties', () async {
    final properties = <String, String>{
      'chapter-list/count': '2',
      'chapter-list/0/time': '10.0',
      'chapter-list/0/title': 'Intro',
      'chapter-list/1/time': '60.0',
      'chapter-list/1/title': 'Main',
    };

    final chapters = await parseChapters(
      count: 2,
      chapterProperty: (name) async => properties[name] ?? '',
    );

    expect(chapters, hasLength(2));
    expect(chapters[0].start, const Duration(seconds: 10));
    expect(chapters[0].title, 'Intro');
    expect(chapters[1].start, const Duration(seconds: 60));
    expect(chapters[1].title, 'Main');
  });

  test('parseChapters skips unreadable chapters', () async {
    final properties = <String, String>{
      'chapter-list/count': '2',
      'chapter-list/0/time': '10.0',
      'chapter-list/0/title': 'Intro',
    };

    final chapters = await parseChapters(
      count: 2,
      chapterProperty: (name) async {
        if (name.contains('/1/')) {
          throw Exception('chapter 1 is unreadable');
        }
        return properties[name] ?? '';
      },
    );

    expect(chapters, hasLength(1));
    expect(chapters[0].title, 'Intro');
  });

  test('parseChapters returns empty list when count is zero', () async {
    final chapters = await parseChapters(
      count: 0,
      chapterProperty: (name) async => '',
    );

    expect(chapters, isEmpty);
  });
}
