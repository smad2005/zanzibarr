import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/player/picture_in_picture_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'desteklenen native masaüstünde PiP kanalına giriş ve çıkış gönderiliyor',
    () async {
      const channel = MethodChannel('com.zanzibarr/test-window');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final window = NativePictureInPictureWindow(
        channel: channel,
        supported: true,
      );

      expect(window.isSupported, isTrue);
      expect(await window.enter(), isTrue);
      expect(await window.exit(), isTrue);
      expect(calls, ['enterPictureInPicture', 'exitPictureInPicture']);
    },
  );

  test(
    'desteklenmeyen platform kanal çağrısı yapmadan false döndürür',
    () async {
      const channel = MethodChannel('com.zanzibarr/test-window-unsupported');
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final window = NativePictureInPictureWindow(
        channel: channel,
        supported: false,
      );

      expect(window.isSupported, isFalse);
      expect(await window.enter(), isFalse);
      expect(await window.exit(), isFalse);
      expect(calls, 0);
    },
  );

  test('enter forwards video size as aspect ratio arguments', () async {
    const channel = MethodChannel('com.zanzibarr/test-window-size');
    final arguments = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          arguments.add(call.arguments);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final window = NativePictureInPictureWindow(
      channel: channel,
      supported: true,
    );

    expect(await window.enter(width: 1920, height: 1080), isTrue);
    expect(await window.enter(), isTrue);
    expect(arguments, [
      {'width': 1920, 'height': 1080},
      null,
    ]);
  });

  test('changes stream reports native picture-in-picture events', () async {
    const channel = MethodChannel('com.zanzibarr/test-window-events');
    final window = NativePictureInPictureWindow(
      channel: channel,
      supported: true,
    );
    final received = <PictureInPictureChange>[];
    final subscription = window.changes.listen(received.add);
    addTearDown(subscription.cancel);
    addTearDown(() => channel.setMethodCallHandler(null));

    Future<void> send(Map<String, Object> arguments) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(
                MethodCall('pictureInPictureChanged', arguments),
              ),
              (_) {},
            );

    await send({'active': true, 'dismissed': false});
    await send({'active': false, 'dismissed': true});
    await Future<void>.delayed(Duration.zero);

    expect(received.map((change) => (change.active, change.dismissed)), [
      (true, false),
      (false, true),
    ]);
  });
}
