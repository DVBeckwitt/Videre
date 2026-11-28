/// Estimates the transfer rate from bytes received during one download part.
class DownloadTransferRate {
  static const _sampleWindow = Duration(milliseconds: 500);

  ({int bytes, Duration elapsed})? _sample;
  int? _lastBytes;
  int? _bytesPerSecond;

  int? observe(int bytes, Duration elapsed) {
    final sample = _sample;
    final restarted = bytes < (_lastBytes ?? bytes);
    _lastBytes = bytes;
    if (sample == null || restarted || elapsed < sample.elapsed) {
      _sample = (bytes: bytes, elapsed: elapsed);
      _bytesPerSecond = null;
    } else {
      final duration = elapsed - sample.elapsed;
      if (duration >= _sampleWindow) {
        _sample = (bytes: bytes, elapsed: elapsed);
        _bytesPerSecond = (bytes - sample.bytes) *
            Duration.microsecondsPerSecond ~/
            duration.inMicroseconds;
      }
    }
    return _bytesPerSecond;
  }
}
