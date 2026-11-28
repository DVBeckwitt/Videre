import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart'
    show DeepCollectionEquality;
import 'package:just_audio/just_audio.dart';

import '../downloads/models/downloaded_video.dart';
import '../downloads/services/download_playback_source.dart';
import '../downloads/services/download_storage.dart';
import '../downloads/services/explicit_music_download.dart';
import '../extensions.dart';
import '../globals.dart';
import '../music/models/device_playlist_track.dart';
import '../music/services/cached_music.dart';
import '../music/models/replay_gain.dart';
import '../music/models/local_music_track.dart';
import '../network/media_companion.dart';
import '../network/network_proxy.dart';
import '../videos/models/adaptive_format.dart';
import '../videos/models/ided_video.dart';
import '../videos/models/video.dart';
import 'media_source.dart';
import 'models/backend_playback.dart';
import 'models/local_music_playback.dart';
import 'models/music_audio_quality.dart';
import 'models/playback_cache_identity.dart';
import 'models/playback_queue.dart';
import 'models/watch_audio_track.dart';

typedef LocalMusicSourceTag = ({String occurrenceId, ReplayGain? replayGain});

/// The same ordered, admitted renditions are used for playback and preloading.
typedef AudioPlaybackSources = ({
  List<AudioSource> sources,
  BackendPlayback? playbackRoute,
  BackendPlayback? menuRoute,
  Set<MusicAudioQuality> qualities,
  Map<AudioSource, MusicAudioQuality> sourceQualities,
  MusicStreamingQuality streamingQuality,
  List<WatchAudioTrack> watchTracks,
  Map<AudioSource, String> watchTrackIds,
});

String? explicitAudioDownloadFingerprint(IdedVideo? entry) => switch (entry) {
      Video(:final explicitMusicDownload) ||
      DownloadedVideo(:final explicitMusicDownload) =>
        explicitMusicDownload,
      _ => null,
    };

bool audioPlaybackRouteIsCurrent(BackendPlayback route) {
  final selected = db.getAccount(route.preferredServer.accountId);
  return selected != null &&
      selected.inUse &&
      !NetworkProxy.instance.isChanging &&
      route.matchesPlaybackConnection(db, selected);
}

bool samePreparedAudioSource(
        AudioPlaybackSources? prepared, AudioPlaybackSources active,
        {int index = 0}) =>
    _sameAudioSource(prepared?.sources.elementAtOrNull(index),
        active.sources.elementAtOrNull(index));

bool _sameAudioSource(AudioSource? first, AudioSource? next) {
  if (first is ClippingAudioSource && next is ClippingAudioSource) {
    return first.start == next.start &&
        first.end == next.end &&
        _sameAudioSource(first.child, next.child);
  }
  if (first is! UriAudioSource ||
      next is! UriAudioSource ||
      first.runtimeType != next.runtimeType ||
      first.uri != next.uri ||
      !mapEquals(first.headers, next.headers) ||
      !const DeepCollectionEquality()
          .equals(first.mediaCompanions, next.mediaCompanions)) {
    return false;
  }
  if (first is ProgressiveAudioSource && next is ProgressiveAudioSource) {
    final firstCached = first.playbackCache?['cachedMusic'] as Map?;
    final nextCached = next.playbackCache?['cachedMusic'] as Map?;
    if (firstCached != null || nextCached != null) {
      return mapEquals(firstCached, nextCached);
    }
    final firstDownload = first.playbackCache?['download'] as Map?;
    final nextDownload = next.playbackCache?['download'] as Map?;
    return mapEquals(firstDownload, nextDownload);
  }
  return true;
}

