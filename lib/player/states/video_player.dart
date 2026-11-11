import 'dart:async';
import 'dart:io';

import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:logging/logging.dart';
import 'package:river_player/river_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../globals.dart';
import '../../main.dart';
import '../../network/nerdvpn_access.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/pretty_bytes.dart';
import '../../videos/models/video.dart';
import '../adaptive_dash_manifest.dart';
import '../media_source.dart';
import '../models/backend_playback.dart';
import '../models/media_command.dart';
import '../models/playback_pitch.dart';
import '../models/video_quality.dart';
import '../views/components/player_controls.dart';
import '../views/components/subtitle_failure_notice.dart';
import '../views/tv/components/player_controls.dart';
import 'interfaces/media_player.dart';

part 'video_player.freezed.dart';

final log = Logger('VideoPlayer');
const _maxPlaybackSources = 10;

Map<String, String>? _compatibleResolutions(
  Server server,
  Map<String, String>? resolutions,
  Map<String, String>? sourceHeaders,
) {
  if (resolutions == null) return null;

  final compatible = Map.fromEntries(
    resolutions.entries.where((entry) {
      final resolutionHeaders = mediaHeaders(server, entry.value);
      return mapEquals(resolutionHeaders, sourceHeaders);
    }),
  );
  return compatible.isEmpty ? null : compatible;
}

String _streamLabel(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final label = candidate?.trim();
    if (label != null && label.isNotEmpty) return label;
  }
  return 'unknown';
}

String _sourceKey(String url) {
  final uri = Uri.parse(url).normalizePath();
  final defaultPort = (uri.scheme == 'http' && uri.port == 80) ||
      (uri.scheme == 'https' && uri.port == 443);
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        port: defaultPort ? 0 : uri.port,
        fragment: '',
      )
      .toString();
}

List<BetterPlayerDataSource> _buildPlaybackDataSources(
  Video video,
  Server server, {
  required bool preferDash,
  int? preferredQuality,
  String? lastSubtitle,
}) {
  final sources = <BetterPlayerDataSource>[];
  final seen = <String>{};
  late final subtitles = video.captions.map((caption) {
    return BetterPlayerSubtitlesSource(
      type: BetterPlayerSubtitlesSourceType.memory,
      contentLoader: () => service.getPlaybackCaptions(
        video.videoId,
        caption,
        server: server,
      ),
      name: caption.label,
      selectedByDefault: caption.label == lastSubtitle,
    );
  }).toList();

  void add(String url, BetterPlayerVideoFormat format,
      {Map<String, String>? resolutions}) {
    if (sources.length >= _maxPlaybackSources || !seen.add(_sourceKey(url))) {
      return;
    }
    final headers = mediaHeaders(server, url);
    sources.add(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url,
      videoFormat: format,
      liveStream: video.liveNow,
      subtitles: subtitles,
      resolutions: _compatibleResolutions(server, resolutions, headers),
      headers: headers,
      useAsmsSubtitles: false,
    ));
  }

  String? adaptiveUrl(String? value) {
    final url = parseMediaUrl(value);
    return url == null
        ? null
        : validatedMediaUrl(proxyMediaUrl(url, server, adaptive: true), server);
  }

  final hls = adaptiveUrl(video.hlsUrl);
  if (hls != null) {
    add(hls, BetterPlayerVideoFormat.hls);
  }

  final dash = adaptiveUrl(video.dashUrl);
  void addDash() {
    if (dash != null) {
      add(dash, BetterPlayerVideoFormat.dash);
    }
  }

  final streams = <({String resolution, String url})>[];
  final streamUrls = <String>{};
  for (final stream in (video.formatStreams ?? []).reversed) {
    if (stream.isLegacyHd720) continue;
    final url = parseMediaUrl(stream.url);
    if (url == null) continue;
    final safeUrl = validatedMediaUrl(proxyMediaUrl(url, server), server);
    if (safeUrl == null || !streamUrls.add(_sourceKey(safeUrl))) continue;
    final resolution = _streamLabel([
      stream.resolution,
      stream.qualityLabel,
      stream.quality,
      stream.itag,
    ]);
    streams.add((resolution: resolution, url: safeUrl));
    if (streams.length >= _maxPlaybackSources) {
      break;
    }
  }

  void addProgressive() {
    final accepted = streams
        .where((stream) => !seen.contains(_sourceKey(stream.url)))
        .take(_maxPlaybackSources - sources.length)
        .toList();
    final resolutions = <String, String>{};
    for (final stream in accepted) {
      resolutions.putIfAbsent(stream.resolution, () => stream.url);
    }
    // Change playback priority without reordering the quality menu.
    final preferred = preferredVideoQualityIndex(
        accepted.map((s) => videoQualityHeight(s.resolution)).toList(),
        preferredQuality);
    if (preferred != null) {
      accepted.insert(0, accepted.removeAt(preferred));
    }
    for (final stream in accepted) {
      final sourceResolutions = resolutions[stream.resolution] == stream.url
          ? resolutions
          : {...resolutions, stream.resolution: stream.url};
      add(stream.url, BetterPlayerVideoFormat.other,
          resolutions: sourceResolutions);
    }
  }

  if (preferDash) addDash();
  addProgressive();
  if (!preferDash) addDash();
  return sources;
}

class VideoPlayerCubit extends MediaPlayerCubit<VideoPlayerState> {
  BetterPlayerController? videoController;
  final SettingsCubit settings;
  List<BetterPlayerDataSource> _playbackSources = const [];
  Server? _playbackServer;
  String? _playbackVideoId;
  int _playbackSourceIndex = 0;
  bool _playbackInitialized = false;
  bool _terminalErrorSent = false;
  int? _manualRetryGeneration;
  bool _sourceFailurePending = false;
  int _playbackGeneration = 0;
  int _parentPlaybackGeneration = 0;
  Future<void>? _controllerSetup;
  ({int generation, int sourceIndex})? _controllerSetupAttempt;
  Completer<void> _setupCancellation = Completer<void>();
  Function(BetterPlayerEvent)? _videoListener;
  Duration _playbackStartAt = Duration.zero;
  Duration? _pendingSeek;
  int _seekRevision = 0;
  bool _waitingForInitialSeek = false;
  bool _sourceBackendRetryable = false;
  bool _backendRecoveryPending = false;
  bool _recoveringInitializedPlayback = false;
  bool _playbackOffline = false;
  bool _requestedPlaying = true;
  double _playbackSpeed = 1;
  VoidCallback? _endSpeedBoost;
  int _playbackPitchSemitones = 0;
  String? _qualityVideoId;
  int? _videoQuality;
  BetterPlayerSubtitlesSource? _failedSubtitle;

