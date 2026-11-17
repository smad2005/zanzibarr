import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Altyazı font kataloğu. TTF'ler `assets/fonts/` altında paketlenir (OFL);
/// libmpv/fontconfig'e verilmeden önce uygulama destek dizinine çıkarılır
/// (Android'de fontconfig yok; tüm platformlarda aynı yol kullanılır).
class SubtitleFont {
  const SubtitleFont({
    required this.id,
    required this.asset,
    required this.family,
  });

  /// Tercih deposunda tutulan kimlik (`sans`/`serif`/`mono`).
  final String id;

  /// Paket içi asset yolu.
  final String asset;

  /// Fontun iç aile adı — mpv `sub-font` değeri bu olmalı.
  final String family;
}

const kSubtitleFonts = <SubtitleFont>[
  SubtitleFont(
    id: 'sans',
    asset: 'assets/fonts/subtitle.ttf',
    family: 'Noto Sans',
  ),
  SubtitleFont(
    id: 'serif',
    asset: 'assets/fonts/subtitle_serif.ttf',
    family: 'Noto Serif',
  ),
  SubtitleFont(
    id: 'mono',
    asset: 'assets/fonts/subtitle_mono.ttf',
    family: 'Noto Sans Mono',
  ),
];

/// Seçici dışı fontconfig fallback fontları. Seçili ana fontta bulunmayan
/// Arapça gliflerin kare yerine bu ailelerden alınmasını sağlar; kullanıcıya
/// ayrıca bir dil/font seçtirmek gerekmez.
const kSubtitleFallbackFonts = <SubtitleFont>[
  SubtitleFont(
    id: 'arabic_sans',
    asset: 'assets/fonts/subtitle_arabic_sans.ttf',
    family: 'Noto Sans Arabic',
  ),
  SubtitleFont(
    id: 'arabic_serif',
    asset: 'assets/fonts/subtitle_arabic_serif.ttf',
    family: 'Noto Naskh Arabic',
  ),
];

/// Resolver'ın `sub-fonts-dir` dizinine çıkardığı tüm fontlar. Seçili ana
/// fontlar ve onların eksik gliflerini karşılayan fallback'ler birlikte
/// bulunmalı ki libass/fontconfig Arapça metni de doğru işleyebilsin.
const kSubtitleFontAssets = <SubtitleFont>[
  ...kSubtitleFonts,
  ...kSubtitleFallbackFonts,
];

const kDefaultSubtitleFontId = 'sans';

/// Kimliği bilinen fonta çözer; bilinmeyen kimlik varsayılana düşer.
SubtitleFont subtitleFontFor(String id) {
  for (final font in kSubtitleFonts) {
    if (font.id == id) return font;
  }
  return kSubtitleFonts.first;
}

/// Çözülmüş hedef: mpv `sub-fonts-dir` dizini + `sub-font` aile adı.
class SubtitleFontTarget {
  const SubtitleFontTarget({required this.fontsDir, required this.family});

  final String fontsDir;
  final String family;
}

/// Font asset'lerini diske çıkarıp mpv hedefini üretir. Testlerde sahte
/// uygulama enjekte edilir (asset/disk erişimi olmadan).
abstract class SubtitleFontResolver {
  Future<SubtitleFontTarget> resolve(String id);
}

class AssetSubtitleFontResolver implements SubtitleFontResolver {
  @override
  Future<SubtitleFontTarget> resolve(String id) async {
    final font = subtitleFontFor(id);
    final dir = await _fontsDirectory();
    // Seçili fontun yanında fallback'ler de her zaman bulunur. Özellikle
    // Arapça glifler ana Noto Sans/Serif/Mono fontlarında yoktur; fontconfig
    // bunları ancak aynı dizindeki Arapça ailelerden tamamlayabilir.
    for (final assetFont in kSubtitleFontAssets) {
      final file = File('${dir.path}/${assetFont.id}.ttf');
      // Katalog sabit ve asset'ler uygulamayla birlikte sürümlenir; dosya varsa
      // tekrar yazılmaz (boyut kontrolü yeterli — içerik asset ile aynıdır).
      final data = await rootBundle.load(assetFont.asset);
      if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    }
    return SubtitleFontTarget(fontsDir: dir.path, family: font.family);
  }

  Future<Directory> _fontsDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/subtitle_fonts');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
