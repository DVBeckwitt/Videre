import 'music_artist.dart';
import 'music_playlist.dart';
import 'music_track.dart';

enum MusicCatalogSearchType { all, songs, channels, playlists }

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

final class MusicCatalogChannelHit extends MusicCatalogSearchHit {
  const MusicCatalogChannelHit(this.artist);

  final MusicArtist artist;

  @override
  MusicCatalogSearchType get type => MusicCatalogSearchType.channels;

  @override
  String get id => artist.id;
}

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
