import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../cast/cast_device_picker.dart';
import '../../cast/cast_service.dart';
import '../../l10n/app_localizations.dart';
import '../../settings/opensubtitles_settings.dart';
import '../../settings/provider_settings.dart';
import '../../src/rust/api/streaming.dart';
import '../../src/rust/api/subtitles.dart'
    show
        OpenSubtitlesConfigDto,
        SubtitleDto,
        downloadOpensubtitles,
        searchOpensubtitles;
import '../chapter.dart';
import '../entry_picker.dart';
import '../media_preferences.dart';
import '../picture_in_picture_window.dart';
import '../smart_canvas.dart';
import '../smart_canvas_overlay.dart';
import '../playback_history.dart';
import '../playback_startup_guard.dart';
import '../player_keyboard_controls.dart';
import '../subtitle_search_dialog.dart';
import '../up_next_overlay.dart';
import 'chapters_source.dart';
import 'tv_audio_tracks.dart';
import 'tv_platform.dart';
import 'tv_player_controls.dart';
import 'tv_stream_backend.dart';

/// Native Tizen/webOS player backed by Flutter's video_player plugin.
///
/// The Rust range server is shared with the media_kit builds. Only the video
/// renderer and its controls differ: no libmpv, codecs or platform channels
/// are loaded by this screen beyond the official TV plugins.
class TvPlayerScreen extends StatefulWidget {
  const TvPlayerScreen({
    super.key,
    required this.nzbPath,
    this.initialEntryKey,
    this.platform = TvPlatform.tizen,
    this.store,
    this.preferenceStore,
    this.historyStore,
    this.watchedStore,
    this.osStore,
    this.osSearchFn,
    this.osDownloadFn,
    this.streamBackend,
    this.castService,
    this.pictureInPictureWindow,
    this.chapters = const [],
    this.loadChapters = false,
    this.startupTimeout = const Duration(seconds: 45),
  });

  final String nzbPath;
  final String? initialEntryKey;
  final TvPlatform platform;
  final ProviderSettingsStore? store;
  final MediaPreferencesStore? preferenceStore;
  final PlaybackHistoryStore? historyStore;
  final WatchedEpisodeStore? watchedStore;
  final OpenSubtitlesSettingsStore? osStore;
  final OpenSubtitlesSearchFn? osSearchFn;
  final OpenSubtitlesDownloadFn? osDownloadFn;
  final TvStreamBackend? streamBackend;
  final CastController? castService;
  final PictureInPictureWindow? pictureInPictureWindow;
  final List<Chapter> chapters;
  final bool loadChapters;
  final Duration startupTimeout;

