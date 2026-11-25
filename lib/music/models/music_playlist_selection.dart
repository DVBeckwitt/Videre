import 'dart:collection';
import 'dart:convert';

import '../../playlists/models/playlist_reference.dart';
import '../../videos/models/video.dart';

typedef _Occurrence = ({String videoId, String? sourceId, bool ambiguous});

class MusicPlaylistSelection {
  final _selected = <String>{};
  late final Set<String> selected = UnmodifiableSetView(_selected);
  Map<String, _Occurrence> _rows = {};
  String? _duplicateSnapshot;

  /// Reconcile against the entire playlist and return the keyed source rows.
  List<Video> reconcile(List<Video> raw) {
    final assigned = assignPlaylistEntryIds(raw);
    final videoCounts = <String, int>{};
    final sourceIds = <String?>[];
    final sourceCounts = <String, int>{};
    for (final video in raw) {
      videoCounts.update(video.videoId, (count) => count + 1,
          ifAbsent: () => 1);
      final sourceId = video.queueEntryId ?? playlistSourceEntryId(video);
      sourceIds.add(sourceId);
      if (sourceId != null) {
        sourceCounts.update(sourceId, (count) => count + 1, ifAbsent: () => 1);
      }
    }

    final rows = <String, _Occurrence>{};
    final ambiguous = <int>{};
    for (final (i, video) in raw.indexed) {
      final sourceId = sourceIds[i];
      final repeated = sourceId == null
          ? videoCounts[video.videoId]! > 1
          : sourceCounts[sourceId]! > 1;
      if (repeated) ambiguous.add(i);
      if (video.musicMetadata == null) continue;
      rows[assigned[i].queueEntryId!] =
          (videoId: video.videoId, sourceId: sourceId, ambiguous: repeated);
    }
    // An ordinal or collision suffix can move to a different copy. Without a
    // unique source identity, even moving indistinguishable copies past an
    // unrelated song is ambiguous. Retain them only across equivalent lists.
    final snapshot = ambiguous.isEmpty
        ? null
        : jsonEncode([
            for (final (i, video) in raw.indexed)
              [
                assigned[i].queueEntryId,
                sourceIds[i],
                video.videoId,
                video.musicMetadata != null,
                if (ambiguous.contains(i)) video
              ],
          ]);
    final duplicatesChanged = snapshot != _duplicateSnapshot;
    _selected.removeWhere((id) =>
        rows[id] != _rows[id] ||
        (duplicatesChanged && rows[id]?.ambiguous == true));
    _duplicateSnapshot = snapshot;
    _rows = rows;
    return assigned;
  }

  void clear() => _selected.clear();

  void toggle(String rowId) {
    if (_rows.containsKey(rowId) && !_selected.remove(rowId)) {
      _selected.add(rowId);
    }
  }

  void toggleAll(Iterable<String> visibleIds) {
    final visible = visibleIds.where(_rows.containsKey).toSet();
    if (visible.isEmpty) return;
    final select = !visible.every(_selected.contains);
    _selected.clear();
    if (select) _selected.addAll(visible);
  }
}
