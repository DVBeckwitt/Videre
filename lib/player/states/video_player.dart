import 'dart:async';

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
import '../../settings/models/db/server.dart';
import '../../utils/pretty_bytes.dart';
import '../../videos/models/video.dart';
import '../models/backend_playback.dart';
import '../models/playback_pitch.dart';
import '../views/components/player_controls.dart';
import '../views/tv/components/player_controls.dart';
import 'interfaces/media_player.dart';

part 'video_player.freezed.dart';

final log = Logger('VideoPlayer');
const _maxPlaybackSources = 10;

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

String? _mediaUrl(String? value) {
  final url = value?.trim();
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.toString();
}

String? _validMediaUrl(String? value, Server server) {
  final url = _mediaUrl(value);
  final uri = url == null ? null : Uri.parse(url);
  final serverUri = Uri.tryParse(server.url);
  if (uri == null || serverUri == null) return null;
  if (_sameOrigin(uri, serverUri)) return uri.toString();

  final host = uri.host.toLowerCase();
  final trustedVideoHost = host == 'googlevideo.com' ||
      host.endsWith('.googlevideo.com') ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
  return uri.scheme == 'https' && uri.port == 443 && trustedVideoHost
      ? uri.toString()
      : null;
}

Map<String, String>? _mediaHeaders(Server server, String url) {
  final headers = server.headersForUrl(url);
  return headers == null || headers.isEmpty ? null : headers;
}

