import 'package:clipious/network/content_link.dart';
import 'package:clipious/settings/models/db/server.dart';

import 'comment.dart';

/// A loaded comment anchored to its earliest valid point in the video.
class TimedComment {
  const TimedComment._(this.comment, this.timestamp);

  final Comment comment;
  final Duration timestamp;

  // Refuse partial matches in malformed tokens like 1:02:99 and -0:30.
  static final _clock = RegExp(
    r'(?<![\w.:/@+=-])(\d+):([0-5]\d)(?::([0-5]\d))?(?![\w/]|\.\d|:[^\s]|:$)',
  );

  static final _linkTime = RegExp(
    r'^(?:\d+|(?=\d)(?:\d+h)?(?:\d+m)?(?:\d+s)?)$',
  );

  static List<TimedComment> index(
    Iterable<Comment> comments, {
    required String videoId,
    required Duration duration,
    Server? server,
  }) {
    if (duration <= Duration.zero) return const [];

    final seen = <String>{};
    final indexed = <({TimedComment entry, int order})>[];
    for (final (order, comment) in comments.indexed) {
      final id = comment.commentId.trim();
      if (seen.contains(id)) continue;

      Duration? earliest;
      for (final timestamp in _timestampsIn(
        comment.content,
        videoId,
        duration,
        server,
      )) {
        if (timestamp < duration &&
            (earliest == null || timestamp < earliest)) {
          earliest = timestamp;
        }
      }
      if (earliest == null) continue;
      if (id.isNotEmpty) seen.add(id);
      indexed.add((entry: TimedComment._(comment, earliest), order: order));
    }
    indexed.sort((a, b) {
      final time = a.entry.timestamp.compareTo(b.entry.timestamp);
      return time == 0 ? a.order.compareTo(b.order) : time;
    });
    return List<TimedComment>.unmodifiable(indexed.map((row) => row.entry));
  }

  /// Index of the last comment at or before [position], or -1 before the first.
  static int activeIndexAt(List<TimedComment> index, Duration position) {
    var low = 0;
    var high = index.length;
    while (low < high) {
      final middle = low + (high - low) ~/ 2;
      if (index[middle].timestamp <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - 1;
  }

  static Iterable<Duration> _timestampsIn(
    String text,
    String videoId,
    Duration duration,
    Server? server,
  ) sync* {
    var start = 0;
    for (final address in ContentLink.webAddressesIn(text)) {
      yield* _clockTimes(text.substring(start, address.start), duration);
      final link = ContentLink.parse(address.uri, server: server);
      final timestamp = link?.timestamp;
      if (link != null &&
          link.kind == ContentLinkKind.video &&
          link.id == videoId &&
          timestamp != null &&
          _linkTime.hasMatch(timestamp)) {
        yield link.startAt!;
      }
      start = address.end;
    }
    yield* _clockTimes(text.substring(start), duration);
  }

  static Iterable<Duration> _clockTimes(String text, Duration duration) sync* {
    for (final match in _clock.allMatches(text)) {
      final first = int.tryParse(match[1]!);
      final last = match[3];
      final unit =
          last == null ? Duration.secondsPerMinute : Duration.secondsPerHour;
      final remaining = last == null
          ? int.parse(match[2]!)
          : int.parse(match[2]!) * Duration.secondsPerMinute + int.parse(last);
      final maxSeconds = duration.inSeconds;
      // Bound the multiplication before constructing the Duration.
      if (first == null ||
          maxSeconds < remaining ||
          first > (maxSeconds - remaining) ~/ unit) {
        continue;
      }
      yield Duration(seconds: first * unit + remaining);
    }
  }
}
