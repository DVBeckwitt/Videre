import '../../playlists/models/playlist.dart';
import '../../videos/models/video.dart';
import 'downloaded_video.dart';

/// The download manager's recorded progress through a playlist's online songs.
class MusicPlaylistOfflineProgress {
  final int total;
  final int complete;
  final int needsAttention;
  final bool waitingForWifi;
  final double? progress;

  const MusicPlaylistOfflineProgress({
    required this.total,
    required this.complete,
    required this.needsAttention,
    required this.waitingForWifi,
    required this.progress,
  });
}

/// Duplicate occurrences share one download. Device tracks have their own
/// playback identity and already live outside the download manager.
Map<String, Video> playlistOfflineSongs(Playlist playlist) {
  final songs = <String, Video>{};
  for (final video in playlist.videos) {
    if (video.musicMetadata?.title.trim().isNotEmpty == true &&
        !video.filterHide &&
        !video.downloadPlaybackOnly &&
        video.liveNow != true &&
        DownloadedVideo.isSafeFileId(video.videoId)) {
      songs.putIfAbsent(video.videoId, () => video);
    }
  }
  return songs;
}
