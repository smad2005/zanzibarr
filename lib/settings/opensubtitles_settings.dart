import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// OpenSubtitles (https://api.opensubtitles.com) ayarları.
///
/// Kimlik bilgileri (API anahtarı, kullanıcı adı, parola) yalnızca OS
/// secure storage'da (Keychain/Keystore) tutulur; hiçbir sır kaynak koda
/// veya düz metin dosyaya yazılmaz. Arama için yalnız API anahtarı yeter;
/// indirme uç noktası (ücretsiz API anahtarlarında) oturum açmış kullanıcı
/// ister — hesap bilgileri opsiyoneldir.
class OpenSubtitlesSettings {
  const OpenSubtitlesSettings({
    this.baseUrl = '',
    this.apiKey = '',
    this.username = '',
    this.password = '',
    this.languages = defaultLanguages,
  });

  /// API kök adresi; boşsa Rust motoru varsayılanı kullanır
  /// (`api.opensubtitles.com`). Bölgesel engeller için değiştirilebilir.
  final String baseUrl;

  /// OpenSubtitles profilindeki "API consumers" bölümünden alınan anahtar.
  final String apiKey;

  /// OpenSubtitles hesabı (indirme kotasını yükseltir); opsiyonel.
  final String username;

  final String password;

  /// Tercih edilen altyazı dilleri (ISO kodları, öncelik sırasıyla).
  /// Seçim arama diyalogundaki dil çiplerinden güncellenir.
  final List<String> languages;

  /// Varsayılan dil tercihi: sahibin kitlesi için Türkçe + İngilizce, ve
  /// son kullanıcı raporundaki Arapça altyazı senaryosu.
  static const defaultLanguages = ['tr', 'en', 'ar'];

  /// API anahtarı varsa arama yapılabilir.
  bool get canSearch => apiKey.isNotEmpty;

  /// Hesap girişi girildiyse indirme anonim kota yerine kullanıcı
  /// kotasıyla yapılır.
  bool get hasAccount => username.isNotEmpty && password.isNotEmpty;
}

/// [OpenSubtitlesSettings] için OS secure storage üzerinde kalıcı depo.
class OpenSubtitlesSettingsStore {
  OpenSubtitlesSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kBaseUrl = 'opensubtitles.baseUrl';
  static const _kApiKey = 'opensubtitles.apiKey';
  static const _kUsername = 'opensubtitles.username';
  static const _kPassword = 'opensubtitles.password';
  static const _kLanguages = 'opensubtitles.languages';

  Future<OpenSubtitlesSettings> load() async {
    final defaults = const OpenSubtitlesSettings();
    return OpenSubtitlesSettings(
      baseUrl: await _storage.read(key: _kBaseUrl) ?? defaults.baseUrl,
      apiKey: await _storage.read(key: _kApiKey) ?? defaults.apiKey,
      username: await _storage.read(key: _kUsername) ?? defaults.username,
      password: await _storage.read(key: _kPassword) ?? defaults.password,
      languages: sanitizeLanguages(
        (await _storage.read(key: _kLanguages))?.split(',') ??
            defaults.languages,
      ),
    );
  }

  Future<void> save(OpenSubtitlesSettings settings) async {
    await _storage.write(key: _kBaseUrl, value: settings.baseUrl);
    await _storage.write(key: _kApiKey, value: settings.apiKey);
    await _storage.write(key: _kUsername, value: settings.username);
    await _storage.write(key: _kPassword, value: settings.password);
    await _storage.write(key: _kLanguages, value: settings.languages.join(','));
  }

  /// Yalnızca dil tercihini günceller (arama diyalogundaki çip seçimi).
  /// Diğer alanlar okunmadan korunur: parola/API anahtarı bu yoldan
  /// değiştirilemez.
  Future<void> saveLanguages(List<String> languages) async {
    await _storage.write(key: _kLanguages, value: sanitizeLanguages(languages).join(','));
  }

  Future<void> clear() async {
    for (final key in [
      _kBaseUrl,
      _kApiKey,
      _kUsername,
      _kPassword,
      _kLanguages,
    ]) {
      await _storage.delete(key: key);
    }
  }

  /// Dil listesini güvenli hale getirir: boşlukları kırpar, küçük harfe
  /// indirger, tekrarları ayıklar, boş girdileri atar.
  static List<String> sanitizeLanguages(List<String> languages) {
    return languages
        .map((code) => code.trim().toLowerCase())
        .where((code) => code.isNotEmpty)
        .toSet()
        .toList();
  }
}
