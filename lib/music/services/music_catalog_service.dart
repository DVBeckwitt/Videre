import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/invidious_music_catalog_service.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;

MusicCatalogService musicCatalogService = InvidiousMusicCatalogService();

class MusicCatalogException implements Exception {
  final String message;

  const MusicCatalogException(this.message);

  @override
  String toString() => message;
}

class MusicCatalogUnsupported extends MusicCatalogException {
  const MusicCatalogUnsupported()
      : super('This catalog feature is not available through Invidious.');
}

/// Standard Invidious Music catalog contract with no network implementation. An
/// unsupported or forgotten override must fail without contacting another host.
/// Historical direct-catalog parsing fixtures live under test/, not in the app.
abstract class MusicCatalogService {
  Future<List<MusicTrack>> searchSongs(String query) async =>
      throw const MusicCatalogUnsupported();

  Future<List<MusicArtist>> searchArtists(String query) async =>
      throw const MusicCatalogUnsupported();

  Future<List<MusicPlaylist>> searchPlaylists(String query) async =>
      throw const MusicCatalogUnsupported();

  Future<List<MusicTrack>> getTrendingSongs() async =>
      throw const MusicCatalogUnsupported();

  Future<MusicTrack> getSong(String videoId,
          {VideoLoadObserver? loadObserver}) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicArtistPage> getArtist(String id) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicCollection> getPlaylist(String id) async =>
      throw const MusicCatalogUnsupported();
}
