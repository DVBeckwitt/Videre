import 'dart:io';

import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/download_playback_source.dart';
import '../../downloads/services/explicit_music_download.dart';
import '../../globals.dart';
import '../../player/models/local_music_playback.dart';
import '../../settings/models/db/server.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/invidious_image.dart';
import '../../utils/models/image_object.dart';
import '../../videos/models/music_metadata.dart';
import '../../videos/models/video.dart';
import '../models/device_music_artwork_preferences.dart';
import '../models/local_music_track.dart';
import '../models/song_artwork.dart';
import 'music_artwork_cache.dart';
import 'music_community_cover_cache.dart';
import 'music_community_cover_preferences.dart';

/// Reuses the current song's local artwork for sharing without making requests.
Future<List<File>> findMusicLyricShareArtwork({
  required MusicMetadata track,
  required Video? video,
  required DownloadedVideo? offline,
  required LocalMusicTrack? localTrack,
  required Server? server,
  required IDbClient owner,
  required bool Function() isCurrent,
}) async {
  final profile = owner.profileId;
  final videoId = video?.videoId ?? offline?.videoId;
  bool current() => isCurrent() && owner.profileId == profile;
  if (videoId == null || !current()) return const [];

  try {
    final videoPin = video?.explicitMusicDownload;
    final fingerprint = videoPin ?? offline?.explicitMusicDownload;
    if (fingerprint != null) {
      final id = videoPin != null ? video!.videoId : offline!.videoId;
      final download = readyMusicDownload(owner, id, fingerprint: fingerprint);
      final cover = await download?.existingSongArtwork;
      return current() && cover != null ? [cover] : const [];
    }

    final offlineId = offline?.videoId;
    final deviceId = isLocalMusicPlaybackId(offlineId) ? offlineId! : videoId;
    if (isLocalMusicPlaybackId(deviceId)) {
      if (localTrack == null ||
          offline?.profileId != profile ||
          localTrack.uri != offline?.storageUri ||
          localTrack.playbackId != localMusicTrackId(deviceId)) {
        return const [];
      }
      final preferAdjacent =
          DeviceMusicArtworkPreferences.forDatabase(owner).source !=
              DeviceMusicArtworkSource.embeddedOnly;
      final files = <File>[];
      for (final path in [
        if (preferAdjacent) localTrack.adjacentArtPath,
        localTrack.artPath,
      ].nonNulls) {
        if (path.isEmpty) continue;
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (!current()) return const [];
        if (type == FileSystemEntityType.file) files.add(File(path));
      }
      return files;
    }

    if (offline != null || video?.downloadPlaybackOnly == true) {
      final download = offline ?? admittedMusicDownload(video);
      if (download == null ||
          download.profileId != profile ||
          download.videoId != videoId) {
        return const [];
      }
      final cover = await download.existingSongArtwork;
      return current() && cover != null ? [cover] : const [];
    }

    final consent = communityCoverArtPreferenceRevision.value;
    bool communityAllowed() =>
        current() &&
        db.profileId == profile &&
        communityCoverArtPreferenceRevision.value == consent &&
        isCommunityCoverArtEnabled();

    if (communityAllowed()) {
      final cover = await communityMusicCoverCache.read(profile, videoId,
          isCurrent: communityAllowed);
      if (cover != null && communityAllowed()) return [cover];
    }

    if (!current() || server == null || server.profileId != profile) {
      return const [];
    }
    final account = owner.getAccount(server.accountId);
    if (account == null) return const [];
    final images = displaySongThumbnails(
      videoId,
      track.thumbnails,
      video?.videoThumbnails ?? const [],
      artTrack: track.isArtTrack || video?.isStockArtTrack == true,
      instanceUrl:
          (video?.playbackConnection ?? video?.backendPlayback)?.server.url,
    );
    if (images.isEmpty) return const [];

    final cache = musicArtworkCache.catalogManager(profile);
    final seen = <String>{};
    for (final candidate
        in ImageObject.getThumbnailUrlsByPreferredOrder(images)) {
      if (!current()) return const [];
      final url = invidiousImageUrl(candidate, account);
      if (url == null || !seen.add(url)) continue;
      // Use Thumbnail's profile namespace for public URLs and account scope
      // for the selected instance's URLs.
      final key = invidiousImageCacheKey(url, account);
      final cacheKey =
          key == url ? 'music-artwork:$profile:$key' : 'music-artwork:$key';
      final entry = await cache.getFileFromCache(cacheKey);
      if (entry != null) return current() ? [entry.file] : const [];
    }
  } catch (_) {
    // Artwork is optional when the cache or file becomes unavailable.
  }
  return const [];
}