  bool get _shouldPlay => _requestedPlaying && player.shouldStartPlayback;

  VideoPlayerCubit(super.initialState, super.player, this.settings) {
    onInit();
  }

  void onInit() {
    log.fine("Ready, playing video");
    playVideo(state.offlineVideo != null, startAt: state.startAt);
  }

  @override
  Future<void> close() async {
    await stopForProxyChange();
    await super.close();
  }

  @override
  Future<void> stopForProxyChange() async {
    dismissSubtitleFailure();
    _playbackGeneration++;
    _playbackSources = const [];
    _playbackServer = null;
    _playbackVideoId = null;
    _backendRecoveryPending = false;
    _requestedPlaying = false;
    _cancelSetup();
    _controllerSetup = null;
    _controllerSetupAttempt = null;
    final controller = videoController;
    try {
      // BetterPlayer disposal is synchronous but native pause is asynchronous.
      // Wait for silence before another person's account can become active.
      await controller?.videoPlayerController?.pause();
    } finally {
      if (identical(videoController, controller)) disposeControllers();
    }
  }

  @override
  void disposeControllers() {
    _endSpeedBoost?.call();
    WakelockPlus.disable();
    log.fine("Disposing video controller");
    final newState = state.copyWith();
    videoController?.exitFullScreen();
    if (_videoListener != null) {
      videoController?.removeEventsListener(_videoListener!);
      _videoListener = null;
    }
    videoController?.dispose();
    videoController = null;
    if (!isClosed) {
      emit(newState);
    }
  }

  void forwardEvent(BetterPlayerEvent event) {
    MediaEventType? type;
    MediaState mediaState = MediaState.playing;

    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.setPitch:
        final semitones = semitonesForPitchFactor(event.parameters?['pitch']);
        if (semitones != null) {
          player.setEvent(MediaEvent<int>(
              state: MediaState.ready,
              type: MediaEventType.pitchChanged,
              value: semitones));
        }
        return;
      case BetterPlayerEventType.setSpeed:
        player.setEvent(MediaEvent(
            state: MediaState.playing,
            type: MediaEventType.speedChanged,
            value: event.parameters?['speed']));
        return;
      case BetterPlayerEventType.pause:
        type = MediaEventType.pause;
        break;
      case BetterPlayerEventType.setVolume:
        break;
      case BetterPlayerEventType.play:
        type = MediaEventType.play;
        break;

      case BetterPlayerEventType.progress:
        EasyThrottle.throttle(
            'video-player-progress', const Duration(seconds: 1), () {
          if (isClosed || _terminalErrorSent || _backendRecoveryPending) return;
          player.setEvent(MediaEvent(
              state: MediaState.playing,
              type: MediaEventType.progress,
              value: videoController?.videoPlayerController?.value.position ??
                  Duration.zero));
        });
      case BetterPlayerEventType.seekTo:
        // we bypass the rest so we can send the current progress
        player.setEvent(MediaEvent(
            state: MediaState.playing,
            type: MediaEventType.progress,
            value: videoController?.videoPlayerController?.value.position ??
                Duration.zero));
        return;
      case BetterPlayerEventType.bufferingEnd:
        mediaState = MediaState.playing;
        break;
      case BetterPlayerEventType.bufferingStart:
        mediaState = MediaState.buffering;
        break;
      case BetterPlayerEventType.changedPlayerVisibility:
        break;
      case BetterPlayerEventType.changedPlaylistItem:
        break;
      case BetterPlayerEventType.setupDataSource:
        mediaState = MediaState.loading;
        break;
      case BetterPlayerEventType.controlsVisible:
        break;
      case BetterPlayerEventType.openFullscreen:
        break;
      case BetterPlayerEventType.initialized:
        player.setEvent(MediaEvent<int>(
            state: MediaState.ready,
            type: MediaEventType.pitchChanged,
            value: getPitchSemitones()));
        player.setEvent(MediaEvent<double>(
            state: MediaState.ready,
            type: MediaEventType.speedChanged,
            value: getSpeed()));
        player.setEvent(MediaEvent<double>(
            state: MediaState.ready,
            type: MediaEventType.aspectRatioChanged,
            value: getAspectRatio()));
        mediaState = MediaState.ready;
        break;
      case BetterPlayerEventType.hideFullscreen:
        break;
      case BetterPlayerEventType.finished:
        mediaState = MediaState.completed;
        break;
      case BetterPlayerEventType.exception:
        mediaState = MediaState.error;
        break;
      case BetterPlayerEventType.controlsHiddenStart:
        break;
      case BetterPlayerEventType.controlsHiddenEnd:
        break;
      case BetterPlayerEventType.changedTrack:
        break;
      case BetterPlayerEventType.changedSubtitles:
        return;
      case BetterPlayerEventType.changedResolution:
        break;
      default:
        return;
    }

