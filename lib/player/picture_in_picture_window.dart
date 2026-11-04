import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class PictureInPictureChange {
  const PictureInPictureChange({required this.active, this.dismissed = false});

  final bool active;
  final bool dismissed;
}

/// Oynatıcı penceresini kompakt, diğer pencerelerin üstünde kalan moda alır.
///
/// Yerel pencere uygulaması macOS ve Windows'tadır. Desteklenmeyen
/// platformlarda çağrılar güvenli biçimde `false` döndürür.
abstract interface class PictureInPictureWindow {
  bool get isSupported;

  Stream<PictureInPictureChange> get changes;

  Future<bool> enter({int? width, int? height});

  Future<bool> exit();
}

class NativePictureInPictureWindow implements PictureInPictureWindow {
  NativePictureInPictureWindow({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('com.zanzibarr/window'),
      _supported =
          supported ??
          (Platform.isMacOS || Platform.isWindows || Platform.isAndroid);

  final MethodChannel _channel;
  final bool _supported;
  StreamController<PictureInPictureChange>? _changes;

  @override
  bool get isSupported => _supported;

  @override
  Stream<PictureInPictureChange> get changes {
    final existing = _changes;
    if (existing != null) return existing.stream;
    final controller = StreamController<PictureInPictureChange>.broadcast();
    _changes = controller;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'pictureInPictureChanged') return;
      final arguments = call.arguments;
      if (arguments is! Map) return;
      controller.add(
        PictureInPictureChange(
          active: arguments['active'] == true,
          dismissed: arguments['dismissed'] == true,
        ),
      );
    });
    return controller.stream;
  }

  @override
  Future<bool> enter({int? width, int? height}) =>
      _invoke('enterPictureInPicture', {
        'width': ?width,
        'height': ?height,
      });

  @override
  Future<bool> exit() => _invoke('exitPictureInPicture');

  Future<bool> _invoke(String method, [Map<String, Object>? arguments]) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>(
            method,
            arguments == null || arguments.isEmpty ? null : arguments,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
