import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Newznab indexer ayarları (tek hesap).
///
/// API anahtarı yalnızca OS secure storage'da (Keychain/Keystore) tutulur;
/// hiçbir sır kaynak koda veya düz metin dosyaya yazılmaz.
class IndexerSettings {
  const IndexerSettings({this.baseUrl = '', this.apiKey = ''});

  /// Indexer'ın kök adresi (ör. `https://indexer.example`; sonunda `/api`
  /// olabilir ya da olmayabilir, Rust tarafı normalize eder).
  final String baseUrl;

  /// Newznab API anahtarı.
  final String apiKey;

  /// İki alan da doluysa indexer kullanılabilir kabul edilir; boş URL
  /// "indexer kapalı" demektir.
  bool get isComplete => baseUrl.isNotEmpty && apiKey.isNotEmpty;
}

/// Kayıtlı bir indexer hesabı (profil): çoklu indexer desteğinde her hesap
/// ayrı bir profildir; arama açık profillerin tamamını paralel sorgular ve
/// sonuçlar tekilleştirilir. Prowlarr (`…/prowlarr/{id}/api`) ve NZBHydra2
/// (`…/api`) newznab-uyumlu uç sağladıkları için normal birer indexer hesabı
/// olarak eklenirler.
class IndexerProfile {
  const IndexerProfile({
    required this.id,
    this.label = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.enabled = true,
  });

  /// Kalıcı profil kimliği; arama sonuçları bu id ile etiketlenir
  /// (`SearchItemDto.sourceId`) ve NZB indirme doğru hesapla yapılır.
  final String id;

  /// Gösterim adı (ör. "Miatrix", "Prowlarr"); boşsa URL host'u gösterilir.
  final String label;

  final String baseUrl;
  final String apiKey;

  /// Aramalara katılıp katılmadığı. Kapalı hesap listede durur ama sorgulanmaz.
  final bool enabled;

  bool get isComplete => baseUrl.isNotEmpty && apiKey.isNotEmpty;

  /// Aramaya katılabilir mi: hem açık hem tam yapılandırılmış olmalı.
  bool get searchable => enabled && isComplete;

  IndexerSettings get settings => IndexerSettings(baseUrl: baseUrl, apiKey: apiKey);

  /// Listelerde gösterilen ad: etiket boşsa URL' nin host'u.
  String get displayName {
    final trimmed = label.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isNotEmpty) return host;
    return baseUrl;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'enabled': enabled,
      };

  /// JSON'dan profili çözer; eksik/bozuk kayıtlar null döner (silinir).
  static IndexerProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return IndexerProfile(
      id: id,
      label: _asString(json['label']),
      baseUrl: _asString(json['baseUrl']),
      apiKey: _asString(json['apiKey']),
      enabled: switch (json['enabled']) {
        bool value => value,
        _ => true,
      },
    );
  }

  static String _asString(Object? value) => value is String ? value : '';

  /// Yeni bir profil kimliği üretir.
  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

/// [IndexerSettings]/[IndexerProfile] için OS secure storage üzerinde
/// kalıcı depo.
///
/// Çoklu indexer: profiller `indexer.profiles` anahtarında JSON
/// listesidir. Eski tek-indexer anahtarları ilk açılışta otomatik olarak
/// varsayılan profile taşınır (veri kaybı yok).
class IndexerSettingsStore {
  IndexerSettingsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // Eski (tek indexer) anahtarları: göç ve geriye uyumluluk için kalır.
  static const _kBaseUrl = 'indexer.baseUrl';
  static const _kApiKey = 'indexer.apiKey';
  static const _kProfiles = 'indexer.profiles';

  static const _migrationProfileId = 'default';

  /// Kayıtlı tüm indexer profilleri. Depo boşsa eski tek-indexer
  /// anahtarlarından (varsa) otomatik göç yapılır.
  Future<List<IndexerProfile>> loadProfiles() async {
    final profiles = _decode(await _storage.read(key: _kProfiles));
    if (profiles.isNotEmpty) return profiles;

    // İlk çoklu indexer açılışı: eski tek indexer'ı varsayılan profile taşı.
    final legacy = await _loadLegacy();
    if (legacy.baseUrl.isNotEmpty || legacy.apiKey.isNotEmpty) {
      final migrated = IndexerProfile(
        id: _migrationProfileId,
        label: '',
        baseUrl: legacy.baseUrl,
        apiKey: legacy.apiKey,
        enabled: true,
      );
      await _storage.write(
        key: _kProfiles,
        value: jsonEncode([migrated.toJson()]),
      );
      return [migrated];
    }
    return const [];
  }

  /// Geriye uyumlu tek-indexer görünümü: aramaya katılabilen ilk profil
  /// (yoksa ilk profil, hiç profil yoksa boş ayarlar).
  Future<IndexerSettings> load() async {
    final profiles = await loadProfiles();
    if (profiles.isEmpty) return const IndexerSettings();
    return (profiles.firstWhere(
          (profile) => profile.searchable,
          orElse: () => profiles.first,
        ))
        .settings;
  }

  /// Profili kaydeder (yeni ise ekler, varsa günceller).
  Future<void> saveProfile(IndexerProfile profile) async {
    final profiles = await loadProfiles();
    final index = profiles.indexWhere((existing) => existing.id == profile.id);
    final updated = profiles.toList();
    if (index >= 0) {
      updated[index] = profile;
    } else {
      updated.add(profile);
    }
    await _storage.write(
      key: _kProfiles,
      value: jsonEncode(updated.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> deleteProfile(String id) async {
    final profiles = await loadProfiles();
    final updated = profiles
        .where((profile) => profile.id != id)
        .toList(growable: false);
    await _storage.write(
      key: _kProfiles,
      value: jsonEncode(updated.map((p) => p.toJson()).toList()),
    );
  }

  /// Eski tek-indexer API'si (geriye uyumluluk): ilk profili günceller;
  /// hiç profil yoksa yeni varsayılan profil oluşturur.
  Future<void> save(IndexerSettings settings) async {
    final profiles = await loadProfiles();
    final id = profiles.isEmpty ? _migrationProfileId : profiles.first.id;
    await saveProfile(IndexerProfile(
      id: id,
      // İlk profil güncellenirken etiket ve açık bayrağı korunur.
      label: profiles.isEmpty ? '' : profiles.first.label,
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      enabled: profiles.isEmpty ? true : profiles.first.enabled,
    ));
  }

  Future<void> clear() async {
    for (final key in [_kBaseUrl, _kApiKey, _kProfiles]) {
      await _storage.delete(key: key);
    }
  }

  /// Eski (tek indexer) anahtarlarından ayarları okur.
  Future<IndexerSettings> _loadLegacy() async {
    const defaults = IndexerSettings();
    return IndexerSettings(
      baseUrl: await _storage.read(key: _kBaseUrl) ?? defaults.baseUrl,
      apiKey: await _storage.read(key: _kApiKey) ?? defaults.apiKey,
    );
  }

  static List<IndexerProfile> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(IndexerProfile.fromJson)
          .whereType<IndexerProfile>()
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }
}
