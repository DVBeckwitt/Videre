import 'dart:async';

import 'package:clipious/player/models/manual_music_preparation.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/videos/models/ided_video.dart';

/// Lets tests release native preparation independently of catalog metadata.
class HeldMusicPreparer implements ManualMusicPreparer {
  final requests = <String, Completer<bool>>{};
  final current = <String, bool Function()>{};
  final skippedDownloads = <String, bool>{};
  final started = Completer<IdedVideo>();

  @override
  Future<bool> prepareMusicSelection(
      IdedVideo entry, Duration startAt, bool Function() isCurrent,
      {bool skipDownload = false}) {
    final id = playbackQueueId(entry);
    current[id] = isCurrent;
    skippedDownloads[id] = skipDownload;
    final request = requests[id] = Completer<bool>();
    if (!started.isCompleted) started.complete(entry);
    return request.future;
  }

  @override
  void cancelMusicSelection() {}
}