  @override
  State<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends State<TvPlayerScreen>
    implements PlayerKeyboardHandler {
  late final TvStreamBackend _backend =
      widget.streamBackend ?? const FrbTvStreamBackend();
  late final MediaPreferencesStore _preferenceStore =
      widget.preferenceStore ?? MediaPreferencesStore();
  late final PlaybackHistoryStore _historyStore =
      widget.historyStore ?? PlaybackHistoryStore();
  late final WatchedEpisodeStore _watchedStore =
      widget.watchedStore ?? WatchedEpisodeStore();
  late final OpenSubtitlesSettingsStore _osStore =
      widget.osStore ?? OpenSubtitlesSettingsStore();
  late final OpenSubtitlesSearchFn _osSearchFn =
      widget.osSearchFn ?? _defaultOpenSubtitlesSearch;
  late final OpenSubtitlesDownloadFn _osDownloadFn =
      widget.osDownloadFn ?? _defaultOpenSubtitlesDownload;

  final _keyboardFocusNode = FocusNode(debugLabel: 'TV player keyboard root');
  final _playButtonFocusNode = FocusNode(debugLabel: 'TV play button');

  VideoPlayerController? _controller;
  StreamInfo? _info;
  BigInt? _sessionId;
  String? _resolvedEntryKey;
  ProviderSettings _providerSettings = const ProviderSettings();
  MediaPreferences _preferences = MediaPreferences.defaults();
  List<PlayableEntryDto> _queue = const [];
  List<PlayableEntryDto> _entries = const [];
  PlayableEntryDto? _upNext;
  List<VideoAudioTrack> _audioTracks = const [];
  List<Chapter> _chapters = const [];
  late final CastController _castService;
  CastSession? _castSession;
  bool _castBusy = false;
  String? _castDeviceName;
  StreamSubscription<Duration>? _castPositionSubscription;
  late final PictureInPictureWindow _pictureInPictureWindow;
  bool _isPictureInPicture = false;
  bool _videoFill = false;
  bool _canvasEditing = false;
  CanvasCrop _canvasCrop = const CanvasCrop.full();

  Object? _error;
  String _status = '';
  bool _ready = false;
  bool _playing = false;
  bool _buffering = false;
  bool _disposing = false;
  bool _completionHandled = false;
  bool _subtitleEnabled = false;
  bool _subtitlePanelVisible = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _subtitleDelay = Duration.zero;
  double _rate = 1.0;
  double _volume = 100;
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  Timer? _historyTimer;

  @override
  void initState() {
    super.initState();
    _castService = widget.castService ?? AppCastService();
    _pictureInPictureWindow =
        widget.pictureInPictureWindow ?? NativePictureInPictureWindow();
    unawaited(_start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_status.isEmpty) _status = AppLocalizations.of(context).statusPreparing;
  }

  Future<void> _start() async {
    try {
      await _loadPreferences();
      final store = widget.store ?? ProviderSettingsStore();
      _providerSettings = await store.load();
      if (!_providerSettings.isComplete) {
        if (!mounted) return;
        setState(
          () => _error = AppLocalizations.of(
            context,
          ).errorProviderSettingsMissing,
        );
        return;
      }

      var entries = const <PlayableEntryDto>[];
      try {
        entries = await _backend.listEntries(widget.nzbPath);
      } catch (_) {
        // beginStream has the authoritative, more detailed error surface.
      }
      var entryKey = widget.initialEntryKey;
      if (entryKey == null && entries.length > 1) {
        if (!mounted) return;
        entryKey = await showPlayableEntryPicker(context, entries);
        if (entryKey == null) {
          if (mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _queue = queueAfterEntry(entries, entryKey);
      });
      await _openEntry(entryKey);
    } catch (error) {
      await _fail(error);
    }
  }

  Future<void> _loadPreferences() async {
    try {
      _preferences = await _preferenceStore.load(widget.nzbPath);
      _canvasCrop = CanvasCrop(
        left: _preferences.crop.left,
        top: _preferences.crop.top,
        right: _preferences.crop.right,
        bottom: _preferences.crop.bottom,
      );
      _subtitleDelay = Duration(
        milliseconds: (_preferences.subtitleDelaySeconds * 1000).round(),
      );
    } catch (_) {
      _preferences = MediaPreferences.defaults();
      _canvasCrop = const CanvasCrop.full();
      _subtitleDelay = Duration.zero;
    }
  }

  Future<void> _loadChapters(String url) async {
    final found = await loadStreamChapters(url);
    if (!mounted || _disposing || found.isEmpty) return;
    setState(() => _chapters = found);
  }

  Future<void> _openEntry(String? entryKey) async {
    _resolvedEntryKey = entryKey;
    _completionHandled = false;
    _subtitleEnabled = false;
    _audioTracks = const [];
    _position = Duration.zero;
    _duration = Duration.zero;
    _ready = false;
    _playing = false;
    _buffering = false;
    _error = null;
    _upNext = null;
    await _disposeController();
    await _stopSession();

    final sessionId = await _backend.begin(
      config: ProviderConfigDto(
        host: _providerSettings.host,
        port: _providerSettings.port,
        username: _providerSettings.username,
        password: _providerSettings.password,
        maxConnections: _providerSettings.maxConnections,
      ),
      nzbPath: widget.nzbPath,
      entryKey: entryKey,
    );
    _sessionId = sessionId;
    final info = await _backend.awaitInfo(sessionId);
    if (_disposing || !mounted) {
      await _backend.stop(sessionId);
      return;
    }
    _info = info;
    setState(() {
      _chapters = widget.chapters;
    });
    if (widget.loadChapters && widget.chapters.isEmpty) {
      unawaited(_loadChapters(info.url));
    }
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(info.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _controller = controller;
    controller.addListener(_onControllerChanged);
    await controller.initialize().timeout(widget.startupTimeout);
    if (_disposing || !mounted) return;

    await controller.setLooping(false);
    if (widget.platform.supportsInAppVolume) {
      await controller.setVolume(_volume / 100);
    }
    await controller.setPlaybackSpeed(_rate);
    controller.setCaptionOffset(_subtitleDelay);
    await _loadAudioTracks();
    await _resumeHistory();
    if (!mounted) return;
    setState(() {
      _ready = true;
      _status = AppLocalizations.of(context).statusPlaying(info.filename);
    });
    unawaited(_autoLoadExternalSubtitle(info));
    await controller.play();
    _historyTimer?.cancel();
    _historyTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_saveHistory()),
    );
    _revealControls();
  }

  void _onControllerChanged() {
    final controller = _controller;
    if (!mounted || controller == null || _disposing) return;
    final value = controller.value;
    if (value.hasError) {
      unawaited(_fail(value.errorDescription ?? 'video_player'));
      return;
    }
    setState(() {
      _position = value.position;
      _duration = value.duration;
      _playing = value.isPlaying;
      _buffering = value.isBuffering;
      if (value.isBuffering && _info != null) {
        _status = AppLocalizations.of(context).statusBuffering(_info!.filename);
      } else if (_ready && _info != null) {
        _status = AppLocalizations.of(context).statusPlaying(_info!.filename);
      }
    });
    if (value.isCompleted) _onCompleted();
  }

  Future<void> _resumeHistory() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final history = await _historyStore.entryFor(
        widget.nzbPath,
        entryKey: _resolvedEntryKey,
      );
      if (history == null || history.isCompleted) return;
      if (history.position > Duration.zero) {
        await controller.seekTo(history.position);
      }
    } catch (_) {
      // History is optional and must never prevent playback.
    }
  }

  Future<void> _saveHistory() async {
    final info = _info;
    if (info == null || _duration <= Duration.zero) return;
    try {
      await _historyStore.save(
        PlaybackHistoryEntry(
          nzbPath: widget.nzbPath,
          entryKey: _resolvedEntryKey,
          title: info.filename,
          positionSeconds: _position.inMilliseconds / 1000,
          durationSeconds: _duration.inMilliseconds / 1000,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (_) {}
  }

  void _onCompleted() {
    if (_completionHandled || !_ready || _disposing) return;
    _completionHandled = true;
    unawaited(_saveHistory());
    final key = _resolvedEntryKey;
    final info = _info;
    if (key != null && info != null) {
      unawaited(
        _watchedStore.add(
          WatchedEpisodeEntry(
            nzbPath: widget.nzbPath,
            entryKey: key,
            title: info.filename,
            watchedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
    }
    if (_queue.isNotEmpty && mounted) {
      setState(() => _upNext = _queue.first);
    }
  }

  Future<void> _playUpNextNow() async {
    if (_queue.isEmpty) return;
    final next = _queue.first;
    setState(() {
      _queue = _queue.skip(1).toList(growable: false);
      _upNext = null;
    });
    // The entry key is carried through the queue item; resume/history uses the
    // same key on the next episode through this local replacement.
    await _openEntry(next.key);
  }

  void _dismissUpNext() {
    if (mounted) setState(() => _upNext = null);
  }

  void _clearUpNextQueue() {
    if (mounted) {
      setState(() {
        _queue = const [];
        _upNext = null;
      });
    }
  }

  void _toggleVideoFit() {
    if (mounted) setState(() => _videoFill = !_videoFill);
  }

  Future<void> _togglePictureInPicture() async {
    final controller = _controller;
    if (controller == null || !_pictureInPictureWindow.isSupported) return;
    final enter = !_isPictureInPicture;
    final size = controller.value.size;
    final changed = enter
        ? await _pictureInPictureWindow.enter(
            width: size.width <= 0 ? null : size.width.toInt(),
            height: size.height <= 0 ? null : size.height.toInt(),
          )
        : await _pictureInPictureWindow.exit();
    if (!mounted || !changed) return;
    setState(() => _isPictureInPicture = enter);
  }

  void _toggleCanvasEditor() {
    if (!mounted) return;
    setState(() => _canvasEditing = !_canvasEditing);
  }

  void _commitCanvasCrop(CanvasCrop crop) {
    _canvasCrop = clampCanvasCrop(crop, minimumExtent: 0.000001);
    if (!mounted) return;
    setState(() => _canvasEditing = false);
    final rect = NormalizedCropRect(
      left: _canvasCrop.left,
      top: _canvasCrop.top,
      right: _canvasCrop.right,
      bottom: _canvasCrop.bottom,
    );
    unawaited(_preferenceStore.save(widget.nzbPath, _preferences.copyWith(crop: rect)));
  }

  Future<void> _switchEpisode() async {
    if (_entries.length < 2 || !mounted) return;
    final key = await showPlayableEntryPicker(context, _entries);
    if (key == null || !mounted || key == _resolvedEntryKey) return;
    await _saveHistory();
    await _openEntry(key);
  }

  Future<void> _toggleCast() async {
    if (_castSession != null) {
      await _endCastSession();
      return;
    }
    final url = _info?.castUrl ?? '';
    if (url.isEmpty || !mounted) {
      _showCastMessage(AppLocalizations.of(context).castUnavailable);
      return;
    }
    final l10n = AppLocalizations.of(context);
    final device = await CastDevicePicker.show(context, service: _castService);
    _castService.stopDiscovery();
    if (device == null || !mounted) return;
    setState(() => _castBusy = true);
    try {
      final session = await _castService.startCasting(
        device,
        url: url,
        title: _info?.filename ?? '',
        startPosition: _position,
        duration: _duration,
      );
      if (!mounted) {
        await session.disconnect();
        return;
      }
      _castSession = session;
      _castDeviceName = device.name;
      await _castPositionSubscription?.cancel();
      _castPositionSubscription = session.positionStream.listen((position) {
        if (!mounted || _castSession == null) return;
        setState(() => _position = position);
      });
      await _controller?.pause();
      setState(() {});
      _showCastMessage(l10n.castPlayingOn(device.name));
    } catch (error) {
      if (mounted) {
        _showCastMessage(l10n.castFailed('$error'));
      }
    } finally {
      if (mounted) setState(() => _castBusy = false);
    }
  }

  Future<void> _endCastSession() async {
    final session = _castSession;
    if (session == null) return;
    _castSession = null;
    _castDeviceName = null;
    await _castPositionSubscription?.cancel();
    _castPositionSubscription = null;
    unawaited(_saveHistory());
    try {
      await _castService.stopCasting();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _showCastMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _fail(Object error) async {
    await _stopSession();
    if (_disposing || !mounted) return;
    setState(() {
      _ready = false;
      _error = describeStreamStartupError(error, AppLocalizations.of(context));
    });
  }

  Future<void> _stopSession() async {
    final sessionId = _sessionId;
    _sessionId = null;
    if (sessionId != null) {
      try {
        await _backend.stop(sessionId);
      } catch (_) {}
    }
  }

  Future<void> _disposeController() async {
    _historyTimer?.cancel();
    _historyTimer = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      // A slow native event-channel teardown must not stall Up next or the
      // next NZB session. Native disposal continues in the background.
      await controller.dispose().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
  }

  Future<void> _close() async {
    if (_disposing) return;
    _disposing = true;
    await _saveHistory();
    await _stopSession();
    await _disposeController();
    if (mounted) await Navigator.of(context).maybePop();
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _revealControls();
  }

  Future<void> _seekRelative(Duration offset) async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    final target = _position + offset;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    await controller.seekTo(clamped);
    _revealControls();
  }

  Future<void> _setRate(double value) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _rate = value);
    await controller.setPlaybackSpeed(value);
    _revealControls();
  }

  Future<void> _setVolume(double value) async {
    if (!widget.platform.supportsInAppVolume) return;
    final clamped = value.clamp(0.0, 100.0).toDouble();
    setState(() => _volume = clamped);
    await _controller?.setVolume(clamped / 100);
    _revealControls();
  }

  Future<void> _loadAudioTracks() async {
    final controller = _controller;
    if (controller == null || !controller.isAudioTrackSupportAvailable()) {
      return;
    }
    try {
      final tracks = await controller.getAudioTracks();
      if (!mounted) return;
      setState(() => _audioTracks = tracks);
      final selected = pickTvAudioTrackByLanguage(
        tracks,
        _preferences.audioLanguage,
      );
      if (selected != null) await controller.selectAudioTrack(selected);
    } catch (_) {
      // webOS and older native players have no track-selection surface.
    }
  }

  Future<void> _selectAudioTrack(String id) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.selectAudioTrack(id);
    final track = _audioTracks.where((item) => item.id == id).firstOrNull;
    if (track?.language != null) {
      _preferences = _preferences.copyWithAudioLanguage(track!.language!);
      await _preferenceStore.save(widget.nzbPath, _preferences);
    }
    await _loadAudioTracks();
  }

  static Future<List<SubtitleDto>> _defaultOpenSubtitlesSearch(
    OpenSubtitlesConfigDto config,
    String query,
    List<String> languages,
    String? movieHash,
    BigInt? movieBytesize,
  ) => searchOpensubtitles(
    config: config,
    query: query,
    languages: languages,
    movieHash: movieHash,
    movieBytesize: movieBytesize,
  );

  static Future<String> _defaultOpenSubtitlesDownload(
    OpenSubtitlesConfigDto config,
    BigInt fileId,
    String? downloadDir,
  ) => downloadOpensubtitles(
    config: config,
    fileId: fileId,
    downloadDir: downloadDir,
  );

  Future<OpenSubtitlesSettings?> _loadOpenSubtitlesSettings() async {
    try {
      return await _osStore.load();
    } catch (_) {
      return null;
    }
  }

  OpenSubtitlesConfigDto _osConfigFor(OpenSubtitlesSettings settings) =>
      OpenSubtitlesConfigDto(
        baseUrl: settings.baseUrl,
        apiKey: settings.apiKey,
        username: settings.username,
        password: settings.password,
      );

  Future<String?> _subtitleCacheDirectory() async {
    try {
      final root = await getApplicationCacheDirectory();
      return '${root.path}${Platform.pathSeparator}subtitles';
    } catch (_) {
      return null;
    }
  }

  Future<void> _openSubtitleSearch() async {
    final info = _info;
    if (info == null || !mounted) return;
    final settings = await _loadOpenSubtitlesSettings();
    if (!mounted) return;
    if (settings == null || !settings.canSearch) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).subtitleSearchMissingSettings,
            ),
          ),
        );
      return;
    }
    final downloadDir = await _subtitleCacheDirectory();
    if (!mounted || downloadDir == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => SubtitleSearchDialog(
        config: _osConfigFor(settings),
        filename: info.filename,
        streamUrl: info.url,
        streamSize: info.size.toInt(),
        downloadDir: downloadDir,
        initialLanguages: settings.languages,
        searchFn: _osSearchFn,
        downloadFn: _osDownloadFn,
        hashFn: defaultOpenSubtitlesHashFn,
        onSelected: (path, language) => unawaited(
          _applyExternalSubtitle(path, language: language, persist: true),
        ),
        onLanguagesChanged: (languages) =>
            unawaited(_osStore.saveLanguages(languages)),
      ),
    );
  }

  Future<void> _applyExternalSubtitle(
    String path, {
    required String language,
    required bool persist,
  }) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final content = await File(path).readAsString();
      final file = content.trimLeft().startsWith('WEBVTT')
          ? WebVTTCaptionFile(content)
          : SubRipCaptionFile(content);
      await controller.setClosedCaptionFile(Future.value(file));
      controller.setCaptionOffset(_subtitleDelay);
      if (mounted) setState(() => _subtitleEnabled = true);
    } catch (_) {
      return;
    }
    if (!persist || !mounted) return;
    final entryName = _info?.filename;
    if (entryName == null || entryName.isEmpty) return;
    _preferences = _preferences.copyWithExternalSubtitle(
      entryName: entryName,
      subtitle: ExternalSubtitle(path: path, language: language),
      language: language.isEmpty ? null : language,
    );
    await _preferenceStore.save(widget.nzbPath, _preferences);
  }

  Future<void> _autoLoadExternalSubtitle(StreamInfo info) async {
    final entryName = info.filename;
    if (entryName.isEmpty) return;
    final associated = _preferences.externalSubtitles[entryName];
    if (associated != null && File(associated.path).existsSync()) {
      await _applyExternalSubtitle(
        associated.path,
        language: associated.language,
        persist: false,
      );
      return;
    }
    final preferred = _preferences.subtitleLanguage;
    if (preferred == null) return;
    final settings = await _loadOpenSubtitlesSettings();
    if (settings == null || !settings.canSearch) return;
    if (!mounted || _info != info) return;
    final downloadDir = await _subtitleCacheDirectory();
    if (downloadDir == null || !mounted || _info != info) return;
    final config = _osConfigFor(settings);
    try {
      final hash = await defaultOpenSubtitlesHashFn(
        info.url,
        info.size.toInt(),
      );
      if (!mounted || _info != info) return;
      final results = await _osSearchFn(
        config,
        info.filename,
        [preferred],
        hash,
        info.size,
      );
      if (!mounted || _info != info || results.isEmpty) return;
      var best = results.first;
      for (final result in results) {
        if (result.matchedByHash) {
          best = result;
          break;
        }
      }
      final path = await _osDownloadFn(config, best.fileId, downloadDir);
      if (!mounted || _info != info) return;
      await _applyExternalSubtitle(
        path,
        language: best.language.isEmpty ? preferred : best.language,
        persist: true,
      );
    } catch (_) {
      // Automatic subtitle loading is best-effort and never blocks playback.
    }
  }

  Future<void> _toggleSubtitles() async {
    final controller = _controller;
    if (controller == null) return;
    if (_subtitleEnabled) {
      await controller.setClosedCaptionFile(null);
      if (mounted) setState(() => _subtitleEnabled = false);
      return;
    }
    final entryName = _info?.filename;
    final associated = entryName == null
        ? null
        : _preferences.externalSubtitles[entryName];
    if (associated != null && File(associated.path).existsSync()) {
      await _applyExternalSubtitle(
        associated.path,
        language: associated.language,
        persist: false,
      );
    } else {
      await _openSubtitleSearch();
    }
  }

  Future<void> _nudgeSubtitleDelay(Duration delta) async {
    final next = _subtitleDelay + delta;
    final clamped = next.isNegative ? Duration.zero : next;
    setState(() => _subtitleDelay = clamped);
    _controller?.setCaptionOffset(clamped);
    _revealControls();
  }

  void _revealControls() {
    _controlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = true);
    if (_playing) {
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _controlsVisible = false);
      });
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _historyTimer?.cancel();
    _keyboardFocusNode.dispose();
    _playButtonFocusNode.dispose();
    unawaited(_castPositionSubscription?.cancel());
    unawaited(_castService.dispose());
    if (_isPictureInPicture) unawaited(_pictureInPictureWindow.exit());
    unawaited(_stopSession());
    unawaited(_disposeController());
    super.dispose();
  }

  // ---- PlayerKeyboardHandler ------------------------------------------------

  @override
  bool get playbackReady => _ready;
  @override
  bool get playing => _playing;
  @override
  bool get controlsVisible => _controlsVisible;
  @override
  bool get canvasEditing => _canvasEditing;
  @override
  bool get subtitleControlsVisible => _subtitlePanelVisible;
  @override
  bool get isPictureInPicture => _isPictureInPicture;
  @override
  bool get isFullscreen => false;
  @override
  bool get remoteNavigationMode => true;
  @override
  Duration get seekStep => const Duration(seconds: 10);
  @override
  void revealControls() => _revealControls();
  @override
  void hideControls() {
    _controlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = false);
  }

  @override
  void togglePlay() => unawaited(_togglePlay());
  @override
  void seekRelative(Duration offset) => unawaited(_seekRelative(offset));
  @override
  void adjustVolume(double delta) {
    if (widget.platform.supportsInAppVolume) {
      unawaited(_setVolume(_volume + delta));
    }
  }

  @override
  void beginFastScan(int direction) =>
      unawaited(_seekRelative(Duration(seconds: direction * 30)));
  @override
  void endFastScan() {}
  @override
  void toggleFullscreen() {}
  @override
  void exitFullscreen() {}
  @override
  void togglePictureInPicture() => unawaited(_togglePictureInPicture());
  @override
  void toggleCanvasEditor() => _toggleCanvasEditor();
  @override
  void cancelCanvasEditing() {
    if (mounted) setState(() => _canvasEditing = false);
  }
  @override
  void toggleSubtitleControls() {
    setState(() => _subtitlePanelVisible = !_subtitlePanelVisible);
    _revealControls();
  }

  @override
  void dismissSubtitleControls() {
    if (mounted) setState(() => _subtitlePanelVisible = false);
  }

  @override
  void stepBackward() => unawaited(_seekRelative(const Duration(seconds: -1)));
  @override
  void stepForward() => unawaited(_seekRelative(const Duration(seconds: 1)));
  @override
  void nudgeSubtitleDelay(Duration delta) =>
      unawaited(_nudgeSubtitleDelay(delta));
  @override
  void closePlayer() => unawaited(_close());
  @override
  void focusPlayButton() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playButtonFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error != null ? _buildErrorView() : _buildPlayerView(),
    );
  }

  Widget _buildErrorView() {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44),
              const SizedBox(height: 18),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.45),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      setState(() => _error = null);
                      unawaited(_start());
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(l10n.retry),
                  ),
                  OutlinedButton(
                    onPressed: () => unawaited(_close()),
                    child: Text(l10n.closePlayer),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerView() {
    final l10n = AppLocalizations.of(context);
    final controller = _controller;
    return PlayerKeyboardControls(
      handler: this,
      focusNode: _keyboardFocusNode,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            LayoutBuilder(
              builder: (context, constraints) {
                final crop = _canvasCrop;
                final full = crop.left == 0 &&
                    crop.top == 0 &&
                    crop.right == 1 &&
                    crop.bottom == 1;
                final player = VideoPlayer(controller);
                if (full) return Center(child: player);
                return ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: Transform.translate(
                      offset: Offset(
                        -crop.left * constraints.maxWidth,
                        -crop.top * constraints.maxHeight,
                      ),
                      child: SizedBox(
                        width: constraints.maxWidth / crop.width,
                        height: constraints.maxHeight / crop.height,
                        child: player,
                      ),
                    ),
                  ),
                );
              },
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox.square(
                    dimension: 42,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white60),
                    ),
                  ),
                ],
              ),
            ),
          if (_canvasEditing &&
              controller != null &&
              controller.value.isInitialized)
            SmartCanvasOverlay(
              crop: _canvasCrop,
              sourceAspectRatio: controller.value.aspectRatio,
              onChanged: (value) => setState(() => _canvasCrop = value),
              onCommit: _commitCanvasCrop,
              onCancel: () => setState(() => _canvasEditing = false),
            ),
          if (_subtitleEnabled && controller != null)
            ClosedCaption(
              text: controller.value.caption.text,
              textStyle: TextStyle(
                color: _subtitleColor,
                fontSize: 26 * _preferences.subtitleScale,
                fontFamily: switch (_preferences.subtitleFont) {
                  'serif' => 'Noto Serif',
                  'mono' => 'Noto Sans Mono',
                  _ => 'Noto Sans',
                },
                backgroundColor: Colors.black54,
              ),
            ),
          TvPlayerControls(
            visible: _controlsVisible,
            ready: _ready,
            playing: _playing,
            buffering: _buffering,
            filename: _info?.filename ?? l10n.videoPreparing,
            status: [
              _status,
              ?_castDeviceName,
              if (_castBusy) l10n.castConnecting,
              widget.platform.playerBadge,
            ].join(' · '),
            position: _position,
            duration: _duration,
            rate: _rate,
            volume: _volume,
            volumeSupported: widget.platform.supportsInAppVolume,
            audioTracks: _audioTracks,
            subtitleEnabled: _subtitleEnabled,
            playButtonFocusNode: _playButtonFocusNode,
            onClose: () => unawaited(_close()),
            onTogglePlay: () => unawaited(_togglePlay()),
            onSeek: (target) => unawaited(_controller?.seekTo(target)),
            onSeekRelative: (offset) => unawaited(_seekRelative(offset)),
            onRate: (value) => unawaited(_setRate(value)),
            onVolume: (value) => unawaited(_setVolume(value)),
            onAudioTrack: (id) => unawaited(_selectAudioTrack(id)),
            onToggleSubtitles: () => unawaited(_toggleSubtitles()),
            onSearchSubtitles: () => unawaited(_openSubtitleSearch()),
            chapters: _chapters,
            showChapters: _preferences.showChapters,
            onChapterTap: (target) => unawaited(_controller?.seekTo(target)),
            videoFill: _videoFill,
            onToggleVideoFit: _toggleVideoFit,
            onToggleCanvas: _toggleCanvasEditor,
            onTogglePictureInPicture: () => unawaited(_togglePictureInPicture()),
            pictureInPictureSupported: _pictureInPictureWindow.isSupported,
            isPictureInPicture: _isPictureInPicture,
            onToggleCast: () => unawaited(_toggleCast()),
            castAvailable: (_info?.castUrl.isNotEmpty ?? false),
            casting: _castSession != null,
            onEpisodeSwitch: () => unawaited(_switchEpisode()),
            hasMultipleEpisodes: _entries.length > 1,
          ),
          if (_subtitlePanelVisible) _buildSubtitlePanel(),
          if (_upNext case final next?)
            UpNextOverlay(
              entryName: next.name,
              onPlayNow: () => unawaited(_playUpNextNow()),
              onCancel: _dismissUpNext,
              onClearQueue: _clearUpNextQueue,
            ),
        ],
      ),
    );
  }

  Color get _subtitleColor {
    final raw = _preferences.subtitleColor.replaceFirst('#', '');
    final value = int.tryParse(raw, radix: 16) ?? 0xFFFFFF;
    return Color(0xFF000000 | value);
  }

  Widget _buildSubtitlePanel() {
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 24, bottom: 140),
        child: Material(
          color: const Color(0xF2202023),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: l10n.subtitleEarlierTooltip,
                  onPressed: () => unawaited(
                    _nudgeSubtitleDelay(const Duration(milliseconds: -100)),
                  ),
                  icon: const Icon(Icons.remove_rounded),
                ),
                Text(
                  '${(_subtitleDelay.inMilliseconds / 1000).toStringAsFixed(1)} s',
                  style: const TextStyle(color: Colors.white70),
                ),
                IconButton(
                  tooltip: l10n.subtitleLaterTooltip,
                  onPressed: () => unawaited(
                    _nudgeSubtitleDelay(const Duration(milliseconds: 100)),
                  ),
                  icon: const Icon(Icons.add_rounded),
                ),
                IconButton(
                  tooltip: l10n.doneLabel,
                  onPressed: dismissSubtitleControls,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
