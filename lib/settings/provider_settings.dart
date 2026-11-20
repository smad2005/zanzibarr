import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// NNTP sağlayıcı ayarları (tek hesabın bağlantı parametreleri).
///
/// Kimlik bilgileri yalnızca OS secure storage'da (Keychain/Keystore) tutulur;
/// hiçbir sır kaynak koda veya düz metin dosyaya yazılmaz.
class ProviderSettings {
  const ProviderSettings({
    this.host = '',
    this.port = 563,
    this.username = '',
    this.password = '',
    this.maxConnections = 10,
  });

  /// NNTP sunucu adresi (ör. sağlayıcının TLS host'u).
  final String host;

  /// NNTPS portu; 563 = TLS.
  final int port;

  final String username;
  final String password;

  /// Sağlayıcının izin verdiği eşzamanlı bağlantı sayısı.
  /// Faz 1'deki bağlantı havuzunun boyutu buradan gelir.
  final int maxConnections;

  bool get isComplete =>
      host.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
}

/// Kayıtlı bir NNTP hesabı (profil): çoklu hesap desteğinde her hesap
/// ayrı bir profildir; `id` ayarlar/liste ve seçimlerde kalıcı kimliktir.
/// Akış (stream) her zaman *aktif* profille kurulur.
class ProviderProfile {
  const ProviderProfile({
    required this.id,
    this.label = '',
    this.host = '',
    this.port = 563,
    this.username = '',
    this.password = '',
    this.maxConnections = 10,
  });

  /// Kalıcı profil kimliği; depodaki kayıtları eşleştirmede kullanılır.
  final String id;

  /// Gösterim adı (ör. "Ev", "Yedek"); boşsa listede host gösterilir.
  final String label;

  final String host;
  final int port;
  final String username;
  final String password;
  final int maxConnections;

  ProviderSettings get settings => ProviderSettings(
        host: host,
        port: port,
        username: username,
        password: password,
        maxConnections: maxConnections,
      );

  bool get isComplete =>
      host.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  /// Listelerde gösterilen ad: etiket boşsa host, o da boşsa kullanıcı adı.
  String get displayName {
    final trimmed = label.trim();
    if (trimmed.isNotEmpty) return trimmed;
    if (host.isNotEmpty) return host;
    return username;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'maxConnections': maxConnections,
      };

  /// JSON'dan profili çözer; eksik/bozuk kayıtlar null döner (silinir).
  /// Sürüm toleranslıdır: eksik alanlar Profile varsayılanlarıyla okunur.
  static ProviderProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    int asInt(Object? value, int fallback) => switch (value) {
          int parsed => parsed,
          String text => int.tryParse(text) ?? fallback,
          _ => fallback,
        };
    return ProviderProfile(
      id: id,
      label: _asString(json['label']),
      host: _asString(json['host']),
      port: asInt(json['port'], 563),
      username: _asString(json['username']),
      password: _asString(json['password']),
      maxConnections: asInt(json['maxConnections'], 10),
    );
  }

  static String _asString(Object? value) => value is String ? value : '';

  /// Yeni bir profil kimliği üretir (mikrosaniye tabanlı; çakışma
  /// pratikte olanaksız).
  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

/// [ProviderSettings]/[ProviderProfile] için OS secure storage üzerinde
/// kalıcı depo.
///
/// Çoklu hesap: profiller `provider.profiles` anahtarında JSON listesidir;
/// akışta kullanılan *aktif* profil `provider.activeProfileId`'dedir.
/// Eski tek-hesap düzenindeki anahtarlar ilk açılışta otomatik olarak
/// varsayılan profile taşınır (veri kaybı yok).
class ProviderSettingsStore {
  ProviderSettingsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // Eski (tek hesap) anahtarları: göç ve geriye uyumluluk için kalır.
  static const _kHost = 'provider.host';
  static const _kPort = 'provider.port';
  static const _kUsername = 'provider.username';
  static const _kPassword = 'provider.password';
  static const _kMaxConnections = 'provider.maxConnections';

  static const _kProfiles = 'provider.profiles';
  static const _kActiveProfileId = 'provider.activeProfileId';

  static const _migrationProfileId = 'default';

