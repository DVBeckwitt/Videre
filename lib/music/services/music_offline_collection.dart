import 'dart:async';

import '../../app/states/app.dart';
import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/download_playback_source.dart';
import '../../downloads/services/download_storage.dart';
import '../../downloads/services/explicit_music_download.dart';
import '../../player/models/backend_playback.dart';
import '../../player/models/local_music_playback.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/video.dart';
import 'cached_music.dart';
import 'local_music_library.dart';

// Android's storage worker uses a bounded queue shared with other file probes.
Future<void>? _pendingFileCheck;

Future<String?> _checkFile(
    DownloadedVideo file, bool Function() isCurrent) async {
  final preceding = _pendingFileCheck;
  final done = Completer<void>();
  _pendingFileCheck = done.future;
  try {
    if (preceding != null) await preceding;
    if (!isCurrent()) return null;
    return await DownloadStorage().musicFileProof(file, verifyCompletion: true);
  } finally {
    if (identical(_pendingFileCheck, done.future)) _pendingFileCheck = null;
    done.complete();
  }
}

/// Verifies the exact stored rendition and returns a pin for its current file.
/// An ordinary song supplies its playback metadata so an older download with
/// conflicting provenance cannot be used as this occurrence's rendition.
Future<String?> verifyOfflineMusicDownload({
  required IDbClient database,
  required AppState session,
  required String id,
  required String fingerprint,
  required Video? song,
  required String? pinnedFileProof,
  required bool Function() isCurrent,
}) async {
  bool current() => database.profileId == session.profileId && isCurrent();
  if (!current()) return null;
  try {
    final file = readyMusicDownload(database, id, fingerprint: fingerprint);
    final provenance = file?.playbackProvenance;
    if (file == null ||
        provenance == null ||
        provenance.profileId != file.profileId ||
        provenance.accountId != file.accountId ||
        provenance.contentId != id ||
        !provenance.audioOnly ||
        provenance.container != file.container) {
      return null;
    }
    BackendPlayback? route;
    if (song != null) {
      final server = session.server;
      if (server == null) return null;
      final prepared = await prepareDownloadedPlaybackVideo(
        database: database,
        video: song,
        audioOnly: true,
        server: server,
        isCurrent: current,
      );
      final admitted = admittedMusicDownload(prepared);
      if (!current() ||
          admitted == null ||
          musicDownloadFingerprint(admitted) != fingerprint) {
        return null;
      }
      route = prepared!.playbackConnection;
    }
    final proof = await _checkFile(file, current);
    if (!current() ||
        proof == null ||
        (pinnedFileProof != null && pinnedFileProof != proof)) {
      return null;
    }
    if (route != null &&
        !route.matches(await database.getCurrentlySelectedServer())) {
      return null;
    }
    return current() &&
            readyMusicDownload(database, id, fingerprint: fingerprint) != null
        ? musicDownloadFileFingerprint(file, proof)
        : null;
  } catch (_) {
    return null;
  }
}

