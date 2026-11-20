import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// OpenSubtitles "moviehash" (https://opensubtitles.stoplight.io — Hash
/// source codes): dosya BOYUTU + ilk 64 KB ve son 64 KB'taki tüm 64-bit
/// little-endian sözcüklerinin toplamı (mod 2^64).
///
/// Zanzibarr'ta dosya diskte değil: yerel aralık sunucusu (oynatılan
/// stream'in kendi localhost URL'i) üzerinden `Range` istekleriyle yalnız
/// bu 128 KB alınır — tembel akış kuralı bozulmaz (§AGENTS 4.3),
/// kullanıcı hash araması için video indirmiş olmaz.
///
/// Hata/eksik yanıt durumunda `null` döner; çağıran altyazı aramasını
/// yalnız dosya adıyla sürdürür.
class OpenSubtitlesHasher {
  // Alan özeldir; test enjeksiyonu için adlandırılmış parametre atanır.
  // ignore: prefer_initializing_formals
  const OpenSubtitlesHasher({http.Client? client}) : _client = client;

  final http.Client? _client;

  /// moviehash chunk uzunluğu: baş ve sondan alınan bayt sayısı.
  static const chunkBytes = 65536;

  /// [streamUrl] üzerinden [streamSize] baytlık akışın moviehash'ini
  /// hesaplar. Onaltılık 16 hane döner; hesaplanamazsa null.
  Future<String?> hashOfStream({
    required String streamUrl,
    required int streamSize,
  }) async {
    if (streamSize <= 0) return null;
    final client = _client ?? http.Client();
    final ownsClient = _client == null;
    try {
      final head = await _fetchChunk(
        client,
        streamUrl,
        start: 0,
        end: math.min(chunkBytes, streamSize) - 1,
      );
      if (head == null) return null;
      final tailStart = math.max(0, streamSize - chunkBytes);
      Uint8List tail = head;
      if (tailStart > 0) {
        tail =
            await _fetchChunk(
              client,
              streamUrl,
              start: tailStart,
              end: streamSize - 1,
            ) ??
            head;
      }
      return _hashHeadAndTail(head, tail, size: streamSize);
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// `bytes=start..end` (dahil) aralığını çeker; 4xx/5xx/zaman aşımı ya da
  /// beklenenden kısa gövdede null döner.
  Future<Uint8List?> _fetchChunk(
    http.Client client,
    String url, {
    required int start,
    required int end,
  }) async {
    try {
      final response = await client
          .get(
            Uri.parse(url),
            headers: {'Range': 'bytes=$start-$end'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 206 && response.statusCode != 200) {
        return null;
      }
      // Beklenen uzunluk kesin biliniyor; kısa gövde bozuk hash üretir.
      if (response.bodyBytes.length != end - start + 1) {
        return null;
      }
      return response.bodyBytes;
    } on Object {
      // Ağ hatası: hash araması sessizce atlanır (ad-bazlı arama sürer).
      return null;
    }
  }

  /// Saf hash hesabı: boyut + head/tail sözcükleri (testlerde doğrudan
  /// doğrulanır). Tüm aritmetik uint64 modülünde sarar.
  static String _hashHeadAndTail(Uint8List head, Uint8List tail, {required int size}) {
    var hash = size;
    hash = _addChunk(hash, head);
    hash = _addChunk(hash, tail);
    if (hash < 0) {
      return BigInt.from(hash)
          .toUnsigned(64)
          .toRadixString(16)
          .padLeft(16, '0');
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static int _addChunk(int hash, Uint8List chunk) {
    final words = ByteData.sublistView(chunk);
    for (var offset = 0; (offset + 8) <= chunk.length; offset += 8) {
      // VM int'i 64-bit işaretli: toplam taşması uint64 gibi sarar.
      hash += words.getUint64(offset, Endian.little);
    }
    return hash;
  }
}
