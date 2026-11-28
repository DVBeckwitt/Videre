part of 'audio_player.dart';

/// Applies gains only to the current Music decoder and its admitted successor.
/// The primary decoder owns the queue, media session and genuine EOF event.
class _SongTransitionPlayback {
  _SongTransitionPlayback(this.owner);

  static const _sampleInterval = Duration(milliseconds: 120);
  static const _sampleLimit = Duration(milliseconds: 350);

  final AudioPlayerCubit owner;
  _StandbyAudio? incoming;
  Timer? _timer;
  String? _afterEof;
  bool _started = false;
  Object? _request;
  bool _intro = false;
  bool _ducked = false;
  bool muted = false;
  bool primaryIsMusic = false;
  double _primaryGain = 1;
  double _secondaryGain = 0;
  double? _overlapSpanMs;
  final _progressClock = Stopwatch();
  bool _samplingProgress = false;
  Duration? _lastSampleRequest;
  NativePlaybackProgress? _incomingProgress;
  Duration? _incomingAdvancedAt;

  bool get _checkNativeProgress =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool _canContinueOverlap(_StandbyAudio slot) =>
      _overlapSpanMs != null &&
      owner._wantsToPlay &&
      owner.player.shouldStartPlayback &&
      slot.decoder.playing &&
      slot.decoder.processingState == ProcessingState.ready &&
      (!_checkNativeProgress || _hasRecentIncomingProgress);

  bool get _hasRecentIncomingProgress {
    final advancedAt = _incomingAdvancedAt;
    return advancedAt != null &&
        _progressClock.elapsed - advancedAt < _sampleLimit;
  }

  double get startVolume => _volumeAt(_primaryGain, music: primaryIsMusic);
  SongTransitionMode get _mode => owner.settings.state.songTransitionMode;

  double _volumeAt(double gain, {required bool music}) => muted
      ? 0
      : gain *
          owner.player.sleepTimerGain.value *
          (music ? owner.settings.state.musicPlaybackVolume : 1);

  void _gain(AudioPlayer? decoder, double factor, {bool music = true}) {
    if (decoder == null) return;
    final volume = _volumeAt(factor, music: music);
    if (decoder.volume == volume ||
        (volume != 0 && (decoder.volume - volume).abs() < 0.001)) {
      return;
    }
    unawaited(decoder.setVolume(volume).catchError((Object _) {
      // A closed decoder can no longer contribute to the mix.
    }));
  }

  void applyStartVolume() =>
      _gain(owner.audioPlayer, _primaryGain, music: primaryIsMusic);

  void refreshVolume() {
    final duckGain = _ducked ? .5 : 1.0;
    _gain(owner.audioPlayer, _primaryGain * duckGain, music: primaryIsMusic);
    _gain(incoming?.decoder, _secondaryGain * duckGain);
  }

  void refreshSleepVolume() => refreshVolume();

  void setMuted(bool value) {
    muted = value;
    refreshVolume();
  }

  void _watch() {
    _timer ??=
        Timer.periodic(const Duration(milliseconds: 40), (_) => update());
  }

  void _unwatch() {
    _timer?.cancel();
    _timer = null;
  }

  void _rewind(_StandbyAudio slot) {
    final prepared = slot.ready;
    final decoder = slot.decoder;
    _gain(decoder, 0);
    final paused = decoder.pause();
    slot.ready = () async {
      try {
        await paused;
        final source = await prepared;
        if (source != null &&
            (identical(owner._standbys[playbackQueueId(slot.entry)], slot) ||
                identical(owner._promoted, slot)) &&
            decoder.position != Duration.zero) {
          await decoder.seek(Duration.zero);
        }
        return source;
      } catch (_) {
        return null;
      }
    }();
  }

  void stop({bool release = false}) {
    final slot = incoming;
    final started = _started;
    final changedPrimary = _primaryGain != 1;
    incoming = null;
    _request = null;
    _afterEof = null;
    _started = false;
    _intro = false;
    _overlapSpanMs = null;
    _progressClock
      ..stop()
      ..reset();
    _samplingProgress = false;
    _lastSampleRequest = null;
    _incomingProgress = null;
    _incomingAdvancedAt = null;
    _primaryGain = 1;
    _secondaryGain = 0;
    _unwatch();
    if (slot != null && started) {
      if (release) {
        _gain(slot.decoder, 0);
        unawaited(slot.decoder.pause().catchError((Object _) {}));
      } else {
        _rewind(slot);
      }
    }
    if (changedPrimary) applyStartVolume();
  }

