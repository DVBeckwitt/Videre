/// A read-only playlist published by Android's media index.
class LocalMusicIndexedPlaylist {
  const LocalMusicIndexedPlaylist._(this.id, this.name, this.memberUris);

  final int id;
  final String name;

  /// Exact audio URIs in source order, including repeated occurrences.
  final List<String> memberUris;

  static List<LocalMusicIndexedPlaylist> parse(Object? documents) {
    if (documents is! List) return const [];
    final playlists = <int, LocalMusicIndexedPlaylist>{};
    for (final document in documents) {
      if (document is! Map) continue;
      final id = document['id'];
      final name = document['name'];
      final members = document['memberUris'];
      if (id is! int || id <= 0 || name is! String || members is! List) {
        continue;
      }
      final label = name.trim();
      if (label.isEmpty) continue;
      playlists[id] = LocalMusicIndexedPlaylist._(
          id, label, List.unmodifiable(members.whereType<String>()));
    }
    return List.unmodifiable(playlists.values);
  }
}
