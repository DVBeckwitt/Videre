import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/invidious_music_catalog_service.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/videos/models/video.dart';

MusicCatalogService musicCatalogService = InvidiousMusicCatalogService();

const musicExploreGenres = ['pop', 'jazz', 'classical', 'electronic'];

bool musicDiscoveryMustStop(Object error) =>
    error is InvidiousServiceError &&
    (error.isRateLimited ||
        error.retryAfterIsInvalid ||
        (error.retryAfter ?? Duration.zero) > Duration.zero ||
        error.isAuthenticationFailure ||
        error.isGatewayAccessFailure);

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

  /// Bounded discovery verified against full Invidious video metadata. An
  /// artist seed narrows the search and excludes the profile's saved songs.
  /// Callers can revoke the request when its screen or session is replaced.
  /// [onInstanceFailure] stops further batches while this one can still
  /// return recordings verified before the instance rejected a request.
  Future<List<MusicTrack>> getDiscoverySongs(
          {String? artist,
          bool Function()? isCurrent,
          void Function(InvidiousServiceError)? onInstanceFailure}) async =>
      throw const MusicCatalogUnsupported();

  /// Finds verified recordings for one of the Music Home Explore genres.
  Future<List<MusicTrack>> getGenreSongs(String genre,
          {bool Function()? isCurrent,
          void Function(InvidiousServiceError)? onInstanceFailure}) async =>
      throw const MusicCatalogUnsupported();

  /// Fetches one batch related to up to three learned recordings. The catalog
  /// verifies each returned song against full metadata.
  Future<List<MusicTrack>> getRelatedSongs(Iterable<String> seedIds,
          {bool Function()? isCurrent}) async =>
      throw const MusicCatalogUnsupported();

  /// Inspects a small followed-channel upload pool. Feed metadata alone does
  /// not establish that an upload is music or that its creator matches.
  Future<List<MusicTrack>> getSubscriptionSongs(Iterable<Video> uploads,
          {required Server expectedServer, bool Function()? isCurrent}) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicTrack> getSong(String videoId,
          {VideoLoadObserver? loadObserver}) async =>
      throw const MusicCatalogUnsupported();

  /// A visual counterpart for the active online recording, if its selected
  /// instance supplies one. Local files and downloaded recordings stay local.
  Future<Video?> findMusicVideo(Video song,
          {required bool Function() isCurrent}) async =>
      null;

  /// Loads display details for explicitly selected saved IDs. Reports null
  /// for an unavailable recording and stops on connection-wide failures.
  Future<void> loadSavedSongDetails(Iterable<String> ids,
          {required bool Function() isCurrent,
          required Future<void> Function(String id, MusicLibraryEntry? details)
              onResult}) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicArtistPage> getArtist(String id) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicArtistReleases> getArtistReleases(String id,
          {String? continuation, bool Function()? isCurrent}) async =>
      throw const MusicCatalogUnsupported();

  /// Reads the first page of a known regional or worldwide Music chart.
  Future<List<MusicTrack>> getChartSongs(String playlistId,
          {bool Function()? isCurrent}) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicCollection> getPlaylist(String id) async =>
      throw const MusicCatalogUnsupported();
}
