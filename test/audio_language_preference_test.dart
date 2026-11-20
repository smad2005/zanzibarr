import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zanzibarr/player/player_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pickAudioTrackByLanguage', () {
    AudioTrack track(String id, String? language) =>
        AudioTrack(id, null, language);

    test('birebir eşleşme daima kazanır', () {
      final tracks = [
        track('2', 'en-US'),
        track('1', 'en'),
        track('3', 'de'),
      ];
      expect(pickAudioTrackByLanguage(tracks, 'en')?.id, '1');
      expect(pickAudioTrackByLanguage(tracks, 'de')?.id, '3');
    });

    test('alt kodlu etiket tercih başıyla eşleşir', () {
      // "en-US" etiketi "en" tercihini karşılar.
      final tracks = [track('1', 'en-US'), track('2', 'de')];
      expect(pickAudioTrackByLanguage(tracks, 'en')?.id, '1');
      // Ters yön: kısa etiket, alt kodlu tercihi karşılar.
      expect(pickAudioTrackByLanguage(tracks, 'de-AT')?.id, '2');
    });

    test('auto/no ve harici kanallar yok sayılır', () {
      final tracks = [
        track('auto', 'en'),
        track('no', 'en'),
        AudioTrack.uri('file:///dub.mka', title: 'dub', language: 'en'),
        track('1', 'de'),
      ];
      expect(pickAudioTrackByLanguage(tracks, 'en'), isNull);
      expect(pickAudioTrackByLanguage(tracks, 'de')?.id, '1');
    });

    test('dil etiketi olmayan kanallar değerlendirilmez', () {
      final tracks = [track('1', ''), track('2', null), track('3', 'de')];
      expect(pickAudioTrackByLanguage(tracks, 'en'), isNull);
      expect(pickAudioTrackByLanguage(tracks, 'de')?.id, '3');
    });

    test('uygun kanal yoksa null döner', () {
      final tracks = [track('1', 'ja'), track('2', 'fr')];
      expect(pickAudioTrackByLanguage(tracks, 'en'), isNull);
      expect(pickAudioTrackByLanguage(const [], 'en'), isNull);
    });

    test('büyük/küçük harf ve boşluk normalizasyonu', () {
      final tracks = [track('1', ' EN ')];
      expect(pickAudioTrackByLanguage(tracks, 'en')?.id, '1');
    });
  });
}