Future<AudioPlaybackSources?> resolveAudioPlaybackSources({
  required Video? video,
  required DownloadedVideo? offlineVideo,
  required String sessionId,
  required bool Function() isCurrent,
  LocalMusicTrack? Function(String)? openedAudioTrack,
  MusicAudioQuality? qualityPreference,
  MusicStreamingQuality? streamingQualityOverride,
  BackendPlayback? qualityRoute,
  WatchAudioPreference? watchAudio,
  bool skipDownload = false,
  bool verifyPinnedCompletion = true,
  void Function()? onBlockedMediaOrigin,
}) async {
  final sources = <AudioSource>[];
  final qualities = <MusicAudioQuality>{};
  final sourceQualities = <AudioSource, MusicAudioQuality>{};
  final watchTrackIds = <AudioSource, String>{};
  List<WatchAudioTrack> watchTracks = const [];
  BackendPlayback? playbackRoute;
  BackendPlayback? menuRoute;
  var streamingQuality = MusicStreamingQuality.auto;
  final entry = offlineVideo ?? video;
  final fingerprint = explicitAudioDownloadFingerprint(entry);
  if (CachedMusicPlayback.of(video) case final cached?) {
    final database = db;
    final server = await database.getCurrentlySelectedServer();
    if (!isCurrent() || !identical(database, db)) return null;
    final identity = cached.source(server, video!.videoId);
    if (identity == null) throw StateError('Cached song is unavailable');
    sources.add(ProgressiveAudioSource(cached.uri, playbackCache: identity));
  } else if (entry != null && fingerprint != null) {
    if (!isCurrent()) return null;
    final database = db;
    if (offlineVideo != null && offlineVideo.profileId != database.profileId) {
      throw StateError('Saved Music download belongs to another profile');
    }
    final id = entry.videoId;
    final saved = readyMusicDownload(database, id, fingerprint: fingerprint);
    if (saved == null) throw StateError('Saved Music download unavailable');
    final proof = pinnedMusicDownloadFileProof(fingerprint);
    if (proof != null) {
      final available = await DownloadStorage()
          .musicFileProof(saved, verifyCompletion: verifyPinnedCompletion);
      if (!isCurrent() || !identical(database, db)) return null;
      if (available != proof) {
        throw StateError('Saved Music file is unavailable or was replaced');
      }
    }
    final path = await saved.effectivePath;
    if (!isCurrent() || !identical(database, db)) return null;
    if (readyMusicDownload(database, id, fingerprint: fingerprint) == null) {
      throw StateError('Saved Music download changed');
    }
    final uri = saved.storageUri == null ? Uri.file(path) : Uri.tryParse(path);
    if (uri == null ||
        !(uri.scheme == 'content' && uri.host.isNotEmpty ||
            uri.scheme == 'file' && uri.host.isEmpty && uri.hasAbsolutePath)) {
      throw StateError('Saved Music download has no local file');
    }
    // A document's name can resemble a streaming manifest. Always open the
    // selected file as a single progressive audio source.
    sources.add(ProgressiveAudioSource(uri));
  } else if (isLocalMusicPlaybackId(entry?.videoId)) {
    if (!isCurrent()) return null;
    final id = entry!.videoId;
    final track = isOpenedAudioPlaybackId(id)
        ? openedAudioTrack?.call(id)
        : localMusicTrackForPlayback(id);
    if (track == null ||
        (offlineVideo != null && offlineVideo.profileId != db.profileId) ||
        (offlineVideo == null &&
            devicePlaylistFileProof(entry.videoId) == null)) {
      throw StateError('Local music file is unavailable');
    }
    // A provider's document name is opaque. Even a misleading suffix
    // must never select a playlist decoder that opens nested URLs.
    final tag =
        (occurrenceId: playbackQueueId(entry), replayGain: track.replayGain);
    final source = ProgressiveAudioSource(Uri.parse(track.uri), tag: tag);
    final start = track.cueStartUs;
    final end = track.cueEndUs;
    sources.add(start == null
        ? source
        : ClippingAudioSource(
            child: source,
            start: Duration(microseconds: start),
            end: end == null ? null : Duration(microseconds: end),
            tag: tag));
  } else if (offlineVideo != null) {
    // The local library can rename a managed document while this queue still
    // holds the previous provider URI. Resolve the current owned download on
    // the next decoder open, leaving the mounted audio descriptor alone.
    final managed = offlineVideo.storageUri != null &&
            offlineVideo.profileId == db.profileId
        ? db.getDownloadByVideoId(offlineVideo.videoId)
        : null;
    final path = managed != null &&
            managed.downloadComplete &&
            managed.storageUri != null &&
            managed.profileId == offlineVideo.profileId &&
            managed.audioOnly == offlineVideo.audioOnly &&
            managed.folderUri == offlineVideo.folderUri
        ? managed.storageUri!
        : await offlineVideo.effectivePath;
    if (!isCurrent()) return null;
    sources.add(Uri.tryParse(path)?.scheme == 'content'
        ? AudioSource.uri(Uri.parse(path))
        : AudioSource.file(path));
  } else {
    final selectedServer = await db.getCurrentlySelectedServer();
    if (!isCurrent()) return null;
    if (qualityRoute != null &&
        !qualityRoute.matchesPlaybackConnection(db, selectedServer)) {
      return null;
    }
    final playback = video?.backendPlayback ?? video?.playbackConnection;
    if (playback != null &&
        !playback.matchesPlaybackConnection(db, selectedServer)) {
      throw StateError('Playback context changed');
    }
    final server = playback?.server ?? selectedServer;
    final instanceFallback = playback?.isInstanceFallback == true;
    final crossProfile =
        instanceFallback && server.profileId != selectedServer.profileId;
    final mediaServer = instanceFallback ? server : selectedServer;
    playbackRoute = playback ?? BackendPlayback(selectedServer);
    final companions =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? mediaCompanionContext(mediaServer)
            : null;
    if (video == null) return null;
    final music = watchAudio == null && video.musicMetadata != null;
    if (music) {
      menuRoute = playbackRoute;
      streamingQuality =
          streamingQualityOverride ?? MusicStreamingQuality.forDatabase(db);
    }
    final local = instanceFallback || skipDownload || qualityPreference != null
        ? null
        : await resolveDownloadPlaybackSource(
            database: db,
            video: video,
            server: server,
            audioOnly: true,
            sessionId: sessionId,
            isCurrent: isCurrent);
    if (!isCurrent()) return null;
    var blockedMediaOrigin = false;
    String? admit(String candidate) =>
        proxiedPlaybackMediaUrl(candidate, mediaServer,
            onBlockedMediaOrigin: () => blockedMediaOrigin = true);

    final audioByUrl = <String, AdaptiveFormat>{};
    final watchMetadata = <String, List<AudioTrack?>>{};
    void rememberTrack(String url, AudioTrack? track) {
      if (watchAudio != null) {
        (watchMetadata[url] ??= []).add(track);
      }
    }

    final adaptive = (video.adaptiveFormats ?? <AdaptiveFormat>[])
        .where((format) => format.type.startsWith('audio/'))
        .sortByReversed((format) => int.tryParse(format.bitrate ?? '') ?? 0);
    for (final format in adaptive) {
      final url = admit(format.url);
      if (url == null) continue;
      audioByUrl.putIfAbsent(url, () => format);
      rememberTrack(url, format.audioTrack);
    }
    final combined = <String>{};
    for (final stream in (video.formatStreams ?? []).reversed) {
      if (stream.isLegacyHd720) continue;
      final url = admit(stream.url);
      if (url == null) continue;
      combined.add(url);
      rememberTrack(url, stream.audioTrack);
    }
    // Bitrate changes must keep the same audio language. Untagged
    // streams are the original/default track on ordinary instances.
    if (music && audioByUrl.isNotEmpty) {
      final available = audioByUrl.values;
      final primary = available.firstWhere(
          (format) => format.audioTrack == null,
          orElse: () => available.firstWhere(
              (format) => format.audioTrack?.audioIsDefault == true,
              orElse: () => available.first));
      audioByUrl.removeWhere(
          (_, format) => format.audioTrack?.id != primary.audioTrack?.id);
    }
    final qualityByUrl = <String, MusicAudioQuality>{};
    if (music) {
      for (final entry in audioByUrl.entries) {
        final quality = musicAudioQualityOf(entry.value);
        if (quality != null) {
          qualityByUrl[entry.key] = quality;
          qualities.add(quality);
        }
      }
    }
    // Audio playback should not depend on a combined video stream.
    // Keep combined formats as a fallback for missing usable audio.
    final watchPlan = watchAudio == null
        ? null
        : _watchSources(watchAudio, audioByUrl.keys, combined, watchMetadata);
    final candidates = watchPlan?.urls ??
        {
          if (qualityPreference != null)
            for (final entry in qualityByUrl.entries)
              if (entry.value == qualityPreference) entry.key,
          if (streamingQuality == MusicStreamingQuality.dataSaver)
            ...qualityByUrl.keys.toList().reversed,
          ...audioByUrl.keys,
          ...combined,
        };
    if (watchPlan != null) watchTracks = watchPlan.tracks;
    if (local != null) {
      final download = local.playbackCache['download'];
      final remote = download is Map ? download['remoteUri'] : null;
      final useDownloadOnly = video.downloadPlaybackOnly &&
          watchAudio?.trackId == null &&
          watchAudio?.progressiveUrl == null;
      // Ordinary Watch can use an opportunistic local copy when its proven
      // remote rendition is among the chosen track's admitted candidates.
      if (watchPlan == null || useDownloadOnly || candidates.contains(remote)) {
        final source = AudioSource.uri(Uri.parse(local.uri),
            playbackCache: local.playbackCache);
        sources.add(source);
        if (watchPlan?.trackIds[remote] case final id?) {
          watchTrackIds[source] = id;
        }
      }
    }
    for (final url in candidates) {
      final source = AudioSource.uri(Uri.parse(url),
          headers: mediaHeaders(server, url),
          mediaCompanions: companions,
          playbackCache: crossProfile
              ? null
              : playbackCacheIdentity(
                  video: video,
                  server: server,
                  sourceUrl: url,
                  sessionId: sessionId,
                  mediaCompanions: companions != null,
                  progressiveMusicAudio:
                      music && !instanceFallback ? audioByUrl[url] : null,
                ));
      sources.add(source);
      final quality = qualityByUrl[url];
      if (quality != null) sourceQualities[source] = quality;
      if (watchPlan?.trackIds[url] case final id?) watchTrackIds[source] = id;
      if (sources.length >= 10) break;
    }
    if (sources.isEmpty && blockedMediaOrigin) onBlockedMediaOrigin?.call();
  }
  return (
    sources: sources,
    playbackRoute: playbackRoute,
    menuRoute: menuRoute,
    qualities: qualities,
    sourceQualities: sourceQualities,
    streamingQuality: streamingQuality,
    watchTracks: watchTracks,
    watchTrackIds: watchTrackIds,
  );
}

