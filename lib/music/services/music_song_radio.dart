import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/utils/video_post_processing.dart'
    show privateVideoString;

final _onlineSongId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
const _relatedSongLimit = 6;

enum MusicSongRadioResult { started, empty, unavailable, superseded }

bool canUseOnlineMusicSong(Video song) =>
    _onlineSongId.hasMatch(song.videoId) &&
    song.musicMetadata != null &&
    song.explicitMusicDownload == null &&
    !song.downloadPlaybackOnly &&
    !song.filtered &&
    !song.filterHide &&
    song.title != privateVideoString &&
    song.liveNow != true &&
    song.isUpcoming != true &&
    song.paid != true &&
    (song.premiereTimestamp ?? 0) <=
        DateTime.now().millisecondsSinceEpoch ~/ 1000;

Future<List<Video>> loadMusicSongRadio(
  Video seed, {
  required bool Function() isCurrent,
  required Iterable<MusicTrack> Function(Iterable<MusicTrack>) eligible,
  MusicCatalogService? catalog,
}) async {
  if (!isCurrent() || !canUseOnlineMusicSong(seed)) return const [];
  final related = await (catalog ?? musicCatalogService)
      .getRelatedSongs([seed.videoId], isCurrent: isCurrent);
  if (!isCurrent()) return const [];
  final seen = {seed.videoId};
  final songs = eligible(related)
      .map((track) => track.toVideo())
      .where((song) => canUseOnlineMusicSong(song) && seen.add(song.videoId))
      .take(_relatedSongLimit)
      .toList();
  if (!isCurrent() || songs.isEmpty) return const [];
  return [seed, ...songs];
}
