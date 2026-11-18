import 'dart:math' as math;

/// Listening time confirmed by advancing native playback samples.
///
/// Position is only a guard against stalls; it is never treated as time spent
/// listening. Seek, buffer and focus transitions break the sample pair. This
/// also keeps SponsorBlock jumps out of the recommendation engine's milestones.
class PlaybackLearningClock {
  int _playedMicroseconds = 0;
  int? _sampleTime;
  Duration? _position;
  double _speed = 1;

  Duration get played => Duration(microseconds: _playedMicroseconds);

  void sample(Duration position, int monotonicMicroseconds,
      {double speed = 1}) {
    final previousTime = _sampleTime;
    final previousPosition = _position;
    if (previousTime != null && previousPosition != null) {
      final elapsed = monotonicMicroseconds - previousTime;
      final advanced = (position - previousPosition).inMicroseconds;
      if (elapsed > 0 && advanced > 0) {
        // A delayed callback may span real background listening. Credit only
        // the smaller of wall time and media advancement at the prior speed.
        _playedMicroseconds += math.min(elapsed, (advanced / _speed).round());
      }
    }
    _sampleTime = monotonicMicroseconds;
    _position = position;
    _speed = speed.isFinite && speed > 0 ? speed : 1;
  }

  void interrupt() {
    _sampleTime = null;
    _position = null;
  }
}
