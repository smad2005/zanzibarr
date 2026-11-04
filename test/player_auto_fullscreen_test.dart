import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanzibarr/player/player_screen.dart';

bool _decide({
  TargetPlatform platform = TargetPlatform.android,
  Orientation? previous = Orientation.portrait,
  Orientation current = Orientation.landscape,
  bool ready = true,
  bool pictureInPicture = false,
  bool fullscreen = false,
}) => shouldAutoEnterFullscreen(
  platform: platform,
  previous: previous,
  current: current,
  ready: ready,
  pictureInPicture: pictureInPicture,
  fullscreen: fullscreen,
);

void main() {
  test('enters fullscreen when a mobile device rotates to landscape', () {
    expect(_decide(platform: TargetPlatform.android), isTrue);
    expect(_decide(platform: TargetPlatform.iOS), isTrue);
  });

  test('ignores desktop platforms', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      expect(_decide(platform: platform), isFalse, reason: '$platform');
    }
  });

  test('requires a portrait to landscape transition', () {
    expect(_decide(previous: null), isFalse);
    expect(_decide(previous: Orientation.landscape), isFalse);
    expect(_decide(current: Orientation.portrait), isFalse);
  });

  test('skips when playback is not ready', () {
    expect(_decide(ready: false), isFalse);
  });

  test('skips when already fullscreen or in picture-in-picture', () {
    expect(_decide(fullscreen: true), isFalse);
    expect(_decide(pictureInPicture: true), isFalse);
  });
}
