import 'package:flutter/foundation.dart';

import 'local_music_album.dart';

/// A listener's choice among exact releases in the device catalog.
class LocalMusicAlbumEditionGroup {
  static final _albumKey = RegExp(r'^[a-f0-9]{64}$');

  final List<String> albumKeys;
  final String preferredKey;

  LocalMusicAlbumEditionGroup._(Iterable<String> albumKeys, this.preferredKey)
      : albumKeys = List.unmodifiable(albumKeys);

  static LocalMusicAlbumEditionGroup? tryCreate(
      List<String> albumKeys, String preferredKey) {
    final distinct = albumKeys.toSet();
    if (distinct.length < 2 ||
        distinct.length != albumKeys.length ||
        !distinct.contains(preferredKey) ||
        distinct.any((key) => _albumKey.stringMatch(key) != key)) {
      return null;
    }
    return LocalMusicAlbumEditionGroup._(albumKeys, preferredKey);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalMusicAlbumEditionGroup &&
      preferredKey == other.preferredKey &&
      listEquals(albumKeys, other.albumKeys);

  @override
  int get hashCode => Object.hash(preferredKey, Object.hashAll(albumKeys));
}

/// Selects one exact, currently visible release per group for album browsing.
/// The saved member order supplies a fallback while the preferred copy is away.
List<LocalMusicAlbum> browseLocalMusicAlbumEditions(
    List<LocalMusicAlbum> albums, List<LocalMusicAlbumEditionGroup> groups) {
  final visible = albums.map((album) => album.key).toSet();
  final hidden = <String>{};
  for (final group in groups) {
    final chosen = visible.contains(group.preferredKey)
        ? group.preferredKey
        : group.albumKeys.where(visible.contains).firstOrNull;
    hidden.addAll(group.albumKeys.where((key) => key != chosen));
  }
  return List.unmodifiable(
      albums.where((album) => !hidden.contains(album.key)));
}
