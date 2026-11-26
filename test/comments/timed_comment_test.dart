import 'package:clipious/comments/models/comment.dart';
import 'package:clipious/comments/models/timed_comment.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter_test/flutter_test.dart';

const _videoId = 'dQw4w9WgXcQ';
const _duration = Duration(minutes: 90);

Comment _comment(String id, String content) => Comment(
      'Author',
      [],
      '',
      '',
      false,
      content,
      'today',
      0,
      id,
      false,
      null,
      null,
    );

List<TimedComment> _index(
  Iterable<Comment> comments, {
  Duration duration = _duration,
  Server? server,
}) =>
    TimedComment.index(
      comments,
      videoId: _videoId,
      duration: duration,
      server: server,
    );

void main() {
  test('orders loaded pages by the earliest valid time in each comment', () {
    final firstPage = [
      _comment('longer', '(1:02:03)'),
      _comment('multiple', '1:06:00 and then [0:42]'),
      _comment('tie-1', '0:42: my favorite bit'),
    ];
    final secondPage = [
      _comment('intro', '00:00'),
      _comment('tie-2', 'I heard it at 0:42.'),
      _comment('long-minutes', '75:30'),
      _comment('multiple', 'Duplicate result 0:04'),
      _comment('', '0:05'),
      _comment('', '0:06'),
    ];

    final entries = _index([...firstPage, ...secondPage]);
    expect(
      entries.map(
        (entry) => (entry.comment.commentId, entry.timestamp.inSeconds),
      ),
      [
        ('intro', 0),
        ('', 5),
        ('', 6),
        ('multiple', 42),
        ('tie-1', 42),
        ('tie-2', 42),
        ('longer', 3723),
        ('long-minutes', 4530),
      ],
    );
  });

  test('ignores malformed tokens, plain comments and out-of-range times', () {
    final entries = _index([
      _comment('plain', 'nothing here'),
      _comment('bad', '0:61 1:62:03 0:08:95 -0:05 +0:06 0:5 0:07.50 x0:04'),
      _comment('overflow', '99999999999999999999999999:59:59'),
      _comment('end', '1:30:00'),
      _comment('after', '1:30:01'),
      _comment('mixed', '0:14:9 1:35:00 then 1:29:59'),
    ]);
    expect(entries.single.comment.commentId, 'mixed');
    expect(entries.single.timestamp, const Duration(minutes: 89, seconds: 59));
  });

  test(
    'requires a known duration and allows starts below a fractional end',
    () {
      final comments = [_comment('start', '0:00'), _comment('later', '0:01')];
      expect(_index(comments, duration: Duration.zero), isEmpty);
      expect(
        _index(comments, duration: const Duration(seconds: 1)),
        hasLength(1),
      );
      expect(
        _index(comments, duration: const Duration(milliseconds: 1001)),
        hasLength(2),
      );
    },
  );

  test('uses explicit timed URLs for the selected video and provider', () {
    final entries = _index([
      _comment('same', 'See https://youtu.be/$_videoId?t=1m2s.'),
      _comment('other', 'https://youtu.be/9bZkp7q19f0?t=17'),
      _comment('lookalike', 'https://youtu.be.example.org/$_videoId?t=10'),
      _comment('in-path', 'https://example.org/path/0:30'),
      _comment('in-query', 'https://example.org/?q=0:30'),
      _comment('bad-link-time', 'https://youtu.be/$_videoId?t=2s1s'),
      _comment('late-link', 'https://youtu.be/$_videoId?t=5400'),
      _comment('no-link-time', 'https://youtu.be/$_videoId'),
      _comment('mixed-link', 'https://youtu.be/$_videoId?t=120 and (0:55)'),
      _comment(
        'instance',
        'https://instance.example/iv/watch?v=$_videoId&t=25',
      ),
    ], server: Server(url: 'https://instance.example/iv'));

    expect(
      entries.map(
        (entry) => (entry.comment.commentId, entry.timestamp.inSeconds),
      ),
      [('instance', 25), ('mixed-link', 55), ('same', 62)],
    );
    expect(
      TimedComment.index(
        entries.map((entry) => entry.comment),
        videoId: '9bZkp7q19f0',
        duration: _duration,
      ).map((entry) => entry.comment.commentId),
      ['mixed-link'],
    );
  });

  test(
    'resolves the nearest reached row across forward and backward seeks',
    () {
      final entries = _index([
        _comment('first', '0:10'),
        _comment('second', '0:30'),
        _comment('tie', '0:30'),
        _comment('last', '0:58'),
      ]);
      expect(TimedComment.activeIndexAt(const [], Duration.zero), -1);
      expect(TimedComment.activeIndexAt(entries, Duration.zero), -1);
      expect(
        TimedComment.activeIndexAt(entries, const Duration(seconds: 10)),
        0,
      );
      expect(
        TimedComment.activeIndexAt(entries, const Duration(seconds: 30)),
        2,
      );
      expect(
        TimedComment.activeIndexAt(entries, const Duration(minutes: 1)),
        3,
      );
      expect(
        TimedComment.activeIndexAt(entries, const Duration(seconds: 26)),
        0,
      );
      expect(
        TimedComment.activeIndexAt(entries, const Duration(seconds: 4)),
        -1,
      );
    },
  );
}