Map<String, String>? _compatibleResolutions(
  Server server,
  Map<String, String>? resolutions,
  Map<String, String>? sourceHeaders,
) {
  if (resolutions == null) return null;

  final compatible = Map.fromEntries(
    resolutions.entries.where((entry) {
      final resolutionHeaders = _mediaHeaders(server, entry.value);
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

String _proxyUrl(String url, Server server, bool useProxy,
    {bool adaptive = false}) {
  if (!useProxy) return url;
  if (adaptive) {
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {
      ...uri.queryParametersAll,
      'local': ['true']
    }).toString();
  }
  final source = Uri.parse(url);
  final host = source.host.toLowerCase();
  if (host != 'googlevideo.com' && !host.endsWith('.googlevideo.com')) {
    return url;
  }
  final target = Uri.tryParse(server.url);
  if (target == null ||
      (target.scheme != 'http' && target.scheme != 'https') ||
      target.host.isEmpty) {
    return url;
  }
  final prefix = target.path.endsWith('/')
      ? target.path.substring(0, target.path.length - 1)
      : target.path;
  return Uri(
    scheme: target.scheme,
    userInfo: target.userInfo,
    host: target.host,
    port: target.hasPort ? target.port : null,
    path: '$prefix${source.path}',
    query: source.hasQuery ? source.query : null,
    fragment: source.hasFragment ? source.fragment : null,
  ).toString();
}

List<BetterPlayerDataSource> _buildPlaybackDataSources(
  Video video,
  Server server, {
  required bool preferDash,
  required bool useProxy,
  String? lastSubtitle,
}) {
  final sources = <BetterPlayerDataSource>[];
  final seen = <String>{};
  late final subtitles = video.captions
      .map((caption) => BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.network,
            urls: ['${server.url}${caption.url}'],
            name: caption.label,
            selectedByDefault: caption.label == lastSubtitle,
          ))
      .toList();

  void add(String url, BetterPlayerVideoFormat format,
      {Map<String, String>? resolutions}) {
    if (sources.length >= _maxPlaybackSources || !seen.add(_sourceKey(url))) {
      return;
    }
    final headers = _mediaHeaders(server, url);
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
    final url = _mediaUrl(value);
    return url == null
        ? null
        : _validMediaUrl(
            _proxyUrl(url, server, useProxy, adaptive: true), server);
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
    final url = _mediaUrl(stream.url);
    if (url == null) continue;
    final safeUrl = _validMediaUrl(_proxyUrl(url, server, useProxy), server);
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
  bool _sourceFailurePending = false;
  int _playbackGeneration = 0;
  int _parentPlaybackGeneration = 0;
  Future<void>? _controllerSetup;
  ({int generation, int sourceIndex})? _controllerSetupAttempt;
  Completer<void> _setupCancellation = Completer<void>();
  Function(BetterPlayerEvent)? _videoListener;
  Duration _playbackStartAt = Duration.zero;
  Duration? _pendingSeek;
  bool _waitingForInitialSeek = false;
  bool _sourceBackendRetryable = false;
  bool _backendRecoveryPending = false;
  bool _playbackOffline = false;
  bool _requestedPlaying = true;
  double _playbackSpeed = 1;
  int _playbackPitchSemitones = 0;

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
    _playbackGeneration++;
    _playbackSources = const [];
    _playbackServer = null;
    _playbackVideoId = null;
    _backendRecoveryPending = false;
    _requestedPlaying = false;
    _cancelSetup();
    _controllerSetup = null;
    _controllerSetupAttempt = null;
    disposeControllers();
  }

  @override
  void disposeControllers() {
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
        break;
      case BetterPlayerEventType.changedResolution:
        break;
      default:
        return;
    }

    player.setEvent(MediaEvent(state: mediaState, type: type));
  }

  void onVideoListener(BetterPlayerEvent event) {
    if (isClosed || _backendRecoveryPending || _terminalErrorSent) return;
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
      if (_playbackInitialized &&
          (_playbackOffline ||
              !retryable ||
              state.video?.backendPlayback == null)) {
        _emitTerminalPlaybackError();
      } else if (_playbackInitialized) {
        final generation = _playbackGeneration;
        final sourceIndex = _playbackSourceIndex;
        unawaited(_recoverBackend(generation, sourceIndex).then((recovered) {
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
      }
      if (event.betterPlayerEventType == BetterPlayerEventType.progress) {
        player.reportBackendPlaybackProgress(
            video.videoId, video.backendPlayback, nativeValue.position,
            playing: nativeValue.isPlaying && !nativeValue.isBuffering);
      } else if (event.betterPlayerEventType == BetterPlayerEventType.seekTo) {
        player.reportBackendPlaybackProgress(
            video.videoId, video.backendPlayback, nativeValue.position,
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
        settings.setLastSubtitle(
            videoController?.betterPlayerSubtitlesSource?.name ?? '');
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
    videoController?.pause();
    WakelockPlus.disable();
    player.setEvent(const MediaEvent(state: MediaState.error));
    final generation = _playbackGeneration;
    void pauseAfterSetup() {
      if (!isClosed &&
          generation == _playbackGeneration &&
          _terminalErrorSent) {
        videoController?.pause();
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
      if (!await _recoverBackend(generation, sourceIndex) &&
          _isCurrentAttempt(generation, sourceIndex)) {
        _emitTerminalPlaybackError();
      }
      return;
    }
    _playbackSourceIndex++;
    await _setupPlaybackSource();
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
        server != null &&
        videoId != null) {
      String? resolved;
      try {
        resolved = await Future.any([
          service.dashManifestResolver.resolve(source.url, videoId, server,
              throwRetryable: state.video?.backendPlayback != null),
          cancelled.then<String?>((_) => null),
        ]);
      } on BackendPlaybackFailure {
        if (!_isCurrentAttempt(generation, sourceIndex)) return;
        _sourceBackendRetryable = true;
      }
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
      if (resolved == null) {
        _sourceFailurePending = true;
        await _handleSourceFailure(generation, sourceIndex);
        return;
      }
      source = source.copyWith(url: resolved);
      _playbackSources[sourceIndex] = source;
    }

    _listenForPlaybackEvents(generation);
    final selectedTrack = _selectedResolution(source);
    if (selectedTrack != null) {
      emit(state.copyWith(selectedNonDashTrack: selectedTrack));
    }
    log.info(
        'Playing ${source.videoFormat} source from ${Uri.parse(source.url).host}');
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
      final pendingSeek = _pendingSeek;
      if (seekAfterSetup || pendingSeek != null) {
        await seek(pendingSeek ?? _playbackStartAt);
      }
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
      try {
        if (_requestedPlaying) {
          await videoController?.play();
        } else {
          await videoController?.pause();
        }
        if (_isCurrentAttempt(generation, sourceIndex) &&
            !_terminalErrorSent &&
            state.video != null) {
          player.reportBackendPlaybackReady(
              state.video!.videoId, state.video!.backendPlayback,
              playing: _requestedPlaying);
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
      {Duration? startAt, bool preservePlaybackIntent = false}) async {
    if (player.state.isAudio) {
      return;
    }
    _backendRecoveryPending = false;
    _pendingSeek = null;
    _playbackOffline = offline;
    if (!preservePlaybackIntent) {
      _requestedPlaying =
          !offline && state.video?.backendPlayback?.manualSelection == true
              ? player.requestedPlaying
              : true;
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
    var newState = state.copyWith(startAt: startAt);
    _playbackServer = null;
    _playbackVideoId = null;
    if (newState.video != null || newState.offlineVideo != null) {
      final idedVideo = offline ? newState.offlineVideo! : newState.video!;
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
            BetterPlayerDataSourceType.file,
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
        if (playback != null && !playback.matches(selectedServer)) {
          // Cached queue entries may outlive credentials or proxy changes.
          // The parent refetches these; direct decoder admission fails closed.
          _playbackSources = const [];
          _emitTerminalPlaybackError();
          return;
        }
        final server = playback?.server ?? selectedServer;
        player.setRequestedBackend(newState.video!.videoId, playback);
        _playbackServer = server;
        _playbackVideoId = newState.video!.videoId;
        final sources = _buildPlaybackDataSources(
          newState.video!,
          server,
          preferDash: isUsingDash(),
          useProxy: service.useProxy(),
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

      final fillVideo = settings.state.fillFullscreen;

      final reusedController = videoController != null;
      if (!reusedController) {
        videoController = BetterPlayerController(BetterPlayerConfiguration(
            overlay: isTv
                ? const TvPlayerControls()
                : PlayerControls(mediaPlayerCubit: this),
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
            startAt: startAt,
            // The cubit restores play/pause intent after each source is ready.
            autoPlay: false,
            allowedScreenSleep: false,
            fit: fillVideo ? BoxFit.cover : BoxFit.contain,
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
    playVideo(true);
  }

  @override
  bool isPlaying() {
    return videoController?.isPlaying() ?? false;
  }

  @override
  void pause() {
    _requestedPlaying = false;
    videoController?.pause();
  }

  @override
  void play() {
    _requestedPlaying = true;
    if (!_backendRecoveryPending) videoController?.play();
  }

  @override
  Future<void> seek(Duration position) async {
    final controller = videoController;
    final generation = _playbackGeneration;
    if (_backendRecoveryPending ||
        controller?.videoPlayerController?.value.duration == null) {
      // TV remote input can arrive before native source initialization. Apply
      // only the latest position once that source is ready.
      _pendingSeek = position;
      return;
    }
    _pendingSeek = null;
    await controller?.seekTo(position);
    if (isClosed ||
        generation != _playbackGeneration ||
        !identical(videoController, controller) ||
        _terminalErrorSent ||
        _backendRecoveryPending) {
      return;
    }
    // Native seek completion may restore the pre-seek playing value. A user
    // pause/play made while the seek was pending must take precedence.
    if (controller?.isPlaying() != _requestedPlaying) {
      if (_requestedPlaying) {
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
      return tracks.indexOf(track);
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
    var sub = videoController?.betterPlayerSubtitlesSourceList[index];
    if (sub != null) {
      videoController?.setupSubtitleSource(sub, sourceInitialize: true);
    }
  }

  @override
  selectVideoTrack(int index) {
    final tracks = getVideoTracks();
    if (index < 0 || index >= tracks.length) return;
    if (videoController?.betterPlayerAsmsTracks.isNotEmpty ?? false) {
      final betterPlayerAsmsTrack =
          videoController?.betterPlayerAsmsTracks[index];
      if (betterPlayerAsmsTrack != null) {
        videoController?.setTrack(betterPlayerAsmsTrack);
      }
      return;
    }
    final track = tracks[index];
    final url = videoController?.betterPlayerDataSource?.resolutions?[track];
    if (url != null) {
      videoController?.setResolution(url);
      emit(state.copyWith(selectedNonDashTrack: track));
      return;
    }
    final sourceIndex = _playbackSources
        .indexWhere((source) => _selectedResolution(source) == track);
    if (sourceIndex < 0) return;
    final wasPlaying = isPlaying();
    final generation = _playbackGeneration;
    _playbackStartAt = position();
    _playbackSourceIndex = sourceIndex;
    _playbackInitialized = false;
    _terminalErrorSent = false;
    _sourceFailurePending = false;
    WakelockPlus.enable();
    _setupPlaybackSource().then((_) {
      if (!wasPlaying && !isClosed && generation == _playbackGeneration) {
        videoController?.pause();
      }
    });
  }

  @override
  bool isMuted() {
    return videoController?.videoPlayerController?.value.volume == 0;
  }

  @override
  void toggleVolume(bool soundOn) {
    videoController?.setVolume(soundOn ? 1 : 0);
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
    double width =
        videoController?.videoPlayerController?.value.size?.width ?? 16;
    double height =
        videoController?.videoPlayerController?.value.size?.height ?? 9;
    return width / height;
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
      Video? video,
      DownloadedVideo? offlineVideo,
      bool? playNow,
      bool? disableControls}) = _VideoPlayerState;

  const VideoPlayerState._();
}
