import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum DohProvider { cloudflare, nextdns, google, custom }

class DohSettings {
  const DohSettings({
    required this.enabled,
    required this.provider,
    this.customUrl = '',
  });

  final bool enabled;
  final DohProvider provider;
  final String customUrl;

  static const defaults = DohSettings(
    enabled: true,
    provider: DohProvider.cloudflare,
  );

  String get endpoint {
    if (!enabled) return '';
    return switch (provider) {
      DohProvider.cloudflare => 'https://cloudflare-dns.com/dns-query',
      DohProvider.nextdns => 'https://dns.nextdns.io',
      DohProvider.google => 'https://dns.google/dns-query',
      DohProvider.custom => customUrl.trim(),
    };
  }

  Map<String, Object> toJson() => <String, Object>{
    'enabled': enabled,
    'provider': provider.name,
    'customUrl': customUrl,
  };

  factory DohSettings.fromJson(Map<String, Object?> value) {
    final rawProvider = value['provider'];
    final provider = DohProvider.values.firstWhere(
      (item) => item.name == rawProvider,
      orElse: () => DohProvider.cloudflare,
    );
    return DohSettings(
      enabled: value['enabled'] == true,
      provider: provider,
      customUrl: value['customUrl'] is String ? value['customUrl'] as String : '',
    );
  }
}

class DohSettingsStore {
  DohSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const storageKey = 'settings.doh.v1';

  Future<DohSettings> load() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return DohSettings.defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return DohSettings.defaults;
      return DohSettings.fromJson(Map<String, Object?>.from(decoded));
    } on FormatException {
      return DohSettings.defaults;
    }
  }

  Future<void> save(DohSettings settings) =>
      _storage.write(key: storageKey, value: jsonEncode(settings.toJson()));
}
