import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/settings/doh_settings.dart';

void main() {
  test('defaults enable Cloudflare resolver', () {
    final settings = DohSettings.defaults;
    expect(settings.enabled, isTrue);
    expect(settings.provider, DohProvider.cloudflare);
    expect(settings.endpoint, 'https://cloudflare-dns.com/dns-query');
  });

  test('disabled settings have no endpoint', () {
    const settings = DohSettings(
      enabled: false,
      provider: DohProvider.google,
    );
    expect(settings.endpoint, isEmpty);
  });

  test('custom endpoint is trimmed', () {
    const settings = DohSettings(
      enabled: true,
      provider: DohProvider.custom,
      customUrl: '  https://dns.example/dns-query  ',
    );
    expect(settings.endpoint, 'https://dns.example/dns-query');
  });

  test('unknown provider falls back to Cloudflare', () {
    final settings = DohSettings.fromJson({
      'enabled': true,
      'provider': 'unknown',
      'customUrl': '',
    });
    expect(settings.provider, DohProvider.cloudflare);
    expect(settings.enabled, isTrue);
  });
}
