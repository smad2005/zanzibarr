import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'subtitle_fonts.dart';

/// Minimal persistence surface used by [MediaPreferencesStore].
///
/// Keeping this interface independent from the platform storage makes the
/// preference rules testable without touching Keychain or Keystore.
abstract interface class PlayerPreferenceStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// [PlayerPreferenceStorage] backed by the application's secure key-value
/// storage.
///
/// These preferences do not contain credentials. The existing secure storage
/// is reused only as a cross-platform persistence backend.
class FlutterSecurePlayerPreferenceStorage implements PlayerPreferenceStorage {
  FlutterSecurePlayerPreferenceStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A crop rectangle expressed in normalized video coordinates.
///
/// Every edge is in the inclusive 0–1 range. Invalid or empty rectangles are
/// replaced with [fullFrame].
class NormalizedCropRect {
  const NormalizedCropRect._({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  factory NormalizedCropRect({
    double left = 0,
    double top = 0,
    double right = 1,
    double bottom = 1,
  }) {
    final safeLeft = _finiteOr(left, 0).clamp(0.0, 1.0).toDouble();
    final safeTop = _finiteOr(top, 0).clamp(0.0, 1.0).toDouble();
    final safeRight = _finiteOr(right, 1).clamp(0.0, 1.0).toDouble();
    final safeBottom = _finiteOr(bottom, 1).clamp(0.0, 1.0).toDouble();

    if (safeLeft >= safeRight || safeTop >= safeBottom) {
      return fullFrame;
    }
    return NormalizedCropRect._(
      left: safeLeft,
      top: safeTop,
      right: safeRight,
      bottom: safeBottom,
    );
  }

  static const fullFrame = NormalizedCropRect._(
    left: 0,
    top: 0,
    right: 1,
    bottom: 1,
  );

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  Map<String, Object> toJson() => <String, Object>{
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  static NormalizedCropRect fromJson(Object? value) {
    if (value is! Map) return fullFrame;
    final left = _finiteNumber(value['left']);
    final top = _finiteNumber(value['top']);
    final right = _finiteNumber(value['right']);
    final bottom = _finiteNumber(value['bottom']);
    if (left == null || top == null || right == null || bottom == null) {
      return fullFrame;
    }
    return NormalizedCropRect(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NormalizedCropRect &&
      left == other.left &&
      top == other.top &&
      right == other.right &&
      bottom == other.bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// A normalized two-dimensional value used for canvas alignment and pan.
class NormalizedVector2 {
  const NormalizedVector2._(this.x, this.y);

  factory NormalizedVector2({double x = 0, double y = 0}) =>
      NormalizedVector2._(
        _finiteOr(x, 0).clamp(-1.0, 1.0).toDouble(),
        _finiteOr(y, 0).clamp(-1.0, 1.0).toDouble(),
      );

  static const center = NormalizedVector2._(0, 0);

  final double x;
  final double y;

  Map<String, Object> toJson() => <String, Object>{'x': x, 'y': y};

  static NormalizedVector2 fromJson(Object? value) {
    if (value is! Map) return center;
    final x = _finiteNumber(value['x']);
    final y = _finiteNumber(value['y']);
    if (x == null || y == null) return center;
    return NormalizedVector2(x: x, y: y);
  }

  @override
  bool operator ==(Object other) =>
      other is NormalizedVector2 && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// Bir giriş dosyasına ilişkilendirilmiş harici altyazı (OpenSubtitles
/// indirmesi). Anahtar, oynatılan girdinin `StreamInfo.filename`'dır;
/// bölümler arasında yanlış dosya yeniden kullanılmasın diye her girdi
/// kendi altyazısını taşır.
class ExternalSubtitle {
  const ExternalSubtitle({required this.path, required this.language});

  /// İndirilen altyazının mutlak dosya yolu (sır içermez).
  final String path;

  /// Altyazının ISO dil kodu ("tr", "en", …).
  final String language;

  Map<String, Object> toJson() => <String, Object>{
    'path': path,
    'language': language,
  };

  static ExternalSubtitle? fromJson(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final language = value['language'];
    if (path is! String || language is! String) return null;
    if (path.isEmpty) return null;
    return ExternalSubtitle(
      path: _sanitizePath(path),
      language: _languageCodeOrNull(language) ?? '',
    );
  }

  /// Yollar makul uzunlukta tutulur; yine de sır değildir (uygulama
  /// önbelleğindeki bir dosyadır).
  static String _sanitizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.length > 1024) {
      return trimmed.substring(trimmed.length - 1024);
    }
    return trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is ExternalSubtitle && path == other.path && language == other.language;

  @override
  int get hashCode => Object.hash(path, language);
}

/// "Two/three-letter ISO-639 language code or null" validator, shared by
/// [MediaPreferences] and [ExternalSubtitle].
String? _languageCodeOrNull(String value) {
  final code = value.trim().toLowerCase();
  return RegExp(r'^[a-z]{2,3}$').hasMatch(code) ? code : null;
}

/// Non-secret, per-media playback preferences.
///
/// The public constructor sanitizes every value before it can be persisted.
/// Preset strings are stable identifiers rather than user-facing labels.
class MediaPreferences {
  factory MediaPreferences({
    NormalizedCropRect crop = NormalizedCropRect.fullFrame,
    double? aspectRatio,
    NormalizedVector2 alignment = NormalizedVector2.center,
    NormalizedVector2 pan = NormalizedVector2.center,
    int seekStepSeconds = defaultSeekStepSeconds,
    Duration? periodicInfoInterval,
    String videoPreset = defaultVideoPreset,
    String audioPreset = defaultAudioPreset,
    String upscalePreset = defaultUpscalePreset,
    double subtitleScale = defaultSubtitleScale,
    double subtitlePosition = defaultSubtitlePosition,
    double subtitleDelaySeconds = 0,
    String subtitleColor = defaultSubtitleColor,
    String subtitleFont = kDefaultSubtitleFontId,
    double audioDelaySeconds = 0,
    bool showChapters = defaultShowChapters,
    String? subtitleLanguage,
    Map<String, ExternalSubtitle> externalSubtitles = const {},
  }) => MediaPreferences._(
    crop: crop,
    aspectRatio: _sanitizeAspectRatio(aspectRatio),
    alignment: alignment,
    pan: pan,
    seekStepSeconds: seekStepSeconds
        .clamp(minimumSeekStepSeconds, maximumSeekStepSeconds)
        .toInt(),
    periodicInfoInterval: _sanitizeInfoInterval(periodicInfoInterval),
    videoPreset: _sanitizePreset(videoPreset, defaultVideoPreset),
    audioPreset: _sanitizePreset(audioPreset, defaultAudioPreset),
    upscalePreset: _sanitizePreset(upscalePreset, defaultUpscalePreset),
    subtitleScale: _finiteOr(
      subtitleScale,
      defaultSubtitleScale,
    ).clamp(minimumSubtitleScale, maximumSubtitleScale).toDouble(),
    subtitlePosition: _finiteOr(
      subtitlePosition,
      defaultSubtitlePosition,
    ).clamp(minimumSubtitlePosition, maximumSubtitlePosition).toDouble(),
    subtitleDelaySeconds: _finiteOr(
      subtitleDelaySeconds,
      0,
    ).clamp(-maximumDelaySeconds, maximumDelaySeconds).toDouble(),
    subtitleColor: _sanitizeSubtitleColor(subtitleColor),
    subtitleFont: _sanitizeSubtitleFont(subtitleFont),
    audioDelaySeconds: _finiteOr(
      audioDelaySeconds,
      0,
    ).clamp(-maximumDelaySeconds, maximumDelaySeconds).toDouble(),
    showChapters: showChapters,
    subtitleLanguage: subtitleLanguage == null || subtitleLanguage.isEmpty
        ? null
        : _languageCodeOrNull(subtitleLanguage),
    externalSubtitles: _sanitizeExternalSubtitles(externalSubtitles),
  );

  const MediaPreferences._({
    required this.crop,
    required this.aspectRatio,
    required this.alignment,
    required this.pan,
    required this.seekStepSeconds,
    required this.periodicInfoInterval,
    required this.videoPreset,
    required this.audioPreset,
    required this.upscalePreset,
    required this.subtitleScale,
    required this.subtitlePosition,
    required this.subtitleDelaySeconds,
    required this.subtitleColor,
    required this.subtitleFont,
    required this.audioDelaySeconds,
    required this.showChapters,
    required this.subtitleLanguage,
    required this.externalSubtitles,
  });

  /// Şema sürümü 2: `subtitleLanguage` + `externalSubtitles` alanları eklendi
  /// (OpenSubtitles entegrasyonu). Sürüm 1 kayıtları yeni alanların
  /// varsayılanlarıyla okunur — mevcut tercihler yükseltmede kaybolmaz.
  static const schemaVersion = 2;
  /// `decodeOrDefault` desteklediği en eski şema sürümü.
  static const _oldestSupportedSchemaVersion = 1;
  static const minimumSeekStepSeconds = 1;
  static const maximumSeekStepSeconds = 600;
  static const defaultSeekStepSeconds = 1;
  static const minimumPeriodicInfoInterval = Duration(milliseconds: 250);
  static const maximumPeriodicInfoInterval = Duration(minutes: 1);
  static const defaultVideoPreset = 'auto';
  static const defaultAudioPreset = 'auto';
  static const defaultUpscalePreset = 'off';
  static const minimumSubtitleScale = 0.0;
  static const maximumSubtitleScale = 100.0;
  static const defaultSubtitleScale = 1.0;
  static const minimumSubtitlePosition = 0.0;
  static const maximumSubtitlePosition = 150.0;
  static const defaultSubtitlePosition = 100.0;
  static const maximumDelaySeconds = 600.0;
  static const defaultSubtitleColor = '#FFFFFF';
  static const defaultShowChapters = true;

  static final RegExp _presetPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');
  static final RegExp _subtitleColorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

  final NormalizedCropRect crop;
  final double? aspectRatio;
  final NormalizedVector2 alignment;
  final NormalizedVector2 pan;
  final int seekStepSeconds;

  /// `null` means that periodic playback information is disabled.
  final Duration? periodicInfoInterval;

  final String videoPreset;
  final String audioPreset;
  final String upscalePreset;
  final double subtitleScale;
  final double subtitlePosition;
  final double subtitleDelaySeconds;
  final String subtitleColor;

  /// Altyazı font kataloğu kimliği (`subtitle_fonts.dart`); bilinmeyen
  /// kimlikler varsayılana (`sans`) düşer.
  final String subtitleFont;
  final double audioDelaySeconds;

  /// Bölüm (chapter) işaretleri oynatıcıda gösterilsin mi; kalıcı tercih
  /// `MediaPreferencesStore.loadShowChapters` ile okunur.
  final bool showChapters;

  /// Bu içerik için kullanıcının seçtiği altyazı dili (ISO kodu). Kuyruğun
  /// sonraki bölümlerinde otomatik altyazı araması bu dili kullanır;
  /// seçim yapılmadıysa null.
  final String? subtitleLanguage;

  /// Girdi dosya adına (`StreamInfo.filename`) bağlanmış harici altyazılar
  /// (OpenSubtitles indirmeleri). Bölüm açılırken dosya hâlâ diskteyse
  /// ağa çıkılmadan yeniden yüklenir.
  final Map<String, ExternalSubtitle> externalSubtitles;

  bool get periodicInfoEnabled => periodicInfoInterval != null;

  static MediaPreferences defaults() => MediaPreferences();

  /// Altyazı ilişkilendirmesi güncellenmiş kopya: [entryName] girdisine
  /// [subtitle] bağlanır ve [language] boş değilse içerik dil tercihi
  /// ayrıca güncellenir. Kalan alanlar aynen taşınır.
  MediaPreferences copyWithExternalSubtitle({
    required String entryName,
    required ExternalSubtitle subtitle,
    String? language,
  }) => MediaPreferences(
    crop: crop,
    aspectRatio: aspectRatio,
    alignment: alignment,
    pan: pan,
    seekStepSeconds: seekStepSeconds,
    periodicInfoInterval: periodicInfoInterval,
    videoPreset: videoPreset,
    audioPreset: audioPreset,
    upscalePreset: upscalePreset,
    subtitleScale: subtitleScale,
    subtitlePosition: subtitlePosition,
    subtitleDelaySeconds: subtitleDelaySeconds,
    subtitleColor: subtitleColor,
    subtitleFont: subtitleFont,
    audioDelaySeconds: audioDelaySeconds,
    showChapters: showChapters,
    // language null'da mevcut dil tercihi korunur (yalnız altyazı güncelleme).
    subtitleLanguage: language ?? subtitleLanguage,
    externalSubtitles: {...externalSubtitles, entryName: subtitle},
  );

  /// Tüm alanların kopyası; verilmeyen alanlar mevcut değerden taşınır.
  MediaPreferences copyWith({
    NormalizedCropRect? crop,
    double? aspectRatio,
    NormalizedVector2? alignment,
    NormalizedVector2? pan,
    int? seekStepSeconds,
    Duration? periodicInfoInterval,
    String? videoPreset,
    String? audioPreset,
    String? upscalePreset,
    double? subtitleScale,
    double? subtitlePosition,
    double? subtitleDelaySeconds,
    String? subtitleColor,
    String? subtitleFont,
    double? audioDelaySeconds,
    bool? showChapters,
    String? subtitleLanguage,
    Map<String, ExternalSubtitle>? externalSubtitles,
  }) {
    return MediaPreferences(
      crop: crop ?? this.crop,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      alignment: alignment ?? this.alignment,
      pan: pan ?? this.pan,
      seekStepSeconds: seekStepSeconds ?? this.seekStepSeconds,
      periodicInfoInterval:
          periodicInfoInterval ?? this.periodicInfoInterval,
      videoPreset: videoPreset ?? this.videoPreset,
      audioPreset: audioPreset ?? this.audioPreset,
      upscalePreset: upscalePreset ?? this.upscalePreset,
      subtitleScale: subtitleScale ?? this.subtitleScale,
      subtitlePosition: subtitlePosition ?? this.subtitlePosition,
      subtitleDelaySeconds:
          subtitleDelaySeconds ?? this.subtitleDelaySeconds,
      subtitleColor: subtitleColor ?? this.subtitleColor,
      subtitleFont: subtitleFont ?? this.subtitleFont,
      audioDelaySeconds: audioDelaySeconds ?? this.audioDelaySeconds,
      showChapters: showChapters ?? this.showChapters,
      subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
      externalSubtitles: externalSubtitles ?? this.externalSubtitles,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'crop': crop.toJson(),
    'aspectRatio': aspectRatio,
    'alignment': alignment.toJson(),
    'pan': pan.toJson(),
    'seekStepSeconds': seekStepSeconds,
    'periodicInfoIntervalMs': periodicInfoInterval?.inMilliseconds,
    'videoPreset': videoPreset,
    'audioPreset': audioPreset,
    'upscalePreset': upscalePreset,
    'subtitleScale': subtitleScale,
    'subtitlePosition': subtitlePosition,
    'subtitleDelaySeconds': subtitleDelaySeconds,
    'subtitleColor': subtitleColor,
    'subtitleFont': subtitleFont,
    'audioDelaySeconds': audioDelaySeconds,
    'showChapters': showChapters,
    'subtitleLanguage': subtitleLanguage,
    'externalSubtitles': externalSubtitles.map(
      (name, subtitle) => MapEntry(name, subtitle.toJson()),
    ),
  };

  String encode() => jsonEncode(toJson());

  /// Returns defaults for malformed JSON, unsupported schema versions or
  /// structurally invalid values. Individual numeric values are sanitized by
  /// the public constructor.
  ///
  /// Sürüm 1 kayıtları (altyazı ilişkilendirmesinden önce) eksik alanların
  /// varsayılanlarıyla okunur; hiçbir mevcut tercih düşmez.
  static MediaPreferences decodeOrDefault(String encoded) {
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) {
        return defaults();
      }
      final version = value['schemaVersion'];
      if (version != schemaVersion && version != _oldestSupportedSchemaVersion) {
        return defaults();
      }

      final intervalValue = value['periodicInfoIntervalMs'];
      Duration? interval;
      if (intervalValue != null) {
        if (intervalValue is! num || !intervalValue.toDouble().isFinite) {
          return defaults();
        }
        interval = Duration(milliseconds: intervalValue.toInt());
      }

      final subtitleLanguage = value['subtitleLanguage'];
      final externalSubtitlesValue = value['externalSubtitles'];
      Map<String, ExternalSubtitle> externalSubtitles = const {};
      if (externalSubtitlesValue is Map) {
        final parsed = <String, ExternalSubtitle>{};
        for (final entry in externalSubtitlesValue.entries) {
          if (entry.key is! String) continue;
          final subtitle = ExternalSubtitle.fromJson(entry.value);
          if (subtitle != null) {
            parsed[entry.key as String] = subtitle;
          }
        }
        externalSubtitles = parsed;
      }

      return MediaPreferences(
        crop: NormalizedCropRect.fromJson(value['crop']),
        aspectRatio: _finiteNumber(value['aspectRatio']),
        alignment: NormalizedVector2.fromJson(value['alignment']),
        pan: NormalizedVector2.fromJson(value['pan']),
        seekStepSeconds: _integerOr(
          value['seekStepSeconds'],
          defaultSeekStepSeconds,
        ),
        periodicInfoInterval: interval,
        videoPreset: _stringOr(value['videoPreset'], defaultVideoPreset),
        audioPreset: _stringOr(value['audioPreset'], defaultAudioPreset),
        upscalePreset: _stringOr(value['upscalePreset'], defaultUpscalePreset),
        subtitleScale: _numberOr(value['subtitleScale'], defaultSubtitleScale),
        subtitlePosition: _numberOr(
          value['subtitlePosition'],
          defaultSubtitlePosition,
        ),
        subtitleDelaySeconds: _numberOr(value['subtitleDelaySeconds'], 0),
        subtitleColor: _stringOr(value['subtitleColor'], defaultSubtitleColor),
        subtitleFont: _stringOr(value['subtitleFont'], kDefaultSubtitleFontId),
        audioDelaySeconds: _numberOr(value['audioDelaySeconds'], 0),
        showChapters: _boolOr(value['showChapters'], defaultShowChapters),
        subtitleLanguage:
            subtitleLanguage is String ? subtitleLanguage : null,
        externalSubtitles: externalSubtitles,
      );
    } on FormatException {
      return defaults();
    } on TypeError {
      return defaults();
    }
  }

  static double? _sanitizeAspectRatio(double? value) {
    if (value == null || !value.isFinite || value <= 0) return null;
    return value.clamp(0.1, 10.0).toDouble();
  }

  static Duration? _sanitizeInfoInterval(Duration? value) {
    if (value == null) return null;
    final milliseconds = value.inMilliseconds.clamp(
      minimumPeriodicInfoInterval.inMilliseconds,
      maximumPeriodicInfoInterval.inMilliseconds,
    );
    return Duration(milliseconds: milliseconds.toInt());
  }

  static String _sanitizePreset(String value, String fallback) =>
      _presetPattern.hasMatch(value) ? value : fallback;

  static String _sanitizeSubtitleColor(String value) =>
      _subtitleColorPattern.hasMatch(value.trim())
          ? value.trim().toUpperCase()
          : defaultSubtitleColor;

  static String _sanitizeSubtitleFont(String value) =>
      subtitleFontFor(value.trim()).id;

  /// Anahtarlar boş olamaz; altyazı referanslarını tutan eşlem kopyası
  /// (sabitleme değil) döner — widget'larda mutasyon kazaları istenmez.
  static Map<String, ExternalSubtitle> _sanitizeExternalSubtitles(
    Map<String, ExternalSubtitle> value,
  ) {
    final sanitized = <String, ExternalSubtitle>{};
    for (final entry in value.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || name.length > 512) continue;
      sanitized[name] = entry.value;
    }
    return Map.unmodifiable(sanitized);
  }

  @override
  bool operator ==(Object other) =>
      other is MediaPreferences &&
      crop == other.crop &&
      aspectRatio == other.aspectRatio &&
      alignment == other.alignment &&
      pan == other.pan &&
      seekStepSeconds == other.seekStepSeconds &&
      periodicInfoInterval == other.periodicInfoInterval &&
      videoPreset == other.videoPreset &&
      audioPreset == other.audioPreset &&
      upscalePreset == other.upscalePreset &&
      subtitleScale == other.subtitleScale &&
      subtitlePosition == other.subtitlePosition &&
      subtitleDelaySeconds == other.subtitleDelaySeconds &&
      subtitleColor == other.subtitleColor &&
      subtitleFont == other.subtitleFont &&
      audioDelaySeconds == other.audioDelaySeconds &&
      showChapters == other.showChapters &&
      subtitleLanguage == other.subtitleLanguage &&
      // Map == kimlik karşılaştırır; içerik karşılaştırması gerekir.
      mapEquals(externalSubtitles, other.externalSubtitles);

  @override
  int get hashCode => Object.hash(
    crop,
    aspectRatio,
    alignment,
    pan,
    seekStepSeconds,
    periodicInfoInterval,
    videoPreset,
    audioPreset,
    upscalePreset,
    subtitleScale,
    subtitlePosition,
    subtitleDelaySeconds,
    subtitleColor,
    subtitleFont,
    audioDelaySeconds,
    showChapters,
    subtitleLanguage,
    externalSubtitles,
  );
}

/// Persists [MediaPreferences] under a path-free per-media namespace.
class MediaPreferencesStore {
  MediaPreferencesStore({PlayerPreferenceStorage? storage})
    : _storage = storage ?? FlutterSecurePlayerPreferenceStorage();

  final PlayerPreferenceStorage _storage;

  static const storageKeyPrefix = 'zanzibarr.player_preferences.';
  static final BigInt _fnvOffsetBasis64 = BigInt.parse(
    'cbf29ce484222325',
    radix: 16,
  );
  static final BigInt _fnvPrime64 = BigInt.parse('100000001b3', radix: 16);
  static final BigInt _uint64Mask = BigInt.parse('ffffffffffffffff', radix: 16);

  /// Builds a deterministic namespace without embedding the NZB path in it.
  static String storageKeyFor(String nzbPath) {
    var hash = _fnvOffsetBasis64;
    for (final byte in utf8.encode(nzbPath)) {
      hash ^= BigInt.from(byte);
      hash = (hash * _fnvPrime64) & _uint64Mask;
    }
    final digest = hash.toRadixString(16).padLeft(16, '0');
    return '$storageKeyPrefix$digest';
  }

  Future<MediaPreferences> load(String nzbPath) async {
    final encoded = await _storage.read(storageKeyFor(nzbPath));
    if (encoded == null) return MediaPreferences.defaults();
    return MediaPreferences.decodeOrDefault(encoded);
  }

  Future<void> save(String nzbPath, MediaPreferences preferences) =>
      _storage.write(storageKeyFor(nzbPath), preferences.encode());

  Future<void> clear(String nzbPath) => _storage.delete(storageKeyFor(nzbPath));

  static const seekStepKey = 'zanzibarr.player.seek_step_seconds';

  Future<int?> loadSeekStepSeconds() async {
    final value = int.tryParse(await _storage.read(seekStepKey) ?? '');
    if (value == null) return null;
    return value.clamp(
      MediaPreferences.minimumSeekStepSeconds,
      MediaPreferences.maximumSeekStepSeconds,
    );
  }

  Future<void> saveSeekStepSeconds(int seconds) =>
      _storage.write(seekStepKey, '$seconds');

  static const showChaptersKey = 'zanzibarr.player.show_chapters';

  Future<bool?> loadShowChapters() async {
    final raw = await _storage.read(showChaptersKey);
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    return null;
  }

  Future<void> saveShowChapters(bool value) =>
      _storage.write(showChaptersKey, '$value');

double _finiteOr(double value, double fallback) =>
    value.isFinite ? value : fallback;

double? _finiteNumber(Object? value) {
  if (value is! num) return null;
  final number = value.toDouble();
  return number.isFinite ? number : null;
}

double _numberOr(Object? value, double fallback) =>
    _finiteNumber(value) ?? fallback;

bool _boolOr(Object? value, bool fallback) => value is bool ? value : fallback;

int _integerOr(Object? value, int fallback) {
  if (value is! num || !value.toDouble().isFinite) return fallback;
  return value.toInt();
}

String _stringOr(Object? value, String fallback) =>
    value is String ? value : fallback;
