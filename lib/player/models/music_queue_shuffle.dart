import 'dart:collection';
import 'dart:math';

import '../../downloads/models/downloaded_video.dart';
import '../../music/models/local_music_album.dart';
import '../../music/models/local_music_track.dart';
import '../../videos/models/ided_video.dart';
import '../../videos/models/video.dart';
import 'local_music_playback.dart';
import 'playback_queue.dart';

typedef _UnitEntry = ({String id, LocalMusicTrack? track});
typedef _SourceBucket = ({
  int tie,
  bool matchesFollowing,
  ListQueue<String> occurrences,
});

enum MusicQueueShuffle {
  albums,
  folders,
  fewerRepeats;

  /// Shuffles the supplied upcoming occurrences between fixed queue entries.
  List<String> shuffleUpcoming({
    required Iterable<IdedVideo> entries,
    required IdedVideo? previous,
    required LocalMusicTrack? Function(String) deviceTrackForId,
    IdedVideo? following,
    Random? random,
  }) {
    if (this == fewerRepeats) {
      return _spaceOccurrences(entries,
          previous: previous, following: following, random: random);
    }

    LocalMusicTrack? deviceTrack(IdedVideo entry) =>
        isLocalMusicPlaybackId(entry.videoId)
            ? deviceTrackForId(localMusicTrackId(entry.videoId))
            : null;

    (String, String)? unitKey(IdedVideo entry, LocalMusicTrack? track) {
      if (this == folders) {
        final key = track?.folderLocations.lastOrNull?.key;
        return key == null ? null : ('folder', key);
      }
      if (isLocalMusicPlaybackId(entry.videoId)) {
        final key = track?.albumKey;
        return key == null ? null : ('device album', key);
      }
      final key = switch (entry) {
        Video() => entry.musicMetadata?.albumPlaylistId,
        DownloadedVideo() => entry.musicMetadata?.albumPlaylistId,
        _ => null,
      };
      return key == null ? null : ('catalog album', key);
    }

    final byKey = <(String, String), List<_UnitEntry>>{};
    final units = <List<_UnitEntry>>[];
    for (final entry in entries) {
      final track = deviceTrack(entry);
      final item = (id: playbackQueueId(entry), track: track);
      final key = unitKey(entry, track);
      if (key == null) {
        units.add([item]);
      } else {
        byKey.putIfAbsent(key, () {
          final unit = <_UnitEntry>[];
          units.add(unit);
          return unit;
        }).add(item);
      }
    }
    units.shuffle(random);

    final previousKey =
        previous == null ? null : unitKey(previous, deviceTrack(previous));
    if (units.length > 1 && identical(units.first, byKey[previousKey])) {
      final justHeard = units.removeAt(0);
      units.insert(1 + (random ?? Random()).nextInt(units.length), justHeard);
    }

    return [
      for (final unit in units)
        if (this == albums && unit.length > 1 && unit.first.track != null)
          ..._orderDeviceAlbum(unit)
        else
          for (final item in unit) item.id,
    ];
  }
}

Iterable<String> _orderDeviceAlbum(List<_UnitEntry> unit) sync* {
  // Several occurrences may refer to the same authorized track object.
  final idsByTrack = Map<LocalMusicTrack, ListQueue<String>>.identity();
  for (final item in unit) {
    (idsByTrack[item.track!] ??= ListQueue()).add(item.id);
  }
  final ordered = orderLocalMusicAlbumTracks(unit.map((item) => item.track!));
  for (final track in ordered) {
    yield idsByTrack[track]!.removeFirst();
  }
}

String _sourceId(IdedVideo entry) => isLocalMusicPlaybackId(entry.videoId)
    ? localMusicTrackId(entry.videoId)
    : entry.videoId;

List<String> _spaceOccurrences(
  Iterable<IdedVideo> entries, {
  required IdedVideo? previous,
  required IdedVideo? following,
  required Random? random,
}) {
  final bySource = <String, ListQueue<String>>{};
  for (final entry in entries) {
    (bySource[_sourceId(entry)] ??= ListQueue()).add(playbackQueueId(entry));
  }

  final sources = bySource.keys.toList()..shuffle(random);
  final available = SplayTreeSet<_SourceBucket>((first, second) {
    final count = second.occurrences.length.compareTo(first.occurrences.length);
    if (count != 0) return count;
    // Schedule tied copies of the following source earlier so another source
    // can separate them from the fixed entry at the end of the range.
    if (first.matchesFollowing != second.matchesFollowing) {
      return first.matchesFollowing ? -1 : 1;
    }
    return first.tie.compareTo(second.tie);
  });
  final previousSource = previous == null ? null : _sourceId(previous);
  final followingSource = following == null ? null : _sourceId(following);
  _SourceBucket? last;
  for (final (index, source) in sources.indexed) {
    final bucket = (
      tie: index,
      matchesFollowing: source == followingSource,
      occurrences: bySource[source]!,
    );
    if (source == previousSource) {
      last = bucket;
    } else {
      available.add(bucket);
    }
  }

  final order = <String>[];
  while (available.isNotEmpty || last != null) {
    // Keep the last source out of the set while another source can play.
    final bucket = available.isEmpty ? last! : available.first;
    if (available.remove(bucket) && last != null) available.add(last);
    order.add(bucket.occurrences.removeFirst());
    last = bucket.occurrences.isEmpty ? null : bucket;
  }
  return order;
}
