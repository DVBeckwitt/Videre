import '../../videos/models/music_metadata.dart';
import '../../videos/models/video.dart';
import 'local_music_track.dart';

const _devicePlaylistPrefix = 'device:playlist:';
final _fileProof = RegExp(r'^[a-f0-9]{64}$');

/// The identity comes from Android's device index. Playlist data contains
/// display metadata and this opaque proof, with no persisted media URI.
String? devicePlaylistFileProof(String id) {
  if (!id.startsWith(_devicePlaylistPrefix)) return null;
  final proof = id.substring(_devicePlaylistPrefix.length);
  return _fileProof.stringMatch(proof) == proof ? proof : null;
}

Video? devicePlaylistVideo(LocalMusicTrack track) {
  final proof = track.isCueTrack
      ? track.visibilityKey
      : track.documentVisibilityKey ?? track.visibilityKey;
  if (proof == null || _fileProof.stringMatch(proof) != proof) return null;
  return Video(
    videoId: '$_devicePlaylistPrefix$proof',
    title: track.title,
    author: track.artist,
    lengthSeconds: track.durationMs ~/ Duration.millisecondsPerSecond,
    musicMetadata: MusicMetadata(
        title: track.title, artist: track.artist ?? '', album: track.album),
  );
}
