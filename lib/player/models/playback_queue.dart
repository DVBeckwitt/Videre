import '../../videos/models/ided_video.dart';
import '../../videos/models/video.dart';

/// An upload can occur more than once in a playlist. Keep its network ID apart
/// from the identity used for queue navigation, reordering and saved sessions.
String playbackQueueId(IdedVideo video) =>
    video is Video ? video.queueEntryId ?? video.videoId : video.videoId;

/// Muzza's PlayerExt.getQueueWindows traverses the player timeline through
/// previous, current and next windows, including the active shuffle order.
/// Videre has separate source and traversal lists. Use each occurrence once
/// and give an explicitly queued repeat priority over its earlier history.
List<T> playbackQueueTraversal<T extends IdedVideo>(
  Iterable<T> entries, {
  required Iterable<String> played,
  required String? current,
  required Iterable<String> upcoming,
}) {
  final remaining = {
    for (final entry in entries) playbackQueueId(entry): entry
  };
  final next = upcoming.where((id) => id != current).toSet();
  return [
    for (final id in played)
      if (id != current && !next.contains(id))
        if (remaining.remove(id) case final entry?) entry,
    if (remaining.remove(current) case final entry?) entry,
    for (final id in next)
      if (remaining.remove(id) case final entry?) entry,
    // A source may be awaiting its initial transition or a playlist append.
    ...remaining.values,
  ];
}

/// Unique-ID queues keep their existing IDs, including in legacy sessions.
/// Only collisions need a local key, retained when the queue is reordered.
List<Video> assignPlaybackQueueIds(Iterable<Video> videos) {
  final items = videos.toList();
  final reserved = items.map(playbackQueueId).toSet();
  final used = <String>{};
  var sequence = 0;
  return items.map((video) {
    final key = playbackQueueId(video);
    if (used.add(key)) return video;
    String unique;
    do {
      unique = '${video.videoId}#${++sequence}';
    } while (reserved.contains(unique) || used.contains(unique));
    used.add(unique);
    return video.copyWith(queueEntryId: unique);
  }).toList();
}
