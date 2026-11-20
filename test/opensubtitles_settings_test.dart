import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/settings/opensubtitles_settings.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final _memoryStorage = <String, String>{};

void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return _memoryStorage[key];
          case 'write':
            _memoryStorage[key!] = args['value'] as String;
            return null;
          case 'delete':
            _memoryStorage.remove(key);
            return null;
          case 'deleteAll':
            _memoryStorage.clear();
            return null;
        }
        return null;
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _memoryStorage.clear();
    _mockSecureStorage();
  });

  test('Boş depoda varsayılanlar döner: üç dil, anahtar yok', () async {
    final settings = await OpenSubtitlesSettingsStore().load();
    expect(settings.apiKey, isEmpty);
    expect(settings.canSearch, isFalse);
    expect(settings.hasAccount, isFalse);
    expect(settings.baseUrl, isEmpty);
    expect(settings.languages, ['tr', 'en', 'ar']);
  });

  test('Kaydedilen kimlik bilgileri ve diller geri okunur', () async {
    final store = OpenSubtitlesSettingsStore();
    await store.save(
      const OpenSubtitlesSettings(
        baseUrl: 'https://api.example.com',
        apiKey: 'anahtar',
        username: 'kullanici',
        password: 'sifre',
        languages: ['en', 'tr', 'en', ' de ', 'ar'],
      ),
    );
    final settings = await store.load();
    expect(settings.baseUrl, 'https://api.example.com');
    expect(settings.canSearch, isTrue);
    expect(settings.hasAccount, isTrue);
    // Tekrarlar ayıklanır, sıra korunur.
    expect(settings.languages, ['en', 'tr', 'de', 'ar']);
  });

  test('saveLanguages yalnızca dil anahtarını günceller', () async {
    final store = OpenSubtitlesSettingsStore();
    await store.save(
      const OpenSubtitlesSettings(apiKey: 'anahtar', password: 'sifre'),
    );
    await store.saveLanguages(['ar', 'tr', '']);
    final settings = await store.load();
    expect(settings.languages, ['ar', 'tr']);
    // Kimlik alanları dokunulmaz.
    expect(settings.apiKey, 'anahtar');
    expect(settings.password, 'sifre');
  });

  test('clear tüm anahtarları temizler', () async {
    final store = OpenSubtitlesSettingsStore();
    await store.save(
      const OpenSubtitlesSettings(apiKey: 'anahtar', languages: ['tr']),
    );
    await store.clear();
    final settings = await store.load();
    expect(settings.canSearch, isFalse);
    expect(settings.languages, OpenSubtitlesSettings.defaultLanguages);
  });

  test('Kısmi hesap girişi hasAccount false kalır', () async {
    const settings = OpenSubtitlesSettings(username: 'yalnız-kullanici');
    expect(settings.hasAccount, isFalse);
    expect(settings.canSearch, isFalse);
  });
}
