import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../player/media_source.dart';
import '../../player/models/playback_cache_identity.dart';
import '../../player/models/backend_playback.dart';
import '../../network/gateway_context.dart';
import '../../settings/models/db/server.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/music_metadata.dart';
import '../../videos/models/video.dart';
import '../models/download_formats.dart';
import '../models/downloaded_video.dart';

/// A complete local rendition, never a byte-range alias for a remote stream.
class DownloadPlaybackSource {
  final String uri;
  final String? videoQuality;
  final DownloadedVideo download;
  final Map<String, Object?> playbackCache;

  const DownloadPlaybackSource(
      this.uri, this.videoQuality, this.download, this.playbackCache);
}

/// Restores trustworthy saved metadata without fabricating an online stream.
/// The queue remains online-owned; only its first source candidate is local.
Future<Video?> prepareDownloadedPlaybackVideo({
  required IDbClient database,
  required Video video,
  Server? server,
  required bool audioOnly,
  required bool Function() isCurrent,
  int? preferredQuality,
  void Function(DownloadPlaybackSource source)? onPrepared,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final download = database.getDownloadByVideoId(video.videoId);
    if (download == null ||
        download.playbackProvenance == null ||
        !download.downloadComplete ||
        download.downloadFailed ||
        download.storageFailed ||
        download.authenticationRequired ||
        download.audioOnly != audioOnly ||
        download.profileId != database.profileId) {
      return null;
    }
    // This is an optional local probe. Do not make ordinary cached metadata
    // playback depend on a new account lookup when no saved source is usable.
    server ??= await database.getCurrentlySelectedServer();
    if (!isCurrent()) return null;
    final savedMusic = download.musicMetadata;
    final incomingArt = video.musicMetadata?.thumbnails ?? const [];
    final music = savedMusic != null &&
            savedMusic.thumbnails.isEmpty &&
            incomingArt.isNotEmpty
        ? MusicMetadata(
            title: savedMusic.title,
            artist: savedMusic.artist,
            album: savedMusic.album,
            thumbnails: incomingArt)
        : savedMusic ?? video.musicMetadata;
    final candidate = video.copyWith(
        downloadPlaybackOnly: true,
        title: download.title,
        author: download.author ?? video.author,
        authorUrl: download.authorUrl ?? video.authorUrl,
        musicMetadata: music,
        videoThumbnails: video.videoThumbnails.isNotEmpty
            ? video.videoThumbnails
            : music?.thumbnails ?? const [],
        lengthSeconds: download.lengthSeconds,
        dashUrl: null,
        hlsUrl: null,
        adaptiveFormats: null,
        formatStreams: null,
        playbackConnection: BackendPlayback(server),
        backendPlayback: null,
        playbackSourceId: Object());
    final local = await resolveDownloadPlaybackSource(
        database: database,
        // Fresh known metadata may contradict an older saved rendition. Do not
        // discard that evidence merely to take the metadata-free shortcut.
        video: video.adaptiveFormats?.isNotEmpty == true ? video : candidate,
        server: server,
        audioOnly: audioOnly,
        sessionId: 'prepare:${DateTime.now().microsecondsSinceEpoch}',
        isCurrent: isCurrent,
        preferredQuality: preferredQuality);
    if (local == null || !isCurrent()) return null;
    // Expose only the same admitted record that supplies the local rendition.
    // Playback can reuse its saved optional metadata without another lookup or
    // serializing source/credential state into the Video model.
    onPrepared?.call(local);
    return candidate;
  } catch (_) {
    return null;
  }
}

