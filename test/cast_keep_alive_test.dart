import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/cast/cast_keep_alive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.zanzibarr/cast_keep_alive');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('starts cast keep-alive once on Android', (tester) async {
    final keepAlive = CastKeepAlive(isAndroid: true);
    await keepAlive.start(title: 'Film.mkv', device: 'Salon TV');
    await keepAlive.start(title: 'Film.mkv', device: 'Salon TV');
    expect(calls, ['start']);
  });

  testWidgets('stops cast keep-alive once', (tester) async {
    final keepAlive = CastKeepAlive(isAndroid: true);
    await keepAlive.start(title: 'Film.mkv', device: 'Salon TV');
    await keepAlive.stop();
    await keepAlive.stop();
    expect(calls, ['start', 'stop']);
  });

  testWidgets('does nothing outside Android', (tester) async {
    final keepAlive = CastKeepAlive(isAndroid: false);
    await keepAlive.start(title: 'Film.mkv', device: 'Salon TV');
    await keepAlive.stop();
    expect(calls, isEmpty);
  });
}
