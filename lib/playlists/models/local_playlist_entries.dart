import 'dart:convert';

import 'package:uuid/enums.dart';
import 'package:uuid/uuid.dart';

import '../../videos/models/video.dart';
import 'playlist.dart';
import 'playlist_reference.dart';

final _storedEntryId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _migratedEntryId = RegExp(r'^legacy-[a-f0-9-]{36}$');

String _migrateEntryId(String playlistId, String oldQueueKey, [int salt = 0]) =>
    'legacy-${const Uuid().v5(Namespace.url.value, jsonEncode([
              playlistId,
              oldQueueKey,
              salt
            ]))}';

/// Persist one unique indexId per local occurrence. Deriving legacy IDs from
/// the full original order lets older saved queue keys identify the same copy.
Playlist normalizeLocalPlaylistEntries(Playlist playlist) {
  if (!playlist.isLocal) return playlist;
  String? usableId(Video video) {
    final id = video.indexId;
    // Older portable backups assigned the recording ID to every copy.
    return id != null && id != video.videoId && _storedEntryId.hasMatch(id)
        ? id
        : null;
  }

  final reserved = playlist.videos.map(usableId).nonNulls.toSet();
  final seen = <String>{};
  List<Video>? originalQueue;
  var migrated = false;
  final videos = <Video>[];
  for (final (index, video) in playlist.videos.indexed) {
    final current = usableId(video);
    if (current != null && seen.add(current)) {
      videos.add(video);
      continue;
    }
    originalQueue ??= assignPlaylistEntryIds(playlist.videos.map(
        (v) => v.queueEntryId == null ? v : v.copyWith(queueEntryId: null)));
    final oldQueueKey = originalQueue[index].queueEntryId!;
    var salt = 0;
    var id = _migrateEntryId(playlist.playlistId, oldQueueKey);
    while (!reserved.add(id)) {
      id = _migrateEntryId(playlist.playlistId, oldQueueKey, ++salt);
    }
    migrated = true;
    videos.add(video.copyWith(indexId: id, queueEntryId: null));
  }
  return migrated ? playlist.copyWith(videos: videos) : playlist;
}

/// Match the current key or the key saved before a legacy row was migrated.
bool matchesLocalPlaylistEntryKey(
    String playlistId, Video candidate, String videoId, String? queueKey) {
  if (candidate.videoId != videoId || queueKey == null) return false;
  if ((candidate.queueEntryId ?? playlistSourceEntryId(candidate)) ==
      queueKey) {
    return true;
  }
  final id = candidate.indexId;
  return id != null &&
      _migratedEntryId.hasMatch(id) &&
      queueKey.startsWith('playlist:') &&
      id == _migrateEntryId(playlistId, queueKey);
}

/// Preserve destination order and merge explicit identities. A historical
/// backup lacks original identities, so use each unmatched destination copy
/// once when comparing its repeated recordings.
Playlist mergeLocalPlaylistEntries(
    Playlist existing, Playlist imported, Set<String> unidentifiedIds) {
  final existingIds = existing.videos.map((video) => video.indexId!).toSet();
  final incomingIds = imported.videos.map((video) => video.indexId!).toSet();
  final unmatched = <String, int>{};
  for (final video in existing.videos) {
    if (!incomingIds.contains(video.indexId)) {
      unmatched.update(video.videoId, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  final videos = [...existing.videos];
  for (final video in imported.videos) {
    final id = video.indexId!;
    if (existingIds.contains(id)) continue;
    final count = unmatched[video.videoId] ?? 0;
    if (count > 0 && unidentifiedIds.contains(id)) {
      unmatched[video.videoId] = count - 1;
      continue;
    }
    videos.add(video);
  }
  return existing.copyWith(videos: videos, videoCount: videos.length);
}
