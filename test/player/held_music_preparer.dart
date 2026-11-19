import 'dart:async';

import 'package:clipious/player/models/manual_music_preparation.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/videos/models/ided_video.dart';

/// Lets tests release native preparation independently of catalog metadata.
class HeldMusicPreparer implements ManualMusicPreparer {
  final requests = <String, Completer<bool>>{};
  final current = <String, bool Function()>{};
  final started = Completer<IdedVideo>();

  @override
  Future<bool> prepareMusicSelection(
      IdedVideo entry, Duration startAt, bool Function() isCurrent) {
    final id = playbackQueueId(entry);
    current[id] = isCurrent;
    final request = requests[id] = Completer<bool>();
    if (!started.isCompleted) started.complete(entry);
    return request.future;
  }

  @override
  void cancelMusicSelection() {}
}
