import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../chapter.dart';

const _maxProbeBytes = 8 * 1024 * 1024;

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int? readId() {
    if (offset >= bytes.length) return null;
    final first = bytes[offset];
    if (first == 0) return null;
    var length = 1;
    var mask = 0x80;
    while (length < 4 && (first & mask) == 0) {
      length++;
      mask >>= 1;
    }
    if (offset + length > bytes.length) return null;
    var value = first;
    for (var i = 1; i < length; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    offset += length;
    return value;
  }

  int? readSize() {
    if (offset >= bytes.length) return null;
    final first = bytes[offset];
    var length = 1;
    var mask = 0x80;
    while (length < 8 && (first & mask) == 0) {
      length++;
      mask >>= 1;
    }
    if (offset + length > bytes.length) return null;
    var value = first & (mask - 1);
    for (var i = 1; i < length; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    offset += length;
    if (value == (1 << (7 * length)) - 1) return -1;
    return value;
  }

  int? readUint(int end) {
    if (offset >= end || offset + 8 < end) return null;
    var value = 0;
    while (offset < end) {
      value = (value << 8) | bytes[offset];
      offset++;
    }
    return value;
  }

  String? readString(int end) {
    if (offset > end) return null;
    final slice = bytes.sublist(offset, math.min(end, bytes.length));
    offset = math.min(end, bytes.length);
    return utf8.decode(slice, allowMalformed: true).replaceAll(RegExp(r'\x00+'), '').trim();
  }
}

class _ChapterDraft {
  int? nanos;
  String title = '';
}

const _masterIds = <int>{
  0x1A45DFA3,
  0x18538067,
  0x1043A770,
  0x45B9,
  0xB6,
  0x80,
};

List<Chapter> parseEbmlChapters(Uint8List bytes) {
  final reader = _Reader(bytes);
  final chapters = <Chapter>[];
  _scan(reader, bytes.length, null, chapters);
  chapters.sort((a, b) => a.start.compareTo(b.start));
  return chapters;
}

void _scan(_Reader reader, int end, _ChapterDraft? draft, List<Chapter> chapters) {
  while (reader.offset < end) {
    final id = reader.readId();
    if (id == null) break;
    final size = reader.readSize();
    if (size == null) break;
    final childEnd = size < 0 ? end : math.min(end, reader.offset + size);
    if (id == 0xB6) {
      final next = _ChapterDraft();
      _scan(reader, childEnd, next, chapters);
      final nanos = next.nanos;
      if (nanos != null) {
        chapters.add(
          Chapter(
            start: Duration(microseconds: nanos ~/ 1000),
            title: next.title,
          ),
        );
      }
    } else if (id == 0xF1) {
      final value = reader.readUint(childEnd);
      if (draft != null) draft.nanos = value;
    } else if (id == 0x85) {
      final value = reader.readString(childEnd);
      if (draft != null && value != null && value.isNotEmpty) draft.title = value;
    } else if (_masterIds.contains(id)) {
      _scan(reader, childEnd, draft, chapters);
    }
    reader.offset = childEnd;
  }
}

class _Box {
  _Box(this.type, this.start, this.end);

  final String type;
  final int start;
  final int end;
}

int _be32(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

int _be64(Uint8List bytes, int offset) {
  if (offset + 8 > bytes.length) return 0;
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = (value << 8) | bytes[offset + i];
  }
  return value;
}

List<_Box> _boxes(Uint8List bytes, int start, int end) {
  final result = <_Box>[];
  var offset = start;
  while (offset + 8 <= end && result.length < 10000) {
    var size = _be32(bytes, offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    var header = 8;
    if (size == 1) {
      size = _be64(bytes, offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) break;
    result.add(_Box(type, offset + header, offset + size));
    offset += size;
  }
  return result;
}

_Box? _firstBox(Uint8List bytes, int start, int end, String type) {
  for (final box in _boxes(bytes, start, end)) {
    if (box.type == type) return box;
    if (['moov', 'trak', 'mdia', 'minf', 'stbl'].contains(box.type)) {
      final found = _firstBox(bytes, box.start, box.end, type);
      if (found != null) return found;
    }
  }
  return null;
}

List<Chapter> parseMp4Chapters(Uint8List bytes, {int baseOffset = 0}) {
  final moov = _firstBox(bytes, 0, bytes.length, 'moov');
  if (moov == null) return const [];
  final chapters = <Chapter>[];
  for (final trak in _boxes(bytes, moov.start, moov.end).where((b) => b.type == 'trak')) {
    final mdia = _firstBox(bytes, trak.start, trak.end, 'mdia');
    if (mdia == null) continue;
    final mdhd = _firstBox(bytes, mdia.start, mdia.end, 'mdhd');
    final hdlr = _firstBox(bytes, mdia.start, mdia.end, 'hdlr');
    final stbl = _firstBox(bytes, mdia.start, mdia.end, 'stbl');
    if (mdhd == null || hdlr == null || stbl == null) continue;
    final version = bytes[mdhd.start - 4];
    final timescale = version == 1
        ? _be32(bytes, mdhd.start + 20)
        : _be32(bytes, mdhd.start + 12);
    if (timescale <= 0) continue;
    final handler = String.fromCharCodes(
      bytes.sublist(hdlr.start + 8, math.min(hdlr.start + 12, hdlr.end)),
    );
    final name = String.fromCharCodes(
      bytes.sublist(hdlr.start + 16, hdlr.end),
    ).toLowerCase();
    if (!(handler == 'text' || handler == 'sbtl') || !name.contains('chap')) {
      continue;
    }
    final stts = _firstBox(bytes, stbl.start, stbl.end, 'stts');
    final stsz = _firstBox(bytes, stbl.start, stbl.end, 'stsz');
    final stco = _firstBox(bytes, stbl.start, stbl.end, 'stco') ??
        _firstBox(bytes, stbl.start, stbl.end, 'co64');
    if (stts == null || stsz == null || stco == null) continue;

    final durations = <int>[];
    final sttsCount = _be32(bytes, stts.start + 4);
    var sttsOffset = stts.start + 8;
    for (var i = 0; i < sttsCount && sttsOffset + 8 <= stts.end; i++) {
      final count = _be32(bytes, sttsOffset);
      final delta = _be32(bytes, sttsOffset + 4);
      for (var j = 0; j < count && durations.length < 1000; j++) {
        durations.add(delta);
      }
      sttsOffset += 8;
    }
    final constantSize = _be32(bytes, stsz.start + 4);
    final sampleCount = _be32(bytes, stsz.start + 8);
    var sizes = <int>[];
    if (constantSize > 0) {
      sizes = List<int>.filled(math.min(sampleCount, durations.length), constantSize);
    } else {
      var sizeOffset = stsz.start + 12;
      while (sizes.length < durations.length && sizeOffset + 4 <= stsz.end) {
        sizes.add(_be32(bytes, sizeOffset));
        sizeOffset += 4;
      }
    }
    final chunkCount = _be32(bytes, stco.start + 4);
    final wide = stco.type == 'co64';
    final offsets = <int>[];
    var chunkOffset = stco.start + 8;
    for (var i = 0; i < chunkCount && offsets.length < durations.length; i++) {
      final step = wide ? 8 : 4;
      offsets.add(wide ? _be64(bytes, chunkOffset) : _be32(bytes, chunkOffset));
      chunkOffset += step;
    }
    var elapsed = 0;
    for (var i = 0; i < offsets.length && i < sizes.length; i++) {
      elapsed += durations[i];
      final from = offsets[i] - baseOffset;
      if (from < 0 || from >= bytes.length) continue;
      final to = math.min(bytes.length, from + sizes[i]);
      if (from < 0 || from >= to) continue;
      final marker = _indexOf(bytes, ascii.encode('tx3g'), from, to);
      if (marker < 0 || marker + 10 > to) continue;
      final textLength = bytes[marker + 4] << 8 | bytes[marker + 5];
      if (textLength <= 0 || marker + 6 + textLength > to) continue;
      final title = utf8
          .decode(
            bytes.sublist(marker + 6, marker + 6 + textLength),
            allowMalformed: true,
          )
          .replaceAll(RegExp(r'\x00+'), '')
          .trim();
      if (title.isEmpty) continue;
      chapters.add(
        Chapter(
          start: Duration(
            milliseconds: (elapsed * 1000 / timescale).round(),
          ),
          title: title,
        ),
      );
    }
  }
  chapters.sort((a, b) => a.start.compareTo(b.start));
  return chapters;
}

int _indexOf(Uint8List bytes, List<int> needle, int start, int end) {
  if (needle.isEmpty || end - start < needle.length) return -1;
  for (var i = start; i <= end - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

Future<List<Chapter>> loadStreamChapters(
  String url, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (!url.startsWith('http')) return const [];
  try {
    final uri = Uri.parse(url);
    final head = await http
        .get(uri, headers: <String, String>{'Range': 'bytes=0-${_maxProbeBytes - 1}'})
        .timeout(timeout);
    if (head.statusCode != 206 && head.statusCode != 200) return const [];
    final headBytes = Uint8List.fromList(
      head.bodyBytes.take(_maxProbeBytes).toList(),
    );
    final ebml = parseEbmlChapters(headBytes);
    if (ebml.isNotEmpty) return ebml;
    final mp4 = parseMp4Chapters(headBytes);
    if (mp4.isNotEmpty) return mp4;
    final contentRange = head.headers['content-range'];
    final total = int.tryParse(contentRange?.split('/').last ?? '') ?? 0;
    if (total <= _maxProbeBytes) return const [];
    final tailStart = total - _maxProbeBytes;
    final tail = await http
        .get(uri, headers: <String, String>{'Range': 'bytes=$tailStart-${total - 1}'})
        .timeout(timeout);
    if (tail.statusCode != 206) return const [];
    return parseMp4Chapters(Uint8List.fromList(tail.bodyBytes), baseOffset: tailStart);
  } catch (_) {
    return const [];
  }
}
