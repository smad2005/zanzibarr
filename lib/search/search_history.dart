import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Arama geçmişi ve kayıtlı aramalar için kalıcı depo (roadmap #9).
///
/// Sır içermez; mevcut secure storage yalnızca projedeki yerleşik anahtar-
/// değer kalıcılık deseni olarak kullanılır (UiPreferencesStore ile aynı
/// gerekçe). Kayıtlar JSON dizge listesi olarak tutulur:
/// - Son aramalar: her aramada en öne eklenir, tekilleştirilir, üst sınıra
///   kırpılır; kullanıcı tek tıkla temizleyebilir.
/// - Kayıtlı aramalar: yalnızca kullanıcının kaydettikleri; elle eklenir ve
///   elle kaldırılır.
class SearchHistoryStore {
  SearchHistoryStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kRecent = 'search.recentQueries';
  static const _kSaved = 'search.savedQueries';

  /// Depoda tutulan en fazla kayıt sayısı (geçmiş ve kayıtlı ayrı).
  static const maxEntries = 20;

  static const _maxQueryLength = 100;

  Future<List<String>> loadRecent() async =>
      _decode(await _storage.read(key: _kRecent));

  Future<List<String>> loadSaved() async =>
      _decode(await _storage.read(key: _kSaved));

  /// Aramayı geçmişin en önüne ekler; aynı sorgu varsa öne taşınır.
  Future<void> recordSearch(String query) async {
    final entry = normalizeQuery(query);
    if (entry.isEmpty) return;
    final recent = await loadRecent();
    final updated = <String>[
      entry,
      ...recent.where((existing) => existing != entry),
    ].take(maxEntries).toList();
    await _storage.write(key: _kRecent, value: _encode(updated));
  }

  Future<void> clearRecent() => _storage.delete(key: _kRecent);

  /// Sorguyu kayıtlı aramalara ekler; zaten kayıtlıysa listenin başına
  /// taşınır (ayrıklı giriş yaratılmaz).
  Future<void> saveSearch(String query) async {
    final entry = normalizeQuery(query);
    if (entry.isEmpty) return;
    final saved = await loadSaved();
    final updated = <String>[
      entry,
      ...saved.where((existing) => existing != entry),
    ].take(maxEntries).toList();
    await _storage.write(key: _kSaved, value: _encode(updated));
  }

  Future<void> removeSaved(String query) async {
    final entry = normalizeQuery(query);
    final saved = await loadSaved();
    final updated = saved.where((existing) => existing != entry).toList();
    await _storage.write(key: _kSaved, value: _encode(updated));
  }

  /// Sorguyu tek satıra indirger, boşlukları sıkıştırır, üst uzunluk
  /// sınırına kırpar. Bu biçim hem kaydedilir hem karşılaştırmada kullanılır.
  static String normalizeQuery(String query) {
    final collapsed = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.length <= _maxQueryLength) return collapsed;
    return collapsed.substring(0, _maxQueryLength);
  }

  static List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().take(maxEntries).toList();
    } on FormatException {
      return const [];
    }
  }

  static String _encode(List<String> entries) => jsonEncode(entries);
}
