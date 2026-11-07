import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:zanzibarr/player/media_preferences.dart';
import 'package:zanzibarr/player/playback_history.dart';
import 'package:zanzibarr/player/player_keyboard_controls.dart';
import 'package:zanzibarr/player/picture_in_picture_window.dart';
import 'package:zanzibarr/cast/cast_service.dart';
import 'package:zanzibarr/l10n/app_localizations.dart';
import 'package:zanzibarr/settings/provider_settings.dart';

class _MemoryPreferenceStorage implements PlayerPreferenceStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _FakeProviderSettingsStore extends Fake implements ProviderSettingsStore {
  @override
  Future<ProviderSettings> load() async => ProviderSettings(
    host: 'test',
    port: 119,
    username: 'test',
    password: 'test',
    maxConnections: 1,
  );
}

class _FakePictureInPictureWindow extends Fake implements PictureInPictureWindow {
  @override
  Stream<PictureInPictureChange> get changes => const Stream.empty();
  
  @override
  bool get isSupported => false;
}

class _FakeCastController extends Fake implements CastController {
  @override
  Future<void> dispose() async {}
}

class _FakeHandler implements PlayerKeyboardHandler {
  @override
  bool playbackReady = true;
  @override
  bool playing = true;
  @override
  bool controlsVisible = false;
  @override
  bool canvasEditing = false;
  @override
  bool subtitleControlsVisible = false;
  @override
  bool isPictureInPicture = false;
  @override
  bool isFullscreen = false;
  @override
  bool remoteNavigationMode = true;
  @override
  Duration seekStep = const Duration(seconds: 10);

  int closeCount = 0;

  @override
  void revealControls() {}
  @override
  void hideControls() {}
  @override
  void togglePlay() {}
  @override
  void seekRelative(Duration offset) {}
  @override
  void adjustVolume(double delta) {}
  @override
  void beginFastScan(int direction) {}
  @override
  void endFastScan() {}
  @override
  void toggleFullscreen() {}
  @override
  void exitFullscreen() {}
  @override
  void togglePictureInPicture() {}
  @override
  void toggleCanvasEditor() {}
  @override
  void cancelCanvasEditing() {}
  @override
  void toggleSubtitleControls() {}
  @override
  void dismissSubtitleControls() {}
  @override
  void stepBackward() {}
  @override
  void stepForward() {}
  @override
  void nudgeSubtitleDelay(Duration delta) {}
  @override
  void closePlayer() => closeCount++;
  @override
  void focusPlayButton() {}
}

void main() {
  group('PlaybackHistoryStore', () {
    late _MemoryPreferenceStorage historyStorage;
    late PlaybackHistoryStore historyStore;

    setUp(() {
      historyStorage = _MemoryPreferenceStorage();
      historyStore = PlaybackHistoryStore(storage: historyStorage);
    });

    test('save and load entry works correctly', () async {
      await historyStore.save(PlaybackHistoryEntry(
        nzbPath: '/media/test.nzb',
        entryKey: 'rar:e01',
        title: 'test.mkv',
        positionSeconds: 120.5,
        durationSeconds: 3600,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));

      final entry = await historyStore.entryFor('/media/test.nzb', entryKey: 'rar:e01');
      expect(entry, isNotNull);
      expect(entry!.positionSeconds, 120.5);
    });

    test('entries with position <= 3 seconds are not saved by player (store saves all)', () async {
      await historyStore.save(PlaybackHistoryEntry(
        nzbPath: '/media/short.nzb',
        entryKey: null,
        title: 'short.mkv',
        positionSeconds: 2.0,
        durationSeconds: 100,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));

      final entries = await historyStore.load();
      expect(entries, hasLength(1));
    });

    test('entry with position > 3 seconds is saved', () async {
      await historyStore.save(PlaybackHistoryEntry(
        nzbPath: '/media/long.nzb',
        entryKey: null,
        title: 'long.mkv',
        positionSeconds: 10.0,
        durationSeconds: 100,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));

      final entries = await historyStore.load();
      expect(entries, hasLength(1));
      expect(entries.single.positionSeconds, 10.0);
    });
  });

  group('PlayerKeyboardHandler closePlayer behavior', () {
    testWidgets('closePlayer is called when Back pressed with controls hidden', (WidgetTester tester) async {
      final handler = _FakeHandler();
      handler.controlsVisible = false;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerKeyboardControls(
              handler: handler,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
      await tester.pump();

      expect(handler.closeCount, 1);
    });

    testWidgets('closePlayer is called when Escape pressed with controls hidden in TV mode', (WidgetTester tester) async {
      final handler = _FakeHandler();
      handler.controlsVisible = false;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerKeyboardControls(
              handler: handler,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(handler.closeCount, 1);
    });

    testWidgets('closePlayer is NOT called when controls visible (first hides controls)', (WidgetTester tester) async {
      final handler = _FakeHandler();
      handler.controlsVisible = true;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerKeyboardControls(
              handler: handler,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
      await tester.pump();

      expect(handler.closeCount, 0);
    });
  });
}