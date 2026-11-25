import 'local_music_track.dart';

/// A release identified by the authorized native catalog.
class LocalMusicAlbum {
  final String key;
  final String title;
  final String? albumArtist;
  final String? releaseDate;
  final String? originalReleaseDate;
  final List<LocalMusicTrack> tracks;

  LocalMusicAlbum._(this.key, this.title, List<LocalMusicTrack> members)
      : albumArtist = _albumArtist(members),
        releaseDate = _sharedDate(members.map((track) => track.releaseDate)),
        originalReleaseDate =
            _sharedDate(members.map((track) => track.originalReleaseDate)),
        tracks = orderLocalMusicAlbumTracks(members);
}

/// Uses only catalog keys, and keeps the order of a release's first occurrence.
List<LocalMusicAlbum> groupLocalMusicAlbums(Iterable<LocalMusicTrack> tracks) {
  final groups = <String, List<LocalMusicTrack>>{};
  for (final track in tracks) {
    final key = track.albumKey;
    if (key == null || (track.album?.trim().isEmpty ?? true)) continue;
    (groups[key] ??= []).add(track);
  }
  return List.unmodifiable([
    for (final group in groups.entries)
      LocalMusicAlbum._(
          group.key, group.value.first.album!.trim(), group.value),
  ]);
}

LocalMusicAlbum? findLocalMusicAlbum(
    Iterable<LocalMusicTrack> tracks, String key) {
  final groups =
      groupLocalMusicAlbums(tracks.where((track) => track.albumKey == key));
  return groups.firstOrNull;
}

/// Orders occurrences by disc and track while retaining input order for ties.
/// A numbered track without a disc belongs to the first disc. Rows with no
/// position follow the numbered discs.
List<LocalMusicTrack> orderLocalMusicAlbumTracks(
    Iterable<LocalMusicTrack> tracks) {
  final entries = tracks.indexed.toList();
  entries.sort((a, b) {
    final first = a.$2;
    final second = b.$2;
    final disc = _comparePosition(_discPosition(first), _discPosition(second));
    if (disc != 0) return disc;
    final track = _comparePosition(first.trackNumber, second.trackNumber);
    return track == 0 ? a.$1.compareTo(b.$1) : track;
  });
  return List.unmodifiable(entries.map((entry) => entry.$2));
}

int? _discPosition(LocalMusicTrack track) =>
    track.discNumber ?? (track.trackNumber == null ? null : 1);

int _comparePosition(int? a, int? b) {
  if (a == b) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

String? _albumArtist(List<LocalMusicTrack> tracks) {
  final artists = tracks
      .map((track) => track.albumArtist?.trim())
      .nonNulls
      .where((artist) => artist.isNotEmpty)
      .toSet();
  return artists.length == 1 ? artists.single : null;
}

String? _sharedDate(Iterable<String?> values) {
  final dates = values.nonNulls.toSet();
  String? date;
  for (final candidate in dates) {
    if (date == null || candidate.length > date.length) date = candidate;
  }
  // Missing precision can be filled by a matching date on another track.
  // Conflicting dates do not establish a release-level date.
  return date != null && dates.every(date.startsWith) ? date : null;
}
