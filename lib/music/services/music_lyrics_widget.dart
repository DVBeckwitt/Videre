import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../models/music_lyrics.dart';

typedef MusicLyricsWidgetRow = ({int positionMs, String text, bool active});

typedef MusicLyricsWidgetPlayback = ({
  Object owner,
  Object? timeline,
  String title,
  List<MusicLyricsWidgetRow> rows,
});

List<MusicLyricsWidgetRow> musicLyricsWidgetRows(
  List<MusicLyricCue> cues, {
  required int anchor,
  required bool active,
  required Duration delay,
  required Duration seekLimit,
}) {
  const rowCount = 3;
  final first =
      (anchor - 1).clamp(0, math.max(0, cues.length - rowCount)).toInt();
  final end = math.min(first + rowCount, cues.length);
  final rows = <MusicLyricsWidgetRow>[];
  for (var index = first; index < end; index++) {
    final cue = cues[index];
    final start = cue.start + delay;
    final text = cue.text.trim();
    if (start <= seekLimit && text.isNotEmpty) {
      rows.add((
        positionMs: math.max(0, start.inMilliseconds),
        text: text,
        active: active && index == anchor,
      ));
    }
  }
  return rows;
}

/// Bridges the player-owned lyric snapshot to the Android launcher.
class MusicLyricsWidget {
  static final _log = Logger('MusicLyricsWidget');
  final MusicLyricsWidgetPlayback? Function() _readPlayback;
  final bool Function(Duration, bool Function()) _seek;
  final MethodChannel _channel;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  MusicLyricsWidgetPlayback? _published;
  String? _token;
  final _publishedPositions = <int>{};
  bool _closed = false;

  MusicLyricsWidget({
    required MusicLyricsWidgetPlayback? Function() readPlayback,
    required bool Function(Duration, bool Function()) seek,
    required Iterable<Stream<Object?>> updates,
    MethodChannel channel = const MethodChannel('videre/music_lyrics_widget'),
  })  : _readPlayback = readPlayback,
        _seek = seek,
        _channel = channel {
    _channel.setMethodCallHandler(_handleCall);
    _subscriptions.addAll(
      updates.map((stream) => stream.listen((_) => refresh())),
    );
    refresh();
  }

  void refresh() {
    if (_closed) return;
    final next = _readPlayback();
    final previous = _published;
    final sameTimeline = _sameTimeline(next, previous);
    if (sameTimeline &&
        next?.title == previous?.title &&
        listEquals(next?.rows, previous?.rows)) {
      return;
    }
    if (!sameTimeline) {
      _token = next == null ? null : const Uuid().v4();
      _publishedPositions.clear();
    }
    _published = next;
    if (next != null) {
      // A row can move off the widget while its click is being delivered.
      _publishedPositions.addAll(next.rows.map((row) => row.positionMs));
    }
    unawaited(_publish(next, _token));
  }

  bool _sameTimeline(
    MusicLyricsWidgetPlayback? a,
    MusicLyricsWidgetPlayback? b,
  ) =>
      a?.owner == b?.owner && a?.timeline == b?.timeline;

  Future<void> _publish(
      MusicLyricsWidgetPlayback? playback, String? token) async {
    try {
      await _channel.invokeMethod<void>(
        'setLyrics',
        playback == null
            ? null
            : {
                'token': token,
                'title': playback.title,
                'cues': [
                  for (final row in playback.rows)
                    {
                      'positionMs': row.positionMs,
                      'text': row.text,
                      'active': row.active,
                    },
                ],
              },
      );
    } on MissingPluginException {
      // The launcher bridge is only available in the Android media engine.
    } on PlatformException catch (error) {
      _log.fine('Could not update the Lyrics launcher widget', error);
    }
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'seek') throw MissingPluginException();
    final arguments = call.arguments;
    if (arguments is! Map ||
        arguments['token'] is! String ||
        arguments['positionMs'] is! int) {
      return false;
    }
    final token = arguments['token'] as String;
    final position = arguments['positionMs'] as int;
    final originating = _published;
    bool isCurrent() =>
        !_closed &&
        token == _token &&
        _publishedPositions.contains(position) &&
        _sameTimeline(originating, _readPlayback());

    // The decoder evaluates this again when it consumes the queued command.
    return isCurrent() && _seek(Duration(milliseconds: position), isCurrent);
  }

  Future<void> close() async {
    _closed = true;
    _channel.setMethodCallHandler(null);
    await _publish(null, null);
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}
