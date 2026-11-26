import 'package:flutter/services.dart';

typedef MusicWaveformSource = ({Uri uri, int? startUs, int? endUs});
typedef MountedMusicWaveform = ({
  MusicWaveformSource source,
  int revision,
  Duration? duration,
});

/// Short, bounded amplitude summaries retained only for the lifetime of the app.
class MusicWaveforms {
  static final instance = MusicWaveforms();
  static const _channel =
      MethodChannel('com.github.dvbeckwitt.videre/music_waveform');
  static const _binCount = 256;
  static const _cacheCapacity = 24;
  static int _nextRequestId = 0;

  final _cache = <(String, MusicWaveformSource, String), List<double>>{};

  MusicWaveformRequest load(String profileId, MusicWaveformSource source) {
    final request = MusicWaveformRequest._(++_nextRequestId);
    request.peaks = _load(profileId, source, request);
    return request;
  }

  Future<List<double>?> _load(String profileId, MusicWaveformSource source,
      MusicWaveformRequest request) async {
    final uri = source.uri;
    if (!(uri.scheme == 'content' && uri.host.isNotEmpty ||
        uri.scheme == 'file' && uri.host.isEmpty && uri.hasAbsolutePath)) {
      return null;
    }
    final args = {'uri': uri.toString(), 'requestId': request._id};
    try {
      final revision = await _channel.invokeMethod<String>('revision', {
        ...args,
        'begin': true,
      });
      if (request._cancelled) return null;
      final key = revision == null ? null : (profileId, source, revision);
      final cached = key == null ? null : _cache.remove(key);
      if (key != null && cached != null) {
        _cache[key] = cached;
        return cached;
      }

      final decoded = await _channel.invokeListMethod<Object?>('extract', {
        ...args,
        'binCount': _binCount,
        if (revision != null) 'expectedRevision': revision,
        if (source.startUs case final start?) 'startUs': start,
        if (source.endUs case final end?) 'endUs': end,
      });
      if (request._cancelled ||
          decoded == null ||
          decoded.length != _binCount ||
          decoded.any((peak) =>
              peak is! double || !peak.isFinite || peak < 0 || peak > 1)) {
        return null;
      }
      final peaks = List<double>.unmodifiable(decoded.cast<double>());
      if (key == null) return peaks;
      final current = await _channel.invokeMethod<String>('revision', args);
      if (request._cancelled || current != revision) return null;
      if (_cache.length >= _cacheCapacity) _cache.remove(_cache.keys.first);
      return _cache[key] = peaks;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class MusicWaveformRequest {
  MusicWaveformRequest._(this._id);

  final int _id;
  bool _cancelled = false;
  late final Future<List<double>?> peaks;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    try {
      await MusicWaveforms._channel.invokeMethod<void>(
        'cancel',
        {'requestId': _id},
      );
    } on PlatformException {
      // The Flutter request is already retired.
    } on MissingPluginException {
      // Waveform extraction is only available on Android.
    }
  }
}
