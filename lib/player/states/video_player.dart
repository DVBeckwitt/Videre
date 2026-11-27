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
import '../../downloads/services/download_playback_source.dart';
import '../../main.dart';
import '../../network/media_companion.dart';
import '../../network/nerdvpn_access.dart';
import '../../network/network_proxy.dart';
import '../../network/tor_browser.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/pretty_bytes.dart';
import '../../videos/models/video.dart';
import '../adaptive_dash_manifest.dart';
import '../media_source.dart';
import '../models/backend_playback.dart';
import '../models/media_command.dart';
import '../models/playback_pitch.dart';
import '../models/playback_cache_identity.dart';
import '../models/video_quality.dart';
import '../models/watch_audio_track.dart';
import '../services/watch_local_subtitles.dart';
import '../views/components/player_controls.dart';
import '../views/components/subtitle_failure_notice.dart';
import '../views/tv/components/player_controls.dart';
import 'interfaces/media_player.dart';

part 'video_player.freezed.dart';

final log = Logger('VideoPlayer');
const _maxPlaybackSources = 10;

typedef WatchSubtitleTimingTarget = ({
  String videoId,
  int generation,
  String profileId,
  int sessionRevision,
});

String _subtitleTimingKey(String videoId) => 'watch-subtitle-timing-$videoId';

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
  required bool preferProgressiveStartup,
  int? preferredQuality,
  String? preferredAudioTrack,
  String? lastSubtitle,
  void Function()? onBlockedMediaOrigin,
}) {
  final sources = <BetterPlayerDataSource>[];
  final mediaCompanions =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? mediaCompanionContext(server)
          : null;
  final cacheSession =
      '${DateTime.now().microsecondsSinceEpoch}:${identityHashCode(video)}';
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
      mediaCompanions: mediaCompanions,
      trackManifestLoader: mediaCompanions == null
          ? null
          : (url) =>
              service.dashManifestResolver.loadTrackManifest(url, server),
      playbackCache: playbackCacheIdentity(
          video: video,
          server: server,
          sourceUrl: url,
          mediaCompanions: mediaCompanions != null,
          sessionId: cacheSession),
      useAsmsSubtitles: false,
    ));
  }

  String? admit(String? value, {bool adaptive = false}) =>
      proxiedPlaybackMediaUrl(value, server,
          adaptive: adaptive, onBlockedMediaOrigin: onBlockedMediaOrigin);
  final hls = admit(video.hlsUrl, adaptive: true);
  if (hls != null) {
    add(hls, BetterPlayerVideoFormat.hls);
  }

  final dash = admit(video.dashUrl, adaptive: true);
  void addDash() {
    if (dash != null) {
      add(dash, BetterPlayerVideoFormat.dash);
    }
  }

  final ordinaryStreams = <({String resolution, String url, bool isVideo})>[];
  final matchingStreams = <({String resolution, String url, bool isVideo})>[];
  final streamUrls = <String>{};
  for (final stream in (video.formatStreams ?? []).reversed) {
    if (stream.isLegacyHd720) continue;
    final isVideo = stream.type.toLowerCase().startsWith('video/');
    final mayMatch = isVideo &&
        preferredAudioTrack != null &&
        watchAudioTrackId(stream.audioTrack) == preferredAudioTrack;
    if (ordinaryStreams.length == _maxPlaybackSources &&
        (!mayMatch || matchingStreams.length == _maxPlaybackSources)) {
      continue;
    }
    final safeUrl = admit(stream.url);
    if (safeUrl == null) continue;
    final key = _sourceKey(safeUrl);
    if (streamUrls.contains(key)) continue;
    final matches = mayMatch &&
        watchAudioTrackIdForProgressiveUrl(video, server, safeUrl) ==
            preferredAudioTrack;
    final target = matches ? matchingStreams : ordinaryStreams;
    if (target.length == _maxPlaybackSources) continue;
    streamUrls.add(key);
    final resolution = _streamLabel([
      stream.resolution,
      stream.qualityLabel,
      stream.quality,
      stream.itag,
    ]);
    target.add((resolution: resolution, url: safeUrl, isVideo: isVideo));
    if (preferredAudioTrack == null && target.length == _maxPlaybackSources) {
      break;
    }
  }
  final streams = [...matchingStreams, ...ordinaryStreams];

  // NerdVPN's signed DASH route adds a watch request and separate audio/video
  // buffering. Try one suitable combined stream, then keep DASH next in line.
  var selectedStartupStream = preferDash &&
          preferProgressiveStartup &&
          hls == null &&
          dash != null &&
          video.liveNow != true &&
          (video.lengthSeconds ?? 0) > 0
      ? streams.where((stream) {
          final height = videoQualityHeight(stream.resolution);
          return stream.isVideo &&
              height != null &&
              height > 0 &&
              (preferredQuality == null || height == preferredQuality) &&
              _sourceKey(stream.url) != _sourceKey(dash);
        }).firstOrNull
      : null;
  if (selectedStartupStream != null &&
      !matchingStreams.contains(selectedStartupStream)) {
    final matchingStartup = matchingStreams
        .where((stream) => _sourceKey(stream.url) != _sourceKey(dash!))
        .toList();
    final index = preferredVideoQualityIndex(
        matchingStartup.map((s) => videoQualityHeight(s.resolution)).toList(),
        preferredQuality);
    if (index != null) selectedStartupStream = matchingStartup[index];
  }
  final startupStream = selectedStartupStream;

  void addProgressive() {
    final reservedDash = startupStream == null ? 0 : 1;
    final accepted = streams
        .where((stream) => !seen.contains(_sourceKey(stream.url)))
        .take(_maxPlaybackSources - sources.length - reservedDash)
        .toList();
    if (startupStream != null && !accepted.contains(startupStream)) {
      accepted.removeLast();
      accepted.add(startupStream);
    }
    final resolutions = <String, String>{};
    for (final stream in accepted) {
      resolutions.putIfAbsent(stream.resolution, () => stream.url);
    }
    // Change playback priority without reordering the quality menu.
    final matching = accepted.where(matchingStreams.contains).toList();
    final qualityChoices = matching.isEmpty ? accepted : matching;
    final qualityIndex = preferredVideoQualityIndex(
        qualityChoices.map((s) => videoQualityHeight(s.resolution)).toList(),
        preferredQuality);
    final preferred = startupStream != null
        ? accepted.indexOf(startupStream)
        : (qualityIndex == null
            ? 0
            : accepted.indexOf(qualityChoices[qualityIndex]));
    if (preferred > 0) {
      accepted.insert(0, accepted.removeAt(preferred));
    }
    for (final (index, stream) in accepted.indexed) {
      final sourceResolutions = resolutions[stream.resolution] == stream.url
          ? resolutions
          : {...resolutions, stream.resolution: stream.url};
      add(stream.url, BetterPlayerVideoFormat.other,
          resolutions: sourceResolutions);
      if (index == 0 && startupStream != null) addDash();
    }
  }

  if (preferDash && startupStream == null) addDash();
  addProgressive();
  if (!preferDash) addDash();
  return sources;
}

