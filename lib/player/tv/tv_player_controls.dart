import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../chapter.dart';
import '../player_format.dart';

/// Lightweight, entirely Flutter-rendered TV chrome. It deliberately shares
/// no media_kit types, so Tizen/webOS packages never pull in libmpv.
class TvPlayerControls extends StatelessWidget {
  const TvPlayerControls({
    super.key,
    required this.visible,
    required this.ready,
    required this.playing,
    required this.buffering,
    required this.filename,
    required this.status,
    required this.position,
    required this.duration,
    required this.rate,
    required this.volume,
    required this.volumeSupported,
    required this.audioTracks,
    required this.subtitleEnabled,
    required this.playButtonFocusNode,
    required this.onClose,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onSeekRelative,
    required this.onRate,
    required this.onVolume,
    required this.onAudioTrack,
    required this.onToggleSubtitles,
    required this.onSearchSubtitles,
    this.chapters = const [],
    this.showChapters = false,
    this.onChapterTap,
    this.videoFill = false,
    this.onToggleVideoFit,
    this.onToggleCanvas,
    this.onTogglePictureInPicture,
    this.pictureInPictureSupported = false,
    this.isPictureInPicture = false,
    this.onToggleCast,
    this.castAvailable = false,
    this.casting = false,
    this.onEpisodeSwitch,
    this.hasMultipleEpisodes = false,
  });

