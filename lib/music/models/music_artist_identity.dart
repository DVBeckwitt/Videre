import 'package:clipious/content_filter/community_models.dart';

import 'local_music_artist.dart';

enum MusicArtistSource { catalog, device }

/// Identifies an artist by a catalog channel or an existing device group.
/// The display label can change while this identity continues to resolve it.
class MusicArtistIdentity {
  const MusicArtistIdentity.catalog(this.id)
      : source = MusicArtistSource.catalog;

  const MusicArtistIdentity.device(this.id) : source = MusicArtistSource.device;

  final MusicArtistSource source;
  final String id;

  bool get isValid => switch (source) {
        MusicArtistSource.catalog => normalizeChannelId(id) == id,
        MusicArtistSource.device =>
          id.length <= 1024 && localMusicArtistKey(id) == id,
      };

  String get storageKey => '${source.name}:$id';

  static MusicArtistIdentity? fromStorageKey(String key) {
    final separator = key.indexOf(':');
    if (separator < 0) return null;
    final id = key.substring(separator + 1);
    final identity = switch (key.substring(0, separator)) {
      'catalog' => MusicArtistIdentity.catalog(id),
      'device' => MusicArtistIdentity.device(id),
      _ => null,
    };
    return identity?.isValid == true ? identity : null;
  }

  @override
  bool operator ==(Object other) =>
      other is MusicArtistIdentity && other.source == source && other.id == id;

  @override
  int get hashCode => Object.hash(source, id);
}

final _artistAliasControls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

String? normalizeMusicArtistAlias(String? value) {
  if (value == null) return null;
  final clean = value.replaceAll(_artistAliasControls, ' ').trim();
  return clean.isEmpty || clean.runes.length > 1024 ? null : clean;
}
