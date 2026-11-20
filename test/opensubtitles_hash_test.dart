import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/player/opensubtitles_hash.dart';

/// 128 KB yepyeni dosya: baş ve son 64 KB parçaları ER YA DA GEÇ ayrılır.
const _fileSize = 131072;

/// Test sunucusu: `Range: bytes=a-b` isteklerini gerçek sunucu gibi karşılar
/// (206 + tam dilim); motorun localhost aralık sunucusuyla aynı davranış).
Future<HttpServer> _startRangeServer(Uint8List bytes) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader) ?? '';
    final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
    if (match == null) {
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${bytes.length}',
    );
    request.response.add(bytes.sublist(start, end + 1));
    await request.response.close();
  });
  return server;
}

/// Bağımsız BigInt referansı:moviehash tanımının birebir açıklaması.
/// Paketin int aritmetiği (uint64 sarma) bundan AYRI doğrulanır.
String _referenceHash(Uint8List head, Uint8List tail, int size) {
  var hash = BigInt.from(size);
  BigInt addChunk(BigInt value, Uint8List chunk) {
    final words = ByteData.sublistView(chunk);
    var result = value;
    for (var offset = 0; (offset + 8) <= chunk.length; offset += 8) {
      result += BigInt.from(words.getUint64(offset, Endian.little));
    }
    return result;
  }
  hash = addChunk(hash, head);
  hash = addChunk(hash, tail);
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

Uint8List _syntheticBytes() {
  final random = math.Random(20261120);
  final bytes = Uint8List(_fileSize);
  // Entropi + taşma senaryosu: yüksek değerli sözcükler sarmayı dener.
  for (var i = 0; i < bytes.length; i += 7) {
    bytes[i] = random.nextInt(256);
  }
  for (var i = 0; i < 8; i += 2) {
    bytes[i] = 0xFF;
  }
  bytes[_fileSize - 8] = 0xFF;
  return bytes;
}

void main() {
  test('baş ve son 64 KB üzerinden moviehash BigInt referansıyla uyuşur',
      () async {
    final bytes = _syntheticBytes();
    final server = await _startRangeServer(bytes);
    addTearDown(() => server.close(force: true));

    final hash = await const OpenSubtitlesHasher().hashOfStream(
      streamUrl: 'http://127.0.0.1:${server.port}/video.mkv',
      streamSize: _fileSize,
    );

    final head = bytes.sublist(0, 65536);
    final tail = bytes.sublist(_fileSize - 65536);
    expect(hash, _referenceHash(head, tail, _fileSize));
    expect(hash, hasLength(16));
  });

  test('istek hata verirse hash null döner (ad-bazlı arama sürer)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 404;
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final hash = await const OpenSubtitlesHasher().hashOfStream(
      streamUrl: 'http://127.0.0.1:${server.port}/video.mkv',
      streamSize: _fileSize,
    );
    expect(hash, isNull);
  });

  test('sıfır boyutlu akış hashlenmez', () async {
    expect(
      await const OpenSubtitlesHasher().hashOfStream(
        streamUrl: 'http://127.0.0.1/none',
        streamSize: 0,
      ),
      isNull,
    );
  });

  test('64 KB altı akışta baş ve son aynı parçadır', () async {
    // moviehash tanımına göre dosya ≤ 64 KB ise head == tail tek okumadır.
    final bytes = Uint8List.fromList(List.generate(3000, (i) => i % 251));
    final server = await _startRangeServer(bytes);
    addTearDown(() => server.close(force: true));

    final hash = await const OpenSubtitlesHasher().hashOfStream(
      streamUrl: 'http://127.0.0.1:${server.port}/video.mkv',
      streamSize: bytes.length,
    );
    // tailStart == 0: tek parça iki kez toplanmış gibi (tanımlı davranış).
    expect(hash, _referenceHash(bytes, bytes, bytes.length));
  });
}
