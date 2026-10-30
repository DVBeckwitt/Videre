import 'dart:async';

import 'package:easy_debounce/easy_throttle.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:flutter/foundation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/extensions.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../../settings/states/settings.dart';
import '../../videos/models/adaptive_format.dart';
import '../models/media_event.dart';
import '../models/playback_pitch.dart';

part 'audio_player.freezed.dart';

Logger log = Logger('AudioPlayerController');

class AudioPlayerCubit extends MediaPlayerCubit<AudioPlayerState> {
  AudioPlayer? audioPlayer;
  final SettingsCubit settings;
  int _playbackGeneration = 0;
  int _parentPlaybackGeneration = 0;
  bool get _ownsParentPlayback =>
      _parentPlaybackGeneration == player.backendPlaybackGeneration;
  String? _speedVideoId;
  double _playbackSpeed = 1;
  int _playbackPitchSemitones = 0;
  int? _loadingGeneration;
  int? _backendMetadataGeneration;
  bool _playbackOffline = false;
  bool _wantsToPlay = true;
  bool _terminalErrorSent = false;
  Future<void>? _disposal;
  final _playerSubscriptions = <StreamSubscription<dynamic>>[];

  AudioPlayerCubit(super.initialState, super.player, this.settings) {
    onInit();
  }

  @override
  Future<void> close() async {
    try {
      await stopForProxyChange();
    } finally {
      await super.close();
    }
  }

  void onInit() {
    initPlayer();
    playVideo(state.offlineVideo != null, startAt: player.state.startAt);
  }

  @override
  void disposeControllers() {
    unawaited(stopForProxyChange());
  }

