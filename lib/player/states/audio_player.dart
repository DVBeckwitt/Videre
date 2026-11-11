import 'dart:async';

import 'package:easy_debounce/easy_throttle.dart';
import 'package:audio_session/audio_session.dart';
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
import '../media_source.dart';
import '../models/media_command.dart';
import '../models/media_event.dart';
import '../models/backend_playback.dart';
import '../models/audio_stall_detector.dart';
import '../models/playback_pitch.dart';

part 'audio_player.freezed.dart';

Logger log = Logger('AudioPlayerController');
const _maxAudioSources = 10;

class _AudioPlaybackStall implements Exception {
  const _AudioPlaybackStall();
}

bool _retryableAudioFailure(Object error) =>
    error is _AudioPlaybackStall ||
    (error is PlayerException && error.backendRetryable);

class AudioPlayerCubit extends MediaPlayerCubit<AudioPlayerState> {
  AudioPlayer? audioPlayer;
  final SettingsCubit settings;
  int _playbackGeneration = 0;
  int _parentPlaybackGeneration = 0;
  bool get _ownsParentPlayback =>
      _parentPlaybackGeneration == player.backendPlaybackGeneration;
  double _playbackSpeed = 1;
  int _playbackPitchSemitones = 0;
  int? _loadingGeneration;
  int? _backendMetadataGeneration;
  Duration? _pendingSeek;
  bool _playbackOffline = false;
  bool _wantsToPlay = true;
  bool _terminalErrorSent = false;
  int? _manualRetryGeneration;
  bool _sourceAdmitted = false;
  int _sourceLoadRevision = 0;
  int _stallRevision = 0;
  final _stallDetector = AudioStallDetector();
  Timer? _stallTimer;
  bool _focusInterrupted = false;
  bool _resumeAfterFocus = false;
  bool _deferredFocusResume = false;
  int? _focusGeneration;
  AudioPlayer? _nativeProgressOwner;
  Future<({int revision, NativePlaybackProgress? sample})>?
      _nativeProgressRequest;
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
    _pendingSeek = null;
    _wantsToPlay = false;
    _sourceAdmitted = false;
    _resumeAfterFocus = false;
    _deferredFocusResume = false;
    _focusInterrupted = false;
    _sourceLoadRevision++;
    _stopStallWatch(forgetProgress: true);
    _nativeProgressOwner = null;
    _nativeProgressRequest = null;
    final current = audioPlayer;
    audioPlayer = null;
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
      unawaited(_listenForAudioInterruptions(current));
      bool active() =>
          !isClosed &&
          !_terminalErrorSent &&
          _ownsParentPlayback &&
          identical(audioPlayer, current);
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
          if (active() &&
              !_awaitingBackendMetadata &&
              _loadingGeneration == null) {
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

  Future<void> _listenForAudioInterruptions(AudioPlayer current) async {
    final session = await AudioSession.instance;
    if (isClosed || !identical(audioPlayer, current)) return;
    _playerSubscriptions
        .add(session.interruptionEventStream.listen(handleAudioInterruption));
  }

  @visibleForTesting
  void handleAudioInterruption(AudioInterruptionEvent event) {
    if (isClosed || !_ownsParentPlayback) return;
    final endingDuck = !event.begin && event.type == AudioInterruptionType.duck;
    if (event.type == AudioInterruptionType.duck &&
        (!endingDuck || !_focusInterrupted)) {
      return;
    }
    _stopStallWatch();
    if (event.begin) {
      // Permanent loss abandons Android's focus request and may never produce
      // an end event. Cancel automatic resume, but allow a later explicit Play
      // to reach just_audio, which requests audio focus before playing.
      _focusInterrupted = event.type == AudioInterruptionType.pause;
      _focusGeneration = _playbackGeneration;
      _resumeAfterFocus =
          event.type == AudioInterruptionType.pause && _wantsToPlay;
      if (event.type == AudioInterruptionType.unknown) {
        _wantsToPlay = false;
        _deferredFocusResume = false;
      }
      return;
    }
    _focusInterrupted = false;
    final resume = (event.type == AudioInterruptionType.pause || endingDuck) &&
        _resumeAfterFocus &&
        (_deferredFocusResume || endingDuck) &&
        _focusGeneration == _playbackGeneration;
    _resumeAfterFocus = false;
    _deferredFocusResume = false;
    final generation = _playbackGeneration;
    // just_audio owns ordinary pause/resume, but a later duck cancels its
    // remembered pause. Release that blocking pause on gain, as well as any
    // source recovery explicitly deferred while focus was unavailable.
    if (resume) {
      scheduleMicrotask(() {
        if (!isClosed &&
            generation == _playbackGeneration &&
            _ownsParentPlayback &&
            !_terminalErrorSent &&
            _loadingGeneration == null &&
            _wantsToPlay &&
            !_focusInterrupted &&
            !player.playbackInterrupted) {
          play();
        }
      });
    }
  }

  bool get _awaitingBackendMetadata =>
      _backendMetadataGeneration == _playbackGeneration;

  void _stopStallWatch({bool forgetProgress = false}) {
    _stallTimer?.cancel();
    _stallTimer = null;
    _stallRevision++;
    _stallDetector.reset(forgetProgress: forgetProgress);
  }

  bool _canWatchProgress(AudioPlayer current) =>
      !isClosed &&
      !_terminalErrorSent &&
      _ownsParentPlayback &&
      player.state.isAudio &&
      !_playbackOffline &&
      _sourceAdmitted &&
      state.video != null &&
      _loadingGeneration == null &&
      !_awaitingBackendMetadata &&
      _wantsToPlay &&
      !_focusInterrupted &&
      !player.playbackInterrupted &&
      player.shouldStartPlayback &&
      identical(audioPlayer, current) &&
      current.playing;

  void _startStallWatch() {
    final current = audioPlayer;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        current == null ||
        !_canWatchProgress(current)) {
      return;
    }
    _stallTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(checkForStalledPlayback());
    });
  }

  Future<({int revision, NativePlaybackProgress? sample})> _nativeProgress(
      AudioPlayer current) {
    final pending = _nativeProgressRequest;
    if (pending != null && identical(_nativeProgressOwner, current)) {
      return pending;
    }
    final revision = _sourceLoadRevision;
    late final Future<({int revision, NativePlaybackProgress? sample})> request;
    request =
        Future<NativePlaybackProgress?>.sync(current.getNativePlaybackProgress)
            .catchError((Object _) => null)
            .then((sample) => (revision: revision, sample: sample))
            .whenComplete(() {
      if (identical(_nativeProgressRequest, request)) {
        _nativeProgressRequest = null;
        _nativeProgressOwner = null;
        _startStallWatch();
      }
    });
    _nativeProgressOwner = current;
    return _nativeProgressRequest = request;
  }

  /// Fresh native snapshots establish progress; the animated Dart position
  /// stream extrapolates time and cannot establish a silent decoder stall.
  @visibleForTesting
  Future<void> checkForStalledPlayback() async {
    final current = audioPlayer;
    if (current == null || !_canWatchProgress(current)) {
      _stopStallWatch();
      return;
    }
    // Timer ticks share one platform request. A delayed sample is not failure.
    if (_nativeProgressRequest != null) return;
    final generation = _playbackGeneration;
    final revision = _stallRevision;
    final video = state.video!;
    final result = await _nativeProgress(current).timeout(
        const Duration(seconds: 3),
        onTimeout: () => (revision: _sourceLoadRevision, sample: null));
    if (generation != _playbackGeneration ||
        revision != _stallRevision ||
        result.revision != _sourceLoadRevision ||
        !identical(state.video, video) ||
        !_canWatchProgress(current)) {
      return;
    }
    final sample = result.sample;
    if (sample == null) {
      _stopStallWatch();
      return;
    }
    final playing = sample.playWhenReady &&
        sample.isPlaying &&
        sample.processingState == ProcessingState.ready &&
        sample.suppressionReason == 0 &&
        !sample.seekPending &&
        !sample.hasError;
    player.reportPlaybackRecoveryProgress(video, sample.position,
        playing: playing);
    player.reportBackendPlaybackProgress(
        video.videoId, video.backendPlayback, sample.position,
        playing: playing);
    if (_stallDetector.observe(sample, eligible: true)) {
      _beginPlaybackRecovery(current, const _AudioPlaybackStall(),
          resumeAt: sample.position);
    }
  }

  void onStateStreamChange(PlayerState state) {
    if (_terminalErrorSent ||
        !_ownsParentPlayback ||
        _awaitingBackendMetadata) {
      return;
    }
    log.fine('Player state event $state');
    if (!state.playing) {
      _stopStallWatch();
    } else {
      _startStallWatch();
    }
    switch (state.processingState) {
      case ProcessingState.idle:
        // looks like this is causing issues with the player control notification
        // MiniPlayerController.to()?.eventStream.add(MediaEvent(state: MediaState.idle));
        break;
      case ProcessingState.loading:
        player.setEvent(const MediaEvent(state: MediaState.loading));
        break;
      case ProcessingState.buffering:
        // Audio focus can interrupt or resume playback before buffering ends.
        final changed = _loadingGeneration == null &&
            state.playing != player.state.isPlaying;
        player.setEvent(MediaEvent(
            state: MediaState.buffering,
            type: changed
                ? (state.playing ? MediaEventType.play : MediaEventType.pause)
                : null));
        break;
      case ProcessingState.ready:
        final video = this.state.video;
        if (video != null && _loadingGeneration == null) {
          player.reportPlaybackRecoveryReady(video, playing: state.playing);
          player.reportBackendPlaybackReady(
              video.videoId, video.backendPlayback,
              playing: state.playing);
        }
        player.setEvent(const MediaEvent(state: MediaState.ready));
        if (_loadingGeneration == null) {
          // Audio focus changes can pause/resume the native decoder without a
          // UI command. Keep transport controls and notifications in sync.
          player.setEvent(MediaEvent(
              state: MediaState.playing,
              type:
                  state.playing ? MediaEventType.play : MediaEventType.pause));
        }
        break;
      case ProcessingState.completed:
        _sourceAdmitted = false;
        _stopStallWatch();
        player.setEvent(const MediaEvent(state: MediaState.completed));
        break;
    }
  }

  void onDurationChanged(Duration? duration) {
    if (isClosed ||
        _terminalErrorSent ||
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
    if (_terminalErrorSent ||
        !_ownsParentPlayback ||
        _awaitingBackendMetadata ||
        _loadingGeneration != null) {
      return;
    }
    final current = audioPlayer;
    EasyThrottle.throttle('audio-progress', const Duration(seconds: 1), () {
      if (isClosed ||
          _terminalErrorSent ||
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
    if (_playbackOffline ||
        !_sourceAdmitted ||
        !_retryableAudioFailure(error) ||
        state.video == null) {
      _failPlayback(error);
      return;
    }
    _beginPlaybackRecovery(current, error);
  }

  void _beginPlaybackRecovery(AudioPlayer current, Object error,
      {Duration? resumeAt}) {
    if (_loadingGeneration != null || _terminalErrorSent || isClosed) return;
    final generation = _playbackGeneration;
    final parentGeneration = player.backendPlaybackGeneration;
    final sourceRevision = _sourceLoadRevision;
    _loadingGeneration = generation;
    _stopStallWatch();
    emit(state.copyWith(loading: true));
    unawaited(() async {
      // Error callbacks may arrive while the Dart animation still extrapolates
      // progress. Prefer the native playhead; never use a seek target as proof.
      final initialPosition = resumeAt ?? current.position;
      final sample = resumeAt == null
          ? await _nativeProgress(current).timeout(const Duration(seconds: 3),
              onTimeout: () => (revision: sourceRevision, sample: null))
          : null;
      if (isClosed ||
          generation != _playbackGeneration ||
          parentGeneration != player.backendPlaybackGeneration ||
          !identical(audioPlayer, current)) {
        return;
      }
      final measured = sample?.revision == sourceRevision &&
              sample?.sample?.seekPending == false
          ? sample?.sample?.position
          : null;
      final loaded = await _loadAudioSource(current, generation,
          offline: false,
          startAt: resumeAt ?? measured ?? initialPosition,
          firstError: error,
          allowStreamRefresh: true);
      if (loaded && !isClosed && generation == _playbackGeneration) {
        super.playVideo(false);
      }
    }());
  }

  void _failPlayback(Object error) {
    if (isClosed || _terminalErrorSent) return;
    _terminalErrorSent = true;
    _stopStallWatch();
    // A failed source is not playing. Publish pause before the error so the
    // controls and notification stop without hiding the actionable failure.
    pause();
    // Native and metadata exceptions may contain signed URLs or request data.
    log.warning('Audio playback failed (${error.runtimeType})');
    player.setEvent(const MediaEvent(state: MediaState.error));
    emit(state.copyWith(error: 'Audio playback failed', loading: false));
  }

  Future<bool> _loadAudioSource(AudioPlayer current, int generation,
      {required bool offline,
      required Duration? startAt,
      Object? firstError,
      bool allowStreamRefresh = false}) async {
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
          if (offline || !_retryableAudioFailure(failure) || video == null) {
            throw failure;
          }
          _backendMetadataGeneration = generation;
          Video? next;
          var sameRoute = false;
          try {
            if (allowStreamRefresh) {
              try {
                next = await player.refreshCurrentPlayback(video,
                    isCurrent: active);
                sameRoute = next != null;
              } catch (error) {
                if (!active()) return false;
                if (!isBackendRetryable(error)) rethrow;
                // Only a classified transient refresh failure can proceed to
                // the existing, separately bounded alternate-backend policy.
              }
            }
            if (!active()) return false;
            if (next == null && video.backendPlayback != null) {
              next = await service.retryVideoBackend(video, isCurrent: active,
                  onRetry: (request) {
                if (active() &&
                    player.setRequestedBackend(video!.videoId, request)) {
                  player.setEvent(MediaEvent(
                      state: MediaState.loading,
                      type: MediaEventType.backendRetry,
                      value: request.label));
                }
              });
            }
          } finally {
            if (_backendMetadataGeneration == generation) {
              _backendMetadataGeneration = null;
            }
          }
          if (!active()) return false;
          if (next == null) throw failure;
          next = next.preservingMusicMetadataFrom(video);
          video = next;
          if (!sameRoute) player.reportBackendVideoLoaded(next);
          emit(state.copyWith(
              video: next,
              audioLength: Duration(seconds: next.lengthSeconds ?? 0),
              loading: true,
              error: null));
          failure = null;
        }
        try {
          final sources = <AudioSource>[];
          if (offline) {
            final path = await offlineVideo!.effectivePath;
            if (!active()) return false;
            sources.add(Uri.tryParse(path)?.scheme == 'content'
                ? AudioSource.uri(Uri.parse(path))
                : AudioSource.file(path));
          } else {
            final selectedServer = await db.getCurrentlySelectedServer();
            if (!active()) return false;
            final playback =
                video?.backendPlayback ?? video?.playbackConnection;
            if (playback != null && !playback.matches(selectedServer)) {
              throw StateError('Playback context changed');
            }
            final server = playback?.server ?? selectedServer;
            player.setRequestedBackend(video!.videoId, video.backendPlayback);
            final combined = (video.formatStreams ?? [])
                .where((stream) => !stream.isLegacyHd720)
                .toList()
                .reversed
                .map((stream) => stream.url);
            final adaptive = (video.adaptiveFormats ?? <AdaptiveFormat>[])
                .where((format) => format.type.startsWith('audio/'))
                .sortByReversed(
                    (format) => int.tryParse(format.bitrate ?? '') ?? 0)
                .map((format) => format.url);
            // Audio playback should not depend on a combined video stream.
            // Keep combined formats as a fallback for missing usable audio.
            final candidates = [...adaptive, ...combined];
            final seen = <String>{};
            for (final candidate in candidates) {
              final parsed = parseMediaUrl(candidate);
              if (parsed == null) continue;
              final url =
                  validatedMediaUrl(proxyMediaUrl(parsed, server), server);
              if (url == null || !seen.add(url)) continue;
              sources.add(AudioSource.uri(Uri.parse(url),
                  headers: mediaHeaders(server, url)));
              if (sources.length >= _maxAudioSources) break;
            }
          }
          if (sources.isEmpty) {
            throw StateError('No supported audio source');
          }
          for (var index = 0; index < sources.length; index++) {
            try {
              // just_audio can carry its native Play intent into a new source.
              // Restore intent only after setup and the latest parent/focus
              // checks, including a Pause whose child command is still queued.
              if (current.playing) await current.pause();
              if (!active()) return false;
              _sourceLoadRevision++;
              await current.setAudioSource(sources[index],
                  initialPosition: _pendingSeek ?? startAt);
              break;
            } catch (error) {
              if (!active()) return false;
              // An unavailable audio track need not make the whole backend
              // unusable. Try its remaining admitted formats first. Access
              // refusals and non-retryable failures retain their terminal path.
              if (index == sources.length - 1 ||
                  error is! PlayerException ||
                  !error.backendRetryable) {
                rethrow;
              }
            }
          }
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
          // Seeking the old source while metadata or native setup is pending
          // would be overwritten by the replacement's initial position. Apply
          // the latest request after all asynchronous setup has finished.
          while (_pendingSeek != null) {
            final position = _pendingSeek!;
            _pendingSeek = null;
            startAt = position;
            if (current.position != position) await current.seek(position);
            if (!active()) return false;
          }
          // Publish the admitted position before any play/rate event:
          // MediaSession extrapolates progress from those events.
          final position = current.position;
          emit(state.copyWith(audioPosition: position));
          player.setEvent(MediaEvent<Duration>(
              state: MediaState.ready,
              type: MediaEventType.progress,
              value: position));
          super.setSpeed(_playbackSpeed);
          _reportPitch(_playbackPitchSemitones);
          _loadingGeneration = null;
          _sourceAdmitted = true;
          final interrupted = _focusInterrupted || player.playbackInterrupted;
          if (_wantsToPlay && player.shouldStartPlayback && !interrupted) {
            play();
          } else if (interrupted) {
            // Preserve temporary-focus intent while preventing source setup
            // from starting audio before the interruption has ended.
            _deferredFocusResume = _wantsToPlay;
            if (current.playing) await current.pause();
            if (!active()) return false;
            player.setEvent(const MediaEvent(
                state: MediaState.playing, type: MediaEventType.pause));
          } else {
            pause();
          }
          emit(state.copyWith(loading: false, error: null));
          if (video != null && active()) {
            player.reportPlaybackRecoveryReady(video,
                playing:
                    _wantsToPlay && player.shouldStartPlayback && !interrupted);
            player.reportBackendPlaybackReady(
                video.videoId, video.backendPlayback,
                playing:
                    _wantsToPlay && player.shouldStartPlayback && !interrupted);
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
    _pendingSeek = null;
    _sourceAdmitted = false;
    _resumeAfterFocus = false;
    _deferredFocusResume = false;
    _stopStallWatch(forgetProgress: true);
    _playbackOffline = offline;
    _wantsToPlay = player.shouldStartPlayback;
    _terminalErrorSent = false;
    final videoId =
        offline ? state.offlineVideo!.videoId : state.video!.videoId;
    _playbackPitchSemitones = player.pitchForVideo(videoId);
    _playbackSpeed = player.speedForVideo(videoId);
    initPlayer();
    final current = audioPlayer;
    if (current == null) {
      _loadingGeneration = null;
      return;
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
    playVideo(true, startAt: player.state.startAt);
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
  void handleCommand(MediaCommand command) {
    if (_terminalErrorSent && command.type == MediaCommandType.pause) {
      // Parent Retry can publish its error before this queued command arrives.
      // Pause natively without replacing the failure's visible state.
      _wantsToPlay = false;
      _stopStallWatch();
      audioPlayer?.pause();
      return;
    }
    if (command.type == MediaCommandType.play &&
        (_terminalErrorSent || _loadingGeneration == _playbackGeneration)) {
      // The base handler announces Play immediately after dispatch. A failed
      // decoder must reload first, and publish Play only after source admission.
      play();
      return;
    }
    super.handleCommand(command);
  }

  @override
  void play() {
    if (_terminalErrorSent) {
      if (state.offlineVideo == null) {
        unawaited(_retryAfterFailure());
      } else {
        unawaited(playVideo(state.offlineVideo != null,
            startAt: player.state.position));
      }
      return;
    }
    _wantsToPlay = true;
    if (_focusInterrupted || player.playbackInterrupted) {
      // A newer explicit Play supersedes a Pause made during a temporary
      // interruption, without playing before focus returns.
      _focusGeneration = _playbackGeneration;
      _resumeAfterFocus = true;
      _deferredFocusResume = true;
      return;
    }
    if (_loadingGeneration == _playbackGeneration ||
        !player.shouldStartPlayback) {
      return;
    }
    audioPlayer?.play();
    _startStallWatch();
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
  }

  Future<void> _retryAfterFailure() async {
    final generation = _playbackGeneration;
    if (isClosed ||
        !player.state.isAudio ||
        !_ownsParentPlayback ||
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
        // Failed fresh metadata retains this decoder's actionable error. A
        // later explicit Play may retry the same retained queue occurrence.
        _parentPlaybackGeneration = parentGeneration;
      }
    } catch (_) {
      // Keep the existing error without exposing request or credential data.
    } finally {
      if (_manualRetryGeneration == generation) _manualRetryGeneration = null;
    }
  }

  @override
  void seek(Duration position) {
    _stopStallWatch(forgetProgress: true);
    if (_loadingGeneration == _playbackGeneration) {
      _pendingSeek = position;
    } else {
      audioPlayer?.seek(position);
    }
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.seek));
    player.setEvent(MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.progress,
        value: position));
    _startStallWatch();
  }

  @override
  void pause() {
    _wantsToPlay = false;
    _resumeAfterFocus = false;
    _deferredFocusResume = false;
    _stopStallWatch();
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
    super.setSpeed(d);
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
    if (_terminalErrorSent || _awaitingBackendMetadata) return;
    final current = audioPlayer;
    EasyThrottle.throttle('audio-buffering', const Duration(seconds: 1), () {
      if (isClosed ||
          _terminalErrorSent ||
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
