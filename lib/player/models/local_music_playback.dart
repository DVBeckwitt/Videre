import '../../downloads/models/downloaded_video.dart';
import '../../music/models/device_playlist_track.dart';
import '../../music/models/local_music_track.dart';
import '../../music/services/local_music_library.dart';
import '../../videos/models/ided_video.dart';
import '../../videos/models/music_metadata.dart';

/// Reserved even when a library is disabled or a document is gone. A stale
/// device ID must never fall through to download storage or an Invidious call.
bool isLocalMusicPlaybackId(String? id) => id?.startsWith('device:') == true;

bool isOpenedAudioPlaybackId(String? id) =>
    id?.startsWith('device:open:') == true;

/// The first occurrence may use the legacy track ID. Additional occurrences
/// have their own keys but resolve through the same authorized catalog entry.
String localMusicTrackId(String occurrenceId) {
  final separator = occurrenceId.indexOf('#');
  return separator < 0 ? occurrenceId : occurrenceId.substring(0, separator);
}

/// Converts a saved playlist occurrence to the corresponding device queue ID.
String devicePlaylistQueueOccurrenceId(
    String trackId, String playlistTrackId, Iterable<IdedVideo> earlier) {
  final copies =
      earlier.where((entry) => entry.videoId == playlistTrackId).length;
  return copies == 0 ? trackId : '$trackId#$copies';
}

LocalMusicTrack? localMusicTrackForPlayback(String? id) {
  if (id == null || !isLocalMusicPlaybackId(id)) return null;
  final trackId = localMusicTrackId(id);
  final library = LocalMusicLibrary.instance;
  return devicePlaylistFileProof(trackId) != null
      ? library.playlistTrackById(trackId)
      : library.trackById(trackId);
}

Duration? localMusicCueDuration(LocalMusicTrack? track) {
  if (track == null || !track.isCueTrack) return null;
  final end = track.cueEndUs;
  return end == null
      ? track.durationMs > 0
          ? Duration(milliseconds: track.durationMs)
          : null
      : Duration(microseconds: end - track.cueStartUs!);
}

LocalMusicTrack? providerMusicTrackForPlayback(String? id) {
  final track = localMusicTrackForPlayback(id);
  return track?.isDocumentProvider == true ? track : null;
}

/// Queue/display adapter only. It never enters the downloads database.
DownloadedVideo localMusicPlaybackEntry(LocalMusicTrack track, String profileId,
    {String? occurrenceId}) {
  final cueDuration = localMusicCueDuration(track);
  return DownloadedVideo(
    videoId: occurrenceId ?? track.playbackId,
    title: track.title,
    author: track.artist,
    profileId: profileId,
    musicMetadata: MusicMetadata(
        title: track.title, artist: track.artist ?? '', album: track.album),
    lengthSeconds: cueDuration == null
        ? Duration(milliseconds: track.durationMs).inSeconds
        : (cueDuration.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/
            Duration.microsecondsPerSecond,
    audioOnly: true,
    storageUri: track.uri,
    quality: '',
  );
}