  final bool visible;
  final bool ready;
  final bool playing;
  final bool buffering;
  final String filename;
  final String status;
  final Duration position;
  final Duration duration;
  final double rate;
  final double volume;
  final bool volumeSupported;
  final List<VideoAudioTrack> audioTracks;
  final bool subtitleEnabled;
  final FocusNode playButtonFocusNode;
  final VoidCallback onClose;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration> onSeekRelative;
  final ValueChanged<double> onRate;
  final ValueChanged<double> onVolume;
  final ValueChanged<String> onAudioTrack;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onSearchSubtitles;
  final List<Chapter> chapters;
  final bool showChapters;
  final ValueChanged<Duration>? onChapterTap;
  final bool videoFill;
  final VoidCallback? onToggleVideoFit;
  final VoidCallback? onToggleCanvas;
  final VoidCallback? onTogglePictureInPicture;
  final bool pictureInPictureSupported;
  final bool isPictureInPicture;
  final VoidCallback? onToggleCast;
  final bool castAvailable;
  final bool casting;
  final VoidCallback? onEpisodeSwitch;
  final bool hasMultipleEpisodes;

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shown = visible || !playing || !ready;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (buffering && ready)
          const Center(
            child: SizedBox.square(
              dimension: 44,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ),
        if (shown) ...[
          const Align(
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xCC000000), Colors.transparent],
                ),
              ),
              child: SizedBox(height: 116),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            top: 16,
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.closePlayer,
                  onPressed: onClose,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        filename,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xE6000000)],
                ),
              ),
              child: SizedBox(height: 190),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showChapters &&
                              chapters.isNotEmpty &&
                              duration.inMilliseconds > 0)
                            LayoutBuilder(
                              builder: (context, constraints) => SizedBox(
                                height: 14,
                                child: Stack(
                                  children: [
                                    for (final chapter in chapters)
                                      Positioned(
                                        left:
                                            (chapter.start.inMilliseconds /
                                                    duration.inMilliseconds)
                                                .clamp(0.0, 1.0) *
                                            (constraints.maxWidth - 4),
                                        child: GestureDetector(
                                          onTap: () =>
                                              onChapterTap?.call(chapter.start),
                                          child: Container(
                                            width: 4,
                                            height: 12,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                            ),
                            child: Slider(
                              value: duration.inMilliseconds <= 0
                                  ? 0
                                  : (position.inMilliseconds /
                                            duration.inMilliseconds)
                                      .clamp(0.0, 1.0),
                              onChanged: ready && duration.inMilliseconds > 0
                                  ? (value) => onSeek(
                                      Duration(
                                        milliseconds:
                                            (value * duration.inMilliseconds)
                                                .round(),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${formatPlayerDuration(position)} / ${formatPlayerDuration(duration)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    IconButton(
                      focusNode: playButtonFocusNode,
                      tooltip: playing ? l10n.pause : l10n.play,
                      onPressed: ready ? onTogglePlay : null,
                      iconSize: 32,
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.seekBackSeconds(10),
                      onPressed: ready
                          ? () => onSeekRelative(const Duration(seconds: -10))
                          : null,
                      icon: const Icon(Icons.replay_10_rounded),
                    ),
                    IconButton(
                      tooltip: l10n.seekForwardSeconds(10),
                      onPressed: ready
                          ? () => onSeekRelative(const Duration(seconds: 10))
                          : null,
                      icon: const Icon(Icons.forward_10_rounded),
                    ),
                    PopupMenuButton<double>(
                      tooltip: l10n.playbackSpeedTooltip,
                      initialValue: rate,
                      onSelected: onRate,
                      itemBuilder: (_) => [
                        for (final value in _rates)
                          PopupMenuItem(
                            value: value,
                            child: Text('${formatPlayerRate(value)}×'),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '${formatPlayerRate(rate)}×',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: videoFill
                          ? l10n.videoFitContain
                          : l10n.videoFitCover,
                      onPressed: onToggleVideoFit,
                      icon: Icon(
                        videoFill
                            ? Icons.fit_screen_rounded
                            : Icons.fit_screen_outlined,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.smartCanvasAreaLabel,
                      onPressed: onToggleCanvas,
                      icon: const Icon(Icons.crop_rounded),
                    ),
                    if (pictureInPictureSupported)
                      IconButton(
                        tooltip: isPictureInPicture
                            ? 'Exit Picture-in-Picture'
                            : 'Picture-in-Picture',
                        onPressed: onTogglePictureInPicture,
                        icon: Icon(
                          isPictureInPicture
                              ? Icons.picture_in_picture_alt_rounded
                              : Icons.picture_in_picture_outlined,
                        ),
                      ),
                    if (hasMultipleEpisodes)
                      IconButton(
                        tooltip: l10n.episodeSwitch,
                        onPressed: onEpisodeSwitch,
                        icon: const Icon(Icons.playlist_play_rounded),
                      ),
                    if (castAvailable)
                      IconButton(
                        tooltip: casting
                            ? l10n.castDisconnect
                            : l10n.castTooltip,
                        onPressed: onToggleCast,
                        icon: Icon(
                          casting ? Icons.cast_connected_rounded : Icons.cast_rounded,
                        ),
                      ),
                    const Spacer(),
                    if (audioTracks.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: l10n.audioTrack,
                        icon: const Icon(Icons.audiotrack_rounded),
                        onSelected: onAudioTrack,
                        itemBuilder: (_) => [
                          for (final track in audioTracks)
                            PopupMenuItem(
                              value: track.id,
                              child: Text(
                                track.label?.isNotEmpty == true
                                    ? track.label!
                                    : '${track.language ?? l10n.audioTrack} · ${track.id}',
                              ),
                            ),
                        ],
                      ),
                    IconButton(
                      tooltip: l10n.subtitleTrack,
                      onPressed: onToggleSubtitles,
                      icon: Icon(
                        subtitleEnabled
                            ? Icons.subtitles_rounded
                            : Icons.subtitles_outlined,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.subtitleSearchTooltip,
                      onPressed: onSearchSubtitles,
                      icon: const Icon(Icons.travel_explore_rounded),
                    ),
                    if (volumeSupported) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.volume_up_rounded, size: 20),
                      SizedBox(
                        width: 120,
                        child: Slider(
                          value: (volume / 100).clamp(0.0, 1.0),
                          onChanged: (value) => onVolume(value * 100),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
