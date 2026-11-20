import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/settings/provider_settings.dart';
import 'package:zanzibarr/settings/settings_screen.dart';

import 'l10n_test_helper.dart';

/// Gerçek secure storage yerine bellek içi sahte depo.
class _FakeStore extends ProviderSettingsStore {
  ProviderSettings saved = const ProviderSettings();
  List<ProviderProfile> profiles = const [];
  String? activeId;

  @override
  Future<List<ProviderProfile>> loadProfiles() async => profiles;

  @override
  Future<String?> activeProfileId() async => activeId;

  @override
  Future<void> saveProfile(ProviderProfile profile) async {
    final index = profiles.indexWhere((p) => p.id == profile.id);
    final updated = profiles.toList();
    if (index >= 0) {
      updated[index] = profile;
    } else {
      updated.add(profile);
    }
    profiles = updated;
    activeId = profile.id;
    // Eski API ile yazılan denetimler için ayarlar görünümüne de yansıt.
    saved = profile.settings;
  }

  @override
  Future<void> deleteProfile(String id) async {
    profiles = profiles.where((p) => p.id != id).toList();
    if (activeId == id) {
      activeId = profiles.isEmpty ? null : profiles.first.id;
    }
  }

  @override
  Future<ProviderSettings> load() async => saved;
}

/// Ayarlar ekranı artık hesap kartıyla uzun: test yüzeyi uzaltılırsa tüm
/// bölümler tek ekranda kurulur (ListView tembel kurulumu FormField
/// durumunu düşürür — kaydırınca doğrulama hatası kaybolur).
void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('Ayarlar formu doldurulup depoya kaydediliyor', (tester) async {
    final store = _FakeStore();
    _tallSurface(tester);
    await tester.pumpWithL10n(SettingsScreen(store: store));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Sunucu adresi'),
      'news.example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Kullanıcı adı'),
      'kullanici',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Parola'),
      'cok-gizli',
    );

    await tester.tap(find.text('Güvenle kaydet'));
    await tester.pumpAndSettle();

    expect(store.saved.host, 'news.example.com');
    expect(store.saved.port, 563);
    expect(store.saved.username, 'kullanici');
    expect(store.saved.password, 'cok-gizli');
    expect(store.saved.maxConnections, 10);
    expect(store.saved.isComplete, isTrue);
    expect(find.text('Ayarlar güvenli depoya kaydedildi.'), findsOneWidget);
  });

  testWidgets('Boş sunucu adresi kaydı engelliyor', (tester) async {
    final store = _FakeStore();
    _tallSurface(tester);
    await tester.pumpWithL10n(SettingsScreen(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Güvenle kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Sunucu adresi gerekli'), findsOneWidget);
    expect(store.saved.host, isEmpty);
  });

  testWidgets('Hesap seçici kayıtlı hesaplar arasında geçiş yapar', (
    tester,
  ) async {
    final store = _FakeStore()
      ..profiles = const [
        ProviderProfile(
          id: 'a',
          label: 'Ev',
          host: 'news.example.com',
          username: 'ev-user',
          password: 'TESTPASS123',
        ),
        ProviderProfile(
          id: 'b',
          label: 'Yedek',
          host: 'backup.example.com',
          username: 'yedek-user',
          password: 'TESTPASS123',
        ),
      ]
      ..activeId = 'a';
    _tallSurface(tester);
    await tester.pumpWithL10n(SettingsScreen(store: store));
    await tester.pumpAndSettle();

    // Aktif hesabın ("Ev") alanları forma yüklendi.
    expect(find.widgetWithText(TextFormField, 'ev-user'), findsOneWidget);

    // Seçiciyi aç (formdaki hesap-adı alanının değeri de "Ev" olduğundan
    // rastgele eşleşmeden kaçınmak için açılır düğmenin alt metni hedefli-
    // nir), ardından menüden ikinci hesabı seç.
    await tester.tap(
      find
          .descendant(
            of: find.byType(DropdownButtonFormField<String>),
            matching: find.text('Ev'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yedek').last);
    await tester.pumpAndSettle();

    // Alanlar seçilen hesabın değerleriyle doldu.
    expect(find.widgetWithText(TextFormField, 'yedek-user'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'ev-user'), findsNothing);

    // Kaydet seçilen hesabı günceller ve aktif yapar.
    await tester.tap(find.text('Güvenle kaydet'));
    await tester.pumpAndSettle();
    expect(store.activeId, 'b');
    expect(store.saved.host, 'backup.example.com');

    // Kayıt aktifliği değiştirir ama hesap listesi aynı kalır.
    expect(store.profiles.length, 2);
  });
}
