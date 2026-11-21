import 'dart:io';

import 'package:flutter/services.dart';

class CastKeepAlive {
  CastKeepAlive({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel(_channelName),
      _isAndroid = isAndroid ?? Platform.isAndroid;

  static final CastKeepAlive instance = CastKeepAlive();
  static const String _channelName = 'com.zanzibarr/cast_keep_alive';

  final MethodChannel _channel;
  final bool _isAndroid;
  bool _started = false;

  Future<void> start({
    required String title,
    required String device,
  }) async {
    if (!_isAndroid || _started) return;
    _started = true;
    try {
      await _channel.invokeMethod<void>('start', {
        'title': title,
        'device': device,
      });
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_isAndroid || !_started) return;
    _started = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
