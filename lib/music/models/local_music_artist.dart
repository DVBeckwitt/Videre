import 'local_music_track.dart';

enum LocalMusicArtistRole { trackArtist, albumArtist }

class LocalMusicArtistCredit {
  const LocalMusicArtistCredit(this.key, this.name, this.roles);

  final String key;
  final String name;
  final List<LocalMusicArtistRole> roles;
}

class LocalMusicArtist {
  const LocalMusicArtist._(this.key, this.name, this.tracks);

  final String key;
  final String name;
  final List<LocalMusicTrack> tracks;

  bool get hasAlbumArtistCredit => tracks.any((track) =>
      localMusicArtistCredit(track, key)
          ?.roles
          .contains(LocalMusicArtistRole.albumArtist) ==
      true);
}

String? localMusicArtistKey(String? name) {
  final key = name?.trim().toLowerCase();
  return key == null || key.isEmpty || key == '<unknown>' ? null : key;
}

/// Combines artist roles in credit order using each artist's first spelling.
List<LocalMusicArtistCredit> localMusicArtistCredits(LocalMusicTrack track) {
  final credits = <String, ({String name, Set<LocalMusicArtistRole> roles})>{};
  for (final (names, role) in [
    (track.artists, LocalMusicArtistRole.trackArtist),
    (track.albumArtists, LocalMusicArtistRole.albumArtist),
  ]) {
    for (final name in names) {
      final key = localMusicArtistKey(name);
      if (key == null) continue;
      credits
          .putIfAbsent(key, () => (name: name.trim(), roles: {}))
          .roles
          .add(role);
    }
  }
  return [
    for (final credit in credits.entries)
      LocalMusicArtistCredit(
          credit.key, credit.value.name, List.unmodifiable(credit.value.roles)),
  ];
}

LocalMusicArtistCredit? localMusicArtistCredit(
        LocalMusicTrack track, String key) =>
    localMusicArtistCredits(track)
        .where((credit) => credit.key == key)
        .firstOrNull;

/// Builds navigation groups from the caller's current visible source snapshot.
List<LocalMusicArtist> groupLocalMusicArtists(
    Iterable<LocalMusicTrack> tracks) {
  final groups = <String, ({String name, List<LocalMusicTrack> tracks})>{};
  for (final track in tracks) {
    for (final credit in localMusicArtistCredits(track)) {
      final group =
          groups.putIfAbsent(credit.key, () => (name: credit.name, tracks: []));
      group.tracks.add(track);
    }
  }
  return [
    for (final group in groups.entries)
      LocalMusicArtist._(
          group.key, group.value.name, List.unmodifiable(group.value.tracks)),
  ];
}

LocalMusicArtist? findLocalMusicArtist(
    Iterable<LocalMusicTrack> tracks, String key) {
  String? name;
  final members = <LocalMusicTrack>[];
  for (final track in tracks) {
    final credit = localMusicArtistCredit(track, key);
    if (credit == null) continue;
    name ??= credit.name;
    members.add(track);
  }
  return name == null
      ? null
      : LocalMusicArtist._(key, name, List.unmodifiable(members));
}
