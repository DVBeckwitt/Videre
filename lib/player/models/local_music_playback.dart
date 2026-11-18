import '../../downloads/models/downloaded_video.dart';
import '../../music/models/local_music_track.dart';
import '../../music/services/local_music_library.dart';
import '../../videos/models/music_metadata.dart';

/// Reserved even when a library is disabled or a document is gone. A stale
/// device ID must never fall through to download storage or an Invidious call.
bool isLocalMusicPlaybackId(String? id) => id?.startsWith('device:') == true;

LocalMusicTrack? localMusicTrackForPlayback(String? id) =>
    id != null && isLocalMusicPlaybackId(id)
        ? LocalMusicLibrary.instance.trackById(id)
        : null;

/// Queue/display adapter only. It never enters the downloads database.
DownloadedVideo localMusicPlaybackEntry(
        LocalMusicTrack track, String profileId) =>
    DownloadedVideo(
      videoId: track.playbackId,
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