  void interruption(AudioInterruptionEvent event) {
    _ducked = event.type == AudioInterruptionType.duck && event.begin;
    if (event.begin) {
      final slot = incoming;
      final retire =
          slot != null && _started && event.type != AudioInterruptionType.duck;
      stop(release: retire);
      // just_audio can remember a system pause and auto-resume on focus gain.
      // An incoming preview must never resume apart from the selected song.
      if (retire &&
          identical(owner._standbys[playbackQueueId(slot.entry)], slot)) {
        owner._retire(slot.decoder.dispose());
        owner._stage(slot.entry);
      }
    }
    if (!event.begin && event.type == AudioInterruptionType.duck) {
      final decoder = owner.audioPlayer;
      // just_audio changes its volume on the same event. Restore our gain
      // after all listeners have handled the focus gain.
      scheduleMicrotask(() {
        if (!owner.isClosed &&
            owner._ownsParentPlayback &&
            !_ducked &&
            identical(decoder, owner.audioPlayer)) {
          applyStartVolume();
        }
      });
    } else if (!event.begin && muted) {
      applyStartVolume();
    }
  }

  void suspend() {
    if (incoming != null || _primaryGain != 1 || _intro) stop();
  }

  bool switchTo(IdedVideo entry, _StandbyAudio? standby) {
    final id = playbackQueueId(entry);
    final mode = owner.player.isAutomaticMusicHandoffTo(id)
        ? owner.player.musicTransitionModeTo(entry)
        : SongTransitionMode.seamless;
    final continuing = mode == SongTransitionMode.crossfade &&
        _afterEof == id &&
        identical(standby, incoming) &&
        standby != null &&
        _canContinueOverlap(standby);
    if (continuing) {
      incoming = null;
      _started = false;
    }
    stop();
    _intro = mode == SongTransitionMode.fade;
    _primaryGain = _intro ? 0 : 1;
    return continuing;
  }

  void completed() {
    final target = owner.player.automaticMusicSuccessor;
    final slot = incoming;
    if (slot != null &&
        _canContinueOverlap(slot) &&
        target != null &&
        playbackQueueId(slot.entry) == playbackQueueId(target) &&
        owner.player.musicTransitionModeTo(target) ==
            SongTransitionMode.crossfade) {
      _afterEof = playbackQueueId(target);
      _primaryGain = 0;
      _secondaryGain = 1;
      _gain(slot.decoder, 1);
      _watch();
    } else {
      stop();
    }
  }

