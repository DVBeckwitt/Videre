import '../../settings/models/db/server.dart';
import '../../videos/models/adaptive_format.dart';
import '../../videos/models/video.dart';
import '../media_source.dart';

typedef WatchAudioTrack = ({String id, String label});

/// Current Watch occurrence's track and last successfully admitted Video URL.
/// The URL is transient and must be matched against the current response.
typedef WatchAudioPreference = ({String? trackId, String? progressiveUrl});

String? watchAudioTrackId(AudioTrack? track) {
  final id = track?.id.trim();
  return id == null || id.isEmpty ? null : id;
}

/// A muxed source proves a track only when its admitted URL matches exactly
/// and every matching format names the same track. Itag and resolution do not
/// describe the selected audio.
String? watchAudioTrackIdForProgressiveUrl(
    Video video, Server server, String url) {
  final ids = {
    for (final stream in video.formatStreams ?? const [])
      if (!stream.isLegacyHd720 &&
          proxiedPlaybackMediaUrl(stream.url, server) == url)
        watchAudioTrackId(stream.audioTrack),
  };
  return ids.length == 1 ? ids.single : null;
}