/// Resolves each collection occurrence in place. Every admitted remote ID
/// carries an explicit local source so eviction or revocation cannot send the
/// filtered queue back to a streaming backend.
Future<List<Video?>> resolveOfflineMusicCollection({
  required IDbClient database,
  required AppState session,
  required List<Video> videos,
  required bool Function() isCurrent,
}) async {
  final resolved = List<Video?>.filled(videos.length, null);
  final server = session.server;
  bool current() =>
      !session.globalLoading &&
      !session.sessionRecoveryRequired &&
      database.profileId == session.profileId &&
      isCurrent();

  if (!current() || videos.isEmpty) return resolved;
  final deviceIndices = <int>[];
  final cacheIndices = <int>[];
  final verifiedDownloads = <(Video, String?, String), String?>{};
  for (final (index, video) in videos.indexed) {
    if (!current()) break;
    if (video.filtered ||
        video.filterHide ||
        video.isUpcoming == true ||
        video.liveNow == true) {
      continue;
    }
    if (isLocalMusicPlaybackId(video.videoId)) {
      deviceIndices.add(index);
      continue;
    }
    final pinned = video.explicitMusicDownload;
    if (CachedMusicPlayback.of(video) == null) {
      final file =
          readyMusicDownload(database, video.videoId, fingerprint: pinned);
      if (file?.playbackProvenance != null) {
        final fingerprint = musicDownloadFingerprint(file!);
        final descriptor = Video(
          videoId: video.videoId,
          liveNow: video.liveNow,
          adaptiveFormats: pinned == null ? video.adaptiveFormats : null,
        );
        final key = (descriptor, pinned, fingerprint);
        if (!verifiedDownloads.containsKey(key)) {
          verifiedDownloads[key] = await verifyOfflineMusicDownload(
            database: database,
            session: session,
            id: video.videoId,
            fingerprint: fingerprint,
            song: pinned == null ? descriptor : null,
            pinnedFileProof:
                pinned == null ? null : pinnedMusicDownloadFileProof(pinned),
            isCurrent: current,
          );
        }
        final pin = verifiedDownloads[key];
        if (pin != null) {
          resolved[index] = video.copyWith(explicitMusicDownload: pin);
          continue;
        }
      }
    }
    if (pinned == null) cacheIndices.add(index);
  }

  if (current() &&
      server != null &&
      cacheIndices.isNotEmpty &&
      server.profileId == session.profileId) {
    final owner = cachedMusicOwner(server);
    if (owner != null) {
      try {
        final route = BackendPlayback(server);
        final matches = {
          for (final song in await listCachedMusicSongs(server))
            song.videoId: song.rendition,
        };
        if (matches.isNotEmpty &&
            current() &&
            route.matches(await database.getCurrentlySelectedServer()) &&
            current()) {
          for (final index in cacheIndices) {
            final video = videos[index];
            final rendition = matches[video.videoId];
            if (rendition == null) continue;
            final pinned = CachedMusicPlayback.of(video);
            if (pinned != null &&
                (pinned.owner != owner || pinned.rendition != rendition)) {
              continue;
            }
            resolved[index] = video.copyWith(
                playbackSourceId:
                    pinned ?? CachedMusicPlayback(owner, rendition));
          }
        }
      } on Exception {
        // The cache is optional. Its absence does not hide other local sources.
      }
    }
  }

  if (current() && deviceIndices.isNotEmpty) {
    final library = LocalMusicLibrary.instance;
    try {
      await library.initialize();
      final selection = library.selectionId;
      if (current() && library.acceptsSessionSelection(selection)) {
        await library.revalidate();
        if (current() && library.acceptsSessionSelection(selection)) {
          await library.loadForPlayback(deviceIndices.map(
            (index) => localMusicTrackId(videos[index].videoId),
          ));
        }
      }
      if (current() && library.acceptsSessionSelection(selection)) {
        for (final index in deviceIndices) {
          final video = videos[index];
          final track = localMusicTrackForPlayback(video.videoId);
          if (track != null &&
              library.roots.any((root) =>
                  root.uri == track.sourceUri &&
                  !library.isRootUnavailable(root))) {
            resolved[index] = video;
          }
        }
      }
    } on Exception {
      // An unavailable device catalog does not hide owned downloads or caches.
    }
  }

  if (!current()) {
    resolved.fillRange(0, resolved.length, null);
  } else {
    // Other slots may have taken time to check. Retire a download whose
    // stored record changed after its probe, even in the same session.
    for (final (index, video) in resolved.indexed) {
      if (video?.explicitMusicDownload case final fingerprint?) {
        if (readyMusicDownload(database, video!.videoId,
                fingerprint: fingerprint) ==
            null) {
          resolved[index] = null;
        }
      }
    }
  }
  return resolved;
}
