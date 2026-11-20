import 'dart:async';

import 'package:easy_debounce/easy_throttle.dart';
import 'package:audio_session/audio_session.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:flutter/foundation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../../settings/states/settings.dart';
import '../../music/models/song_transition.dart';
import '../../videos/models/ided_video.dart';
import '../../network/network_proxy.dart';
import '../audio_playback_sources.dart';
import '../models/playback_queue.dart';
import '../models/media_command.dart';
import '../models/media_event.dart';
import '../models/backend_playback.dart';
import '../models/audio_stall_detector.dart';
import '../models/playback_pitch.dart';
import '../models/music_audio_quality.dart';
import '../models/local_music_playback.dart';
import '../models/manual_music_preparation.dart';

part 'audio_player.freezed.dart';
part 'song_transition_playback.dart';
part 'manual_music_playback.dart';

Logger log = Logger('AudioPlayerController');

class _AudioPlaybackStall implements Exception {
  const _AudioPlaybackStall();
}

bool _retryableAudioFailure(Object error) =>
    error is _AudioPlaybackStall ||
    (error is PlayerException && error.backendRetryable);

class _StandbyAudio {
  final IdedVideo entry;
  final AudioPlayer decoder;
  late Future<AudioPlaybackSources?> ready;
  bool failed = false;

  _StandbyAudio(this.entry, this.decoder);

  bool matches(IdedVideo candidate) {
    if (playbackQueueId(entry) != playbackQueueId(candidate)) return false;
    final original = entry;
    if (original is DownloadedVideo &&
        isLocalMusicPlaybackId(original.videoId)) {
      // Local queue entries are rebuilt from the granted document at selection.
      // Their display metadata can change without changing the playable bytes.
      final track = localMusicTrackForPlayback(original.videoId);
      return candidate is DownloadedVideo &&
          track != null &&
          candidate.audioOnly &&
          original.audioOnly &&
          original.profileId == db.profileId &&
          candidate.profileId == db.profileId &&
          original.storageUri == track.uri &&
          candidate.storageUri == track.uri;
    }
    if (original == candidate) return true;
    return original is Video &&
        candidate is Video &&
        original.videoId == candidate.videoId &&
        original.playbackSourceId != null &&
        identical(original.playbackSourceId, candidate.playbackSourceId) &&
        identical(original.backendPlayback ?? original.playbackConnection,
            candidate.backendPlayback ?? candidate.playbackConnection);
  }
}