typedef _WatchSubtitlePlayback = ({
  WatchLocalSubtitleOwner owner,
  int occurrence,
});

class _WatchLocalSubtitleSource extends BetterPlayerSubtitlesSource {
  _WatchLocalSubtitleSource(
    String name,
    Future<String> Function() load, {
    required bool selectedByDefault,
  }) : super(
          type: BetterPlayerSubtitlesSourceType.memory,
          name: name,
          contentLoader: load,
          selectedByDefault: selectedByDefault,
        );
}

class VideoPlayerCubit extends MediaPlayerCubit<VideoPlayerState> {
  BetterPlayerController? videoController;
  final SettingsCubit settings;
  List<BetterPlayerDataSource> _playbackSources = const [];
  bool _downloadReuseFailed = false;
  ({BackendPlayback route, String? queueId})? _playbackOwner;
  Server? get _playbackServer => _playbackOwner?.route.server;
  bool Function()? _sourceContinuationIsCurrent;
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
  StreamSubscription<Duration>? _nativePositionSubscription;
  Duration _playbackStartAt = Duration.zero;
  Duration? _pendingSeek;
  int _seekRevision = 0;
  bool _waitingForInitialSeek = false;
  bool _sourceBackendRetryable = false;
  bool _sourceMediaOriginBlocked = false;
  bool _backendRecoveryPending = false;
  bool _recoveringInitializedPlayback = false;
  bool _playbackOffline = false;
  bool _requestedPlaying = true;
  double _playbackSpeed = 1;
  VoidCallback? _endSpeedBoost;
  int _playbackPitchSemitones = 0;
  String? _qualityVideoId;
  int? _videoQuality;
  Video? _qualityMetadata;
  Future<bool>? _qualityPreparation;
  Map<String, BetterPlayerDataSource> _onlineQualitySources = const {};
  BetterPlayerDataSource? _qualityDashSource;
  BetterPlayerDataSource? _savedQualitySource;
  VoidCallback? _qualityFailureFeedback;
  bool _qualityRollbackRefusedNetwork = false;
  BetterPlayerSubtitlesSource? _failedSubtitle;
  final _localSubtitles = const WatchLocalSubtitles();
  _WatchSubtitlePlayback? _localSubtitlePlayback;
  _WatchSubtitlePlayback? _mountedLocalSubtitlePlayback;
  _WatchLocalSubtitleSource? _localSubtitleSource;
  bool _localSubtitleSelected = false;
  bool _changingLocalSubtitle = false;
  bool _clearingLocalSubtitle = false;
  late final StreamSubscription<double> _subtitleSizeSubscription;
  WatchSubtitleTimingTarget? _subtitleTimingTarget;
  Future<void> _subtitleTimingUpdate = Future<void>.value();

  static const subtitleTimingStep = Duration(milliseconds: 100);
  static const subtitleTimingLimit = Duration(seconds: 10);

  bool get _shouldPlay => _requestedPlaying && player.shouldStartPlayback;

  bool get isOnionPlayback =>
      _playbackServer != null &&
      TorBrowser.isOnionAddress(Uri.parse(_playbackServer!.url));

  bool get _canStartNerdVpnProgressive {
    final server = _playbackServer;
    return !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        !isTv &&
        !settings.state.hasDashPreference &&
        server != null &&
        NerdVpnAccess.supports(server) &&
        !isNerdVpnOnionUrl(server.url);
  }

  VideoPlayerCubit(super.initialState, super.player, this.settings) {
    _subtitleSizeSubscription = settings.stream
        .map((state) => state.subtitleSize)
        .distinct()
        .listen((size) => videoController?.setSubtitleFontSize(size));
    onInit();
  }

  void onInit() {
    log.fine("Ready, playing video");
    playVideo(state.offlineVideo != null, startAt: state.startAt);
  }

  @override
  Future<void> close() async {
    await _subtitleSizeSubscription.cancel();
    await stopForProxyChange();
    await super.close();
  }