({Set<String> urls, Map<String, String> trackIds, List<WatchAudioTrack> tracks})
    _watchSources(WatchAudioPreference preference, Iterable<String> adaptive,
        Set<String> progressive, Map<String, List<AudioTrack?>> metadata) {
  final ids = <String, String>{};
  final defaults = <String>{};
  final labels = <String, Set<String>>{};
  for (final entry in metadata.entries) {
    final candidates = entry.value.map(watchAudioTrackId).toSet();
    // Signed URLs described by contradictory metadata cannot prove a track.
    if (candidates.length != 1 || candidates.single == null) continue;
    final id = candidates.single!;
    ids[entry.key] = id;
    for (final track in entry.value.whereType<AudioTrack>()) {
      if (track.audioIsDefault) defaults.add(id);
      final label = track.displayName.trim();
      if (label.isNotEmpty && label != id) (labels[id] ??= {}).add(label);
    }
  }
  final groups = ids.values.toSet();
  final tracks = [
    for (final entry in labels.entries)
      (id: entry.key, label: (entry.value.toList()..sort()).first),
  ]..sort((a, b) {
      final labels = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return labels == 0 ? a.id.compareTo(b.id) : labels;
    });

  final prior = preference.progressiveUrl;
  final exact = progressive.contains(prior) ? prior : null;
  Set<String> forTrack(String id) => {
        ...adaptive.where((url) => ids[url] == id),
        ...progressive.where((url) => ids[url] == id),
      };

  final requested = preference.trackId;
  final selected = groups.contains(requested) ? requested : ids[exact];
  if (selected != null) {
    return (urls: forTrack(selected), trackIds: ids, tracks: tracks);
  }
  if (exact != null) {
    // A live muxed choice with unreported language is the only source proven
    // to contain the same audio. Do not mix later attempts with other dubs.
    return (urls: {exact}, trackIds: ids, tracks: tracks);
  }
  final defaultId = defaults.singleOrNull;
  if (defaultId != null) {
    return (urls: forTrack(defaultId), trackIds: ids, tracks: tracks);
  }
  if (groups.isEmpty) {
    return (urls: {...adaptive, ...progressive}, trackIds: ids, tracks: tracks);
  }
  final unknownAudio = adaptive.where((url) => !ids.containsKey(url));
  final sole = groups.singleOrNull;
  if (sole != null && unknownAudio.isEmpty) {
    return (urls: forTrack(sole), trackIds: ids, tracks: tracks);
  }
  final unknownVideo = progressive.where((url) => !ids.containsKey(url));
  // An unlabeled muxed stream is a better fallback for ambiguous alternates.
  // If every rendition is tagged, choose one stable ID and retry within it.
  final fallback = unknownVideo.isNotEmpty
      ? unknownVideo.toSet()
      : unknownAudio.isNotEmpty
          ? unknownAudio.toSet()
          : forTrack((groups.toList()..sort()).first);
  return (urls: fallback, trackIds: ids, tracks: tracks);
}
