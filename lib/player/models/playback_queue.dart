import '../../videos/models/ided_video.dart';
import '../../videos/models/video.dart';

/// An upload can occur more than once in a playlist. Keep its network ID apart
/// from the identity used for queue navigation, reordering and saved sessions.
String playbackQueueId(IdedVideo video) =>
    video is Video ? video.queueEntryId ?? video.videoId : video.videoId;

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
