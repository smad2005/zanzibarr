import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/settings/provider_settings.dart';

/// Secure storage method channel'ını bellek içi haritayla taklit eder.
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

  test('Boş depoda profiller ve ayarlar boştur', () async {
    final store = ProviderSettingsStore();
    expect(await store.loadProfiles(), isEmpty);
    expect((await store.load()).isComplete, isFalse);
  });

  test('Eski tek hesap anahtarları ilk açılışta profile taşınır', () async {
    // v1.9 ve öncesinin saklama düzenü: alan başına tek anahtar.
    _memoryStorage['provider.host'] = 'secure-eu.news.easynews.com';
    _memoryStorage['provider.port'] = '563';
    _memoryStorage['provider.username'] = 'kullanici';
    _memoryStorage['provider.password'] = 'TESTPASS123';
    _memoryStorage['provider.maxConnections'] = '12';

    final store = ProviderSettingsStore();
    final profiles = await store.loadProfiles();
    expect(profiles.length, 1);
    expect(profiles.first.id, 'default');
    expect(profiles.first.host, 'secure-eu.news.easynews.com');
    expect(profiles.first.maxConnections, 12);

    // load() aktif (taşınan) hesabı döner — mevcut çağrı noktaları (akış,
    // ön kontrol) davranış değişikliği yaşamaz.
    final settings = await store.load();
    expect(settings.host, 'secure-eu.news.easynews.com');
    expect(settings.username, 'kullanici');
    expect(settings.maxConnections, 12);
    expect(await store.activeProfileId(), 'default');
  });

  test('saveProfile yeni hesap ekler ve aktif yapar', () async {
    final store = ProviderSettingsStore();
    const first = ProviderProfile(
      id: 'a',
      label: 'Ev',
      host: 'news.example.com',
      username: 'u1',
      password: 'TESTPASS123',
    );
    const second = ProviderProfile(
      id: 'b',
      label: 'Yedek',
      host: 'backup.example.com',
      username: 'u2',
      password: 'TESTPASS123',
    );

    await store.saveProfile(first);
    expect((await store.load()).host, 'news.example.com');
    expect(await store.activeProfileId(), 'a');

    await store.saveProfile(second);
    // Kaydedilen hesap akışta kullanılacak hesap olur.
    expect((await store.load()).host, 'backup.example.com');
    expect(await store.activeProfileId(), 'b');

    // Aktif olmayan hesap listede durur; yeniden kaydedilince aktifleşir.
    await store.saveProfile(first);
    expect((await store.load()).host, 'news.example.com');
    expect(
      (await store.loadProfiles()).map((p) => p.id),
      containsAll(['a', 'b']),
    );
  });

  test('deleteProfile aktif hesabı silince aktiflik kalana geçer', () async {
    final store = ProviderSettingsStore();
    await store.saveProfile(
      const ProviderProfile(
        id: 'a',
        host: 'news.example.com',
        username: 'u1',
        password: 'TESTPASS123',
      ),
    );
    await store.saveProfile(
      const ProviderProfile(
        id: 'b',
        host: 'backup.example.com',
        username: 'u2',
        password: 'TESTPASS123',
      ),
    );
    await store.deleteProfile('b');
    expect((await store.loadProfiles()).map((p) => p.id), ['a']);
    expect(await store.activeProfileId(), 'a');
    expect((await store.load()).host, 'news.example.com');

    // Son profil silinirse depo boşalır; load() varsayılana döner.
    await store.deleteProfile('a');
    expect(await store.loadProfiles(), isEmpty);
    expect((await store.load()).isComplete, isFalse);
  });

  test("Eski save() APIsi aktif profili günceller", () async {
    final store = ProviderSettingsStore();
    await store.saveProfile(
      const ProviderProfile(
        id: 'a',
        host: 'news.example.com',
        username: 'u1',
        password: 'TESTPASS123',
      ),
    );
    await store.save(
      const ProviderSettings(
        host: 'news.example.com',
        username: 'degisti',
        password: 'TESTPASS123',
      ),
    );
    final profiles = await store.loadProfiles();
    expect(profiles.length, 1);
    expect(profiles.first.id, 'a');
    expect(profiles.first.username, 'degisti');
  });

  test('Bozuk profil JSONu sessizce boş liste okunur', () async {
    _memoryStorage['provider.profiles'] = '[{1, bad';
    final store = ProviderSettingsStore();
    expect(await store.loadProfiles(), isEmpty);
    // Eski anahtarlardan taşınacak veri de yoksa ayarlar boştur.
    expect((await store.load()).isComplete, isFalse);
  });

  test('Profilsiz depoya save() varsayılan profili oluşturur', () async {
    final store = ProviderSettingsStore();
    await store.save(
      const ProviderSettings(
        host: 'news.example.com',
        username: 'u1',
        password: 'TESTPASS123',
      ),
    );
    final profiles = await store.loadProfiles();
    expect(profiles.length, 1);
    expect(profiles.first.host, 'news.example.com');
    expect(await store.activeProfileId(), profiles.first.id);
  });

  test('Etiket görünüm adı belirler: etiket → host → kullanıcı adı', () {
    const profile = ProviderProfile(
      id: 'a',
      label: 'Ev hesabı',
      host: 'news.example.com',
      username: 'u1',
    );
    expect(profile.displayName, 'Ev hesabı');
    const unlabeled = ProviderProfile(
      id: 'b',
      host: 'news.example.com',
      username: 'u1',
    );
    expect(unlabeled.displayName, 'news.example.com');
    const empty = ProviderProfile(id: 'c', username: 'u1');
    expect(empty.displayName, 'u1');
  });
}
