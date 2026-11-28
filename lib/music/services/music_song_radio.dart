import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/utils/video_post_processing.dart'
    show privateVideoString;

final _onlineSongId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
const _relatedSongLimit = 6;
// Add one artist batch only when the verified related lane is less than half full.
const _minimumRelatedSongs = 3;

enum MusicSongRadioResult { started, empty, unavailable, superseded }

bool canUseOnlineMusicSong(Video song) =>
    _onlineSongId.stringMatch(song.videoId) == song.videoId &&
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

String? _publicArtistId(Video song) => [
      for (final credit in song.musicMetadata!.artistCredits)
        normalizeChannelId(credit.id),
      normalizeChannelId(song.authorId),
      channelIdFromAuthorUrl(song.authorUrl),
    ].nonNulls.firstOrNull;

Future<List<Video>> loadMusicSongRadio(
  Video seed, {
  required bool Function() isCurrent,
  required Iterable<MusicTrack> Function(Iterable<MusicTrack>) eligible,
  MusicCatalogService? catalog,
}) async {
  if (!isCurrent() || !canUseOnlineMusicSong(seed)) return const [];
  final source = catalog ?? musicCatalogService;
  final database = db;
  final profile = database.profileId;
  final api = service;
  final session = api.sessionRevision;
  final proxy = NetworkProxy.instance;
  final revision = proxy.revision;
  bool current() =>
      isCurrent() &&
      identical(db, database) &&
      database.profileId == profile &&
      identical(service, api) &&
      api.sessionRevision == session &&
      !proxy.isChanging &&
      proxy.revision == revision;
  if (!current()) return const [];

  List<Video> admit(Iterable<MusicTrack> tracks) {
    final seen = {seed.videoId};
    return eligible(tracks)
        .map((track) => track.toVideo())
        .where((song) => canUseOnlineMusicSong(song) && seen.add(song.videoId))
        .take(_relatedSongLimit)
        .toList();
  }

  var instanceRejected = false;
  final related = await source.getSongRadioRelatedSongs(seed.videoId,
      isCurrent: current, onInstanceFailure: () => instanceRejected = true);
  if (!current()) return const [];
  var songs = admit(related);
  if (!instanceRejected && songs.length < _minimumRelatedSongs) {
    final artist = _publicArtistId(seed) ??
        songs.map(_publicArtistId).nonNulls.firstOrNull;
    if (artist != null && current()) {
      try {
        final supplemental =
            await source.getArtistMixSongs([artist], isCurrent: current);
        if (!current()) return const [];
        songs = admit([...related, ...supplemental]);
      } on MusicCatalogUnsupported {
        // The adapter can still return the related songs it supports.
      } catch (_) {
        if (!current()) return const [];
        if (songs.isEmpty) rethrow;
      }
    }
  }
  if (!current() || songs.isEmpty) return const [];
  return [seed, ...songs];
}