  void update({Duration? position}) {
    final end = _afterEof;
    if (end != null) {
      final slot = incoming;
      if (slot == null ||
          !_canContinueOverlap(slot) ||
          !owner.player.isAutomaticMusicHandoffTo(end) ||
          owner.player.musicTransitionModeTo(slot.entry) !=
              SongTransitionMode.crossfade ||
          owner.player.playbackInterrupted) {
        stop();
      } else {
        _sampleIncomingIfDue(slot);
      }
      return;
    }
    final mode = _mode;
    if (mode != SongTransitionMode.fade &&
        mode != SongTransitionMode.crossfade) {
      suspend();
      return;
    }
    final decoder = owner.audioPlayer;
    // just_audio's position and player-state streams dispatch independently.
    // A final position tick can already see native EOF before its state
    // notification. Let completed() decide the audible successor exactly once.
    if (_overlapSpanMs != null &&
        owner._ownsParentPlayback &&
        owner._sourceAdmitted &&
        owner._loadingGeneration == null &&
        decoder?.processingState == ProcessingState.completed) {
      return;
    }
    if (decoder == null ||
        owner._silenceSkippingOrUpdating ||
        !owner._sourceAdmitted ||
        !owner._ownsParentPlayback ||
        owner._loadingGeneration != null ||
        owner._abRepeat.isActive ||
        !owner._wantsToPlay ||
        _ducked ||
        owner._focusInterrupted ||
        !owner.player.shouldStartPlayback ||
        !decoder.playing ||
        decoder.processingState != ProcessingState.ready) {
      suspend();
      return;
    }
    final duration = decoder.duration ?? owner.state.audioLength;
    if (duration <= Duration.zero) {
      suspend();
      return;
    }
    final at = position ?? decoder.position;
    final speed = decoder.speed;
    final requestedMs = owner.settings.state.songTransitionSeconds * 1000.0;
    final span =
        (duration.inMilliseconds / (2 * speed)).clamp(1.0, requestedMs);
    final remainingMs = (duration - at).inMilliseconds / speed;
    if (_intro &&
        mode == SongTransitionMode.fade &&
        at.inMilliseconds / speed < span) {
      _primaryGain = (at.inMilliseconds / speed / span).clamp(0.0, 1.0);
      applyStartVolume();
      _watch();
      return;
    }
    _intro = false;
    if (remainingMs > span) {
      suspend();
      return;
    }
    final target = owner.player.automaticMusicSuccessor;
    if (target == null ||
        owner.player.musicTransitionModeTo(target) ==
            SongTransitionMode.seamless) {
      suspend();
      return;
    }
    if (mode == SongTransitionMode.fade) {
      if (incoming != null) stop();
      _primaryGain = (remainingMs / span).clamp(0.0, 1.0);
      applyStartVolume();
      _watch();
      return;
    }
    final slot = owner._standbys[playbackQueueId(target)];
    if (slot == null || slot.failed) {
      suspend();
      return;
    }
    final nextDuration = slot.decoder.duration;
    if (nextDuration != null &&
        remainingMs > nextDuration.inMilliseconds / (2 * slot.decoder.speed)) {
      suspend();
      return;
    }
    if (!identical(slot, incoming)) {
      stop();
      incoming = slot;
      final token = _request = Object();
      unawaited(_start(slot, token));
    }
    _watch();
    if (!_started) return;
    if (!slot.decoder.playing ||
        slot.decoder.processingState != ProcessingState.ready) {
      stop();
      return;
    }
    final overlap = _overlapSpanMs;
    if (overlap != null && !_canContinueOverlap(slot)) {
      stop();
      return;
    }
    _sampleIncomingIfDue(slot);
    if (overlap == null) return;
    final fraction = (1.0 - remainingMs / overlap).clamp(0.0, 1.0);
    _primaryGain = 1.0 - fraction;
    _secondaryGain = fraction;
    applyStartVolume();
    _gain(slot.decoder, _secondaryGain);
  }

  void _sampleIncomingIfDue(_StandbyAudio slot) {
    final token = _request;
    if (!_checkNativeProgress || _samplingProgress || token == null) return;
    final now = _progressClock.elapsed;
    final lastRequest = _lastSampleRequest;
    if (lastRequest != null && now - lastRequest < _sampleInterval) return;
    _progressClock.start();
    _lastSampleRequest = now;
    _samplingProgress = true;
    unawaited(_observeIncoming(slot, token, now));
  }

  Future<void> _observeIncoming(
      _StandbyAudio slot, Object token, Duration requestedAt) async {
    final sample = await slot.decoder
        .getNativePlaybackProgress()
        .timeout(_sampleLimit, onTimeout: () => null)
        .catchError((Object _) => null);
    if (!identical(_request, token) || !identical(incoming, slot)) return;
    _samplingProgress = false;
    if (!owner._wantsToPlay ||
        !owner.player.shouldStartPlayback ||
        !slot.decoder.playing ||
        slot.decoder.processingState != ProcessingState.ready) {
      stop();
      return;
    }
    final previous = _incomingProgress;
    if (sample == null ||
        _progressClock.elapsed - requestedAt >= _sampleLimit ||
        !sample.isPlaying ||
        !sample.playWhenReady ||
        sample.processingState != ProcessingState.ready ||
        sample.suppressionReason != 0 ||
        sample.seekPending ||
        sample.hasError ||
        (previous != null &&
            (sample.sourceRevision != previous.sourceRevision ||
                sample.position < previous.position))) {
      if (_overlapSpanMs != null) {
        stop();
      } else {
        _incomingProgress = null;
        _incomingAdvancedAt = null;
      }
      return;
    }
    if (previous != null &&
        sample.sampledAtMillis <= previous.sampledAtMillis) {
      return;
    }
    _incomingProgress = sample;
    if (previous != null && sample.position > previous.position) {
      _incomingAdvancedAt = requestedAt;
      final outgoing = owner.audioPlayer;
      if (_overlapSpanMs == null &&
          outgoing != null &&
          outgoing.playing &&
          outgoing.processingState == ProcessingState.ready) {
        final tail =
            (outgoing.duration ?? owner.state.audioLength) - outgoing.position;
        if (tail > Duration.zero) {
          _overlapSpanMs = tail.inMicroseconds / (1000 * outgoing.speed);
        }
      }
    }
  }

