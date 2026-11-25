import '../../downloads/models/downloaded_video.dart';
import '../../music/models/music_search_text.dart';
import '../../videos/models/ided_video.dart';
import '../../videos/models/video.dart';
import 'local_music_playback.dart';

({String title, String artist}) musicQueueLabels(IdedVideo entry) {
  final (music, title, author) = switch (entry) {
    Video() => (entry.musicMetadata, entry.title, entry.author),
    DownloadedVideo() => (entry.musicMetadata, entry.title, entry.author),
    _ => (null, null, null),
  };
  return (
    title: music?.title ?? title ?? '',
    artist: music?.artist ?? author ?? '',
  );
}

enum MusicQueueSort {
  titleAscending,
  titleDescending,
  artistAscending,
  artistDescending;

  List<String> sortUpcoming(Iterable<IdedVideo> entries) {
    final byArtist = this == artistAscending || this == artistDescending;
    final descending = this == titleDescending || this == artistDescending;
    final songs = entries.indexed.map((row) {
      final (index, entry) = row;
      final labels = musicQueueLabels(entry);
      final label = byArtist ? labels.artist : labels.title;
      return (
        index: index,
        id: playbackQueueId(entry),
        key: normalizeMusicSearchText(label.trim()),
      );
    }).toList();
    songs.sort((first, second) {
      if (first.key == second.key) return first.index.compareTo(second.index);
      if (first.key.isEmpty) return 1;
      if (second.key.isEmpty) return -1;
      return descending
          ? second.key.compareTo(first.key)
          : first.key.compareTo(second.key);
    });
    return songs.map((song) => song.id).toList();
  }
}

/// An upload can occur more than once in a playlist. Keep its network ID apart
/// from the identity used for queue navigation, reordering and saved sessions.
String playbackQueueId(IdedVideo video) {
  if (video is Video) return video.queueEntryId ?? video.videoId;
  if (video is DownloadedVideo) {
    final key = video.queueEntryId;
    if (key != null && savedDownloadSourceId(key) == video.videoId) return key;
  }
  return video.videoId;
}

final _savedOccurrenceOrdinal = RegExp(r'^[1-9][0-9]*$');

/// A saved download has a filesystem-safe source ID. Its queue copies may
/// append a positive decimal ordinal, which is never part of the filename.
String? savedDownloadSourceId(String occurrence) {
  final separator = occurrence.indexOf('#');
  final source =
      separator < 0 ? occurrence : occurrence.substring(0, separator);
  if (!DownloadedVideo.isSafeFileId(source)) return null;
  if (separator >= 0) {
    final ordinal = occurrence.substring(separator + 1);
    if (_savedOccurrenceOrdinal.stringMatch(ordinal) != ordinal) return null;
  }
  return source;
}

/// Keep existing occurrences stable on reorder and reserve their keys before
/// assigning copies. Device entries already carry their own catalog queue IDs.
List<DownloadedVideo> assignDownloadedQueueIds(
    Iterable<DownloadedVideo> videos) {
  final entries = videos.toList();
  final reserved = entries.map(playbackQueueId).toSet();
  final used = <String>{};
  var ordinal = 0;
  return entries.map((video) {
    if (isLocalMusicPlaybackId(video.videoId)) return video;
    if (!DownloadedVideo.isSafeFileId(video.videoId)) {
      throw const FormatException('Invalid saved download ID');
    }
    final key = playbackQueueId(video);
    if (used.add(key)) {
      return video.queueEntryId != null && video.queueEntryId != key
          ? video.copyWith(queueEntryId: null)
          : video;
    }
    String unique;
    do {
      unique = '${video.videoId}#${++ordinal}';
    } while (reserved.contains(unique) || used.contains(unique));
    used.add(unique);
    return video.copyWith(queueEntryId: unique);
  }).toList();
}

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