    player.setEvent(MediaEvent(state: mediaState, type: type));
  }

  void onVideoListener(BetterPlayerEvent event) {
    if (isClosed || _backendRecoveryPending || _terminalErrorSent) return;
    if (event.betterPlayerEventType ==
        BetterPlayerEventType.subtitleLoadFailed) {
      _failedSubtitle =
          event.parameters?['source'] as BetterPlayerSubtitlesSource?;
      emit(state.copyWith(subtitleFailed: _failedSubtitle != null));
      return;
    }
    if (event.betterPlayerEventType == BetterPlayerEventType.progress ||
        event.betterPlayerEventType == BetterPlayerEventType.seekTo) {
      if (!_playbackInitialized) return;
      // Initialization can report zero before the resume seek has finished.
      if (_waitingForInitialSeek) {
        if (event.betterPlayerEventType != BetterPlayerEventType.seekTo ||
            event.parameters?['duration'] is! Duration) {
          return;
        }
        _waitingForInitialSeek = false;
      }
    }
    if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
      if (_backendRecoveryPending || _terminalErrorSent) return;
      final retryable = event.parameters?['backendRetryable'] == true;
      _sourceBackendRetryable = _playbackInitialized
          ? retryable
          : _sourceBackendRetryable || retryable;
      if (_playbackInitialized && (_playbackOffline || !retryable)) {
        _emitTerminalPlaybackError();
      } else if (_playbackInitialized) {
        final generation = _playbackGeneration;
        final sourceIndex = _playbackSourceIndex;
        unawaited(_recoverPlayback(generation, sourceIndex).then((recovered) {
          if (!recovered && _isCurrentAttempt(generation, sourceIndex)) {
            _emitTerminalPlaybackError();
          }
        }));
      } else {
        _requestSourceFailure();
      }
      return;
    }
    if (!_backendRecoveryPending && _controllerSetupAttempt == null) {
      if (event.betterPlayerEventType == BetterPlayerEventType.play) {
        _requestedPlaying = true;
      } else if (event.betterPlayerEventType == BetterPlayerEventType.pause) {
        _requestedPlaying = false;
      }
    }
    if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
      _playbackInitialized = true;
      _sourceFailurePending = false;
      _sourceBackendRetryable = false;
      // Loading a source resets river_player's Dart value to 1 without resetting
      // the native rate. Apply our rate for every source, including resolution
      // changes, while keeping it unchanged for the current video.
      if (videoController?.videoPlayerController != null) {
        videoController?.setSpeed(_playbackSpeed);
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          videoController
              ?.setPitch(pitchFactorForSemitones(_playbackPitchSemitones));
        }
      }
    }

    final nativeValue = videoController?.videoPlayerController?.value;
    final video = state.video;
    if (video != null && nativeValue != null) {
      if (_playbackInitialized &&
          !nativeValue.isPlaying &&
          !nativeValue.isBuffering &&
          (event.betterPlayerEventType == BetterPlayerEventType.pause ||
              event.betterPlayerEventType ==
                  BetterPlayerEventType.bufferingEnd ||
              event.betterPlayerEventType == BetterPlayerEventType.progress)) {
        player.reportBackendPlaybackReady(video.videoId, video.backendPlayback,
            playing: false);
        player.reportPlaybackRecoveryReady(video, playing: false);
      }
      if (event.betterPlayerEventType == BetterPlayerEventType.progress) {
        player.reportBackendPlaybackProgress(
            video.videoId, video.backendPlayback, nativeValue.position,
            playing: nativeValue.isPlaying && !nativeValue.isBuffering);
        player.reportPlaybackRecoveryProgress(video, nativeValue.position,
            playing: nativeValue.isPlaying && !nativeValue.isBuffering);
      } else if (event.betterPlayerEventType == BetterPlayerEventType.seekTo) {
        player.reportBackendPlaybackProgress(
            video.videoId, video.backendPlayback, nativeValue.position,
            playing: false);
        player.reportPlaybackRecoveryProgress(video, nativeValue.position,
            playing: false);
      }
    }
    forwardEvent(event);

    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.bufferingUpdate:
        EasyThrottle.throttle('video-buffering', const Duration(seconds: 1),
            () {
          List<DurationRange> durations = event.parameters?['buffered'] ?? [];
          final buffered = durations.fold(Duration.zero,
              (latest, range) => range.end > latest ? range.end : latest);
          emit(state.copyWith(bufferPosition: buffered));
          player.setEvent(MediaEvent(
              state: MediaState.playing,
              type: MediaEventType.bufferChanged,
              value: state.bufferPosition));
        });
        break;

      case BetterPlayerEventType.changedSubtitles:
        dismissSubtitleFailure();
        settings.setLastSubtitle(
            videoController?.betterPlayerSubtitlesSource?.name ?? '');
        break;
      case BetterPlayerEventType.setupDataSource:
        dismissSubtitleFailure();
        break;
      case BetterPlayerEventType.setPitch:
        final semitones = semitonesForPitchFactor(event.parameters?['pitch']);
        if (semitones != null) _playbackPitchSemitones = semitones;
        break;
      case BetterPlayerEventType.setSpeed:
        final speed = event.parameters?['speed'];
        if (speed is num && speed.isFinite && speed > 0) {
          _playbackSpeed = speed.toDouble();
          settings.setLastSpeed(_playbackSpeed);
        }
        break;
      default:
        break;
    }
  }

  void _listenForPlaybackEvents(int generation) {
    if (_videoListener != null) {
      videoController?.removeEventsListener(_videoListener!);
    }
    final sourceIndex = _playbackSourceIndex;
    _videoListener = (event) {
      if (_isCurrentAttempt(generation, sourceIndex)) {
        onVideoListener(event);
      }
    };
    videoController?.addEventsListener(_videoListener!);
  }

  String? _selectedResolution(BetterPlayerDataSource source) =>
      source.resolutions?.entries
          .where((entry) => entry.value == source.url)
          .firstOrNull
          ?.key;

  void _emitTerminalPlaybackError() {
    if (isClosed ||
        _terminalErrorSent ||
        _parentPlaybackGeneration != player.backendPlaybackGeneration) {
      return;
    }
    _terminalErrorSent = true;
    if (videoController?.betterPlayerDataSource != null) {
      videoController!.pause();
    }
    WakelockPlus.disable();
    // Terminal state suppresses later native callbacks, including Pause.
    // Publish it explicitly so transport controls do not claim playback.
    player.setEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.pause));
    player.setEvent(const MediaEvent(state: MediaState.error));
    final generation = _playbackGeneration;
    void pauseAfterSetup() {
      if (!isClosed &&
          generation == _playbackGeneration &&
          _terminalErrorSent &&
          videoController?.betterPlayerDataSource != null) {
        videoController!.pause();
      }
    }

    _controllerSetup?.then<void>(
      (_) => pauseAfterSetup(),
      onError: (_) => pauseAfterSetup(),
    );
  }

  void _requestSourceFailure() {
    if (_sourceFailurePending) return;
    _sourceFailurePending = true;
    final generation = _playbackGeneration;
    final sourceIndex = _playbackSourceIndex;
    if (_controllerSetupAttempt ==
        (generation: generation, sourceIndex: sourceIndex)) {
      return;
    }
    Future<void>(() => _handleSourceFailure(generation, sourceIndex));
  }

  bool _isCurrentAttempt(int generation, int sourceIndex) =>
      !isClosed &&
      _parentPlaybackGeneration == player.backendPlaybackGeneration &&
      generation == _playbackGeneration &&
      sourceIndex == _playbackSourceIndex;

  void _cancelSetup() {
    if (!_setupCancellation.isCompleted) {
      _setupCancellation.complete();
    }
  }

  Future<void> _handleSourceFailure(int generation, int sourceIndex) async {
    if (!_isCurrentAttempt(generation, sourceIndex) ||
        _playbackInitialized ||
        !_sourceFailurePending) {
      return;
    }
    _sourceFailurePending = false;
    final server = _playbackServer;
    if (server != null) {
      service.dashManifestResolver
          .invalidate(_playbackSources[sourceIndex].url, server);
    }
    if (_playbackSourceIndex + 1 >= _playbackSources.length) {
      final recovered = _recoveringInitializedPlayback
          ? await _recoverPlayback(generation, sourceIndex)
          : await _recoverBackend(generation, sourceIndex);
      if (!recovered && _isCurrentAttempt(generation, sourceIndex)) {
        _emitTerminalPlaybackError();
      }
      return;
    }
    _playbackSourceIndex++;
    await _setupPlaybackSource();
  }

  Future<bool> _recoverPlayback(int generation, int sourceIndex) async {
    final video = state.video;
    final controller = videoController;
    if (!_isCurrentAttempt(generation, sourceIndex)) return true;
    if (_backendRecoveryPending) return true;
    if (_playbackOffline || !_sourceBackendRetryable || video == null) {
      return false;
    }
    bool active() =>
        _isCurrentAttempt(generation, sourceIndex) &&
        identical(state.video, video) &&
        identical(videoController, controller) &&
        !player.state.isAudio;
    final resumeAt = _playbackInitialized ? position() : _playbackStartAt;
    _backendRecoveryPending = true;
    var tryAlternate = false;
    try {
      final replacement =
          await player.refreshCurrentPlayback(video, isCurrent: active);
      if (!active()) return true;
      if (replacement != null) {
        emit(state.copyWith(video: replacement));
        _backendRecoveryPending = false;
        await playVideo(false,
            startAt: _pendingSeek ?? resumeAt,
            preservePlaybackIntent: true,
            recoveringPlayback: true);
        return true;
      }
      tryAlternate = true;
    } catch (error) {
      if (!active()) return true;
      // Access denials, cooldowns and privacy refusals never authorize another
      // route. Only classified transient failures may use the existing budget.
      tryAlternate = isBackendRetryable(error);
    } finally {
      if (generation == _playbackGeneration) _backendRecoveryPending = false;
    }
    return tryAlternate && await _recoverBackend(generation, sourceIndex);
  }

  Future<bool> _recoverBackend(int generation, int sourceIndex) async {
    final video = state.video;
    final controller = videoController;
    if (!_isCurrentAttempt(generation, sourceIndex)) return true;
    if (_backendRecoveryPending) return true;
    if (_playbackOffline ||
        !_sourceBackendRetryable ||
        video?.backendPlayback == null) {
      return false;
    }
    bool active() =>
        _isCurrentAttempt(generation, sourceIndex) &&
        identical(state.video, video) &&
        identical(videoController, controller) &&
        !player.state.isAudio;
    final resumeAt = _playbackInitialized ? position() : _playbackStartAt;
    _backendRecoveryPending = true;
    try {
      final replacement = await service.retryVideoBackend(
        video!,
        isCurrent: active,
        onRetry: (request) {
          if (active() && player.setRequestedBackend(video.videoId, request)) {
            player.setEvent(MediaEvent(
                state: MediaState.loading,
                type: MediaEventType.backendRetry,
                value: request.label));
          }
        },
      );
      if (!active()) return true;
      if (replacement == null) return false;
      player.reportBackendVideoLoaded(replacement);
      emit(state.copyWith(video: replacement));
      _backendRecoveryPending = false;
      await playVideo(false,
          startAt: _pendingSeek ?? resumeAt, preservePlaybackIntent: true);
      return true;
    } catch (_) {
      // API and decoder diagnostics can contain signed URLs. The existing
      // terminal state is enough here; do not log request data during recovery.
      return !active();
    } finally {
      if (generation == _playbackGeneration) _backendRecoveryPending = false;
    }
  }

  Future<void> _setupPlaybackSource({bool seekAfterSetup = true}) async {
    if (!_isCurrentAttempt(_playbackGeneration, _playbackSourceIndex)) return;
    _sourceBackendRetryable = false;
    final generation = _playbackGeneration;
    final sourceIndex = _playbackSourceIndex;
    var source = _playbackSources[sourceIndex];
    final cancelled = _setupCancellation.future;
    final previousSetup = _controllerSetup;
    if (previousSetup != null) {
      try {
        await Future.any([previousSetup, cancelled]);
      } catch (_) {}
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
    }

    final server = _playbackServer;
    final videoId = _playbackVideoId;
    if (source.videoFormat == BetterPlayerVideoFormat.dash &&
        source.inlineDashManifest == null &&
        server != null &&
        videoId != null) {
      String? resolved;
      String? downloadedManifest;
      final canUseInlineManifest = !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          state.video?.liveNow != true;
      var missingCheck = false;
      try {
        resolved = await Future.any([
          service.dashManifestResolver.resolve(source.url, videoId, server,
              throwRetryable: state.video?.backendPlayback != null ||
                  _recoveringInitializedPlayback,
              onMissingCheck: () => missingCheck = true,
              onManifest: canUseInlineManifest
                  ? (content) => downloadedManifest = content
                  : null),
          cancelled.then<String?>((_) => null),
        ]);
      } on BackendPlaybackFailure {
        if (!_isCurrentAttempt(generation, sourceIndex)) return;
        _sourceBackendRetryable = true;
      } catch (error) {
        if (error is! NerdVpnAccessRequired &&
            error is! InvidiousServiceError &&
            error is! HandshakeException &&
            !(error is SocketException && error.osError == null)) {
          rethrow;
        }
        if (_isCurrentAttempt(generation, sourceIndex)) {
          _emitTerminalPlaybackError();
        }
        return;
      }
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
      final video = state.video;
      String? inlineManifest = resolved == null ? null : downloadedManifest;
      var generatedManifest = false;
      if (resolved == null &&
          missingCheck &&
          !_sourceBackendRetryable &&
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          video != null &&
          video.liveNow != true) {
        final manifestUri = Uri.parse(source.url);
        inlineManifest = buildAdaptiveDashManifest(
          formats: video.adaptiveFormats ?? const [],
          duration: Duration(seconds: video.lengthSeconds ?? 0),
          resolveMediaUrl: (value) {
            final url = parseMediaUrl(value);
            if (url == null) return null;
            final target =
                validatedMediaUrl(proxyMediaUrl(url, server), server);
            if (target == null ||
                !sameMediaOrigin(Uri.parse(target), manifestUri)) {
              return null;
            }
            return target;
          },
        );
        generatedManifest = inlineManifest != null;
      }
      if (resolved == null && inlineManifest == null) {
        _sourceFailurePending = true;
        await _handleSourceFailure(generation, sourceIndex);
        return;
      }
      source = source.copyWith(
        url: resolved,
        inlineDashManifest: inlineManifest,
        // Generated audio groups lack language labels. Media3 selects audio.
        useAsmsAudioTracks: generatedManifest ? false : null,
      );
      _playbackSources[sourceIndex] = source;
    }

    _listenForPlaybackEvents(generation);
    final selectedTrack = _selectedResolution(source);
    if (selectedTrack != null) {
      emit(state.copyWith(selectedNonDashTrack: selectedTrack));
    }
    final format = source.inlineDashManifest == null
        ? source.videoFormat.toString()
        : 'DASH supplied in memory';
    log.info('Playing $format source from ${Uri.parse(source.url).host}');
    var setupFailed = false;
    var setup = Future<void>.value();
    try {
      setup = videoController?.setupDataSource(source) ?? Future<void>.value();
      _controllerSetup = setup;
      _controllerSetupAttempt =
          (generation: generation, sourceIndex: sourceIndex);
      await Future.any([setup, cancelled]);
    } catch (error) {
      setupFailed = true;
      if (_isCurrentAttempt(generation, sourceIndex)) {
        _sourceBackendRetryable |= (error is PlatformException &&
                error.details is Map &&
                (error.details as Map)['backendRetryable'] == true) ||
            (videoController?.videoPlayerController?.value.backendRetryable ??
                false);
      }
    } finally {
      if (identical(_controllerSetup, setup)) {
        _controllerSetup = null;
        _controllerSetupAttempt = null;
      }
    }

    if (!_isCurrentAttempt(generation, sourceIndex)) return;
    if (setupFailed || _sourceFailurePending) {
      _sourceFailurePending = true;
      await _handleSourceFailure(generation, sourceIndex);
    } else {
      if (!_playbackOffline &&
          (source.videoFormat == BetterPlayerVideoFormat.dash ||
              source.videoFormat == BetterPlayerVideoFormat.hls) &&
          (_videoQuality ?? 0) > 0) {
        // Manifest track discovery runs independently of native setup. Apply a
        // resolution cap here so slow discovery cannot lose the saved choice.
        // Do not carry a previous video's width or bitrate into the new video.
        videoController?.setTrack(BetterPlayerAsmsTrack(
            null, 2147483647, _videoQuality, 2147483647, null, null, null));
      }
      final pendingSeek = _pendingSeek;
      if (seekAfterSetup || pendingSeek != null) {
        await seek(pendingSeek ?? _playbackStartAt);
      }
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
      try {
        if (_shouldPlay) {
          await videoController?.play();
        } else {
          await videoController?.pause();
        }
        if (_isCurrentAttempt(generation, sourceIndex) &&
            !_terminalErrorSent &&
            state.video != null) {
          player.reportBackendPlaybackReady(
              state.video!.videoId, state.video!.backendPlayback,
              playing: _shouldPlay);
          player.reportPlaybackRecoveryReady(state.video!,
              playing: _shouldPlay);
        }
      } catch (_) {
        if (_isCurrentAttempt(generation, sourceIndex)) {
          _emitTerminalPlaybackError();
        }
      }
    }
  }

  @override
  toggleDash() async {
    log.fine('toggle dash');
    final newState = state.copyWith();
    await player.saveProgress(position().inSeconds);
    await settings.toggleDash(!isUsingDash());
    emit(newState);
    playVideo(false);
  }

  @override
  switchVideo(Video video, {Duration? startAt}) {
    emit(state.copyWith(startAt: startAt, video: video, offlineVideo: null));
    playVideo(false, startAt: startAt);
  }

  @override
  togglePlaying() {
    if (videoController != null) {
      (_backendRecoveryPending ? _requestedPlaying : isPlaying())
          ? pause()
          : play();
      emit(state.copyWith());
    }
  }

  @override
  toggleControls(bool visible) {
    videoController?.setControlsEnabled(visible);
  }

  @override
  Future<void> playVideo(bool offline,
      {Duration? startAt,
      bool preservePlaybackIntent = false,
      bool recoveringPlayback = false}) async {
    if (player.state.isAudio) {
      return;
    }
    _endSpeedBoost?.call();
    dismissSubtitleFailure();
    _backendRecoveryPending = false;
    _recoveringInitializedPlayback = recoveringPlayback;
    _pendingSeek = null;
    _playbackOffline = offline;
    if (!preservePlaybackIntent) {
      _requestedPlaying = player.shouldStartPlayback;
    }
    _cancelSetup();
    _setupCancellation = Completer<void>();
    final generation = ++_playbackGeneration;
    _parentPlaybackGeneration = player.backendPlaybackGeneration;
    if (_controllerSetup != null) {
      _controllerSetup = null;
      _controllerSetupAttempt = null;
      disposeControllers();
    }
    _playbackSourceIndex = 0;
    _playbackInitialized = false;
    _terminalErrorSent = false;
    _sourceFailurePending = false;
    _failedSubtitle = null;
    var newState = state.copyWith(startAt: startAt, subtitleFailed: false);
    _playbackServer = null;
    _playbackVideoId = null;
    if (newState.video != null || newState.offlineVideo != null) {
      final idedVideo = offline ? newState.offlineVideo! : newState.video!;
      if (_qualityVideoId != idedVideo.videoId) {
        _qualityVideoId = idedVideo.videoId;
        _videoQuality = settings.state.rememberVideoQuality
            ? settings.state.lastVideoQuality
            : null;
      }
      _playbackPitchSemitones = player.pitchForVideo(idedVideo.videoId);
      _playbackSpeed = player.speedForVideo(idedVideo.videoId);
      newState = newState.copyWith(bufferPosition: Duration.zero);

      if (startAt == null) {
        final progress = db.getVideoProgress(idedVideo.videoId);
        if (progress > 0 && progress < 0.90) {
          startAt = Duration(
              seconds: ((newState.video?.lengthSeconds ??
                          newState.offlineVideo?.lengthSeconds ??
                          0) *
                      progress)
                  .floor());
        }
      }

      if (offline) {
        final videoPath = await newState.offlineVideo!.effectivePath;
        if (!_isCurrentAttempt(generation, 0)) return;

        _playbackSources = [
          BetterPlayerDataSource(
            Uri.tryParse(videoPath)?.scheme == 'content'
                ? BetterPlayerDataSourceType.network
                : BetterPlayerDataSourceType.file,
            videoPath,
            videoFormat: BetterPlayerVideoFormat.other,
            liveStream: false,
          )
        ];
      } else {
        final selectedServer = await db.getCurrentlySelectedServer();
        if (!_isCurrentAttempt(generation, 0) || player.state.isAudio) {
          return;
        }
        final playback = newState.video?.backendPlayback;
        final connection = playback ?? newState.video?.playbackConnection;
        if (connection != null && !connection.matches(selectedServer)) {
          // Cached queue entries may outlive credentials or proxy changes.
          // The parent refetches these; direct decoder admission fails closed.
          _playbackSources = const [];
          _emitTerminalPlaybackError();
          return;
        }
        final server = connection?.server ?? selectedServer;
        player.setRequestedBackend(newState.video!.videoId, playback);
        _playbackServer = server;
        _playbackVideoId = newState.video!.videoId;
        final sources = _buildPlaybackDataSources(
          newState.video!,
          server,
          preferDash: isUsingDash(),
          preferredQuality: _videoQuality,
          lastSubtitle: settings.state.rememberSubtitles
              ? settings.state.lastSubtitles
              : null,
        );
        if (sources.isEmpty) {
          _playbackSources = const [];
          _emitTerminalPlaybackError();
          return;
        }
        _playbackSources = sources;
        final selectedTrack = _selectedResolution(sources.first);
        if (selectedTrack != null) {
          newState = newState.copyWith(selectedNonDashTrack: selectedTrack);
        }
      }
      _playbackStartAt = startAt ?? Duration.zero;
      _waitingForInitialSeek = _playbackStartAt > Duration.zero;

      WakelockPlus.enable();

      final reusedController = videoController != null;
      if (!reusedController) {
        videoController = BetterPlayerController(BetterPlayerConfiguration(
            overlay: SubtitleFailureOverlay(
              player: this,
              autofocus: isTv,
              child: isTv
                  ? const TvPlayerControls()
                  : PlayerControls(mediaPlayerCubit: this),
            ),
            deviceOrientationsOnFullScreen: [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
              DeviceOrientation.portraitDown,
              DeviceOrientation.portraitUp
            ],
            deviceOrientationsAfterFullScreen: [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
              DeviceOrientation.portraitDown,
              DeviceOrientation.portraitUp
            ],
            handleLifecycle: false,
            // The app bounds the viewport; keep controls across letterboxing.
            expandToFill: false,
            startAt: startAt,
            // The cubit restores play/pause intent after each source is ready.
            autoPlay: false,
            allowedScreenSleep: false,
            fit: BoxFit.contain,
            subtitlesConfiguration: BetterPlayerSubtitlesConfiguration(
                backgroundColor: settings.state.subtitlesBackground
                    ? Colors.black.withValues(alpha: 0.8)
                    : Colors.transparent,
                fontSize: settings.state.subtitleSize,
                outlineEnabled: true,
                outlineColor: Colors.black,
                outlineSize: 1),
            controlsConfiguration:
                const BetterPlayerControlsConfiguration(showControls: false)));
        videoController!.setBetterPlayerGlobalKey(newState.key);
      }
      if (!_isCurrentAttempt(generation, 0)) return;
      emit(newState);
      await _setupPlaybackSource(seekAfterSetup: reusedController);
    }

    if (_isCurrentAttempt(generation, _playbackSourceIndex) &&
        !_terminalErrorSent) {
      super.playVideo(offline);
    }
  }

  @override
  void switchToOfflineVideo(DownloadedVideo v) {
    emit(state.copyWith(video: null, offlineVideo: v));
    playVideo(true, startAt: player.state.startAt);
  }

  @override
  bool isPlaying() {
    return videoController?.isPlaying() ?? false;
  }

  @override
  void handleCommand(MediaCommand command) {
    if (_terminalErrorSent && command.type == MediaCommandType.pause) {
      // A queued parent Pause may arrive after its Retry failure was shown.
      // Stop the decoder without replacing that actionable error with Ready.
      pause();
      return;
    }
    if (command.type == MediaCommandType.play &&
        (_terminalErrorSent ||
            !_playbackInitialized ||
            _backendRecoveryPending)) {
      // The base handler publishes Play immediately. A failed or loading
      // source must first complete admission before claiming playback.
      play();
      return;
    }
    super.handleCommand(command);
  }

  Future<void> _retryAfterFailure() async {
    final generation = _playbackGeneration;
    if (isClosed ||
        player.state.isAudio ||
        _parentPlaybackGeneration != player.backendPlaybackGeneration ||
        _manualRetryGeneration == generation) {
      return;
    }
    _manualRetryGeneration = generation;
    final queueId = player.state.currentQueueId;
    try {
      final retry = player.retryCurrentVideo();
      final parentGeneration = player.backendPlaybackGeneration;
      await retry;
      if (!isClosed &&
          generation == _playbackGeneration &&
          parentGeneration == player.backendPlaybackGeneration &&
          queueId == player.state.currentQueueId &&
          player.state.mediaEvent.state == MediaState.error) {
        // A failed metadata retry keeps this decoder terminal. Re-admit only
        // a later explicit Retry command for that same retained queue entry.
        _parentPlaybackGeneration = parentGeneration;
      }
    } catch (_) {
      // Keep the existing actionable error without exposing request details.
    } finally {
      if (_manualRetryGeneration == generation) _manualRetryGeneration = null;
    }
  }

  @override
  void pause() {
    _endSpeedBoost?.call();
    _requestedPlaying = false;
    videoController?.pause();
  }

  @override
  void play() {
    if (_terminalErrorSent) {
      unawaited(_retryAfterFailure());
      return;
    }
    _requestedPlaying = true;
    if (_playbackInitialized && !_backendRecoveryPending && _shouldPlay) {
      videoController?.play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final controller = videoController;
    final generation = _playbackGeneration;
    final revision = ++_seekRevision;
    _pendingSeek = position;
    if (_backendRecoveryPending ||
        controller?.videoPlayerController?.value.duration == null) {
      // TV remote input can arrive before native source initialization. Apply
      // only the latest position once that source is ready.
      return;
    }
    await controller?.seekTo(position);
    if (isClosed ||
        generation != _playbackGeneration ||
        revision != _seekRevision ||
        !identical(videoController, controller) ||
        _terminalErrorSent ||
        _backendRecoveryPending) {
      return;
    }
    _pendingSeek = null;
    // Native seek completion may restore the pre-seek playing value. A user
    // pause/play made while the seek was pending must take precedence.
    if (controller?.isPlaying() != _shouldPlay) {
      if (_shouldPlay) {
        await controller?.play();
      } else {
        await controller?.pause();
      }
    }
  }

  @override
  Duration? bufferedPosition() {
    return state.bufferPosition;
  }

  @override
  Duration position() {
    return videoController?.videoPlayerController?.value.position ??
        Duration.zero;
  }

  String _videoTrackToString(BetterPlayerAsmsTrack? track) {
    return '${track?.height}p - ${prettyBytes((track?.bitrate ?? 0).toDouble(), bits: true)}/s';
  }

  String _audioTrackToString(BetterPlayerAsmsAudioTrack? track) {
    return '${track?.label} ${track?.language != null ? '- ${track?.language}' : ''}';
  }

  String _subtitleToString(BetterPlayerSubtitlesSource? source) {
    return '${source?.name}';
  }

  @override
  List<String> getVideoTracks() {
    if (state.video == null) return [];
    if (videoController?.betterPlayerAsmsTracks.isNotEmpty ?? false) {
      return videoController?.betterPlayerAsmsTracks
              .map(_videoTrackToString)
              .toList() ??
          [];
    }
    for (final source in _playbackSources) {
      if (source.resolutions != null) {
        return source.resolutions!.keys.toList().reversed.toList();
      }
    }
    return [];
  }

  @override
  int selectedVideoTrack() {
    if (state.video == null) return -1;
    final tracks = getVideoTracks();
    if (videoController?.betterPlayerAsmsTracks.isNotEmpty ?? false) {
      final track = _videoTrackToString(videoController?.betterPlayerAsmsTrack);
      log.fine("Current track: $track");
      final exact = tracks.indexOf(track);
      if (exact >= 0) return exact;
      return preferredVideoQualityIndex(
              videoController!.betterPlayerAsmsTracks
                  .map((t) => t.height)
                  .toList(),
              videoController?.betterPlayerAsmsTrack?.height) ??
          -1;
    }
    return tracks.indexOf(state.selectedNonDashTrack);
  }

  @override
  List<String> getAudioTracks() {
    if (state.video != null) {
      if (videoController?.betterPlayerAsmsAudioTracks?.isNotEmpty ?? false) {
        return videoController?.betterPlayerAsmsAudioTracks
                ?.map(_audioTrackToString)
                .toList() ??
            [];
      }
    }
    // for offline video we don't offer video track selection
    return [];
  }

  @override
  int selectedAudioTrack() {
    if (state.video != null) {
      if (settings.state.useDash) {
        var tracks = getAudioTracks();
        var track =
            _audioTrackToString(videoController?.betterPlayerAsmsAudioTrack);
        log.fine("Current audio track: $track");
        return tracks.indexOf(track);
      }
    }
    // for offline video we don't offer video track selection
    return -1;
  }

  @override
  List<String> getSubtitles() {
    return state.video != null
        ? videoController?.betterPlayerSubtitlesSourceList
                .map(_subtitleToString)
                .toList() ??
            []
        : [];
  }

  @override
  int selectedSubtitle() {
    var tracks = getSubtitles();
    var track = _subtitleToString(videoController?.betterPlayerSubtitlesSource);
    log.fine("Current subtitle track: $track");
    return tracks.indexOf(track);
  }

  @override
  selectAudioTrack(int index) {
    var betterPlayerAsmsTrack =
        videoController?.betterPlayerAsmsAudioTracks?[index];
    log.fine("Selected audio track, ${betterPlayerAsmsTrack?.label}");
    if (betterPlayerAsmsTrack != null) {
      videoController?.setAudioTrack(betterPlayerAsmsTrack);
    }
  }

  @override
  selectSubtitle(int index) {
    final tracks = videoController?.betterPlayerSubtitlesSourceList;
    if (tracks == null || index < 0 || index >= tracks.length) return;
    dismissSubtitleFailure();
    videoController?.setupSubtitleSource(tracks[index]);
  }

  void dismissSubtitleFailure() {
    _failedSubtitle = null;
    if (!isClosed) emit(state.copyWith(subtitleFailed: false));
  }

  Future<void> retrySubtitles() async {
    final source = _failedSubtitle;
    dismissSubtitleFailure();
    if (source != null) await videoController?.setupSubtitleSource(source);
  }

  @override
  Future<void> selectVideoTrack(int index) async {
    final tracks = getVideoTracks();
    if (index < 0 || index >= tracks.length) return;
    if (videoController?.betterPlayerAsmsTracks.isNotEmpty ?? false) {
      final betterPlayerAsmsTrack =
          videoController?.betterPlayerAsmsTracks[index];
      if (betterPlayerAsmsTrack != null) {
        videoController?.setTrack(betterPlayerAsmsTrack);
        await _rememberVideoQuality(betterPlayerAsmsTrack.height);
      }
      return;
    }
    final track = tracks[index];
    final selectedUrl =
        videoController?.betterPlayerDataSource?.resolutions?[track];
    final sourceIndex = _playbackSources.indexWhere((source) =>
        selectedUrl != null
            ? source.url == selectedUrl
            : _selectedResolution(source) == track);
    if (sourceIndex < 0) return;
    // river_player's setResolution snapshots play intent before awaiting the
    // new source. Use our setup path so a later pause or focus loss wins.
    _playbackStartAt =
        _pendingSeek ?? (_playbackInitialized ? position() : _playbackStartAt);
    _waitingForInitialSeek = _playbackStartAt > Duration.zero;
    _playbackGeneration++;
    _playbackSourceIndex = sourceIndex;
    _playbackInitialized = false;
    _terminalErrorSent = false;
    _sourceFailurePending = false;
    _backendRecoveryPending = false;
    WakelockPlus.enable();
    unawaited(_setupPlaybackSource());
    await _rememberVideoQuality(videoQualityHeight(track));
  }

  Future<void> _rememberVideoQuality(int? height) async {
    if (height == null || height < 0 || height > 16384) return;
    _videoQuality = height;
    if (settings.state.rememberVideoQuality) {
      await settings.setLastVideoQuality(height);
    }
  }

  @override
  bool isMuted() {
    return videoController?.videoPlayerController?.value.volume == 0;
  }

  @override
  void toggleVolume(bool soundOn) {
    videoController?.setVolume(soundOn ? 1 : 0);
  }

  /// Plays at 2× until the returned callback is called or playback changes.
  VoidCallback? startSpeedBoost({VoidCallback? onEnded}) {
    final decoder = videoController?.videoPlayerController;
    if (decoder == null ||
        !_playbackInitialized ||
        !isPlaying() ||
        _endSpeedBoost != null ||
        _terminalErrorSent ||
        _backendRecoveryPending ||
        !_isCurrentAttempt(_playbackGeneration, _playbackSourceIndex)) {
      return null;
    }

    Future<void> apply(double? speed, {VoidCallback? onRejected}) async {
      try {
        await decoder.setTemporarySpeed(speed);
      } on PlatformException catch (error) {
        log.fine('Could not apply temporary playback speed (${error.code})');
        onRejected?.call();
      }
    }

    void end() {
      if (!identical(_endSpeedBoost, end)) return;
      _endSpeedBoost = null;
      unawaited(apply(null));
      onEnded?.call();
    }

    _endSpeedBoost = end;
    unawaited(apply(2, onRejected: end));
    return end;
  }

  @override
  void setSpeed(double d) {
    super.setSpeed(d);
    _playbackSpeed = d;
    settings.setLastSpeed(d);
    if (videoController?.videoPlayerController != null) {
      videoController?.setSpeed(d);
    }
  }

  @override
  void setPitchSemitones(int semitones) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _playbackPitchSemitones = clampPitchSemitones(semitones);
    // A loading/recovering player can exist before its native controller does.
    // Keep the choice now; initialization applies it once the decoder exists.
    if (videoController?.videoPlayerController != null) {
      videoController
          ?.setPitch(pitchFactorForSemitones(_playbackPitchSemitones));
    }
    player.setEvent(MediaEvent<int>(
        state: MediaState.ready,
        type: MediaEventType.pitchChanged,
        value: _playbackPitchSemitones));
  }

  @override
  int getPitchSemitones() => _playbackPitchSemitones;

  @override
  double getSpeed() {
    return videoController?.videoPlayerController?.value.speed ?? 1;
  }

  @override
  bool hasDashToggle() {
    return state.video != null;
  }

  @override
  bool isUsingDash() {
    return settings.state.useDash;
  }

  @override
  Duration duration() {
    return videoController?.videoPlayerController?.value.duration ??
        const Duration(milliseconds: 1);
  }

  @override
  double getAspectRatio() {
    final size = videoController?.videoPlayerController?.value.size;
    if (size == null || size.isEmpty) return 16 / 9;
    final ratio = size.aspectRatio;
    return ratio.isFinite && ratio > 0 ? ratio : 16 / 9;
  }

  @override
  void onEnterFullScreen() {
    videoController?.setOverriddenAspectRatio(getAspectRatio());
  }

  @override
  void onExitFullScreen() {
    videoController?.setOverriddenAspectRatio(16 / 9);
  }
}

@freezed
sealed class VideoPlayerState extends MediaPlayerState with _$VideoPlayerState {
  const factory VideoPlayerState(
      {required ColorScheme colors,
      required Color overFlowTextColor,
      required GlobalKey key,
      Duration? startAt,
      @Default("") String selectedNonDashTrack,
      @Default(Duration.zero) Duration? bufferPosition,
      @Default(false) bool subtitleFailed,
      Video? video,
      DownloadedVideo? offlineVideo,
      bool? playNow,
      bool? disableControls}) = _VideoPlayerState;

  const VideoPlayerState._();
}
