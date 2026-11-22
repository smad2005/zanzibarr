import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform_interface;
import 'package:zanzibarr/player/media_preferences.dart';
import 'package:zanzibarr/player/playback_history.dart';
import 'package:zanzibarr/player/player_launcher.dart';
import 'package:zanzibarr/player/tv/tv_audio_tracks.dart';
import 'package:zanzibarr/player/tv/tv_platform.dart';
import 'package:zanzibarr/player/tv/tv_player_controls.dart';
import 'package:zanzibarr/player/tv/tv_player_screen.dart';
import 'package:zanzibarr/player/tv/tv_stream_backend.dart';
import 'package:zanzibarr/settings/provider_settings.dart';
import 'package:zanzibarr/src/rust/api/streaming.dart';

import 'l10n_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TV audio language preference', () {
    const tracks = [
      VideoAudioTrack(id: '1', language: 'en-US', isSelected: true),
      VideoAudioTrack(id: '2', language: 'en', isSelected: false),
      VideoAudioTrack(id: '3', language: 'tr', isSelected: false),
    ];

    test('exact language wins over regional variants', () {
      expect(pickTvAudioTrackByLanguage(tracks, 'en'), '2');
    });

    test('regional variant is the fallback', () {
      expect(pickTvAudioTrackByLanguage([tracks[0], tracks[2]], 'en'), '1');
      expect(pickTvAudioTrackByLanguage(tracks, 'en-US'), '1');
    });

    test('missing or empty preference does not select a track', () {
      expect(pickTvAudioTrackByLanguage(tracks, null), isNull);
      expect(pickTvAudioTrackByLanguage(tracks, ''), isNull);
      expect(pickTvAudioTrackByLanguage(tracks, 'de'), isNull);
    });
  });

  test('platform capability matrix is explicit', () {
    expect(TvPlatform.tizen.supportsInAppVolume, isTrue);
    expect(TvPlatform.webos.supportsInAppVolume, isFalse);
    expect(TvPlatform.tizen.playerBadge, contains('Tizen'));
    expect(TvPlatform.webos.playerBadge, contains('webOS'));
  });

  test('PlayerLauncher uses the registered backend and file-picker policy', () {
    PlayerLauncher.register(
      ({required nzbPath, initialEntryKey}) =>
          Text('$nzbPath/$initialEntryKey'),
      fileSelection: false,
    );
    expect(PlayerLauncher.supportsFileSelection, isFalse);
    final widget =
        PlayerLauncher.create(
              nzbPath: '/tmp/show.nzb',
              initialEntryKey: 'direct:e2',
            )
            as Text;
    expect(widget.data, '/tmp/show.nzb/direct:e2');
    PlayerLauncher.supportsFileSelection = true;
  });

  group('TvPlayerScreen with fake Rust and video backends', () {
    late _FakeVideoPlatform video;
    late _FakeStreamBackend stream;
    late _MemoryPreferenceStorage preferences;
    late _MemoryPreferenceStorage history;
    late _MemoryPreferenceStorage watched;

    setUp(() {
      video = _FakeVideoPlatform();
      platform_interface.VideoPlayerPlatform.instance = video;
      stream = _FakeStreamBackend();
      preferences = _MemoryPreferenceStorage();
      history = _MemoryPreferenceStorage();
      watched = _MemoryPreferenceStorage();
    });

    Future<void> pumpPlayer(
      WidgetTester tester, {
      TvPlatform platform = TvPlatform.tizen,
      String? entryKey,
      String? audioLanguage,
    }) async {
      final store = MediaPreferencesStore(storage: preferences);
      if (audioLanguage != null) {
        final value = MediaPreferences.defaults().copyWithAudioLanguage(
          audioLanguage,
        );
        await preferences.write(
          MediaPreferencesStore.storageKeyFor('/tmp/show.nzb'),
          value.encode(),
        );
      }
      await tester.pumpWithL10n(
        TvPlayerScreen(
          nzbPath: '/tmp/show.nzb',
          initialEntryKey: entryKey,
          platform: platform,
          store: _CompleteProviderStore(),
          preferenceStore: store,
          historyStore: PlaybackHistoryStore(storage: history),
          watchedStore: WatchedEpisodeStore(storage: watched),
          streamBackend: stream,
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
    }

    testWidgets('opens the native stream and applies saved audio language', (
      tester,
    ) async {
      await pumpPlayer(tester, entryKey: 'direct:e1', audioLanguage: 'tr');

      expect(stream.beganKeys, ['direct:e1']);
      expect(video.selectedAudioTrackIds[1], '2');
      expect(find.textContaining('Episode.One.mkv'), findsWidgets);
      expect(find.textContaining('Tizen Media Player'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('webOS omits in-app volume and unsupported audio picker', (
      tester,
    ) async {
      video.audioSupported = false;
      await pumpPlayer(
        tester,
        entryKey: 'direct:e1',
        platform: TvPlatform.webos,
      );

      expect(video.selectedAudioTrackIds, isEmpty);
      expect(find.textContaining('webOS Media'), findsOneWidget);
      expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('completed episode advances with the correct queue key', (
      tester,
    ) async {
      await pumpPlayer(tester, entryKey: 'direct:e1');
      video.complete(1);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('Şimdi oynat'), findsOneWidget);

      await tester.tap(find.text('Şimdi oynat'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(stream.beganKeys, ['direct:e1', 'direct:e2']);
      expect(stream.stoppedIds, isNotEmpty);
      expect(find.textContaining('Episode.Two.mkv'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('TV controls hide volume on webOS and forward actions', (
    tester,
  ) async {
    var playCount = 0;
    var subtitleCount = 0;
    Duration? seekTarget;
    await tester.pumpWithL10n(
      Scaffold(
        body: TvPlayerControls(
          visible: true,
          ready: true,
          playing: false,
          buffering: false,
          filename: 'demo.mkv',
          status: 'ready',
          position: const Duration(seconds: 3),
          duration: const Duration(seconds: 20),
          rate: 1,
          volume: 80,
          volumeSupported: false,
          audioTracks: const [],
          subtitleEnabled: false,
          playButtonFocusNode: FocusNode(),
          onClose: () {},
          onTogglePlay: () => playCount++,
          onSeek: (target) => seekTarget = target,
          onSeekRelative: (_) {},
          onRate: (_) {},
          onVolume: (_) {},
          onAudioTrack: (_) {},
          onToggleSubtitles: () => subtitleCount++,
          onSearchSubtitles: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.tap(find.byIcon(Icons.subtitles_outlined));
    expect(playCount, 1);
    expect(subtitleCount, 1);

    await tester.drag(find.byType(Slider).first, const Offset(80, 0));
    expect(seekTarget, isNotNull);
  });
}

class _CompleteProviderStore extends ProviderSettingsStore {
  @override
  Future<ProviderSettings> load() async => const ProviderSettings(
    host: 'news.example.com',
    username: 'demo',
    password: 'TESTPASS123',
  );
}

class _MemoryPreferenceStorage implements PlayerPreferenceStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeStreamBackend implements TvStreamBackend {
  final beganKeys = <String?>[];
  final stoppedIds = <BigInt>[];
  var _nextSession = 1;

  @override
  Future<List<PlayableEntryDto>> listEntries(String nzbPath) async => [
    PlayableEntryDto(
      key: 'direct:e1',
      name: 'Episode.One.mkv',
      kind: 'direct',
      encodedBytes: BigInt.from(1000),
      partCount: 1,
      delivery: '',
    ),
    PlayableEntryDto(
      key: 'direct:e2',
      name: 'Episode.Two.mkv',
      kind: 'direct',
      encodedBytes: BigInt.from(1000),
      partCount: 1,
      delivery: '',
    ),
  ];

  @override
  Future<BigInt> begin({
    required ProviderConfigDto config,
    required String nzbPath,
    String? entryKey,
  }) async {
    beganKeys.add(entryKey);
    return BigInt.from(_nextSession++);
  }

  @override
  Future<StreamInfo> awaitInfo(BigInt sessionId) async {
    final second = sessionId.toInt() > 1;
    return StreamInfo(
      sessionId: sessionId,
      url: 'http://127.0.0.1/demo.mkv',
      castUrl: '',
      size: BigInt.from(1000000),
      filename: second ? 'Episode.Two.mkv' : 'Episode.One.mkv',
      segmentCount: 1,
      compressed: false,
    );
  }

  @override
  Future<void> stop(BigInt sessionId) async => stoppedIds.add(sessionId);
}

class _FakeVideoPlatform extends platform_interface.VideoPlayerPlatform {
  bool audioSupported = true;
  final selectedAudioTrackIds = <int, String>{};
  final _events = <int, StreamController<platform_interface.VideoEvent>>{};
  var _nextId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(platform_interface.DataSource dataSource) async {
    final id = _nextId++;
    _events[id] = StreamController<platform_interface.VideoEvent>();
    return id;
  }

  @override
  Stream<platform_interface.VideoEvent> videoEventsFor(int playerId) {
    final controller = _events[playerId]!;
    controller.onListen = () {
      controller.add(
        platform_interface.VideoEvent(
          eventType: platform_interface.VideoEventType.initialized,
          duration: Duration(minutes: 1),
          size: Size(1280, 720),
        ),
      );
    };
    return controller.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async => _emitPlaying(playerId, true);

  @override
  Future<void> pause(int playerId) async => _emitPlaying(playerId, false);

  void _emitPlaying(int playerId, bool playing) {
    _events[playerId]?.add(
      platform_interface.VideoEvent(
        eventType: platform_interface.VideoEventType.isPlayingStateUpdate,
        isPlaying: playing,
      ),
    );
  }

  void complete(int playerId) {
    _events[playerId]?.add(
      platform_interface.VideoEvent(
        eventType: platform_interface.VideoEventType.completed,
      ),
    );
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  bool isAudioTrackSupportAvailable() => audioSupported;

  @override
  Future<List<platform_interface.VideoAudioTrack>> getAudioTracks(
    int playerId,
  ) async => const [
    platform_interface.VideoAudioTrack(
      id: '1',
      label: 'English',
      language: 'en',
      isSelected: true,
    ),
    platform_interface.VideoAudioTrack(
      id: '2',
      label: 'Turkish',
      language: 'tr',
      isSelected: false,
    ),
  ];

  @override
  Future<void> selectAudioTrack(int playerId, String trackId) async {
    selectedAudioTrackIds[playerId] = trackId;
  }
}
