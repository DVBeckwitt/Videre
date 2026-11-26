import 'local_music_album.dart';
import 'local_music_artist.dart';
import 'local_music_browse.dart';
import 'local_music_track.dart';
import 'music_song_tap_queue_scope.dart';
import 'on_device_music_entry.dart';

typedef DeviceSongTapQueue = ({
  List<LocalMusicTrack> tracks,
  int startIndex,
  String? title,
});

/// Resolve a scope from the active catalog and its browse order.
DeviceSongTapQueue? deviceSongTapQueue(
  MusicSongTapQueueScope scope,
  LocalMusicTrack tapped,
  List<LocalMusicTrack> visible,
  LocalMusicTrackSort sort,
) {
  final (tracks, title) = switch (scope) {
    MusicSongTapQueueScope.allSongs => (
        sort
            .order(visible.map(OnDeviceMusicEntry.device).toList())
            .map((row) => row.deviceTrack!)
            .toList(),
        null,
      ),
    MusicSongTapQueueScope.album => _album(tapped, visible),
    MusicSongTapQueueScope.artist => _artist(tapped, visible),
    MusicSongTapQueueScope.genre => (
        [
          if (tapped.genreKey case final key?)
            for (final track in visible)
              if (track.genreKey == key) track,
        ],
        tapped.genre,
      ),
    _ => (const <LocalMusicTrack>[], null),
  };
  final index =
      tracks.indexWhere((track) => track.playbackId == tapped.playbackId);
  return index < 0 ? null : (tracks: tracks, startIndex: index, title: title);
}

(List<LocalMusicTrack>, String?) _album(
    LocalMusicTrack tapped, List<LocalMusicTrack> visible) {
  final key = tapped.albumKey;
  final album = key == null ? null : findLocalMusicAlbum(visible, key);
  return (album?.tracks ?? const [], album?.title);
}

(List<LocalMusicTrack>, String?) _artist(
    LocalMusicTrack tapped, List<LocalMusicTrack> visible) {
  // Credits list the performer first, followed by a distinct album artist.
  final credit = localMusicArtistCredits(tapped).firstOrNull;
  final artist =
      credit == null ? null : findLocalMusicArtist(visible, credit.key);
  return (artist?.tracks ?? const [], artist?.name);
}
