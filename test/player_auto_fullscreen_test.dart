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

  test('enters fullscreen at startup when already in landscape', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(
        shouldAutoEnterFullscreenOnReady(
          platform: platform,
          orientation: Orientation.landscape,
          pictureInPicture: false,
          fullscreen: false,
        ),
        isTrue,
        reason: '$platform',
      );
    }
  });

  test('startup check skips portrait, desktop, PiP and existing fullscreen', () {
    bool decide({
      TargetPlatform platform = TargetPlatform.android,
      Orientation orientation = Orientation.landscape,
      bool pictureInPicture = false,
      bool fullscreen = false,
    }) =>
        shouldAutoEnterFullscreenOnReady(
          platform: platform,
          orientation: orientation,
          pictureInPicture: pictureInPicture,
          fullscreen: fullscreen,
        );

    expect(decide(orientation: Orientation.portrait), isFalse);
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      expect(decide(platform: platform), isFalse, reason: '$platform');
    }
    expect(decide(pictureInPicture: true), isFalse);
    expect(decide(fullscreen: true), isFalse);
  });
}
