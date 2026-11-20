import 'package:flutter/foundation.dart' show mapEquals;
import 'package:just_audio/just_audio.dart';

import '../downloads/models/downloaded_video.dart';
import '../downloads/services/download_playback_source.dart';
import '../extensions.dart';
import '../globals.dart';
import '../videos/models/adaptive_format.dart';
import '../videos/models/video.dart';
import 'media_source.dart';
import 'models/backend_playback.dart';
import 'models/local_music_playback.dart';
import 'models/music_audio_quality.dart';
import 'models/playback_cache_identity.dart';

/// The same ordered, admitted renditions are used for playback and preloading.
typedef AudioPlaybackSources = ({
  List<AudioSource> sources,
  BackendPlayback? menuRoute,
  Set<MusicAudioQuality> qualities,
  Map<AudioSource, MusicAudioQuality> sourceQualities,
  MusicStreamingQuality streamingQuality,
});

bool samePreparedAudioSource(
    AudioPlaybackSources? prepared, AudioPlaybackSources active,
    {int index = 0}) {
  final first = prepared?.sources.elementAtOrNull(index);
  final next = active.sources.elementAtOrNull(index);
  if (first is! UriAudioSource ||
      next is! UriAudioSource ||
      first.runtimeType != next.runtimeType ||
      first.uri != next.uri ||
      !mapEquals(first.headers, next.headers)) {
    return false;
  }
  if (first is ProgressiveAudioSource && next is ProgressiveAudioSource) {
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
  MusicAudioQuality? qualityPreference,
  MusicStreamingQuality? streamingQualityOverride,
  BackendPlayback? qualityRoute,
  bool skipDownload = false,
}) async {
  final sources = <AudioSource>[];
  final qualities = <MusicAudioQuality>{};
  final sourceQualities = <AudioSource, MusicAudioQuality>{};
  BackendPlayback? menuRoute;
  var streamingQuality = MusicStreamingQuality.auto;
  if (isLocalMusicPlaybackId(offlineVideo?.videoId)) {
    final track = localMusicTrackForPlayback(offlineVideo!.videoId);
    if (track == null || offlineVideo.profileId != db.profileId) {
      throw StateError('Local music file is unavailable');
    }
    // A provider's document name is opaque. Even a misleading suffix
    // must never select a playlist decoder that opens nested URLs.
    sources.add(ProgressiveAudioSource(Uri.parse(track.uri)));
  } else if (offlineVideo != null) {
    final path = await offlineVideo.effectivePath;
    if (!isCurrent()) return null;
    sources.add(Uri.tryParse(path)?.scheme == 'content'
        ? AudioSource.uri(Uri.parse(path))
        : AudioSource.file(path));
  } else {
    final selectedServer = await db.getCurrentlySelectedServer();
    if (!isCurrent()) return null;
    if (qualityRoute != null && !qualityRoute.matches(selectedServer)) {
      return null;
    }
    final playback = video?.backendPlayback ?? video?.playbackConnection;
    if (playback != null && !playback.matches(selectedServer)) {
      throw StateError('Playback context changed');
    }
    final server = playback?.server ?? selectedServer;
    if (video == null) return null;
    final music = video.musicMetadata != null;
    if (music) {
      menuRoute = playback ?? BackendPlayback(server);
      streamingQuality =
          streamingQualityOverride ?? MusicStreamingQuality.forDatabase(db);
    }
    final local = skipDownload || qualityPreference != null
        ? null
        : await resolveDownloadPlaybackSource(
            database: db,
            video: video,
            server: server,
            audioOnly: true,
            sessionId: sessionId,
            isCurrent: isCurrent);
    if (!isCurrent()) return null;
    if (local != null) {
      sources.add(AudioSource.uri(Uri.parse(local.uri),
          playbackCache: local.playbackCache));
    }
    final combined = (video.formatStreams ?? [])
        .where((stream) => !stream.isLegacyHd720)
        .toList()
        .reversed
        .map((stream) => stream.url);
    String? admit(String candidate) {
      final parsed = parseMediaUrl(candidate);
      return parsed == null
          ? null
          : validatedMediaUrl(proxyMediaUrl(parsed, server), server);
    }

    final audioByUrl = <String, AdaptiveFormat>{};
    final adaptive = (video.adaptiveFormats ?? <AdaptiveFormat>[])
        .where((format) => format.type.startsWith('audio/'))
        .sortByReversed((format) => int.tryParse(format.bitrate ?? '') ?? 0);
    for (final format in adaptive) {
      final url = admit(format.url);
      if (url != null) audioByUrl.putIfAbsent(url, () => format);
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
    final candidates = {
      if (qualityPreference != null)
        for (final entry in qualityByUrl.entries)
          if (entry.value == qualityPreference) entry.key,
      if (streamingQuality == MusicStreamingQuality.dataSaver)
        ...qualityByUrl.keys.toList().reversed,
      ...audioByUrl.keys,
      ...combined.map(admit).whereType<String>(),
    };
    for (final url in candidates) {
      final source = AudioSource.uri(Uri.parse(url),
          headers: mediaHeaders(server, url),
          playbackCache: playbackCacheIdentity(
            video: video,
            server: server,
            sourceUrl: url,
            sessionId: sessionId,
          ));
      sources.add(source);
      final quality = qualityByUrl[url];
      if (quality != null) sourceQualities[source] = quality;
      if (sources.length >= 10) break;
    }
  }
  return (
    sources: sources,
    menuRoute: menuRoute,
    qualities: qualities,
    sourceQualities: sourceQualities,
    streamingQuality: streamingQuality,
  );
}