  @override
  Future<void> stopForProxyChange() async {
    _localSubtitlePlayback = null;
    _localSubtitleSource = null;
    _localSubtitleSelected = false;
    dismissSubtitleFailure();
    _playbackGeneration++;
    _subtitleTimingTarget = null;
    _clearQualityPreparation();
    _playbackSources = const [];
    _playbackOwner = null;
    _sourceContinuationIsCurrent = null;
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
    _mountedLocalSubtitlePlayback = null;
    unawaited(_nativePositionSubscription?.cancel());
    _nativePositionSubscription = null;
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
    _subtitleTimingTarget = null;
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
      final source =
          event.parameters?['source'] as BetterPlayerSubtitlesSource?;
      if (source is _WatchLocalSubtitleSource &&
          !identical(source, _localSubtitleSource)) {
        return;
      }
      _failedSubtitle = source;
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
      if (event.parameters?['nerdVpnRateLimited'] == true) {
        _emitTerminalPlaybackError();
        return;
      }
      final retryable = event.parameters?['backendRetryable'] == true;
      _sourceMediaOriginBlocked |=
          event.parameters?['mediaOriginBlocked'] == true;
      if (_playbackSourceIndex < _playbackSources.length &&
          _playbackSources[_playbackSourceIndex].playbackCache?['download']
              is Map) {
        _downloadReuseFailed = true;
        if (_qualityRollbackRefusedNetwork) {
          _emitTerminalPlaybackError();
          return;
        }
      }
      _sourceBackendRetryable = _playbackInitialized
          ? retryable
          : _sourceBackendRetryable || retryable;
      if (_playbackInitialized &&
          !_usingSavedRendition &&
          _savedQualitySource != null &&
          !_downloadReuseFailed) {
        unawaited(_restoreSavedQualitySource(
            _playbackGeneration, _playbackSourceIndex));
        return;
      }
      if (_playbackInitialized &&
          !_playbackOffline &&
          _sourceMediaOriginBlocked &&
          !retryable &&
          _playbackSourceIndex + 1 < _playbackSources.length) {
        _continueAfterBlockedMedia();
        return;
      }
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
      _sourceMediaOriginBlocked = false;
      // Loading a source resets river_player's Dart value to 1 without resetting
      // the native rate. Apply our rate for every source, including resolution
      // changes, while keeping it unchanged for the current video.
      final decoder = videoController?.videoPlayerController;
      if (decoder != null) {
        // Restore the decoder without emitting a user speed/pitch selection.
        decoder.setSpeed(_playbackSpeed);
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          decoder.setPitch(pitchFactorForSemitones(_playbackPitchSemitones));
        }
      }
    }

    final nativeValue = videoController?.videoPlayerController?.value;
    // An older native request can complete after a newer choice or mode switch.
    if (event.betterPlayerEventType == BetterPlayerEventType.setSpeed &&
            (player.state.isAudio ||
                nativeValue?.speed != event.parameters?['speed']) ||
        event.betterPlayerEventType == BetterPlayerEventType.setPitch &&
            (player.state.isAudio ||
                nativeValue?.pitch != event.parameters?['pitch'])) {
      return;
    }
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
        final source = videoController?.betterPlayerSubtitlesSource;
        _localSubtitleSelected = source is _WatchLocalSubtitleSource;
        if (!_localSubtitleSelected && !_clearingLocalSubtitle) {
          settings.setLastSubtitle(source?.name ?? '');
        }
        break;
      case BetterPlayerEventType.setupDataSource:
        dismissSubtitleFailure();
        break;
      case BetterPlayerEventType.setPitch:
        final semitones = semitonesForPitchFactor(event.parameters?['pitch']);
        if (semitones != null && semitones != _playbackPitchSemitones) {
          _playbackPitchSemitones = semitones;
          player.rememberPlaybackTuning(state.video ?? state.offlineVideo,
              pitch: semitones);
        }
        break;
      case BetterPlayerEventType.setSpeed:
        final speed = event.parameters?['speed'];
        if (speed is num &&
            speed.isFinite &&
            speed > 0 &&
            speed != _playbackSpeed) {
          _playbackSpeed = speed.toDouble();
          player.rememberPlaybackTuning(state.video ?? state.offlineVideo,
              speed: _playbackSpeed);
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
    player.setEvent(MediaEvent(
        state: MediaState.error,
        value: _sourceMediaOriginBlocked
            ? PlaybackFailureReason.separateMediaHost
            : null));
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

  void _continueAfterBlockedMedia() {
    final owner = _playbackOwner;
    if (owner == null) return;
    final route = owner.route;
    final database = db;
    _sourceContinuationIsCurrent = () {
      if (player.state.isAudio ||
          player.state.currentQueueId != owner.queueId ||
          !identical(db, database) ||
          database.profileId != route.preferredServer.profileId ||
          NetworkProxy.instance.isChanging) {
        return false;
      }
      final selected = database.getAccount(route.preferredServer.accountId);
      return selected != null && selected.inUse && route.matches(selected);
    };
    // Retire callbacks and in-flight seeks from the failed decoder. The
    // existing source list advances once and retains the latest user intent.
    _playbackGeneration++;
    _playbackStartAt = _pendingSeek ??
        (_waitingForInitialSeek ? _playbackStartAt : position());
    _waitingForInitialSeek = _playbackStartAt > Duration.zero;
    _playbackInitialized = false;
    _sourceBackendRetryable = false;
    _requestSourceFailure();
  }

  bool _isCurrentAttempt(int generation, int sourceIndex) =>
      !isClosed &&
      _parentPlaybackGeneration == player.backendPlaybackGeneration &&
      generation == _playbackGeneration &&
      sourceIndex == _playbackSourceIndex &&
      (_sourceContinuationIsCurrent?.call() ?? true);

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
    if (_playbackSources[sourceIndex].playbackCache?['download'] is Map) {
      _downloadReuseFailed = true;
      _savedQualitySource = null;
      if (_qualityRollbackRefusedNetwork) {
        _emitTerminalPlaybackError();
        return;
      }
    }
    final server = _playbackServer;
    if (server != null) {
      service.dashManifestResolver
          .invalidate(_playbackSources[sourceIndex].url, server);
    }
    if (_playbackSourceIndex + 1 >= _playbackSources.length) {
      final recovered = _recoveringInitializedPlayback ||
              state.video?.downloadPlaybackOnly == true
          ? await _recoverPlayback(generation, sourceIndex)
          : await _recoverBackend(generation, sourceIndex);
      if (!recovered && _isCurrentAttempt(generation, sourceIndex)) {
        _emitTerminalPlaybackError();
      }
      return;
    }
    if (_playbackSources[sourceIndex + 1].playbackCache?['download'] is Map) {
      final admitted = await _qualityRouteIsCurrent();
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
      if (!admitted) {
        _emitTerminalPlaybackError();
        return;
      }
      _reportQualityFailure();
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
    unawaited(_nativePositionSubscription?.cancel());
    _nativePositionSubscription = null;
    if (!_isCurrentAttempt(_playbackGeneration, _playbackSourceIndex)) return;
    _sourceBackendRetryable = false;
    _sourceMediaOriginBlocked = false;
    final generation = _playbackGeneration;
    final sourceIndex = _playbackSourceIndex;
    final parentPositionGeneration = player.playbackPositionGeneration;
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
        videoId != null &&
        !allowsMediaCompanion(server, Uri.parse(source.url))) {
      String? resolved;
      String? downloadedManifest;
      final androidMedia =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      final canUseInlineManifest = androidMedia && state.video?.liveNow != true;
      String? generateManifest() {
        final video = _qualityMetadata ?? state.video;
        if (!canUseInlineManifest || video == null) return null;
        final manifestUri = Uri.parse(source.url);
        return buildAdaptiveDashManifest(
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
      }

      // The onion API already supplies signed adaptive media URLs. Its browser
      // manifest redirects to the public origin and requires a separate watch
      // session, so use complete API tracks directly through the selected onion.
      String? inlineManifest =
          isNerdVpnOnionUrl(server.url) ? generateManifest() : null;
      var generatedManifest = inlineManifest != null;
      var missingCheck = false;
      var blockedRedirect = false;
      if (!generatedManifest) {
        try {
          resolved = await Future.any([
            service.dashManifestResolver.resolve(source.url, videoId, server,
                throwRetryable: state.video?.backendPlayback != null ||
                    _recoveringInitializedPlayback,
                onMissingCheck: () => missingCheck = true,
                onMediaOriginBlocked:
                    androidMedia ? () => blockedRedirect = true : null,
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
            if (_savedQualitySource != null && !_downloadReuseFailed) {
              // A manifest refusal does not authorize another remote request.
              // The already verified local rendition still needs current
              // session admission, and remains subject to native read guards.
              await _restoreSavedQualitySource(generation, sourceIndex,
                  refuseNetwork: true);
            } else {
              _emitTerminalPlaybackError();
            }
          }
          return;
        }
        inlineManifest = resolved == null ? null : downloadedManifest;
      }
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
      if (resolved == null &&
          inlineManifest == null &&
          (missingCheck || blockedRedirect) &&
          !_sourceBackendRetryable) {
        inlineManifest = generateManifest();
        generatedManifest = inlineManifest != null;
      }
      if (resolved == null && inlineManifest == null) {
        _sourceMediaOriginBlocked = blockedRedirect;
        _sourceFailurePending = true;
        await _handleSourceFailure(generation, sourceIndex);
        return;
      }
      source = source.copyWith(
        url: resolved,
        headers: resolved != null &&
                allowsMediaCompanion(server, Uri.parse(resolved))
            ? const {}
            : source.headers,
        playbackCache: (_qualityMetadata ?? state.video) == null
            ? null
            : playbackCacheIdentity(
                video: (_qualityMetadata ?? state.video)!,
                server: server,
                sourceUrl: resolved ?? source.url,
                mediaCompanions: source.mediaCompanions != null,
                sessionId: source.playbackCache?['sessionId'] as String? ??
                    '$generation',
              ),
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
    final startPosition = _pendingSeek ?? _playbackStartAt;
    final startSeekRevision = _seekRevision;
    final length = Duration(seconds: state.video?.lengthSeconds ?? 0);
    final androidNetworkVod = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        !_playbackOffline &&
        source.type == BetterPlayerDataSourceType.network &&
        state.video?.liveNow != true;
    final nativeStart = androidNetworkVod &&
            source.videoFormat != BetterPlayerVideoFormat.hls &&
            startPosition >= Duration.zero &&
            startPosition < length
        ? startPosition
        : null;
    final initialDashHeight =
        androidNetworkVod && source.videoFormat == BetterPlayerVideoFormat.dash
            ? _videoQuality ?? 0
            : null;
    var setupFailed = false;
    var setup = Future<void>.value();
    final nextSource = _playbackSources.skip(sourceIndex + 1).firstOrNull;
    final nextHeight = nextSource == null
        ? null
        : videoQualityHeight(_selectedResolution(nextSource) ?? '');
    final fastDashStartupFallback =
        source.videoFormat == BetterPlayerVideoFormat.dash &&
            nextSource?.videoFormat == BetterPlayerVideoFormat.other &&
            nextHeight != null &&
            nextHeight > 0 &&
            (_videoQuality == null || nextHeight == _videoQuality);
    final local = _localSubtitleSource;
    final localPlayback = _localSubtitlePlayback;
    if (local != null &&
        localPlayback != null &&
        _isLocalSubtitlePlaybackCurrent(localPlayback)) {
      final track = _newLocalSubtitleSource(
        localPlayback,
        local.name!,
        selectedByDefault: _localSubtitleSelected,
      );
      _localSubtitleSource = track;
      source = source.copyWith(
        subtitles: [track, ...?source.subtitles],
        notificationConfiguration: source.notificationConfiguration,
        bufferingConfiguration: source.bufferingConfiguration,
      );
    }
    _mountedLocalSubtitlePlayback = localPlayback;
    try {
      setup = videoController?.setupDataSource(source,
              initialPosition: nativeStart,
              initialDashHeight: initialDashHeight,
              fastDashStartupFallback: fastDashStartupFallback) ??
          Future<void>.value();
      // The source has cleared the previous video's cues synchronously.
      _restoreSubtitleTiming(generation);
      _controllerSetup = setup;
      _controllerSetupAttempt =
          (generation: generation, sourceIndex: sourceIndex);
      await Future.any([setup, cancelled]);
    } catch (error) {
      setupFailed = true;
      if (_isCurrentAttempt(generation, sourceIndex)) {
        final details = error is PlatformException ? error.details : null;
        if ((details is Map && details['nerdVpnRateLimited'] == true) ||
            (videoController?.videoPlayerController?.value.nerdVpnRateLimited ??
                false)) {
          _emitTerminalPlaybackError();
          return;
        }
        _sourceMediaOriginBlocked |= (details is Map &&
                details['mediaOriginBlocked'] == true) ||
            (videoController?.videoPlayerController?.value.mediaOriginBlocked ??
                false);
        _sourceBackendRetryable |= (details is Map &&
                details['backendRetryable'] == true) ||
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
      final video = state.video;
      if (!_playbackOffline &&
          parentPositionGeneration == player.playbackPositionGeneration &&
          video != null &&
          server != null &&
          source.videoFormat == BetterPlayerVideoFormat.other &&
          source.playbackCache?['download'] is! Map) {
        player.rememberWatchProgressiveAudio(
            video,
            source.url,
            watchAudioTrackIdForProgressiveUrl(
                _qualityMetadata ?? video, server, source.url));
      }
      final native = videoController?.videoPlayerController;
      _nativePositionSubscription =
          native?.nativePositionStream.listen((position) {
        if (!_isCurrentAttempt(generation, sourceIndex) ||
            !_playbackInitialized ||
            _waitingForInitialSeek ||
            _terminalErrorSent ||
            _backendRecoveryPending) {
          return;
        }
        final value = native.value;
        player.setEvent(MediaEvent<Duration>(
          type: MediaEventType.playbackSample,
          value: position,
          state: value.isBuffering
              ? MediaState.buffering
              : value.isPlaying && !value.hasError
                  ? MediaState.playing
                  : MediaState.pause,
        ));
      });
      if (initialDashHeight == null &&
          !_playbackOffline &&
          (source.videoFormat == BetterPlayerVideoFormat.dash ||
              source.videoFormat == BetterPlayerVideoFormat.hls) &&
          (_videoQuality ?? 0) > 0) {
        // Manifest track discovery runs independently of native setup. Apply a
        // resolution cap here so slow discovery cannot lose the saved choice.
        // Do not carry a previous video's width or bitrate into the new video.
        videoController?.setTrack(BetterPlayerAsmsTrack(
            null, 2147483647, _videoQuality, 2147483647, null, null, null));
      }
      if (nativeStart != null && startSeekRevision == _seekRevision) {
        _pendingSeek = null;
        _waitingForInitialSeek = false;
        // The decoder starts at the resume position without a seek event.
        // Publish it even if playback was paused before initialization.
        player.setEvent(MediaEvent(
            state: MediaState.ready,
            type: MediaEventType.progress,
            value: position()));
      }
      final pendingSeek = _pendingSeek;
      if ((nativeStart == null && seekAfterSetup) || pendingSeek != null) {
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
          _sourceContinuationIsCurrent = null;
        }
      } catch (_) {
        if (_isCurrentAttempt(generation, sourceIndex)) {
          _emitTerminalPlaybackError();
        }
      }
    }
  }

  @override
  Future<void> toggleDash({VoidCallback? onQualityFailure}) async {
    log.fine('toggle dash');
    if (_usingSavedRendition || _qualityMetadata != null) {
      if (!await prepareVideoTracks()) return;
      final useDash = !isUsingDash();
      final progressive = _onlineQualitySources.values
          .where(
              (source) => source.videoFormat == BetterPlayerVideoFormat.other)
          .toList();
      final preferred = preferredVideoQualityIndex(
          progressive
              .map((source) =>
                  videoQualityHeight(_selectedResolution(source) ?? ''))
              .toList(),
          _videoQuality);
      final source = useDash
          ? _qualityDashSource
          : progressive.elementAtOrNull(preferred ?? 0);
      if (source == null || !await _qualityRouteIsCurrent()) return;
      final generation = _playbackGeneration;
      await settings.toggleDash(useDash);
      if (generation != _playbackGeneration ||
          !await _qualityRouteIsCurrent()) {
        return;
      }
      _selectPreparedQualitySource(source, onQualityFailure: onQualityFailure);
      return;
    }
    final newState = state.copyWith();
    final useDash = !isUsingDash();
    await player.saveProgress(position().inSeconds);
    await settings.toggleDash(useDash);
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
      _downloadReuseFailed = false;
      _requestedPlaying = player.shouldStartPlayback;
    }
    _cancelSetup();
    _setupCancellation = Completer<void>();
    final generation = ++_playbackGeneration;
    _subtitleTimingTarget = null;
    _clearQualityPreparation();
    _parentPlaybackGeneration = player.backendPlaybackGeneration;
    if (_controllerSetup != null) {
      _controllerSetup = null;
      _controllerSetupAttempt = null;
      disposeControllers();
    }
    _playbackSourceIndex = 0;
    _playbackInitialized = false;
    _terminalErrorSent = false;
    _sourceMediaOriginBlocked = false;
    _sourceFailurePending = false;
    _failedSubtitle = null;
    var newState = state.copyWith(startAt: startAt, subtitleFailed: false);
    _playbackOwner = null;
    _sourceContinuationIsCurrent = null;
    _playbackVideoId = null;
    if (newState.video != null || newState.offlineVideo != null) {
      final idedVideo = offline ? newState.offlineVideo! : newState.video!;
      final isWatch = offline
          ? newState.offlineVideo!.musicMetadata == null
          : newState.video!.musicMetadata == null;
      final localPlayback = WatchLocalSubtitles.supported && isWatch
          ? (
              owner: (profileId: db.profileId, videoId: idedVideo.videoId),
              occurrence: player.playbackPositionGeneration,
            )
          : null;
      if (_localSubtitlePlayback != localPlayback) {
        _localSubtitlePlayback = localPlayback;
        _mountedLocalSubtitlePlayback = null;
        _localSubtitleSource = null;
        _localSubtitleSelected = false;
      }
      if (localPlayback != null && _localSubtitleSource == null) {
        final name = await _readLocalSubtitleName(localPlayback.owner);
        if (!_isCurrentAttempt(generation, 0)) return;
        if (name != null && _isLocalSubtitlePlaybackCurrent(localPlayback)) {
          _localSubtitleSource = _newLocalSubtitleSource(localPlayback, name);
        }
      }
      if (_qualityVideoId != idedVideo.videoId) {
        _qualityVideoId = idedVideo.videoId;
        _videoQuality = settings.state.rememberVideoQuality
            ? settings.state.lastVideoQuality
            : null;
      }
      final tuning = player.playbackTuningFor(idedVideo);
      _playbackPitchSemitones = tuning.pitch;
      _playbackSpeed = tuning.speed;
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
        final downloaded = newState.offlineVideo!;
        final videoPath = await downloaded.effectivePath;
        if (!_isCurrentAttempt(generation, 0)) return;

        _playbackSources = [
          BetterPlayerDataSource(
            Uri.tryParse(videoPath)?.scheme == 'content'
                ? BetterPlayerDataSourceType.network
                : BetterPlayerDataSourceType.file,
            videoPath,
            videoFormat: BetterPlayerVideoFormat.other,
            liveStream: false,
            subtitles: [
              if (downloaded.captionLabel != null)
                BetterPlayerSubtitlesSource(
                  type: BetterPlayerSubtitlesSourceType.memory,
                  name: downloaded.captionLabel,
                  contentLoader: () async =>
                      File(await downloaded.subtitlePath).readAsString(),
                  selectedByDefault: settings.state.rememberSubtitles &&
                      settings.state.lastSubtitles == downloaded.captionLabel,
                ),
            ],
            useAsmsSubtitles: false,
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
        _playbackOwner = (
          route: connection ?? BackendPlayback(selectedServer),
          queueId: player.state.currentQueueId,
        );
        _playbackVideoId = newState.video!.videoId;
        var blockedMediaOrigin = false;
        // The saved setting orders the adaptive and progressive sources.
        // Within the progressive candidates, keep the known audio track.
        final preferredAudioTrack =
            player.watchAudioPreferenceFor(newState.video!)?.trackId;
        final sources = _buildPlaybackDataSources(
          newState.video!,
          server,
          preferDash: settings.state.useDash,
          preferProgressiveStartup: _canStartNerdVpnProgressive,
          preferredQuality: _videoQuality,
          preferredAudioTrack: preferredAudioTrack,
          onBlockedMediaOrigin: () => blockedMediaOrigin = true,
          lastSubtitle: settings.state.rememberSubtitles
              ? settings.state.lastSubtitles
              : null,
        );
        final local = _downloadReuseFailed
            ? null
            : await resolveDownloadPlaybackSource(
                database: db,
                video: newState.video!,
                server: server,
                audioOnly: false,
                sessionId:
                    '$generation:${DateTime.now().microsecondsSinceEpoch}',
                preferredQuality: _videoQuality,
                isCurrent: () =>
                    _isCurrentAttempt(generation, 0) && !player.state.isAudio);
        if (!_isCurrentAttempt(generation, 0) || player.state.isAudio) return;
        if (local != null) {
          final localPriority = preferredAudioTrack == null ||
                  local.download.audioTrackId == preferredAudioTrack
              ? 0
              : sources.lastIndexWhere((source) =>
                      source.videoFormat == BetterPlayerVideoFormat.other &&
                      watchAudioTrackIdForProgressiveUrl(
                              newState.video!, server, source.url) ==
                          preferredAudioTrack) +
                  1;
          final resolutions = <String, String>{
            // Preserve the first source's language-aware choice for each
            // quality when the mounted fallback is a saved file.
            for (final source
                in preferredAudioTrack == null ? sources : sources.reversed)
              ...?source.resolutions,
            if (local.videoQuality != null && localPriority == 0)
              local.videoQuality!: local.uri,
          };
          sources.insert(
              localPriority,
              BetterPlayerDataSource(
                // The platform source DTO accepts content/file URIs here and
                // carries the same initial-seek and guarded admission metadata.
                BetterPlayerDataSourceType.network,
                local.uri,
                videoFormat: BetterPlayerVideoFormat.other,
                liveStream: false,
                playbackCache: local.playbackCache,
                resolutions: resolutions.isEmpty ? null : resolutions,
                subtitles: sources.firstOrNull?.subtitles ??
                    [
                      if (local.download.captionLabel != null)
                        BetterPlayerSubtitlesSource(
                          type: BetterPlayerSubtitlesSourceType.memory,
                          name: local.download.captionLabel,
                          contentLoader: () async =>
                              File(await local.download.subtitlePath)
                                  .readAsString(),
                          selectedByDefault: settings.state.rememberSubtitles &&
                              settings.state.lastSubtitles ==
                                  local.download.captionLabel,
                        ),
                    ],
                useAsmsSubtitles: false,
              ));
        }
        if (sources.isEmpty) {
          _playbackSources = const [];
          if (newState.video?.downloadPlaybackOnly == true) {
            _downloadReuseFailed = true;
            emit(newState);
            _sourceBackendRetryable = true;
            if (await _recoverPlayback(generation, 0)) return;
          }
          _sourceMediaOriginBlocked = blockedMediaOrigin;
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
            overlay: isTv
                ? SubtitleFailureOverlay(
                    player: this,
                    autofocus: true,
                    child: const TvPlayerControls(),
                  )
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
        !_playbackInitialized ||
        _controllerSetupAttempt != null ||
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

  bool get _usingSavedRendition =>
      _playbackSourceIndex < _playbackSources.length &&
      _playbackSources[_playbackSourceIndex].playbackCache?['download'] is Map;

  void _clearQualityPreparation() {
    _qualityPreparation = null;
    _qualityMetadata = null;
    _onlineQualitySources = const {};
    _qualityDashSource = null;
    _savedQualitySource = null;
    _qualityFailureFeedback = null;
    _qualityRollbackRefusedNetwork = false;
  }

  Future<bool> _qualityRouteIsCurrent() async {
    final generation = _playbackGeneration;
    final index = _playbackSourceIndex;
    final database = db;
    final route =
        state.video?.playbackConnection ?? state.video?.backendPlayback;
    if (route == null || NetworkProxy.instance.isChanging) return false;
    try {
      final selected = await database.getCurrentlySelectedServer();
      return identical(database, db) &&
          database.profileId == route.preferredServer.profileId &&
          !NetworkProxy.instance.isChanging &&
          _isCurrentAttempt(generation, index) &&
          route.matches(selected);
    } catch (_) {
      return false;
    }
  }

  /// Quality is optional metadata: opening this menu must leave the admitted
  /// saved rendition playing, including when the instance is unavailable.
  Future<bool> prepareVideoTracks() {
    if (!_usingSavedRendition) return Future.value(true);
    final pending = _qualityPreparation;
    if (pending != null) return pending;
    final generation = _playbackGeneration;
    final index = _playbackSourceIndex;
    final video = state.video!;
    bool active() =>
        _isCurrentAttempt(generation, index) && _usingSavedRendition;
    Future<bool> prepare() async {
      try {
        if (!await _qualityRouteIsCurrent() || !active()) return false;
        if (_qualityMetadata != null) return true;
        final refreshed =
            await service.refreshPlaybackVideo(video, isCurrent: active);
        if (!active() || !await _qualityRouteIsCurrent() || !active()) {
          return false;
        }
        final route = refreshed.playbackConnection ?? refreshed.backendPlayback;
        if (refreshed.videoId != video.videoId ||
            route == null ||
            route.server != _playbackServer) {
          return false;
        }
        final sources = _buildPlaybackDataSources(refreshed, _playbackServer!,
            preferDash: false,
            preferProgressiveStartup: false,
            preferredAudioTrack: player.watchAudioPreferenceFor(video)?.trackId,
            lastSubtitle: settings.state.rememberSubtitles
                ? settings.state.lastSubtitles
                : null);
        final choices = <String, BetterPlayerDataSource>{};
        for (final source in sources) {
          final height = videoQualityHeight(_selectedResolution(source) ?? '');
          if (height != null && height > 0) {
            choices.putIfAbsent('${height}p', () => source);
          }
        }
        final dash = sources
            .where(
                (source) => source.videoFormat == BetterPlayerVideoFormat.dash)
            .firstOrNull;
        if (dash != null) {
          for (final format in refreshed.adaptiveFormats ?? const []) {
            final height = videoQualityHeight(
                format.qualityLabel ?? format.resolution ?? '');
            if (format.type.toLowerCase().startsWith('video/') &&
                height != null &&
                height > 0 &&
                proxiedPlaybackMediaUrl(format.url, _playbackServer!) != null) {
              choices.putIfAbsent('${height}p', () => dash);
            }
          }
        }
        if (choices.isEmpty && dash == null) return false;
        _qualityMetadata = refreshed;
        _onlineQualitySources = choices;
        _qualityDashSource = dash;
        return true;
      } catch (_) {
        return false;
      }
    }

    late final Future<bool> result;
    result = prepare().whenComplete(() {
      if (identical(_qualityPreparation, result)) _qualityPreparation = null;
    });
    _qualityPreparation = result;
    return result;
  }

  void _selectPreparedQualitySource(BetterPlayerDataSource source,
      {VoidCallback? onQualityFailure}) {
    // Keep the parent's source/queue occurrence intact. Fresh URLs are decoder
    // metadata only; recovery still refreshes that same admitted occurrence.
    _playbackStartAt =
        _pendingSeek ?? (_playbackInitialized ? position() : _playbackStartAt);
    _waitingForInitialSeek = _playbackStartAt > Duration.zero;
    if (_usingSavedRendition) {
      _savedQualitySource = _playbackSources[_playbackSourceIndex];
    }
    _qualityFailureFeedback = onQualityFailure;
    _qualityRollbackRefusedNetwork = false;
    _playbackSources = [
      source,
      if (!_downloadReuseFailed && _savedQualitySource != null)
        _savedQualitySource!,
      ..._onlineQualitySources.values
          .toSet()
          .where((other) => other.url != source.url)
    ];
    _playbackGeneration++;
    _playbackSourceIndex = 0;
    _playbackInitialized = false;
    _terminalErrorSent = false;
    _sourceFailurePending = false;
    _backendRecoveryPending = false;
    WakelockPlus.enable();
    unawaited(_setupPlaybackSource());
  }

  void _reportQualityFailure() {
    final feedback = _qualityFailureFeedback;
    _qualityFailureFeedback = null;
    try {
      feedback?.call();
    } catch (_) {
      // Feedback is optional; it cannot prevent restoring admitted playback.
    }
  }

  Future<void> _restoreSavedQualitySource(int generation, int index,
      {bool refuseNetwork = false}) async {
    final saved = _savedQualitySource;
    if (saved == null || !_isCurrentAttempt(generation, index)) return;
    _backendRecoveryPending = true;
    final resumeAt = position();
    final admitted = await _qualityRouteIsCurrent();
    if (!_isCurrentAttempt(generation, index)) return;
    _backendRecoveryPending = false;
    if (!admitted || _downloadReuseFailed) {
      _emitTerminalPlaybackError();
      return;
    }
    _playbackStartAt = _pendingSeek ?? resumeAt;
    _waitingForInitialSeek = _playbackStartAt > Duration.zero;
    _qualityRollbackRefusedNetwork = refuseNetwork;
    // The chosen online source has already failed. Do not revisit it after a
    // failed rollback; a real local failure follows normal bounded recovery.
    _playbackSources = [saved];
    _playbackGeneration++;
    _playbackSourceIndex = 0;
    _playbackInitialized = false;
    _sourceFailurePending = false;
    _reportQualityFailure();
    await _setupPlaybackSource();
  }

  @override
  List<String> getVideoTracks() {
    if (state.video == null) return [];
    if (_usingSavedRendition && _qualityMetadata != null) {
      final local = _selectedResolution(_playbackSources[_playbackSourceIndex]);
      return {if (local != null) local, ..._onlineQualitySources.keys}.toList()
        ..sort((a, b) =>
            (videoQualityHeight(b) ?? 0).compareTo(videoQualityHeight(a) ?? 0));
    }
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

  bool _isLocalSubtitlePlaybackCurrent(_WatchSubtitlePlayback playback) =>
      !isClosed &&
      !player.isClosed &&
      !player.state.isAudio &&
      !player.state.isClosing &&
      _localSubtitlePlayback == playback &&
      player.playbackPositionGeneration == playback.occurrence &&
      db.profileId == playback.owner.profileId;

  bool get canManageLocalSubtitles {
    final playback = _localSubtitlePlayback;
    return playback != null &&
        _mountedLocalSubtitlePlayback == playback &&
        videoController?.betterPlayerDataSource != null &&
        _isLocalSubtitlePlaybackCurrent(playback);
  }

  String? get localSubtitleName =>
      canManageLocalSubtitles ? _localSubtitleSource?.name : null;

  _WatchLocalSubtitleSource _newLocalSubtitleSource(
    _WatchSubtitlePlayback playback,
    String name, {
    bool selectedByDefault = false,
  }) {
    late final _WatchLocalSubtitleSource source;
    source = _WatchLocalSubtitleSource(
      name,
      () async {
        final text = await _localSubtitles.read(playback.owner);
        if (!identical(source, _localSubtitleSource) ||
            !_isLocalSubtitlePlaybackCurrent(playback)) {
          throw const FormatException('The local subtitle was changed');
        }
        return text;
      },
      selectedByDefault: selectedByDefault,
    );
    return source;
  }

  Future<String?> _readLocalSubtitleName(WatchLocalSubtitleOwner owner) async {
    try {
      return await _localSubtitles.attachment(owner);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<WatchLocalSubtitleResult> pickLocalSubtitle() =>
      _changeLocalSubtitle(picking: true);

  Future<WatchLocalSubtitleResult> removeLocalSubtitle() =>
      _changeLocalSubtitle(picking: false);

  Future<WatchLocalSubtitleResult> _changeLocalSubtitle(
      {required bool picking}) async {
    final playback = _localSubtitlePlayback;
    if (playback == null ||
        !canManageLocalSubtitles ||
        _changingLocalSubtitle) {
      return WatchLocalSubtitleResult.cancelled;
    }
    _changingLocalSubtitle = true;
    WatchLocalSubtitlePick? pick;
    try {
      if (picking) {
        pick = await _localSubtitles.pick(playback.owner);
        if (pick == null || !_isLocalSubtitlePlaybackCurrent(playback)) {
          return WatchLocalSubtitleResult.cancelled;
        }
        await _localSubtitles.save(pick.token);
      } else {
        await _localSubtitles.remove(playback.owner);
      }
      if (!_isLocalSubtitlePlaybackCurrent(playback)) {
        return WatchLocalSubtitleResult.cancelled;
      }

      final previous = _localSubtitleSource;
      final replacement =
          pick == null ? null : _newLocalSubtitleSource(playback, pick.name);
      _localSubtitleSource = replacement;
      final controller = videoController;
      if (controller == null) return WatchLocalSubtitleResult.done;
      final tracks = controller.betterPlayerSubtitlesSourceList;
      tracks.remove(previous);
      if (identical(_failedSubtitle, previous) && previous != null) {
        dismissSubtitleFailure();
      }
      if (replacement != null) {
        tracks.insert(0, replacement);
        await controller.setupSubtitleSource(replacement);
      } else if (previous != null &&
          identical(controller.betterPlayerSubtitlesSource, previous)) {
        final off = tracks
            .where(
                (track) => track.type == BetterPlayerSubtitlesSourceType.none)
            .firstOrNull;
        if (off == null) return WatchLocalSubtitleResult.done;
        _clearingLocalSubtitle = true;
        try {
          await controller.setupSubtitleSource(off);
        } finally {
          _clearingLocalSubtitle = false;
        }
      }
      return WatchLocalSubtitleResult.done;
    } on FormatException {
      return WatchLocalSubtitleResult.invalidFile;
    } on PlatformException catch (error) {
      return switch (error.code) {
        'UNSUPPORTED_SUBTITLE' ||
        'SUBTITLE_TOO_LARGE' =>
          WatchLocalSubtitleResult.invalidFile,
        _ => WatchLocalSubtitleResult.unavailable,
      };
    } on MissingPluginException {
      return WatchLocalSubtitleResult.unavailable;
    } finally {
      if (pick != null) await _localSubtitles.discardPick(pick.token);
      _changingLocalSubtitle = false;
    }
  }

  @override
  List<String> getSubtitles() {
    return videoController?.betterPlayerSubtitlesSourceList
            .map(_subtitleToString)
            .toList() ??
        [];
  }

  bool get hasSubtitleTracks =>
      videoController?.betterPlayerSubtitlesSourceList.any(
        (source) => source.type != BetterPlayerSubtitlesSourceType.none,
      ) ??
      false;

  void _restoreSubtitleTiming(int generation) {
    final videoId = state.offlineVideo?.videoId ?? state.video?.videoId;
    final controller = videoController;
    if (_subtitleTimingTarget != null ||
        videoId == null ||
        controller == null) {
      return;
    }
    final profileId = db.profileId;
    final saved = db
        .forProfile(profileId)
        .getSettings(_subtitleTimingKey(videoId))
        ?.value;
    _subtitleTimingTarget = (
      videoId: videoId,
      generation: generation,
      profileId: profileId,
      sessionRevision: settings.appCubit.state.sessionRevision,
    );
    controller.setSubtitleOffset(
      _boundedSubtitleOffset(int.tryParse(saved ?? '') ?? 0),
    );
  }

  WatchSubtitleTimingTarget? get subtitleTimingTarget {
    final target = _subtitleTimingTarget;
    if (target == null ||
        isClosed ||
        player.isClosed ||
        player.state.isAudio ||
        player.state.isClosing ||
        _parentPlaybackGeneration != player.backendPlaybackGeneration ||
        videoController == null ||
        target.videoId !=
            (state.offlineVideo?.videoId ?? state.video?.videoId) ||
        target.profileId != db.profileId ||
        target.sessionRevision != settings.appCubit.state.sessionRevision) {
      return null;
    }
    return target;
  }

  static Duration _boundedSubtitleOffset(int milliseconds) => Duration(
      milliseconds: milliseconds.clamp(-subtitleTimingLimit.inMilliseconds,
          subtitleTimingLimit.inMilliseconds));

  /// Shift captions by [shift], or reset to their authored timing.
  Future<void> adjustSubtitleTiming(WatchSubtitleTimingTarget target,
      {Duration? shift}) {
    // Keep rapid nudges in order, including across dialog reopenings.
    final update = _subtitleTimingUpdate.then((_) async {
      if (subtitleTimingTarget != target) return;
      final database = db.forProfile(target.profileId);
      final key = _subtitleTimingKey(target.videoId);
      final offset = shift == null
          ? Duration.zero
          : _boundedSubtitleOffset(
              (videoController!.subtitleOffset.value + shift).inMilliseconds);
      if (offset == Duration.zero) {
        await database.deleteSetting(key);
      } else {
        await database
            .saveSetting(SettingsValue(key, offset.inMilliseconds.toString()));
      }

      final active = subtitleTimingTarget;
      if (active != null &&
          active.videoId == target.videoId &&
          active.profileId == target.profileId &&
          active.sessionRevision == target.sessionRevision) {
        videoController!.setSubtitleOffset(offset);
      }
    });
    _subtitleTimingUpdate = update.then<void>((_) {}, onError: (Object _) {});
    return update;
  }

  @override
  int selectedSubtitle() {
    final controller = videoController;
    final selected = controller?.betterPlayerSubtitlesSource;
    if (controller == null || selected == null) return -1;
    return controller.betterPlayerSubtitlesSourceList.indexOf(selected);
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
  Future<void> selectVideoTrack(int index,
      {VoidCallback? onQualityFailure}) async {
    final tracks = getVideoTracks();
    if (index < 0 || index >= tracks.length) return;
    if (_usingSavedRendition && _qualityMetadata != null) {
      final track = tracks[index];
      final local = _selectedResolution(_playbackSources[_playbackSourceIndex]);
      if (videoQualityHeight(track) == videoQualityHeight(local ?? '')) return;
      final source = _onlineQualitySources[track];
      final generation = _playbackGeneration;
      if (source == null ||
          !await _qualityRouteIsCurrent() ||
          generation != _playbackGeneration) {
        return;
      }
      final height = videoQualityHeight(track);
      _videoQuality = height;
      _selectPreparedQualitySource(source, onQualityFailure: onQualityFailure);
      await _rememberVideoQuality(height);
      return;
    }
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
    player.rememberPlaybackTuning(state.video ?? state.offlineVideo, speed: d);
    if (videoController?.videoPlayerController != null) {
      videoController?.setSpeed(d);
    }
  }

  @override
  void setPitchSemitones(int semitones) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _playbackPitchSemitones = clampPitchSemitones(semitones);
    player.rememberPlaybackTuning(state.video ?? state.offlineVideo,
        pitch: _playbackPitchSemitones);
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
    final format = videoController?.betterPlayerDataSource?.videoFormat;
    if (format == BetterPlayerVideoFormat.dash) return true;
    // A failed DASH source can leave progressive playback active even while
    // DASH remains the preference. Reflect that fallback so the toggle retries
    // adaptive playback instead of silently disabling it for later videos.
    if (format == BetterPlayerVideoFormat.other) return false;
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