class AudioPlayerCubit extends MediaPlayerCubit<AudioPlayerState>
    implements ManualMusicPreparer {
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
  bool _downloadReuseFailed = false;
  bool _usingDownloadedSource = false;
  MusicAudioQuality? _qualityPreference;
  MusicAudioQualityMenu? _publishedQuality;
  int _sourceLoadRevision = 0;
  int? _completedSourceRevision;
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
  final _standbys = <String, _StandbyAudio>{};
  StreamSubscription<SettingsState>? _qualityChanges;
  Map<String, IdedVideo> _adjacentEntries = const {};
  final _retiring = <Future<void>>{};
  _StandbyAudio? _promoted;
  _ManualMusicDecoder? _manual;
  late final _transition = _SongTransitionPlayback(this);
  final _playerSubscriptions = <StreamSubscription<dynamic>>[];

  AudioPlayerCubit(super.initialState, super.player, this.settings) {
    onInit();
  }

  @override
  Future<void> close() async {
    if (identical(player.manualMusicPreparer, this)) {
      player.manualMusicPreparer = null;
    }
    player.removeAdjacentMusicListener(_updateAdjacents);
    try {
      await stopForProxyChange();
    } finally {
      await _qualityChanges?.cancel();
      await super.close();
    }
  }

  void onInit() {
    player.manualMusicPreparer = this;
    initPlayer();
    playVideo(state.offlineVideo != null, startAt: player.state.startAt);
    player.addAdjacentMusicListener(_updateAdjacents);
    var previous = settings.state.musicStreamingQuality;
    _qualityChanges = settings.stream.listen((state) {
      final quality = state.musicStreamingQuality;
      if (quality == previous) return;
      previous = quality;
      for (final slot in _standbys.values) {
        if (slot.entry is! Video || slot.failed || slot.decoder.playing) {
          continue;
        }
        if (identical(slot, _transition.incoming)) _transition.stop();
        _refreshStandbyQuality(slot, quality);
      }
    });
  }

  @override
  void disposeControllers() {
    unawaited(stopForProxyChange());
  }

  @override
  Future<void> stopForProxyChange() {
    _adjacentEntries = const {};
    cancelMusicSelection();
    _transition.stop(release: true);
    _playbackGeneration++;
    _clearMusicQuality();
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
    _promoted = null;
    final standbys = _standbys.values.toList();
    _standbys.clear();
    for (final slot in standbys) {
      if (!slot.failed) _retire(slot.decoder.dispose());
    }
    final current = audioPlayer;
    audioPlayer = null;
    final clearingSound = current == null
        ? Future<void>.value()
        : player.musicSound.detach(current);
    EasyThrottle.cancel('audio-progress');
    EasyThrottle.cancel('audio-buffering');
    final subscriptions = List.of(_playerSubscriptions);
    _playerSubscriptions.clear();
    if (current == null && subscriptions.isEmpty && _retiring.isEmpty) {
      return _disposal ?? Future<void>.value();
    }
    final retiring = _retiring.toList();
    final previous = _disposal;
    final disposal = () async {
      await clearingSound;
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await current?.dispose();
      await Future.wait(retiring);
      await previous;
    }();
    _disposal = disposal;
    return disposal;
  }

  AudioPlayer _newDecoder() => AudioPlayer(
      // Keep recently played samples on the decoder so a rewind can reuse
      // them, including after a prepared song becomes the active song.
      audioLoadConfiguration: const AudioLoadConfiguration(
          androidLoadControl:
              AndroidLoadControl(backBufferDuration: Duration(seconds: 90))),
      // Preserve the selected instance origin for Android's native transport.
      useProxyForRequestHeaders:
          kIsWeb || defaultTargetPlatform != TargetPlatform.android);

  Future<void> _retire(Future<void> release) {
    final retired = release.onError((Object error, StackTrace _) {
      log.fine('Audio decoder cleanup failed (${error.runtimeType})');
    });
    _retiring.add(retired);
    unawaited(retired.then((_) => _retiring.remove(retired)));
    return retired;
  }

  Future<void> _pauseAndRetire(AudioPlayer old) {
    final pause = old.playing ? old.pause() : Future<void>.value();
    // A route change must await the outgoing decoder even if its pause
    // acknowledgement is still in flight.
    final retired = _retire(pause.whenComplete(old.dispose));
    return pause.onError((Object error, StackTrace stack) => retired);
  }

  @override
  Future<bool> prepareMusicSelection(
      IdedVideo entry, Duration startAt, bool Function() isCurrent) async {
    cancelMusicSelection();
    if (isClosed || player.isClosed || audioPlayer == null || !isCurrent()) {
      return false;
    }
    final id = playbackQueueId(entry);
    final adjacent = _standbys[id];
    // The automatic queue keeps its start-at-zero buffer while a manual request
    // loads a different part of the same song.
    final reuse = startAt == Duration.zero &&
        adjacent != null &&
        !adjacent.failed &&
        !adjacent.decoder.playing &&
        !identical(_transition.incoming, adjacent) &&
        adjacent.matches(entry);
    final slot = reuse
        ? _standbys.remove(id)!
        : (_StandbyAudio(entry, _newDecoder())..ready = Future.value(null));
    final request = _manual =
        _ManualMusicDecoder(slot, startAt, isCurrent, borrowedAdjacent: reuse);
    final ready =
        await Future.any([request.prepare(), request.cancelled.future]);
    if (!identical(_manual, request)) return false;
    if (ready && request.inScope && request.decoderReady) return true;
    final failure = request.inScope ? request.exhaustedSourceError : null;
    cancelMusicSelection();
    if (failure != null) throw ManualMusicSourceFailure(failure);
    return false;
  }

  @override
  void cancelMusicSelection() {
    final request = _manual;
    if (request == null) return;
    _manual = null;
    request.cancelled.complete(false);
    final slot = request.slot;
    final id = playbackQueueId(slot.entry);
    final wanted = _adjacentEntries[id];
    final restore = request.borrowedAdjacent &&
        wanted != null &&
        slot.matches(wanted) &&
        request.samePlaybackContext &&
        !isClosed &&
        !player.isClosed &&
        !player.state.isClosing &&
        !player.state.isHidden &&
        player.state.isAudio &&
        player.state.currentQueueId != id &&
        !_standbys.containsKey(id);
    if (restore && !request.changedDecoder) {
      // An unchanged queue won't publish its window again. Give it back its
      // original zero-position decoder, including a preload still in flight.
      _standbys[id] = slot;
    } else {
      _retire(slot.decoder.dispose());
      if (restore) _stage(wanted);
    }
  }

  void _updateAdjacents(List<IdedVideo> entries) {
    final currentEntry = state.video ?? state.offlineVideo;
    final wanted = <String, IdedVideo>{
      if (!isClosed &&
          audioPlayer != null &&
          player.state.isAudio &&
          !NetworkProxy.instance.isChanging)
        for (final entry in entries.take(2))
          if ((entry is Video && entry.musicMetadata != null ||
                  entry is DownloadedVideo && entry.musicMetadata != null) &&
              (currentEntry == null ||
                  playbackQueueId(entry) != playbackQueueId(currentEntry)))
            playbackQueueId(entry): entry,
    };
    _adjacentEntries = wanted;
    for (final id in _standbys.keys.toList()) {
      final slot = _standbys[id]!;
      final entry = wanted[id];
      if (entry != null && slot.matches(entry)) continue;
      if (identical(_transition.incoming, slot)) {
        _transition.stop(release: true);
      }
      _standbys.remove(id);
      if (!slot.failed) _retire(slot.decoder.dispose());
    }
    for (final item in wanted.entries) {
      if (_standbys.containsKey(item.key)) continue;
      final manual = _manual;
      if (manual != null &&
          manual.borrowedAdjacent &&
          manual.slot.matches(item.value)) {
        continue;
      }
      _stage(item.value);
    }
  }

  void _stage(IdedVideo entry) {
    final slot = _StandbyAudio(entry, _newDecoder());
    _standbys[playbackQueueId(entry)] = slot;
    slot.ready = _prepare(slot);
  }

  void _refreshStandbyQuality(
      _StandbyAudio slot, MusicStreamingQuality quality) {
    slot.ready = slot.ready.then((prepared) {
      if (prepared == null || prepared.streamingQuality == quality) {
        return prepared;
      }
      return _prepare(slot, previous: prepared);
    });
  }

  Future<AudioPlaybackSources?> _prepare(_StandbyAudio slot,
      {AudioPlaybackSources? previous}) async {
    final entry = slot.entry;
    final id = playbackQueueId(entry);
    final owner = db;
    final profileId = owner.profileId;
    final proxy = NetworkProxy.instance.config;
    bool active() =>
        !isClosed &&
        !player.isClosed &&
        identical(db, owner) &&
        db.profileId == profileId &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config) &&
        (identical(_standbys[id], slot) ||
            identical(_manual?.slot, slot) ||
            identical(_promoted, slot));
    try {
      if (!active()) return null;
      final offline = entry is DownloadedVideo ? entry : null;
      if (offline != null && offline.profileId != profileId) return null;
      final video = entry is Video ? entry : null;
      final sources = await resolveAudioPlaybackSources(
          video: video,
          offlineVideo: offline,
          isCurrent: active,
          sessionId:
              'standby:${identityHashCode(slot)}:${DateTime.now().microsecondsSinceEpoch}');
      if (!active()) return null;
      if (sources != null && sources.sources.isNotEmpty) {
        // Queue traversal starts songs at zero even if they have watch history.
        if (!samePreparedAudioSource(previous, sources)) {
          await slot.decoder.setAudioSource(sources.sources.first,
              initialPosition: Duration.zero);
        }
        if (active()) return sources;
      }
    } catch (_) {
      // An optional warm failure is silent. A selected song still gets its
      // ordinary admitted sources and recovery policy.
    }
    if (identical(_standbys[id], slot)) {
      slot.failed = true;
      _retire(slot.decoder.dispose());
    }
    return null;
  }

  Duration? _resumePosition(String videoId, int seconds) {
    if (isLocalMusicPlaybackId(videoId)) return null;
    final progress = db.getVideoProgress(videoId);
    return progress > 0 && progress < 0.9
        ? Duration(seconds: (seconds * progress).floor())
        : null;
  }

  void initPlayer() {
    if (audioPlayer == null) _bindDecoder(_newDecoder());
  }

  void _bindDecoder(AudioPlayer current) {
    audioPlayer = current;
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
    if (isClosed) return;
    _transition.interruption(event);
    if (!_ownsParentPlayback) return;
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
      _sourceAdmitted &&
      (state.video != null || state.offlineVideo != null) &&
      _loadingGeneration == null &&
      !_awaitingBackendMetadata &&
      _wantsToPlay &&
      !_focusInterrupted &&
      !player.playbackInterrupted &&
      player.shouldStartPlayback &&
      identical(audioPlayer, current) &&
      current.processingState != ProcessingState.completed &&
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
    final video = state.video;
    final offlineVideo = state.offlineVideo;
    final result = await _nativeProgress(current).timeout(
        const Duration(seconds: 3),
        onTimeout: () => (revision: _sourceLoadRevision, sample: null));
    if (generation != _playbackGeneration ||
        revision != _stallRevision ||
        result.revision != _sourceLoadRevision ||
        !identical(state.video, video) ||
        !identical(state.offlineVideo, offlineVideo) ||
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
    player.setEvent(MediaEvent<Duration>(
        type: MediaEventType.playbackSample,
        value: sample.position,
        state: playing
            ? MediaState.playing
            : sample.processingState == ProcessingState.buffering
                ? MediaState.buffering
                : MediaState.pause));
    // Offline playback supplies real listening samples but never triggers
    // network metadata recovery when a local decoder is paused or stalled.
    if (_playbackOffline || video == null) return;
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
    if (_sourceAdmitted &&
        state.processingState != ProcessingState.completed &&
        (!state.playing ||
            state.processingState == ProcessingState.buffering)) {
      _transition.suspend();
    }
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
        if (_sourceAdmitted &&
            _loadingGeneration == null &&
            audioPlayer?.processingState == ProcessingState.ready) {
          _completedSourceRevision = null;
        }
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
        // Pausing at EOF also emits a completed player state. A queued event
        // from a replaced source cannot advance the new occurrence.
        if (!_sourceAdmitted ||
            _loadingGeneration != null ||
            _completedSourceRevision == _sourceLoadRevision) {
          return;
        }
        _completedSourceRevision = _sourceLoadRevision;
        _transition.completed();
        // EOF ends progress observation, not admission of the installed source.
        // Replay or a seek away from EOF must retain recovery for that source.
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
    final offline = state.offlineVideo;
    if (_sourceAdmitted &&
        offline != null &&
        isLocalMusicPlaybackId(offline.videoId) &&
        offline.lengthSeconds == 0 &&
        duration != null &&
        duration > Duration.zero) {
      player.reportLocalMusicDuration(offline.videoId, duration);
      emit(state.copyWith(loading: false, audioLength: duration));
    } else {
      emit(state.copyWith(loading: false));
    }
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
    _transition.update(position: position);
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
    if (_usingDownloadedSource) _downloadReuseFailed = true;
    _beginPlaybackRecovery(current, error);
  }

  void _beginPlaybackRecovery(AudioPlayer current, Object error,
      {Duration? resumeAt}) {
    if (_loadingGeneration != null || _terminalErrorSent || isClosed) return;
    final generation = _playbackGeneration;
    final parentGeneration = player.backendPlaybackGeneration;
    final sourceRevision = _sourceLoadRevision;
    _loadingGeneration = generation;
    _transition.stop();
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
    _clearMusicQuality();
    _stopStallWatch();
    // A failed source is not playing. Publish pause before the error so the
    // controls and notification stop without hiding the actionable failure.
    pause();
    // Native and metadata exceptions may contain signed URLs or request data.
    log.warning('Audio playback failed (${error.runtimeType})');
    player.setEvent(const MediaEvent(state: MediaState.error));
    emit(state.copyWith(error: 'Audio playback failed', loading: false));
  }

  void _clearMusicQuality() {
    if (identical(player.musicAudioQuality, _publishedQuality)) {
      player.musicAudioQuality = null;
    }
    _publishedQuality = null;
  }

  void _publishMusicQuality(
      Video video,
      BackendPlayback route,
      Set<MusicAudioQuality> qualities,
      MusicAudioQuality? effective,
      MusicStreamingQuality streamingQuality) {
    final generation = _playbackGeneration;
    final queueId = player.state.currentQueueId;
    late final MusicAudioQualityMenu menu;
    menu = MusicAudioQualityMenu(
      videoId: video.videoId,
      choices: List.unmodifiable(qualities),
      selected: _qualityPreference,
      effective: effective,
      saved: _usingDownloadedSource,
      select: (choice) async {
        bool active() =>
            !isClosed &&
            !player.isClosed &&
            player.state.isAudio &&
            _ownsParentPlayback &&
            _playbackGeneration == generation &&
            player.state.currentQueueId == queueId &&
            identical(player.musicAudioQuality, menu);
        final current = audioPlayer;
        if (current == null ||
            !active() ||
            _loadingGeneration != null ||
            (choice != null && !menu.choices.contains(choice))) {
          return false;
        }
        if (choice == menu.selected &&
            (choice != null ||
                streamingQuality == MusicStreamingQuality.forDatabase(db))) {
          return true;
        }
        _transition.stop();
        final previous = _qualityPreference;
        _loadingGeneration = generation;
        _qualityPreference = choice;
        _stopStallWatch();
        try {
          // The decoder retains the queue and focus intent while replacing
          // just its source. Newer seeks and pauses still win during setup.
          final loaded = await _loadAudioSource(current, generation,
              offline: false, startAt: null, qualityRoute: route);
          if (!loaded && active()) _qualityPreference = previous;
          return loaded &&
              _playbackGeneration == generation &&
              (choice == null || _qualityPreference == choice);
        } finally {
          if (active()) _startStallWatch();
        }
      },
    );
    _publishedQuality = player.musicAudioQuality = menu;
  }

  Future<bool> _loadAudioSource(AudioPlayer current, int generation,
      {required bool offline,
      required Duration? startAt,
      BackendPlayback? qualityRoute,
      _StandbyAudio? standby,
      _ManualMusicDecoder? selection,
      bool continueOverlap = false,
      Object? firstError,
      bool allowStreamRefresh = false}) async {
    var video = state.video;
    final offlineVideo = state.offlineVideo;
    final parentGeneration = player.backendPlaybackGeneration;
    var captureCurrentPosition = qualityRoute != null;
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
            if (allowStreamRefresh || video.downloadPlaybackOnly) {
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
          final staged = standby;
          standby = null;
          final manual = selection;
          selection = null;
          final warmPlan = manual?.admittedPlan ?? await staged?.ready;
          if (!active()) return false;
          // A manual selection rechecked its source after reaching native ready,
          // immediately before the parent committed it. An adjacent preload
          // can be much older and needs fresh admission at this point.
          final plan = manual?.admittedPlan ??
              await resolveAudioPlaybackSources(
                video: video,
                offlineVideo: offline ? offlineVideo : null,
                sessionId:
                    '${identityHashCode(this)}:$generation:${DateTime.now().microsecondsSinceEpoch}',
                isCurrent: active,
                qualityRoute: qualityRoute,
                qualityPreference: _qualityPreference,
                // During a crossfade the incoming song is already audible.
                // Revalidate that rendition without restarting it at zero if
                // the profile default changed in the middle of the overlap.
                streamingQualityOverride:
                    continueOverlap ? warmPlan?.streamingQuality : null,
                skipDownload: _downloadReuseFailed,
              );
          if (!active() || plan == null) return false;
          final preparedIndex = manual?.sourceIndex ?? 0;
          final prepared = warmPlan != null &&
              current.playbackEvent.errorCode == null &&
              current.processingState == ProcessingState.ready &&
              samePreparedAudioSource(warmPlan, plan, index: preparedIndex);
          final firstIndex = prepared ? preparedIndex : 0;
          if (!offline && video != null) {
            player.setRequestedBackend(video.videoId, video.backendPlayback);
          }
          final (
            :sources,
            :menuRoute,
            :qualities,
            :sourceQualities,
            :streamingQuality
          ) = plan;
          MusicAudioQuality? effective;
          if (sources.isEmpty) {
            if (video?.downloadPlaybackOnly == true) {
              throw const _AudioPlaybackStall();
            }
            throw StateError('No supported audio source');
          }
          for (var index = firstIndex; index < sources.length; index++) {
            try {
              // just_audio can carry its native Play intent into a new source.
              // Restore intent only after setup and the latest parent/focus
              // checks, including a Pause whose child command is still queued.
              final continuing = continueOverlap &&
                  prepared &&
                  index == 0 &&
                  current.playing &&
                  _wantsToPlay &&
                  player.shouldStartPlayback &&
                  !_focusInterrupted &&
                  !player.playbackInterrupted &&
                  _pendingSeek == null;
              continueOverlap = false;
              if (current.playing && !continuing) await current.pause();
              if (!active()) return false;
              if (captureCurrentPosition) {
                startAt = current.position;
                captureCurrentPosition = false;
              }
              _sourceLoadRevision++;
              final start = _pendingSeek ?? startAt;
              if (prepared && index == firstIndex) {
                final target = start ?? Duration.zero;
                if (!continuing && current.position != target) {
                  await current.seek(target);
                }
              } else {
                await current.setAudioSource(sources[index],
                    initialPosition: start);
              }
              if (!active()) return false;
              _usingDownloadedSource =
                  sources[index] is ProgressiveAudioSource &&
                      (sources[index] as ProgressiveAudioSource)
                          .playbackCache?['download'] is Map;
              effective = sourceQualities[sources[index]];
              break;
            } catch (error) {
              if (!active()) return false;
              if (sources[index] is ProgressiveAudioSource &&
                  (sources[index] as ProgressiveAudioSource)
                      .playbackCache?['download'] is Map) {
                _downloadReuseFailed = true;
              }
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
          if (menuRoute != null && video != null) {
            if (_qualityPreference != effective) _qualityPreference = null;
            _publishMusicQuality(
                video, menuRoute, qualities, effective, streamingQuality);
          }
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
    _clearMusicQuality();
    _qualityPreference = null;
    _parentPlaybackGeneration = player.backendPlaybackGeneration;
    _loadingGeneration = generation;
    _backendMetadataGeneration = null;
    _pendingSeek = null;
    _sourceAdmitted = false;
    _downloadReuseFailed = false;
    _usingDownloadedSource = false;
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
    final entry = (offline ? state.offlineVideo : state.video)!;
    final id = playbackQueueId(entry);
    final candidate = _standbys[id];
    final reservation = _manual;
    final selection = player.isCommittingMusicSelection &&
            reservation != null &&
            reservation.admittedPlan != null &&
            reservation.inScope &&
            reservation.startAt == (startAt ?? Duration.zero) &&
            reservation.slot.matches(entry)
        ? reservation
        : null;
    final standby = selection?.slot ??
        (candidate != null && !candidate.failed && candidate.matches(entry)
            ? _standbys.remove(id)
            : null);
    if (selection != null) _manual = null;
    final continueOverlap = _transition.switchTo(id, standby);
    _promoted = standby;
    if (standby != null) {
      final old = audioPlayer;
      final subscriptions = List.of(_playerSubscriptions);
      _playerSubscriptions.clear();
      final volume = _transition.startVolume;
      _bindDecoder(standby.decoder);
      for (final subscription in subscriptions) {
        _retire(subscription.cancel());
      }
      // Pause the old audio before the prepared decoder can start. Keep the
      // user's mute setting and rebind the equalizer through the usual path.
      try {
        await Future.wait([
          if (old != null) _pauseAndRetire(old),
          if (standby.decoder.volume != volume)
            standby.decoder.setVolume(volume),
        ]);
      } catch (error) {
        if (!isClosed && generation == _playbackGeneration) {
          _failPlayback(error);
        }
        return;
      }
      if (isClosed || generation != _playbackGeneration) return;
    } else {
      initPlayer();
      if (_transition.startVolume != 1) _transition.applyStartVolume();
    }
    final current = audioPlayer;
    if (current == null) {
      _loadingGeneration = null;
      return;
    }
    if ((state.video?.musicMetadata ?? state.offlineVideo?.musicMetadata) !=
        null) {
      player.musicSound.attach(current, profileId: db.profileId);
    } else {
      await player.musicSound.detach(current);
      if (isClosed ||
          generation != _playbackGeneration ||
          !_ownsParentPlayback ||
          !identical(audioPlayer, current)) {
        if (_loadingGeneration == generation) _loadingGeneration = null;
        return;
      }
    }
    final audioLength = Duration(
        seconds: offline
            ? state.offlineVideo!.lengthSeconds
            : (state.video!.lengthSeconds ?? 0));
    startAt ??= _resumePosition(videoId, audioLength.inSeconds);
    emit(state.copyWith(
        audioPosition: Duration.zero,
        audioLength: audioLength,
        loading: true,
        error: null));
    player.setEvent(const MediaEvent(state: MediaState.loading));
    final loaded = await _loadAudioSource(current, generation,
        offline: offline,
        startAt: startAt,
        standby: standby,
        selection: selection,
        continueOverlap: continueOverlap);
    if (loaded && !isClosed && generation == _playbackGeneration) {
      super.playVideo(offline);
      if (isLocalMusicPlaybackId(videoId) && audioLength == Duration.zero) {
        final duration = current.duration;
        if (duration != null && duration > Duration.zero) {
          player.reportLocalMusicDuration(videoId, duration);
          emit(state.copyWith(audioLength: duration));
          player.setEvent(MediaEvent<Duration>(
              state: MediaState.ready,
              type: MediaEventType.durationChanged,
              value: duration));
        }
      }
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
    if (_manual?.admittedPlan != null &&
        player.isCommittingMusicSelection &&
        (command.type == MediaCommandType.switchVideo ||
            command.type == MediaCommandType.switchToOfflineVideo) &&
        !player.isManualMusicSelectionCommand(command)) {
      // An older switch may still be queued on the widget's Bloc listener.
      // Only the command that committed this selection can take its decoder.
      return;
    }
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
    // Play at native EOF does not rewind just_audio. Use the decoder's state,
    // not a near-end position or the parent's latest progress/pause event.
    if (audioPlayer?.processingState == ProcessingState.completed) {
      seek(Duration.zero);
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
    _transition.stop();
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
    _transition.suspend();
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
    return _transition.muted;
  }

  @override
  void toggleVolume(bool soundOn) {
    _transition.setMuted(!soundOn);
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
