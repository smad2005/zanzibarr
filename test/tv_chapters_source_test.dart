import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/player/tv/chapters_source.dart';

List<int> _uint64(int value) => [
      (value >> 56) & 0xFF,
      (value >> 48) & 0xFF,
      (value >> 40) & 0xFF,
      (value >> 32) & 0xFF,
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> _element(List<int> id, List<int> body) => [
      ...id,
      0x80 | body.length,
      ...body,
    ];

void main() {
  test('parses Matroska chapter atoms from an EBML probe', () {
    final text = utf8.encode('Intro');
    final chapterString = _element([0x85], text);
    final display = _element([0x80], chapterString);
    final start = _element([0xF1], _uint64(5000000000));
    final atom = _element([0xB6], [...start, ...display]);
    final edition = _element([0x45, 0xB9], atom);
    final chapters = _element([0x10, 0x43, 0xA7, 0x70], edition);
    final segment = _element([0x18, 0x53, 0x80, 0x67], chapters);

    final parsed = parseEbmlChapters(Uint8List.fromList(segment));
    expect(parsed, hasLength(1));
    expect(parsed.single.start, const Duration(seconds: 5));
    expect(parsed.single.title, 'Intro');
  });
}