  /// Kayıtlı tüm hesaplar. Depo boşsa eski tek-hesap anahtarlarından
  /// (varsa) otomatik göç yapılır.
  Future<List<ProviderProfile>> loadProfiles() async {
    final profiles = _decode(await _storage.read(key: _kProfiles));
    if (profiles.isNotEmpty) return profiles;

    // İlk çoklu hesap açılışı: eski tek hesabı varsayılan profile taşı.
    final legacy = await _loadLegacy();
    if (legacy.host.isNotEmpty || legacy.username.isNotEmpty) {
      final migrated = ProviderProfile(
        id: _migrationProfileId,
        label: '',
        host: legacy.host,
        port: legacy.port,
        username: legacy.username,
        password: legacy.password,
        maxConnections: legacy.maxConnections,
      );
      await _storage.write(
        key: _kProfiles,
        value: jsonEncode([migrated.toJson()]),
      );
      await _storage.write(key: _kActiveProfileId, value: migrated.id);
      return [migrated];
    }
    return const [];
  }

  /// Aktif hesabın ayarları — akış (begin_stream, cast, ön kontrol) daima
  /// bunu kullanır. Hiç profil yoksa varsayılan (boş) ayarlar döner.
  Future<ProviderSettings> load() async {
    final profiles = await loadProfiles();
    if (profiles.isEmpty) return const ProviderSettings();
    return (await activeProfileOf(profiles)).settings;
  }

  /// Aktif profil kimliği; profil yoksa null.
  Future<String?> activeProfileId() async {
    final id = await _storage.read(key: _kActiveProfileId);
    return (id == null || id.isEmpty) ? null : id;
  }

  /// Aktif profili bulur; kayıtlı aktif id listede yoksa ilk profil kullanılır.
  Future<ProviderProfile> activeProfileOf(
    List<ProviderProfile> profiles,
  ) async {
    assert(profiles.isNotEmpty);
    final id = await activeProfileId();
    return profiles.firstWhere(
      (profile) => profile.id == id,
      orElse: () => profiles.first,
    );
  }

  /// Profili kaydeder (yeni ise ekler, varsa günceller) ve *aktif hesap*
  /// yapar: kaydedilen hesap, akışta kullanılacak hesaptır.
  Future<void> saveProfile(ProviderProfile profile) async {
    final profiles = await loadProfiles();
    final index = profiles.indexWhere((existing) => existing.id == profile.id);
    final updated = List<ProviderProfile>.of(profiles);
    if (index >= 0) {
      updated[index] = profile;
    } else {
      updated.add(profile);
    }
    await _storage.write(
      key: _kProfiles,
      value: jsonEncode(updated.map((p) => p.toJson()).toList()),
    );
    await _storage.write(key: _kActiveProfileId, value: profile.id);
  }

  /// Profili listeden siler. Silinen aktifse aktiflik listenin ilk
  /// kalan profiline geçer; liste boşalırsa aktif kaydı da temizlenir.
  Future<void> deleteProfile(String id) async {
    final profiles = await loadProfiles();
    final updated = profiles
        .where((profile) => profile.id != id)
        .toList(growable: false);
    await _storage.write(
      key: _kProfiles,
      value: jsonEncode(updated.map((p) => p.toJson()).toList()),
    );
    if (await activeProfileId() == id) {
      if (updated.isEmpty) {
        await _storage.delete(key: _kActiveProfileId);
      } else {
        await _storage.write(key: _kActiveProfileId, value: updated.first.id);
      }
    }
  }

  /// Eski tek-hesap API'si (geriye uyumluluk): aktif profili günceller;
  /// hiç profil yoksa yeni varsayılan profil olarak oluşturur.
  Future<void> save(ProviderSettings settings) async {
    final profiles = await loadProfiles();
    final id = profiles.isEmpty ? _migrationProfileId : (await activeProfileId()) ?? profiles.first.id;
    await saveProfile(ProviderProfile(
      id: id,
      host: settings.host,
      port: settings.port,
      username: settings.username,
      password: settings.password,
      maxConnections: settings.maxConnections,
    ));
  }

  Future<void> clear() async {
    for (final key in [
      _kHost,
      _kPort,
      _kUsername,
      _kPassword,
      _kMaxConnections,
      _kProfiles,
      _kActiveProfileId,
    ]) {
      await _storage.delete(key: key);
    }
  }

  /// Eski (tek hesap) anahtarlarından ayarları okur.
  Future<ProviderSettings> _loadLegacy() async {
    const defaults = ProviderSettings();
    return ProviderSettings(
      host: await _storage.read(key: _kHost) ?? defaults.host,
      port: int.tryParse(await _storage.read(key: _kPort) ?? '') ??
          defaults.port,
      username: await _storage.read(key: _kUsername) ?? defaults.username,
      password: await _storage.read(key: _kPassword) ?? defaults.password,
      maxConnections:
          int.tryParse(await _storage.read(key: _kMaxConnections) ?? '') ??
              defaults.maxConnections,
    );
  }

  static List<ProviderProfile> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(ProviderProfile.fromJson)
          .whereType<ProviderProfile>()
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }
}
