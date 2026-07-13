import 'dart:async';

import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/extensions.dart';
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
    sources.add(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url,
      videoFormat: format,
      liveStream: video.liveNow,
      subtitles: subtitles,
      resolutions: resolutions,
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
    final url = _mediaUrl(stream.url);
    if (url == null) continue;
    final safeUrl = _validMediaUrl(_proxyUrl(url, server, useProxy), server);
    if (safeUrl == null || !streamUrls.add(_sourceKey(safeUrl))) continue;
    streams.add((resolution: stream.resolution, url: safeUrl));
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
  int _playbackSourceIndex = 0;
  bool _playbackInitialized = false;
  bool _terminalErrorSent = false;
  bool _sourceFailurePending = false;
  int _playbackGeneration = 0;
  Future<void>? _controllerSetup;
  ({int generation, int sourceIndex})? _controllerSetupAttempt;
  Completer<void> _setupCancellation = Completer<void>();
  Function(BetterPlayerEvent)? _videoListener;
  Duration _playbackStartAt = Duration.zero;

  VideoPlayerCubit(super.initialState, super.player, this.settings) {
    onInit();
  }

  void onInit() {
    log.fine("Ready, playing video");
    playVideo(state.offlineVideo != null, startAt: state.startAt);
  }

  @override
  Future<void> close() async {
    _playbackGeneration++;
    _playbackSources = const [];
    _cancelSetup();
    _controllerSetup = null;
    _controllerSetupAttempt = null;
    disposeControllers();
    await super.close();
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
      case BetterPlayerEventType.setSpeed:
        type = MediaEventType.speedChanged;
        break;
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
    if (isClosed) return;
    if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
      if (_playbackInitialized) {
        _emitTerminalPlaybackError();
      } else {
        _requestSourceFailure();
      }
      return;
    }
    if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
      _playbackInitialized = true;
      _sourceFailurePending = false;
    }

    forwardEvent(event);

    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.bufferingUpdate:
        EasyThrottle.throttle('video-buffering', const Duration(seconds: 1),
            () {
          List<DurationRange> durations = event.parameters?['buffered'] ?? [];
          emit(state.copyWith(
              bufferPosition:
                  durations.sortBy((e) => e.end).map((e) => e.end).last));
          player.setEvent(MediaEvent(
              state: MediaState.playing,
              type: MediaEventType.bufferChanged,
              value: state.bufferPosition));
        });
        break;
      case BetterPlayerEventType.play:
        double speed = 1.0;
        if (settings.state.rememberPlayBackSpeed) {
          log.fine("Setting playback speed to $speed");
          videoController?.setSpeed(settings.state.lastSpeed);
        }
        break;
      case BetterPlayerEventType.changedSubtitles:
        settings.setLastSubtitle(
            videoController?.betterPlayerSubtitlesSource?.name ?? '');
        break;
      case BetterPlayerEventType.setSpeed:
        if (event.parameters?.containsKey("speed") ?? false) {
          settings.setLastSpeed(event.parameters?["speed"]);
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
    _videoListener = (event) {
      if (!isClosed && generation == _playbackGeneration) {
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
    if (isClosed || _terminalErrorSent) return;
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
    if (_playbackSourceIndex + 1 >= _playbackSources.length) {
      _emitTerminalPlaybackError();
      return;
    }
    _playbackSourceIndex++;
    await _setupPlaybackSource();
  }

  Future<void> _setupPlaybackSource({bool seekAfterSetup = true}) async {
    if (isClosed) return;
    final generation = _playbackGeneration;
    final sourceIndex = _playbackSourceIndex;
    final source = _playbackSources[sourceIndex];
    final cancelled = _setupCancellation.future;
    final previousSetup = _controllerSetup;
    if (previousSetup != null) {
      try {
        await Future.any([previousSetup, cancelled]);
      } catch (_) {}
      if (!_isCurrentAttempt(generation, sourceIndex)) return;
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
    } catch (_) {
      setupFailed = true;
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
    } else if (seekAfterSetup) {
      seek(_playbackStartAt);
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
    emit(state.copyWith(startAt: startAt, video: video));
    playVideo(false, startAt: startAt);
  }

  @override
  togglePlaying() {
    if (videoController != null) {
      (videoController?.isPlaying() ?? false)
          ? videoController?.pause()
          : videoController?.play();
      emit(state.copyWith());
    }
  }

  @override
  toggleControls(bool visible) {
    videoController?.setControlsEnabled(visible);
  }

  @override
  playVideo(bool offline, {Duration? startAt}) async {
    if (player.state.isAudio) {
      return;
    }
    _cancelSetup();
    _setupCancellation = Completer<void>();
    final generation = ++_playbackGeneration;
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
    if (newState.video != null || newState.offlineVideo != null) {
      final idedVideo = offline ? newState.offlineVideo! : newState.video!;
      newState = newState.copyWith(bufferPosition: Duration.zero);

      if (startAt == null && !offline) {
        final progress = db.getVideoProgress(idedVideo.videoId);
        if (progress > 0 && progress < 0.90) {
          startAt = Duration(
              seconds:
                  ((newState.video!.lengthSeconds ?? 0) * progress).floor());
        }
      }

      if (offline) {
        final videoPath = await newState.offlineVideo!.effectivePath;
        if (isClosed || generation != _playbackGeneration) return;

        _playbackSources = [
          BetterPlayerDataSource(
            BetterPlayerDataSourceType.file,
            videoPath,
            videoFormat: BetterPlayerVideoFormat.other,
            liveStream: false,
          )
        ];
      } else {
        final server = await db.getCurrentlySelectedServer();
        if (isClosed || generation != _playbackGeneration) return;
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
            autoPlay: true,
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
      if (isClosed || generation != _playbackGeneration) return;
      emit(newState);
      await _setupPlaybackSource(seekAfterSetup: reusedController);
    }

    if (!isClosed && generation == _playbackGeneration && !_terminalErrorSent) {
      super.playVideo(offline);
    }
  }

  @override
  void switchToOfflineVideo(DownloadedVideo v) {
    emit(state.copyWith(offlineVideo: v));
    playVideo(true);
  }

  @override
  bool isPlaying() {
    return videoController?.isPlaying() ?? false;
  }

  @override
  void pause() {
    videoController?.pause();
  }

  @override
  void play() {
    videoController?.play();
  }

  @override
  void seek(Duration position) {
    videoController?.seekTo(position);
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

  @override
  double? speed() {
    return videoController?.videoPlayerController?.value.speed ?? 1;
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
    videoController?.setSpeed(d);
  }

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
