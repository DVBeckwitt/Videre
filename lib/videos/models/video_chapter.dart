import 'dart:convert';

/// A named point on the video's playback timeline.
class VideoChapter {
  final String title;
  final Duration start;

  const VideoChapter({required this.title, required this.start});

  // Duration stores signed 64-bit microseconds.
  static const _maxStartMilliseconds =
      0x7fffffffffffffff ~/ Duration.microsecondsPerMillisecond;
  static const _timestamp = r'\d+:[0-5]\d(?::[0-5]\d)?';
  static final _descriptionLine = RegExp(
    r'^\s*(?:[-*•]\s+)?'
    '(?:($_timestamp)|\\[($_timestamp)\\]|\\(($_timestamp)\\))'
    r'(\s+.+|[-–—|].+|:\s+.+)$',
  );
  static final _onlySeparators = RegExp(r'^[-–—|:\s]+$');
  static final _titleSeparator = RegExp(r'^[-–—|:]\s*');

  /// Optional chapter data on an instance's video details response.
  static List<VideoChapter> parseList(Object? value) {
    if (value is! List) return const [];

    final chapters = <Duration, VideoChapter>{};
    for (final row in value) {
      if (row is! Map || row['title'] is! String) continue;
      final title = (row['title'] as String).trim();
      final seconds = switch (row['startTimeSeconds']) {
        final num value => value.toDouble(),
        final String value => double.tryParse(value),
        _ => null,
      };
      final start = _startFromSeconds(seconds);
      if (title.isEmpty || start == null) continue;
      chapters.putIfAbsent(
        start,
        () => VideoChapter(title: title, start: start),
      );
    }
    return chapters.values.toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  static List<Map<String, Object>> writeList(List<VideoChapter> chapters) => [
        for (final chapter in chapters)
          {
            'title': chapter.title,
            'startTimeSeconds':
                chapter.start.inMilliseconds / Duration.millisecondsPerSecond,
          },
      ];

  /// Read a creator's chronological list of timestamped description lines.
  static List<VideoChapter> fromDescription(
    String? description,
    Duration duration,
  ) {
    if (description == null || duration <= Duration.zero) return const [];

    final chapters = <VideoChapter>[];
    for (final line in const LineSplitter().convert(description)) {
      final match = _descriptionLine.firstMatch(line);
      if (match == null) continue;
      final title = match[4]!.trim().replaceFirst(_titleSeparator, '').trim();
      final start = _parseDescriptionStart((match[1] ?? match[2] ?? match[3])!);
      if (title.isEmpty ||
          _onlySeparators.hasMatch(title) ||
          start == null ||
          start >= duration) {
        continue;
      }
      if (chapters.isEmpty) {
        if (start != Duration.zero) continue;
      } else if (start <= chapters.last.start) {
        continue;
      }
      chapters.add(VideoChapter(title: title, start: start));
    }
    return chapters.length >= 2 ? chapters : const [];
  }

  static Duration? _parseDescriptionStart(String timestamp) {
    final parts = timestamp.split(':');
    final first = int.tryParse(parts.first);
    final hasHours = parts.length == 3;
    final unit = hasHours ? Duration.secondsPerHour : Duration.secondsPerMinute;
    if (first == null ||
        first >
            _maxStartMilliseconds ~/ Duration.millisecondsPerSecond ~/ unit) {
      return null;
    }
    final minutes = hasHours ? int.parse(parts[1]) : 0;
    final seconds = first * unit +
        minutes * Duration.secondsPerMinute +
        int.parse(parts.last);
    return _startFromSeconds(seconds.toDouble());
  }

  static Duration? _startFromSeconds(double? seconds) {
    if (seconds == null || !seconds.isFinite || seconds.isNegative) return null;
    final milliseconds = seconds * Duration.millisecondsPerSecond;
    if (milliseconds > _maxStartMilliseconds) return null;
    return Duration(milliseconds: milliseconds.round());
  }
}