  Future<void> _start(_StandbyAudio slot, Object token) async {
    final entry = slot.entry;
    final decoder = slot.decoder;
    final outgoing = owner.audioPlayer!;
    // Queue planning and actual audible playback are separate admission points.
    // Recheck the account, download proof and selected URI before starting.
    bool current() {
      final successor = owner.player.automaticMusicSuccessor;
      return identical(_request, token) &&
          identical(incoming, slot) &&
          !owner.isClosed &&
          owner._ownsParentPlayback &&
          owner._sourceAdmitted &&
          owner._wantsToPlay &&
          !owner._focusInterrupted &&
          !_ducked &&
          owner.player.shouldStartPlayback &&
          !owner._silenceSkippingOrUpdating &&
          outgoing.playing &&
          outgoing.processingState == ProcessingState.ready &&
          successor != null &&
          playbackQueueId(entry) == playbackQueueId(successor) &&
          owner.player.musicTransitionModeTo(successor) ==
              SongTransitionMode.crossfade;
    }

    try {
      // A manual reservation or an earlier audible overlap may have owned
      // this decoder while the user changed the streaming default.
      if (entry is Video && !owner._requiresLocalSource(entry)) {
        owner._refreshStandbyQuality(
            slot, MusicStreamingQuality.forDatabase(db));
      }
      final prepared = await slot.ready;
      if (!current() || prepared == null) return;
      final active = await resolveAudioPlaybackSources(
        video: entry is Video ? entry : null,
        offlineVideo: entry is DownloadedVideo ? entry : null,
        openedAudioTrack: owner.player.openedAudioTrack,
        sessionId: 'crossfade:${identityHashCode(slot)}',
        isCurrent: current,
      );
      if (!current() ||
          active == null ||
          !samePreparedAudioSource(prepared, active) ||
          decoder.processingState != ProcessingState.ready ||
          decoder.playbackEvent.errorCode != null) {
        return;
      }
      await owner._setMusicGain(decoder, active.sources.first);
      if (!current()) return;
      final tuning = owner.player.playbackTuningFor(entry, preview: true);
      final pitch = pitchFactorForSemitones(tuning.pitch);
      if (decoder.speed != tuning.speed) await decoder.setSpeed(tuning.speed);
      if (!current()) return;
      if (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          decoder.pitch != pitch) {
        await decoder.setPitch(pitch);
      }
      if (!current()) return;
      if (decoder.volume != 0) await decoder.setVolume(0);
      if (!current()) return;
      final tail =
          (outgoing.duration ?? owner.state.audioLength) - outgoing.position;
      final remainingMs = tail.inMilliseconds / outgoing.speed;
      final nextDuration = decoder.duration;
      // For a short successor, leave room to promote it before its own EOF.
      if (remainingMs <= 0 ||
          nextDuration == null ||
          remainingMs >= nextDuration.inMilliseconds / tuning.speed ||
          (explicitAudioDownloadFingerprint(entry) != null &&
              !slot.matches(entry))) {
        if (current()) stop();
        return;
      }
      // just_audio publishes the user's Play intent before the native decoder
      // starts. Keep the outgoing gain until Android observes real progress.
      if (!_checkNativeProgress) _overlapSpanMs = remainingMs;
      _started = true;
      unawaited(decoder.play().catchError((Object _) {
        if (identical(_request, token)) stop();
      }));
    } catch (_) {
      // The ordinary foreground selection owns retry and error reporting.
    }
  }
}
