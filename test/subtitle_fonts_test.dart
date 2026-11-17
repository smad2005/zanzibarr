import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/player/subtitle_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fallback fonts extend assets without changing the picker catalog', () {
    expect(kSubtitleFonts.map((font) => font.id), ['sans', 'serif', 'mono']);
    expect(
      kSubtitleFontAssets.map((font) => font.id),
      ['sans', 'serif', 'mono', 'arabic_sans', 'arabic_serif'],
    );
    expect(
      kSubtitleFallbackFonts.map((font) => font.family),
      ['Noto Sans Arabic', 'Noto Naskh Arabic'],
    );
  });

  test('Arabic fallback assets contain real Arabic glyphs', () async {
    const codepoints = [0x0633, 0x0644, 0x0627, 0x0645, 0x0646, 0x064A];
    for (final font in kSubtitleFallbackFonts) {
      final data = await rootBundle.load(font.asset);
      final bytes = ByteData.sublistView(data);
      for (final codepoint in codepoints) {
        expect(
          _hasGlyph(bytes, codepoint),
          isTrue,
          reason: '${font.family} is missing U+${codepoint.toRadixString(16)}',
        );
      }
    }
  });

  test('resolver extracts every selected and fallback font', () async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final support = await Directory.systemTemp.createTemp('subtitle-fonts-test');
    messenger.setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await support.delete(recursive: true);
    });

    final target = await AssetSubtitleFontResolver().resolve('sans');

    expect(target.family, 'Noto Sans');
    for (final font in kSubtitleFontAssets) {
      final file = File('${support.path}/subtitle_fonts/${font.id}.ttf');
      final data = await rootBundle.load(font.asset);
      expect(file.existsSync(), isTrue, reason: '${font.id} was not extracted');
      expect(file.lengthSync(), data.lengthInBytes, reason: '${font.id} is incomplete');
    }
  });
}

bool _hasGlyph(ByteData bytes, int codepoint) {
  final cmap = _table(bytes, 'cmap');
  final records = _u16(bytes, cmap + 2);
  for (var index = 0; index < records; index++) {
    final record = cmap + 4 + index * 8;
    final subtable = cmap + _u32(bytes, record + 4);
    final format = _u16(bytes, subtable);
    if (format == 4 && _hasGlyphFormat4(bytes, subtable, codepoint)) {
      return true;
    }
    if (format == 12 && _hasGlyphFormat12(bytes, subtable, codepoint)) {
      return true;
    }
  }
  return false;
}

bool _hasGlyphFormat4(ByteData bytes, int table, int codepoint) {
  final segments = _u16(bytes, table + 6) ~/ 2;
  final ends = table + 14;
  final starts = ends + segments * 2;
  final deltas = starts + segments * 2;
  final rangeOffsets = deltas + segments * 2;
  for (var segment = 0; segment < segments; segment++) {
    final start = _u16(bytes, starts + segment * 2);
    final end = _u16(bytes, ends + segment * 2);
    if (codepoint < start || codepoint > end) continue;
    final delta = _u16(bytes, deltas + segment * 2);
    final rangeOffsetAddress = rangeOffsets + segment * 2;
    final rangeOffset = _u16(bytes, rangeOffsetAddress);
    if (rangeOffset == 0) {
      return (codepoint + delta) & 0xFFFF != 0;
    }
    final glyphAddress =
        rangeOffsetAddress + rangeOffset + (codepoint - start) * 2;
    final glyph = _u16(bytes, glyphAddress);
    return glyph != 0 && (glyph + delta) & 0xFFFF != 0;
  }
  return false;
}

bool _hasGlyphFormat12(ByteData bytes, int table, int codepoint) {
  final groups = _u32(bytes, table + 12);
  for (var group = 0; group < groups; group++) {
    final address = table + 16 + group * 12;
    final start = _u32(bytes, address);
    final end = _u32(bytes, address + 4);
    if (codepoint >= start && codepoint <= end) {
      return _u32(bytes, address + 8) != 0;
    }
  }
  return false;
}

int _table(ByteData bytes, String tag) {
  final tables = _u16(bytes, 4);
  for (var index = 0; index < tables; index++) {
    final record = 12 + index * 16;
    final name = String.fromCharCodes([
      for (var offset = 0; offset < 4; offset++) bytes.getUint8(record + offset),
    ]);
    if (name == tag) return _u32(bytes, record + 8);
  }
  throw StateError('TTF table not found: $tag');
}

int _u16(ByteData bytes, int offset) => bytes.getUint16(offset, Endian.big);

int _u32(ByteData bytes, int offset) => bytes.getUint32(offset, Endian.big);