/// Muzza's saved-source-first chain adapted to Videre's separate download files.
/// The native guarded source verifies the bytes before opening this candidate.
/// This lookup does no network I/O and does not change explicit offline playback.
Future<DownloadPlaybackSource?> resolveDownloadPlaybackSource({
  required IDbClient database,
  required Video video,
  required Server server,
  required bool audioOnly,
  required String sessionId,
  required bool Function() isCurrent,
  int? preferredQuality,
}) async {
  if (kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      !isCurrent() ||
      database.profileId != server.profileId ||
      video.liveNow == true) {
    return null;
  }
  try {
    final library = database.forProfile(server.profileId);
    final download = library.getDownloadByVideoId(video.videoId);
    final proof = download?.playbackProvenance;
    if (download == null ||
        proof == null ||
        !download.downloadComplete ||
        download.downloadFailed ||
        download.storageFailed ||
        download.authenticationRequired ||
        download.profileId != server.profileId ||
        download.accountId != server.accountId ||
        download.audioOnly != audioOnly ||
        download.container != proof.container) {
      return null;
    }

    // Automatic playback uses the currently offered default audio track. A
    // saved alternate language must not silently replace that selection.
    String? remoteUri;
    String? videoQuality;
    Map<String, Object?>? cache;
    if (video.downloadPlaybackOnly) {
      if (!proof.matchesScope(
          server: server,
          contentId: video.videoId,
          audioOnly: audioOnly,
          preferredQuality: preferredQuality)) {
        return null;
      }
      videoQuality = proof.videoHeight == null ? null : '${proof.videoHeight}p';
      cache = {
        'version': 1,
        'profileId': server.profileId,
        'accountId': server.accountId,
        'origin': proof.origin,
        'contentId': video.videoId,
        'sessionId': sessionId,
        if (GatewayRequestContext.forAccount(
                server.profileId, server.accountId, server.url)
            case final context?)
          'gatewayContext': context.encoded,
        'resources': <Map<String, Object?>>[],
      };
    } else {
      final formats = DownloadFormats(video.adaptiveFormats);
      final audio = formats.audioFor(proof.container);
      final selectedVideo = audioOnly
          ? null
          : formats.videoFor(
              preferredQuality != null && preferredQuality > 0
                  ? '${preferredQuality}p'
                  : download.quality,
              container: proof.container);
      if (audio == null ||
          (!audioOnly && selectedVideo == null) ||
          !proof.matchesSelection(
              video: video,
              server: server,
              audioOnly: audioOnly,
              container: proof.container,
              audio: audio,
              videoFormat: selectedVideo)) {
        return null;
      }
      final parsed = parseMediaUrl((selectedVideo ?? audio).url);
      remoteUri = parsed == null
          ? null
          : validatedMediaUrl(proxyMediaUrl(parsed, server), server);
      if (remoteUri == null) return null;
      videoQuality = selectedVideo?.qualityLabel;
      cache = playbackCacheIdentity(
          video: video,
          server: server,
          sourceUrl: remoteUri,
          sessionId: sessionId);
    }
    if (cache == null) return null;
    final path = await download.effectivePath;
    if (!isCurrent() || database.profileId != server.profileId) return null;
    final selected = await database.getCurrentlySelectedServer();
    if (!isCurrent() ||
        database.profileId != server.profileId ||
        selected.profileId != server.profileId ||
        selected.accountId != server.accountId ||
        Uri.parse(selected.url).origin != Uri.parse(server.url).origin ||
        jsonEncode(library.getDownloadByVideoId(video.videoId)?.toJson()) !=
            jsonEncode(download.toJson())) {
      return null;
    }
    final uri = download.storageUri == null ? Uri.file(path).toString() : path;
    return DownloadPlaybackSource(uri, videoQuality, download, {
      ...cache,
      'download': {
        'uri': uri,
        if (remoteUri != null) 'remoteUri': remoteUri,
        'byteLength': proof.byteLength,
        'sha256': proof.sha256,
        if (download.storageUri != null) 'folderUri': download.folderUri,
      },
    });
  } catch (_) {
    // Unavailable or legacy local metadata cannot prevent the admitted online
    // source from being tried. Native context failures still fail closed.
    return null;
  }
}
