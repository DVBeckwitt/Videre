import 'music_album.dart';
import 'music_artist.dart';
import 'music_playlist.dart';
import 'music_track.dart';

enum MusicCatalogSearchType {
  all,
  songs,
  albums,
  artists,
  playlists;

  // Older Music callers used the provider's channel filter name.
  static const channels = artists;
}

sealed class MusicCatalogSearchHit {
  const MusicCatalogSearchHit();

  MusicCatalogSearchType get type;
  String get id;
  String get key => keyFor(type, id);

  static String keyFor(MusicCatalogSearchType type, String id) =>
      '${type.name}:$id';
}

final class MusicCatalogSongHit extends MusicCatalogSearchHit {
  const MusicCatalogSongHit(this.track);

  final MusicTrack track;

  @override
  MusicCatalogSearchType get type => MusicCatalogSearchType.songs;

  @override
  String get id => track.videoId;
}

final class MusicCatalogAlbumHit extends MusicCatalogSearchHit {
  const MusicCatalogAlbumHit(this.album);

  final MusicAlbum album;

  @override
  MusicCatalogSearchType get type => MusicCatalogSearchType.albums;

  @override
  String get id => album.id;
}

final class MusicCatalogArtistHit extends MusicCatalogSearchHit {
  const MusicCatalogArtistHit(this.artist);

  final MusicArtist artist;

  @override
  MusicCatalogSearchType get type => MusicCatalogSearchType.artists;

  @override
  String get id => artist.id;
}

typedef MusicCatalogChannelHit = MusicCatalogArtistHit;

final class MusicCatalogPlaylistHit extends MusicCatalogSearchHit {
  const MusicCatalogPlaylistHit(this.playlist);

  final MusicPlaylist playlist;

  @override
  MusicCatalogSearchType get type => MusicCatalogSearchType.playlists;

  @override
  String get id => playlist.id;
}

/// A provider-ordered page. Raw progress survives local row rejection.
class MusicCatalogSearchPage {
  const MusicCatalogSearchPage({
    required this.hits,
    required this.rawKeys,
    int? rawCount,
  }) : _rawCount = rawCount;

  final List<MusicCatalogSearchHit> hits;

  /// Validated identities in the wire page, in order and with duplicates.
  final List<String> rawKeys;
  final int? _rawCount;

  /// All wire rows, including unsupported rows without a navigable identity.
  int get rawCount => _rawCount ?? rawKeys.length;
}