  @override
  Future<void> stopForProxyChange() {
    _playbackGeneration++;
    _loadingGeneration = null;
    _backendMetadataGeneration = null;
    _wantsToPlay = false;
    final current = audioPlayer;
    audioPlayer = null;
    _speedVideoId = null;
    EasyThrottle.cancel('audio-progress');
    EasyThrottle.cancel('audio-buffering');
    final subscriptions = List.of(_playerSubscriptions);
    _playerSubscriptions.clear();
    if (current == null && subscriptions.isEmpty) {
      return _disposal ?? Future<void>.value();
    }
    final disposal = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await current?.dispose();
    }();
    _disposal = disposal;
    return disposal;
  }

  void initPlayer() {
    if (audioPlayer == null) {
      final current = audioPlayer = AudioPlayer();
      bool active() =>
          !isClosed && _ownsParentPlayback && identical(audioPlayer, current);
      _playerSubscriptions.addAll([
        current.playerStateStream.listen((value) {
          if (active()) onStateStreamChange(value);
        }, onError: (Object error, StackTrace stack) {
          if (active()) onPlaybackError(error);
        }),
        current.errorStream.listen((error) {
          if (active()) onPlaybackError(error);
        }),
        current.positionStream.listen((value) {
          if (active()) onPositionChanged(value);
        }),
        current.durationStream.listen((value) {
          if (active()) onDurationChanged(value);
        }),
        current.bufferedPositionStream.listen((value) {
          if (active()) onBufferChanged(value);
        }),
        current.pitchStream.listen((value) {
          if (active() &&
              !_awaitingBackendMetadata &&
              _loadingGeneration == null) {
            final semitones = semitonesForPitchFactor(value);
            if (semitones != null) _reportPitch(semitones);
          }
        }),
        current.speedStream.listen((value) {
          if (active() && !_awaitingBackendMetadata) {
            player.setEvent(MediaEvent<double>(
                state: MediaState.ready,
                type: MediaEventType.speedChanged,
                value: value));
          }
        }),
      ]);
    }
  }

  void _reportPitch(int semitones) {
    player.setEvent(MediaEvent<int>(
        state: MediaState.ready,
        type: MediaEventType.pitchChanged,
        value: semitones));
  }

  bool get _awaitingBackendMetadata =>
      _backendMetadataGeneration == _playbackGeneration;

  void onStateStreamChange(PlayerState state) {
    if (!_ownsParentPlayback || _awaitingBackendMetadata) return;
    log.fine('Player state event $state');
    switch (state.processingState) {
      case ProcessingState.idle:
        // looks like this is causing issues with the player control notification
        // MiniPlayerController.to()?.eventStream.add(MediaEvent(state: MediaState.idle));
        break;
      case ProcessingState.loading:
        player.setEvent(const MediaEvent(state: MediaState.loading));
        break;
      case ProcessingState.buffering:
        player.setEvent(const MediaEvent(state: MediaState.buffering));
        break;
      case ProcessingState.ready:
        final video = this.state.video;
        if (video != null) {
          player.reportBackendPlaybackReady(
              video.videoId, video.backendPlayback,
              playing: state.playing);
        }
        player.setEvent(const MediaEvent(state: MediaState.ready));
        break;
      case ProcessingState.completed:
        player.setEvent(const MediaEvent(state: MediaState.completed));
        break;
    }
  }

  void onDurationChanged(Duration? duration) {
    if (isClosed ||
        !_ownsParentPlayback ||
        audioPlayer == null ||
        _awaitingBackendMetadata) {
      return;
    }
    emit(state.copyWith(loading: false));
    player.setEvent(MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.durationChanged,
        value: duration ?? const Duration(seconds: 1)));
  }

  void onPositionChanged(Duration position) {
    if (!_ownsParentPlayback || _awaitingBackendMetadata) return;
    final current = audioPlayer;
    final video = state.video;
    if (current != null &&
        video != null &&
        _loadingGeneration != _playbackGeneration &&
        !_terminalErrorSent) {
      player.reportBackendPlaybackProgress(
          video.videoId, video.backendPlayback, position,
          playing: current.playing &&
              current.processingState == ProcessingState.ready);
    }
    EasyThrottle.throttle('audio-progress', const Duration(seconds: 1), () {
      if (isClosed ||
          !_ownsParentPlayback ||
          current == null ||
          !identical(audioPlayer, current) ||
          _awaitingBackendMetadata) {
        return;
      }
      emit(state.copyWith(audioPosition: position));
      player.setEvent(MediaEvent(
          state: MediaState.playing,
          type: MediaEventType.progress,
          value: position));
    });
  }

  void onPlaybackError(Object error) {
    final current = audioPlayer;
    if (isClosed ||
        !_ownsParentPlayback ||
        !player.state.isAudio ||
        current == null ||
        _terminalErrorSent ||
        _loadingGeneration == _playbackGeneration) {
      // Source-load errors also complete setAudioSource with an error. The
      // source loop owns those failures, so a native event cannot retry twice.
      return;
    }
    final generation = _playbackGeneration;
    if (_playbackOffline ||
        error is! PlayerException ||
        !error.backendRetryable ||
        state.video?.backendPlayback == null) {
      _failPlayback(error);
      return;
    }
    _loadingGeneration = generation;
    final resumeAt = current.position;
    emit(state.copyWith(loading: true));
    unawaited(_loadAudioSource(current, generation,
            offline: false, startAt: resumeAt, firstError: error)
        .then((loaded) {
      if (loaded && !isClosed && generation == _playbackGeneration) {
        super.playVideo(false);
      }
    }));
  }

  void _failPlayback(Object error) {
    if (isClosed || _terminalErrorSent) return;
    _terminalErrorSent = true;
    // Native and metadata exceptions may contain signed URLs or request data.
    log.warning('Audio playback failed (${error.runtimeType})');
    player.setEvent(const MediaEvent(state: MediaState.error));
    emit(state.copyWith(error: 'Audio playback failed', loading: false));
  }

  Future<bool> _loadAudioSource(AudioPlayer current, int generation,
      {required bool offline,
      required Duration? startAt,
      Object? firstError}) async {
    var video = state.video;
    final offlineVideo = state.offlineVideo;
    final parentGeneration = player.backendPlaybackGeneration;
    bool active() =>
        !isClosed &&
        parentGeneration == player.backendPlaybackGeneration &&
        player.state.isAudio &&
        generation == _playbackGeneration &&
        identical(audioPlayer, current) &&
        (offline
            ? identical(state.offlineVideo, offlineVideo)
            : identical(state.video, video));
    Object? failure = firstError;
    try {
      while (active()) {
        if (failure != null) {
          if (offline ||
              failure is! PlayerException ||
              !failure.backendRetryable ||
              video?.backendPlayback == null) {
            throw failure;
          }
          _backendMetadataGeneration = generation;
          Video? next;
          try {
            next = await service.retryVideoBackend(video!, isCurrent: active,
                onRetry: (request) {
              if (active() &&
                  player.setRequestedBackend(video!.videoId, request)) {
                player.setEvent(MediaEvent(
                    state: MediaState.loading,
                    type: MediaEventType.backendRetry,
                    value: request.label));
              }
            });
          } finally {
            if (_backendMetadataGeneration == generation) {
              _backendMetadataGeneration = null;
            }
          }
          if (!active()) return false;
          if (next == null) throw failure;
          video = next;
          emit(state.copyWith(
              video: next,
              audioLength: Duration(seconds: next.lengthSeconds ?? 0),
              loading: true,
              error: null));
          failure = null;
        }
        try {
          AudioSource? source;
          if (offline) {
            final path = await offlineVideo!.effectivePath;
            if (!active()) return false;
            source = AudioSource.file(path);
          } else {
            final selectedServer = await db.getCurrentlySelectedServer();
            if (!active()) return false;
            final playback = video?.backendPlayback;
            if (playback != null && !playback.matches(selectedServer)) {
              throw StateError('Playback context changed');
            }
            final server = playback?.server ?? selectedServer;
            player.setRequestedBackend(video!.videoId, playback);
            if (service.useProxy()) {
              // Proxy audio uses a supported combined stream.
              final streams = (video.formatStreams ?? [])
                  .where((stream) => !stream.isLegacyHd720);
              if (streams.isNotEmpty) {
                final stream = streams.last;
                source = AudioSource.uri(Uri.parse(stream.url),
                    headers: server.headersForUrl(stream.url));
              }
            } else {
              final AdaptiveFormat? audio = (video.adaptiveFormats ?? [])
                  .where((element) => element.type.contains("audio"))
                  .sortByReversed((e) => int.tryParse(e.bitrate ?? "0") ?? 0)
                  .firstOrNull;
              if (audio != null) {
                source = AudioSource.uri(Uri.parse(audio.url),
                    headers: server.headersForUrl(audio.url));
              }
            }
          }
          if (source == null) {
            throw StateError('No supported audio source');
          }
          await current.setAudioSource(source, initialPosition: startAt);
          if (!active()) return false;
          // A speed or pause selection made during recovery wins over the
          // values that were active when the request began.
          await current.setSpeed(_playbackSpeed);
          if (!active()) return false;
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
            await current
                .setPitch(pitchFactorForSemitones(_playbackPitchSemitones));
          }
          if (!active()) return false;
          _reportPitch(_playbackPitchSemitones);
          _loadingGeneration = null;
          if (_wantsToPlay) {
            play();
          } else {
            pause();
          }
          emit(state.copyWith(loading: false, error: null));
          if (video != null && active()) {
            player.reportBackendPlaybackReady(
                video.videoId, video.backendPlayback,
                playing: _wantsToPlay);
          }
          return true;
        } catch (error) {
          if (!active()) return false;
          failure = error;
        }
      }
    } catch (error) {
      if (active()) _failPlayback(error);
    } finally {
      if (_loadingGeneration == generation) _loadingGeneration = null;
    }
    return false;
  }

  @override
  Future<void> playVideo(bool offline, {Duration? startAt}) async {
    if (!player.state.isAudio) return;
    if (state.video == null && state.offlineVideo == null) return;
    final generation = ++_playbackGeneration;
    _parentPlaybackGeneration = player.backendPlaybackGeneration;
    _loadingGeneration = generation;
    _backendMetadataGeneration = null;
    _playbackOffline = offline;
    _wantsToPlay =
        !offline && state.video?.backendPlayback?.manualSelection == true
            ? player.requestedPlaying
            : true;
    _terminalErrorSent = false;
    final videoId =
        offline ? state.offlineVideo!.videoId : state.video!.videoId;
    _playbackPitchSemitones = player.pitchForVideo(videoId);
    initPlayer();
    final current = audioPlayer;
    if (current == null) {
      _loadingGeneration = null;
      return;
    }
    if (_speedVideoId != videoId) {
      _speedVideoId = videoId;
      _playbackSpeed =
          settings.state.rememberPlayBackSpeed ? settings.state.lastSpeed : 1;
    }
    final audioLength = Duration(
        seconds: offline
            ? state.offlineVideo!.lengthSeconds
            : (state.video!.lengthSeconds ?? 0));
    if (startAt == null) {
      final progress = db.getVideoProgress(videoId);
      if (progress > 0 && progress < 0.9) {
        startAt = Duration(seconds: (audioLength.inSeconds * progress).floor());
      }
    }
    emit(state.copyWith(
        audioPosition: Duration.zero,
        audioLength: audioLength,
        loading: true,
        error: null));
    player.setEvent(const MediaEvent(state: MediaState.loading));
    final loaded = await _loadAudioSource(current, generation,
        offline: offline, startAt: startAt);
    if (loaded && !isClosed && generation == _playbackGeneration) {
      super.playVideo(offline);
    }
  }

  @override
  double getAspectRatio() {
    return 16 / 9;
  }

  @override
  void switchToOfflineVideo(DownloadedVideo v) {
    emit(state.copyWith(video: null, offlineVideo: v));
    playVideo(true);
  }

  @override
  void switchVideo(Video video, {Duration? startAt}) async {
    emit(state.copyWith(video: video, offlineVideo: null));
    playVideo(false, startAt: startAt);
  }

  @override
  void togglePlaying() {
    var state = this.state.copyWith();
    _wantsToPlay ? pause() : play();
    emit(state);
  }

  void onScrubbed(double value) {
    Duration seekTo = Duration(milliseconds: value.toInt());
    seek(seekTo);
    emit(state.copyWith(audioPosition: seekTo));
  }

  void onScrubDrag(double value) {
    Duration seekTo = Duration(milliseconds: value.toInt());
    emit(state.copyWith(audioPosition: seekTo));
  }

  @override
  void toggleControls(bool visible) {
    emit(state.copyWith(disableControls: !visible));
  }

  @override
  bool isPlaying() {
    return playing;
  }

  @override
  void play() {
    _wantsToPlay = true;
    if (_loadingGeneration != _playbackGeneration) audioPlayer?.play();
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
  }

  @override
  void seek(Duration position) {
    audioPlayer?.seek(position);
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.seek));
    player.setEvent(MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.progress,
        value: position));
  }

  @override
  void pause() {
    _wantsToPlay = false;
    audioPlayer?.pause();
    player.setEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.pause));
  }

  @override
  Duration? bufferedPosition() {
    return audioPlayer?.bufferedPosition;
  }

  @override
  Duration position() {
    return state.audioPosition;
  }

  @override
  double? speed() {
    return 1;
  }

  @override
  List<String> getVideoTracks() {
    return [];
  }

  @override
  List<String> getAudioTracks() {
    return [];
  }

  @override
  List<String> getSubtitles() {
    return [];
  }

  @override
  int selectedAudioTrack() {
    return 0;
  }

  @override
  int selectedSubtitle() {
    return 0;
  }

  @override
  int selectedVideoTrack() {
    return 0;
  }

  @override
  selectAudioTrack(int index) {
    return 0;
  }

  @override
  selectSubtitle(int index) {}

  @override
  selectVideoTrack(int index) {}

  @override
  bool isMuted() {
    return (audioPlayer?.volume ?? 0) == 0;
  }

  @override
  void toggleVolume(bool soundOn) {
    audioPlayer?.setVolume(soundOn ? 1 : 0);
  }

  @override
  void setSpeed(double d) {
    _playbackSpeed = d;
    audioPlayer?.setSpeed(d);
    settings.setLastSpeed(d);
  }

  @override
  double getSpeed() {
    return audioPlayer?.speed ?? 1;
  }

  @override
  void setPitchSemitones(int semitones) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _playbackPitchSemitones = clampPitchSemitones(semitones);
    audioPlayer?.setPitch(pitchFactorForSemitones(_playbackPitchSemitones));
    _reportPitch(_playbackPitchSemitones);
  }

  @override
  int getPitchSemitones() => _playbackPitchSemitones;

  @override
  bool hasDashToggle() {
    return false;
  }

  @override
  void toggleDash() {
    // TODO: implement toggleDash
  }

  @override
  bool isUsingDash() {
    // TODO: implement isUsingDash
    throw UnimplementedError();
  }

  @override
  Duration duration() {
    return audioPlayer?.duration ?? const Duration(milliseconds: 1);
  }

  void onBufferChanged(Duration event) {
    if (_awaitingBackendMetadata) return;
    final current = audioPlayer;
    EasyThrottle.throttle('audio-buffering', const Duration(seconds: 1), () {
      if (isClosed ||
          !_ownsParentPlayback ||
          current == null ||
          !identical(audioPlayer, current) ||
          _awaitingBackendMetadata) {
        return;
      }
      player.setEvent(MediaEvent(
          state: MediaState.playing,
          type: MediaEventType.bufferChanged,
          value: event));
    });
  }

  bool get playing => audioPlayer?.playing ?? false;
}

@freezed
sealed class AudioPlayerState extends MediaPlayerState with _$AudioPlayerState {
  const factory AudioPlayerState({
    @Default(Duration(milliseconds: 1)) Duration audioLength,
    @Default(Duration.zero) Duration audioPosition,
    @Default(0) int previousSponsorCheck,
    Video? video,
    DownloadedVideo? offlineVideo,
    bool? playNow,
    bool? disableControls,
    @Default(false) bool loading,
    String? error,
  }) = _AudioPlayerState;

  double get progress =>
      audioPosition.inMilliseconds / audioLength.inMilliseconds;

  const AudioPlayerState._();
}
