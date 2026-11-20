import '../../downloads/models/downloaded_video.dart';
import '../../music/models/local_music_track.dart';
import '../../music/services/local_music_library.dart';
import '../../videos/models/music_metadata.dart';

/// Reserved even when a library is disabled or a document is gone. A stale
/// device ID must never fall through to download storage or an Invidious call.
bool isLocalMusicPlaybackId(String? id) => id?.startsWith('device:') == true;

/// The first occurrence may use the legacy track ID. Additional occurrences
/// have their own keys but resolve through the same authorized catalog entry.
String localMusicTrackId(String occurrenceId) {
  final separator = occurrenceId.indexOf('#');
  return separator < 0 ? occurrenceId : occurrenceId.substring(0, separator);
}

LocalMusicTrack? localMusicTrackForPlayback(String? id) =>
    id != null && isLocalMusicPlaybackId(id)
        ? LocalMusicLibrary.instance.trackById(localMusicTrackId(id))
        : null;

/// Queue/display adapter only. It never enters the downloads database.
DownloadedVideo localMusicPlaybackEntry(LocalMusicTrack track, String profileId,
        {String? occurrenceId}) =>
    DownloadedVideo(
      videoId: occurrenceId ?? track.playbackId,
      title: track.title,
      author: track.artist,
      profileId: profileId,
      musicMetadata: MusicMetadata(
          title: track.title, artist: track.artist ?? '', album: track.album),
      lengthSeconds: Duration(milliseconds: track.durationMs).inSeconds,
      audioOnly: true,
      storageUri: track.uri,
      quality: '',
    );
