part of 'audio_player.dart';

/// Applies gains only to the current Music decoder and its admitted successor.
/// The primary decoder owns the queue, media session and genuine EOF event.
class _SongTransitionPlayback {
  _SongTransitionPlayback(this.owner);

  final AudioPlayerCubit owner;
  _StandbyAudio? incoming;
  Timer? _timer;
  String? _afterEof;
  bool _started = false;
  Object? _request;
  bool _intro = false;
  bool _ducked = false;
  bool muted = false;
  double _primaryGain = 1;
  double _secondaryGain = 0;
  double? _overlapSpanMs;

  double get startVolume => muted ? 0 : _primaryGain;
  SongTransitionMode get _mode => owner.settings.state.songTransitionMode;

  void _gain(AudioPlayer? decoder, double factor) {
    if (decoder == null) return;
    final volume = muted ? 0.0 : factor.clamp(0.0, 1.0).toDouble();
    if ((decoder.volume - volume).abs() < 0.001) return;
    unawaited(decoder.setVolume(volume).catchError((Object _) {
      // A closed decoder can no longer contribute to the mix.
    }));
  }

  void applyStartVolume() => _gain(owner.audioPlayer, _primaryGain);

  void setMuted(bool value) {
    muted = value;
    applyStartVolume();
    _gain(incoming?.decoder, _secondaryGain);
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
    if (!event.begin && muted) applyStartVolume();
  }

  void suspend() {
    if (incoming != null || _primaryGain != 1 || _intro) stop();
  }

  bool switchTo(String id, _StandbyAudio? standby) {
    final automatic = owner.player.isAutomaticMusicHandoffTo(id);
    final continuing = automatic &&
        _mode == SongTransitionMode.crossfade &&
        _afterEof == id &&
        _started &&
        identical(standby, incoming) &&
        standby != null &&
        standby.decoder.playing;
    if (continuing) {
      incoming = null;
      _started = false;
    }
    stop();
    _intro = automatic && _mode == SongTransitionMode.fade;
    _primaryGain = _intro ? 0 : 1;
    return continuing;
  }

  void completed() {
    final target = owner.player.automaticMusicSuccessor;
    final slot = incoming;
    if (slot != null &&
        _started &&
        target != null &&
        playbackQueueId(slot.entry) == playbackQueueId(target) &&
        _mode == SongTransitionMode.crossfade) {
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
      if (!owner.player.isAutomaticMusicHandoffTo(end) ||
          _mode != SongTransitionMode.crossfade ||
          owner.player.playbackInterrupted) {
        stop();
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
    if (_started &&
        owner._ownsParentPlayback &&
        owner._sourceAdmitted &&
        owner._loadingGeneration == null &&
        decoder?.processingState == ProcessingState.completed) {
      return;
    }
    if (decoder == null ||
        !owner._sourceAdmitted ||
        !owner._ownsParentPlayback ||
        owner._loadingGeneration != null ||
        !owner._wantsToPlay ||
        _ducked ||
        owner._focusInterrupted ||
        owner.player.playbackInterrupted ||
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
    if (target == null) {
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
    final fraction = (1.0 - remainingMs / _overlapSpanMs!).clamp(0.0, 1.0);
    _primaryGain = 1.0 - fraction;
    _secondaryGain = fraction;
    applyStartVolume();
    _gain(slot.decoder, _secondaryGain);
  }

  Future<void> _start(_StandbyAudio slot, Object token) async {
    final entry = slot.entry;
    final decoder = slot.decoder;
    final outgoing = owner.audioPlayer!;
    // Queue planning and actual audible playback are separate admission points.
    // Recheck the account, download proof and selected URI before starting.
    bool current() =>
        identical(_request, token) &&
        identical(incoming, slot) &&
        !owner.isClosed &&
        owner._ownsParentPlayback &&
        owner._sourceAdmitted &&
        owner._wantsToPlay &&
        !owner._focusInterrupted &&
        !_ducked &&
        !owner.player.playbackInterrupted &&
        outgoing.playing &&
        outgoing.processingState == ProcessingState.ready &&
        _mode == SongTransitionMode.crossfade &&
        playbackQueueId(entry) == _successorId;
    try {
      final prepared = await slot.ready;
      if (!current() || prepared == null) return;
      final active = await resolveAudioPlaybackSources(
        video: entry is Video ? entry : null,
        offlineVideo: entry is DownloadedVideo ? entry : null,
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
      final rate = owner.player.previewSpeedForVideo(entry.videoId);
      final pitch = pitchFactorForSemitones(
          owner.player.previewPitchForVideo(entry.videoId));
      if (decoder.speed != rate) await decoder.setSpeed(rate);
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
          remainingMs >= nextDuration.inMilliseconds / rate) {
        if (current()) stop();
        return;
      }
      _overlapSpanMs = remainingMs;
      _started = true;
      unawaited(decoder.play().catchError((Object _) {
        if (identical(_request, token)) stop();
      }));
    } catch (_) {
      // The ordinary foreground selection owns retry and error reporting.
    }
  }

  String? get _successorId {
    final entry = owner.player.automaticMusicSuccessor;
    return entry == null ? null : playbackQueueId(entry);
  }
}
