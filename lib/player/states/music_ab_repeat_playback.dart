part of 'audio_player.dart';

class _MusicAbRepeatPlayback {
  _MusicAbRepeatPlayback(this.owner);

  static const _minimumSpan = Duration(seconds: 1);

  final AudioPlayerCubit owner;
  MusicAbRepeatControls? _controls;
  Object? _rewind;

  bool get isActive => _controls?.isActive == true;

  bool get _canUseSource =>
      !owner.isClosed &&
      owner._ownsParentPlayback &&
      owner.player.state.isAudio &&
      !owner.player.state.isClosing &&
      owner._sourceAdmitted &&
      owner._loadingGeneration == null &&
      owner._canSeekAudio &&
      !owner._terminalErrorSent;

  bool _isSource(AudioPlayer decoder, int revision) =>
      _canUseSource &&
      identical(owner.audioPlayer, decoder) &&
      owner._sourceLoadRevision == revision;

  bool get _canWrap =>
      owner._wantsToPlay &&
      !owner._focusInterrupted &&
      owner.player.shouldStartPlayback;

  void detach() {
    final previous = _controls;
    _controls = null;
    _rewind = null;
    if (previous != null &&
        identical(owner.player.musicAbRepeat.value, previous)) {
      owner.player.reportMusicAbRepeatControls(null);
    }
  }

  void syncAvailability() {
    final decoder = owner.audioPlayer;
    final duration = _canUseSource ? decoder?.duration : null;
    final video = owner.state.video;
    if (decoder == null ||
        duration == null ||
        duration < _minimumSpan ||
        video?.liveNow == true ||
        (video?.musicMetadata == null &&
            owner.state.offlineVideo?.musicMetadata == null)) {
      detach();
      return;
    }
    final controls = _controls;
    if (controls == null ||
        (controls.start ?? Duration.zero) > duration - _minimumSpan ||
        (controls.end ?? Duration.zero) > duration) {
      _publish(decoder);
    }
  }

  void _publish(AudioPlayer decoder, {Duration? start, Duration? end}) {
    final revision = owner._sourceLoadRevision;
    late final MusicAbRepeatControls controls;
    bool isCurrent() =>
        identical(_controls, controls) && _isSource(decoder, revision);
    _controls = controls = MusicAbRepeatControls(
      generation: owner._parentPlaybackGeneration,
      sourceRevision: revision,
      start: start,
      end: end,
      mark: () {
        if (!isCurrent() || owner.player.openingMusicEntry != null) {
          return false;
        }
        final duration = decoder.duration;
        if (duration == null ||
            decoder.processingState == ProcessingState.idle ||
            decoder.processingState == ProcessingState.loading) {
          return false;
        }
        final position = decoder.position;
        if (start == null) {
          if (position.isNegative || position > duration - _minimumSpan) {
            return false;
          }
          _publish(decoder, start: position);
        } else {
          if (end != null ||
              position - start < _minimumSpan ||
              position > duration) {
            return false;
          }
          owner._transition.stop();
          _publish(decoder, start: start, end: position);
          unawaited(_rewindToStart(decoder, _controls!));
        }
        return true;
      },
      clear: () {
        if (isCurrent()) _publish(decoder);
      },
    );
    owner.player.reportMusicAbRepeatControls(controls);
  }

  void handleSeek(Duration position) {
    // An explicit seek supersedes a pending internal seek's progress update.
    _rewind = null;
    final start = _controls?.start;
    final end = _controls?.end;
    final decoder = owner.audioPlayer;
    if (decoder != null &&
        start != null &&
        end != null &&
        (position < start || position >= end)) {
      _publish(decoder);
    }
  }

  bool handlePosition(Duration position) {
    final controls = _controls;
    final end = controls?.end;
    final decoder = owner.audioPlayer;
    if (end == null || decoder == null || !_canUseSource) return false;
    if (_rewind != null) return true;
    if (position < end ||
        decoder.position < end ||
        !_canWrap ||
        !decoder.playing ||
        decoder.processingState != ProcessingState.ready) {
      return false;
    }
    unawaited(_rewindToStart(decoder, controls!));
    return true;
  }

  bool handleCompletion() {
    final decoder = owner.audioPlayer;
    if (!isActive || decoder == null || !_canUseSource) return false;
    // EOF and position events can arrive in either order. A stale EOF after
    // a successful wrap must never advance the queue.
    if (decoder.processingState == ProcessingState.completed &&
        _canWrap &&
        decoder.playing) {
      rewindIfActive(decoder);
    }
    // When paused or interrupted at EOF, keep the loop for the next Play.
    return true;
  }

  bool rewindIfActive(AudioPlayer decoder) {
    final controls = _controls;
    if (controls?.isActive != true || !_canUseSource) return false;
    unawaited(_rewindToStart(decoder, controls!));
    return true;
  }

  Future<void> _rewindToStart(
      AudioPlayer decoder, MusicAbRepeatControls controls) async {
    if (_rewind != null) return;
    final token = _rewind = Object();
    final revision = owner._sourceLoadRevision;
    bool stillCurrent() =>
        identical(_rewind, token) && _isSource(decoder, revision);

    owner._stopStallWatch(forgetProgress: true);
    try {
      final start = controls.start!;
      await decoder.seek(start);
      if (!stillCurrent() || !identical(_controls, controls)) return;
      owner._reportMusicAbRepeatSeek(start);
    } catch (error) {
      if (!stillCurrent() || !identical(_controls, controls)) return;
      log.warning('Music A–B repeat seek failed (${error.runtimeType})');
      _publish(decoder);
      if (decoder.processingState == ProcessingState.completed) {
        owner.onStateStreamChange(decoder.playerState);
      }
    } finally {
      if (stillCurrent()) {
        _rewind = null;
        owner._startStallWatch();
      }
    }
  }
}
