import 'dart:convert';

import 'package:clipious/videos/models/storyboard.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const metadata = {
    'templateUrl': r'https://i.ytimg.com/sb/id/L2/M$M.jpg?sig=a%2Fb',
    'width': 160,
    'height': 90,
    'count': 7,
    'interval': 1000,
    'storyboardWidth': 2,
    'storyboardHeight': 2,
    'storyboardCount': 2,
  };

  test('parses optional storyboards without breaking video metadata', () {
    final video = Video.fromJson({
      'videoId': 'id',
      'title': 'Playable',
      'storyboards': [
        null,
        2,
        {'width': 0},
        metadata,
        {...metadata, 'interval': -1},
        {...metadata, 'storyboardWidth': 0},
        {...metadata, 'count': -1},
        {...metadata, 'width': 99999},
        {...metadata, 'templateUrl': 'file:///tmp/sheet.jpg'}
      ],
    });
    expect(video.storyboards, hasLength(1));
    expect(video.title, 'Playable');
    final restored = Video.fromJson(jsonDecode(jsonEncode(video.toJson())));
    expect(restored.storyboards.single.toJson(), metadata);
    expect(Video.fromJson({'videoId': 'id', 'storyboards': 'bad'}).storyboards,
        isEmpty);
    expect(Video.fromJson({'videoId': 'id'}).storyboards, isEmpty);
  });

  test('selects columns, rows and sheets at exact millisecond boundaries', () {
    final board = Storyboard.fromJson(metadata);
    const duration = Duration(seconds: 7);
    for (var i = 0; i < 7; i++) {
      final frame = board.frameAt(Duration(milliseconds: i * 1000), duration)!;
      expect(
          frame.url, 'https://i.ytimg.com/sb/id/L2/M${i ~/ 4}.jpg?sig=a%2Fb');
      expect(frame.column, i % 2);
      expect(frame.row, (i % 4) ~/ 2);
    }
    expect(
        board.frameAt(const Duration(milliseconds: 999), duration)!.column, 0);
    expect(board.frameAt(const Duration(seconds: -10), duration)!.row, 0);
    final end = board.frameAt(const Duration(hours: 1), duration)!;
    expect(end.column, 0);
    expect(end.row, 1);
  });

  test('finds adjacent tiles on either side of a sheet boundary', () {
    final board = Storyboard.fromJson(metadata);
    const duration = Duration(seconds: 7);
    final before = board.frameAt(const Duration(milliseconds: 4500), duration,
        offset: -1)!;
    final after =
        board.frameAt(const Duration(milliseconds: 3500), duration, offset: 1)!;
    expect((before.url, before.column, before.row),
        ('https://i.ytimg.com/sb/id/L2/M0.jpg?sig=a%2Fb', 1, 1));
    expect((after.url, after.column, after.row),
        ('https://i.ytimg.com/sb/id/L2/M1.jpg?sig=a%2Fb', 0, 0));
  });

  test('skips neighbors before the start and beyond the video duration', () {
    final board = Storyboard.fromJson(metadata);
    const duration = Duration(milliseconds: 2500);

    expect(board.frameAt(Duration.zero, duration, offset: -1), isNull);
    final firstNeighbor =
        board.frameAt(const Duration(seconds: -1), duration, offset: 1)!;
    expect((firstNeighbor.column, firstNeighbor.row), (1, 0));

    expect(board.frameAt(duration, duration, offset: 1), isNull);
    final lastNeighbor =
        board.frameAt(const Duration(hours: 1), duration, offset: -1)!;
    expect((lastNeighbor.column, lastNeighbor.row), (1, 0));
  });

  test('skips neighbors in unaddressable and nonexistent sheets', () {
    const position = Duration(seconds: 3);
    const duration = Duration(seconds: 7);
    final singleSheet =
        Storyboard.fromJson({...metadata, 'storyboardCount': 1});
    final noPlaceholder = Storyboard.fromJson(
        {...metadata, 'templateUrl': 'https://i.ytimg.com/sb/id/L2/M0.jpg'});

    for (final board in [singleSheet, noPlaceholder]) {
      expect(board.frameAt(position, duration), isNotNull);
      expect(board.frameAt(position, duration, offset: 1), isNull);
    }
  });

  test('rejects dimensions that would overflow the sheet size limits', () {
    expect(
        Storyboard.parseList([
          {...metadata, 'width': 1 << 62, 'storyboardWidth': 4},
          {...metadata, 'height': 1 << 62, 'storyboardHeight': 4},
          {...metadata, 'width': 4, 'storyboardWidth': 1 << 62},
          {...metadata, 'height': 4, 'storyboardHeight': 1 << 62},
        ]),
        isEmpty);
  });

  test('supports old zero intervals and encoded sheet placeholders', () {
    final board = Storyboard.fromJson(
        {...metadata, 'interval': 0, 'templateUrl': '/sb/i/id/L2/M%24M.jpg'});
    final frame =
        board.frameAt(const Duration(seconds: 8), const Duration(seconds: 14))!;
    expect(frame.url, '/sb/i/id/L2/M1.jpg');
    expect(frame.column, 0);
    expect(frame.row, 0);
    expect(board.frameAt(Duration.zero, Duration.zero), isNull);
  });

  test('large sheet counts cannot overflow frame selection', () {
    final board = Storyboard.fromJson(
        {...metadata, 'count': 1 << 62, 'storyboardCount': 1 << 62});
    final frame =
        board.frameAt(const Duration(seconds: 5), const Duration(seconds: 7))!;
    expect(frame.url, 'https://i.ytimg.com/sb/id/L2/M1.jpg?sig=a%2Fb');
    expect(frame.column, 1);
    expect(frame.row, 0);
  });

  test('never requests nonexistent sheets or invalidates signed query text',
      () {
    final board = Storyboard.fromJson({...metadata, 'storyboardCount': 1});
    final end =
        board.frameAt(const Duration(seconds: 7), const Duration(seconds: 7))!;
    expect(end.url, 'https://i.ytimg.com/sb/id/L2/M0.jpg?sig=a%2Fb');
    expect(end.row, 1);
    expect(end.column, 1);
  });

  test('chooses the smallest sufficient frame size with a largest fallback',
      () {
    final boards = [80, 320, 160]
        .map((width) => Storyboard.fromJson({...metadata, 'width': width}))
        .toList();
    expect(Storyboard.select(boards, 150)!.width, 160);
    expect(Storyboard.select(boards, 500)!.width, 320);
    expect(Storyboard.select([], 160), isNull);
  });
}
