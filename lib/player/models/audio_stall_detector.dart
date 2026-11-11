import 'package:just_audio/just_audio.dart';

/// Recognizes stalled native playback without treating missing samples as proof.
/// The owner supplies source/session eligibility and bounds any recovery attempt.
class AudioStallDetector {
  static const _maximumSampleGapMillis = 6000;
  static const _minimumProgress = Duration(milliseconds: 250);
  static const _bufferMargin = Duration(seconds: 2);
  static const _readyThresholdMillis = 20000;
  static const _bufferingThresholdMillis = 60000;

  NativePlaybackProgress? _previous;
  bool _previousEligible = false;
  bool _previousCandidate = false;
  Duration _forwardProgress = Duration.zero;
  bool _hasAdvanced = false;
  int? _stationarySinceMillis;
  bool _reported = false;

  /// Rearms observation after recovery. A seek, new queue occurrence, or new
  /// native player must also forget its predecessor's progress and revision.
  void reset({bool forgetProgress = false}) {
    _clearBaseline();
    _reported = false;
    if (forgetProgress) {
      _previous = null;
      _hasAdvanced = false;
    }
  }

  void _clearBaseline() {
    _previousEligible = false;
    _previousCandidate = false;
    _forwardProgress = Duration.zero;
    _stationarySinceMillis = null;
  }

  /// Returns true once per explicit reset, using only continuous, current native
  /// observations. [eligible] excludes offline, replaced, or recovering sources.
  bool observe(NativePlaybackProgress sample, {required bool eligible}) {
    if (!eligible) {
      _clearBaseline();
      return false;
    }
    if (sample.sampledAtMillis < 0 ||
        sample.sourceRevision < 0 ||
        sample.position < Duration.zero ||
        sample.bufferedPosition < Duration.zero ||
        (sample.duration != null && sample.duration! < Duration.zero)) {
      _clearBaseline();
      return false;
    }

    final previous = _previous;
    if (previous != null &&
        (sample.sourceRevision < previous.sourceRevision ||
            sample.sampledAtMillis <= previous.sampledAtMillis)) {
      // Late replies cannot replace the latest native observation or extend its
      // measured stall interval. The next fresh sample still checks its gap.
      return false;
    }

    final continuous = previous != null &&
        sample.sourceRevision == previous.sourceRevision &&
        sample.sampledAtMillis - previous.sampledAtMillis <=
            _maximumSampleGapMillis &&
        sample.processingState == previous.processingState &&
        sample.position >= previous.position &&
        (sample.processingState != ProcessingState.buffering ||
            sample.bufferedPosition >= previous.bufferedPosition);
    final wasEligible = _previousEligible;
    final wasCandidate = _previousCandidate;
    if (!continuous) {
      _clearBaseline();
    }
    if (previous != null && sample.sourceRevision != previous.sourceRevision) {
      // Starting a replacement at the old position is not evidence that this
      // new source has ever advanced. Initial loading remains a separate case.
      _hasAdvanced = false;
    }
    _previous = sample;

    final admitted = sample.playWhenReady &&
        sample.suppressionReason == 0 &&
        !sample.seekPending &&
        !sample.hasError &&
        (sample.processingState == ProcessingState.ready ||
            sample.processingState == ProcessingState.buffering);
    if (!admitted) {
      _clearBaseline();
      return false;
    }
    _previousEligible = true;

    if (previous != null &&
        continuous &&
        wasEligible &&
        sample.processingState == ProcessingState.ready &&
        sample.isPlaying &&
        previous.isPlaying &&
        sample.position > previous.position) {
      _forwardProgress += sample.position - previous.position;
      if (_forwardProgress >= _minimumProgress) {
        _hasAdvanced = true;
      }
    }

    final nearEnd = sample.duration != null &&
        sample.duration! - sample.position <= _bufferMargin;
    final candidate = !nearEnd &&
        (sample.processingState == ProcessingState.buffering ||
            (sample.isPlaying &&
                sample.bufferedPosition - sample.position >= _bufferMargin));
    _previousCandidate = candidate;
    if (!candidate) {
      _stationarySinceMillis = null;
      return false;
    }

    final stationary = previous != null &&
        continuous &&
        wasCandidate &&
        sample.position == previous.position &&
        (sample.processingState == ProcessingState.ready ||
            sample.bufferedPosition == previous.bufferedPosition);
    if (!stationary || _stationarySinceMillis == null) {
      _stationarySinceMillis = sample.sampledAtMillis;
      return false;
    }

    final threshold = sample.processingState == ProcessingState.ready
        ? _readyThresholdMillis
        : _bufferingThresholdMillis;
    if (!_reported &&
        _hasAdvanced &&
        sample.sampledAtMillis - _stationarySinceMillis! >= threshold) {
      _reported = true;
      return true;
    }
    return false;
  }
}
