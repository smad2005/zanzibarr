import 'package:video_player/video_player.dart';

/// Returns the track ID for a saved ISO-639 language preference.
/// Exact codes win over regional variants (`en` before `en-US`).
String? pickTvAudioTrackByLanguage(
  List<VideoAudioTrack> tracks,
  String? language,
) {
  final normalized = language?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  for (final track in tracks) {
    if (track.language?.trim().toLowerCase() == normalized) return track.id;
  }
  for (final track in tracks) {
    final candidate = track.language?.trim().toLowerCase();
    if (candidate != null && candidate.startsWith('$normalized-')) {
      return track.id;
    }
  }
  return null;
}
