import '../videos/models/video.dart';

/// Private, profile-owned listening metadata. The journal never contains
/// stream requests, artwork, credentials or source URLs.
class PlaybackCheckpoint {
  final String id;
  final int epoch;
  final int playedMs;
  final int durationMs;
  final int timeMs;
  final Map<String, Object?> candidate;

  const PlaybackCheckpoint._(this.id, this.epoch, this.playedMs,
      this.durationMs, this.timeMs, this.candidate);

  static const maxPlayedMs = 604800000;
  static const maxEpoch = 9007199254740991;
  static const maxTimestamp = 253402300799999;
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _occurrenceId = RegExp(r'^play:[A-Za-z0-9_-]{1,180}$');
  static final _address =
      RegExp(r'(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.)\S+', caseSensitive: false);
  static const _textFields = {
    'title': 1000,
    'author': 300,
    'authorId': 128,
    'artist': 300,
    'artistKey': 512,
    'genre': 100,
    'category': 100,
  };

  static PlaybackCheckpoint create({
    required String id,
    required int epoch,
    required int playedMs,
    required int durationMs,
    required int timeMs,
    required Map<String, Object?> candidate,
  }) =>
      PlaybackCheckpoint._(id, epoch, playedMs, durationMs, timeMs, {
        'id': candidate['id'],
        for (final key in _textFields.keys)
          if (candidate[key] case final String text)
            key: text.replaceAll(_address, '').trim(),
        'durationSeconds': durationMs ~/ 1000,
      });

  static PlaybackCheckpoint? tryParse(Object? value) {
    if (value is! Map ||
        value.keys.any((key) => !const {
              'id',
              'epoch',
              'playedMs',
              'durationMs',
              'timeMs',
              'candidate',
            }.contains(key))) {
      return null;
    }
    final id = value['id'];
    final epoch = value['epoch'];
    final playedMs = value['playedMs'];
    final durationMs = value['durationMs'];
    final timeMs = value['timeMs'];
    final candidate = value['candidate'];
    if (id is! String ||
        !_occurrenceId.hasMatch(id) ||
        epoch is! int ||
        epoch < 0 ||
        epoch > maxEpoch ||
        playedMs is! int ||
        playedMs <= 0 ||
        playedMs > maxPlayedMs ||
        durationMs is! int ||
        durationMs <= 0 ||
        durationMs > maxPlayedMs ||
        timeMs is! int ||
        timeMs < 0 ||
        timeMs > maxTimestamp ||
        candidate is! Map ||
        candidate['id'] is! String ||
        !_videoId.hasMatch(candidate['id'] as String) ||
        candidate['title'] is! String ||
        (candidate['title'] as String).isEmpty ||
        candidate['durationSeconds'] != durationMs ~/ 1000) {
      return null;
    }
    for (final field in candidate.entries) {
      final key = field.key;
      if (key == 'id' || key == 'durationSeconds') continue;
      final limit = _textFields[key];
      final text = field.value;
      if (limit == null ||
          text is! String ||
          text.runes.length > limit ||
          _address.hasMatch(text)) {
        return null;
      }
    }
    return PlaybackCheckpoint._(id, epoch, playedMs, durationMs, timeMs,
        Map.unmodifiable(Map<String, Object?>.from(candidate)));
  }

  Video get video => Video(
      videoId: candidate['id'] as String,
      title: candidate['title'] as String,
      author: candidate['author'] as String?,
      authorId: candidate['authorId'] as String?,
      lengthSeconds: durationMs ~/ 1000,
      genre: candidate['category'] as String?);

  Map<String, Object?> get event => {
        'id': id,
        'type': 'listen',
        'candidate': candidate,
        'playedMs': playedMs,
        'durationMs': durationMs,
        'timeMs': timeMs,
        'skipped': false,
        'completed': false,
      };

  Map<String, Object?> toJson() => {
        'id': id,
        'epoch': epoch,
        'playedMs': playedMs,
        'durationMs': durationMs,
        'timeMs': timeMs,
        'candidate': candidate,
      };
}
