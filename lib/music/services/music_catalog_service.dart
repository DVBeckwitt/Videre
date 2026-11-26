import 'dart:async';
import 'dart:io';

import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/invidious_music_catalog_service.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/videos/models/video.dart';

MusicCatalogService musicCatalogService = InvidiousMusicCatalogService();

const musicExploreGenres = ['pop', 'jazz', 'classical', 'electronic'];
const musicPlaylistOverlapCandidateLimit = 6;

final _publicMusicPlaylistId = RegExp(r'^PL[A-Za-z0-9_-]{1,126}$');

/// Ordinary YouTube playlists can be checked through the catalog's public
/// playlist endpoint. Dynamic mixes, releases and account lists stay out.
bool isMusicPlaylistOverlapCandidate(String id) =>
    _publicMusicPlaylistId.stringMatch(id) == id;

bool musicDiscoveryMustStop(Object error) =>
    error is InvidiousServiceError &&
    (error.isRateLimited ||
        error.retryAfterIsInvalid ||
        (error.retryAfter ?? Duration.zero) > Duration.zero ||
        error.isAuthenticationFailure ||
        error.isGatewayAccessFailure);

bool isMusicBrowseConnectionFailure(Object? error) =>
    error is MusicCatalogConnectionFailure ||
    error is SocketException ||
    error is TimeoutException ||
    error is TlsException ||
    error is GatewayTransportUnavailable ||
    (error is InvidiousServiceError &&
        !error.isGatewayAccessFailure &&
        const {408, 502, 503, 504}.contains(error.statusCode));

class MusicCatalogException implements Exception {
  final String message;

  const MusicCatalogException(this.message);

  @override
  String toString() => message;
}

/// Discovery could not finish verifying candidates because the connection failed.
class MusicCatalogConnectionFailure extends MusicCatalogException {
  const MusicCatalogConnectionFailure(super.message);
}

class MusicCatalogUnsupported extends MusicCatalogException {
  const MusicCatalogUnsupported()
      : super('This catalog feature is not available through Invidious.');
}

enum MusicRecordingAvailability { available, missing }

/// Standard Invidious Music catalog contract with no network implementation. An
/// unsupported or forgotten override must fail without contacting another host.
/// Historical direct-catalog parsing fixtures live under test/, not in the app.
abstract class MusicCatalogService {
  static const artistMixSeedLimit = 3;

  /// Optional suggestions for a draft in Online Search.
  Future<List<String>> searchSuggestions(String query,
          {bool Function()? isCurrent}) async =>
      const [];

  Future<List<MusicTrack>> searchSongs(String query) async =>
      throw const MusicCatalogUnsupported();

  Future<List<MusicAlbum>> searchAlbums(String query) async =>
      throw const MusicCatalogUnsupported();

  Future<List<MusicArtist>> searchArtists(String query) async =>
      throw const MusicCatalogUnsupported();

  Future<List<MusicPlaylist>> searchPlaylists(String query) async =>
      throw const MusicCatalogUnsupported();

  /// One ordered search page. An adapter that only supplies typed results can
  /// still support page one of those types through the original methods.
  Future<MusicCatalogSearchPage> searchPage(
    String query,
    MusicCatalogSearchType type,
    int page, {
    bool Function()? isCurrent,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    void check() {
      if (isCurrent?.call() == false) {
        throw const MusicCatalogException('The music request was cancelled.');
      }
    }

    check();
    final text = query.trim();
    if (text.isEmpty || page > 1) {
      return const MusicCatalogSearchPage(hits: [], rawKeys: []);
    }
    final List<MusicCatalogSearchHit> hits = switch (type) {
      MusicCatalogSearchType.all => throw const MusicCatalogUnsupported(),
      MusicCatalogSearchType.songs =>
        (await searchSongs(text)).map(MusicCatalogSongHit.new).toList(),
      MusicCatalogSearchType.albums =>
        (await searchAlbums(text)).map(MusicCatalogAlbumHit.new).toList(),
      MusicCatalogSearchType.artists =>
        (await searchArtists(text)).map(MusicCatalogArtistHit.new).toList(),
      MusicCatalogSearchType.playlists =>
        (await searchPlaylists(text)).map(MusicCatalogPlaylistHit.new).toList(),
    };
    check();
    final seen = <String>{};
    return MusicCatalogSearchPage(hits: [
      for (final hit in hits)
        if (seen.add(hit.key)) hit
    ], rawKeys: [
      for (final hit in hits) hit.key
    ]);
  }

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

  /// Checks one catalog recording with fresh metadata. Only a definitive
  /// recording-level result is reported as missing. Indeterminate results throw.
  Future<MusicRecordingAvailability> checkRecordingAvailability(String videoId,
          {required bool Function() isCurrent}) async =>
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

  /// Verified music from the selected channels and their related recordings.
  Future<List<MusicTrack>> getArtistMixSongs(Iterable<String> artistIds,
          {bool Function()? isCurrent}) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicArtistPage> getArtist(String id) async =>
      throw const MusicCatalogUnsupported();

  /// Loads the channel separately when the adapter can defer its uploads.
  Future<MusicArtistPage> getArtistOverview(String id) => getArtist(id);

  Future<List<MusicTrack>> getArtistUploads(
    String id, {
    bool Function()? isCurrent,
  }) async =>
      throw const MusicCatalogUnsupported();

  /// Searches one artist channel at the connection that opened the catalog.
  Future<MusicArtistSongSearchPage> searchArtistSongs(
    String artistId,
    String query,
    int page, {
    Server? expectedServer,
    bool Function()? isCurrent,
  }) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicArtistReleases> getArtistReleases(String id,
          {String? continuation,
          Server? expectedServer,
          bool Function()? isCurrent}) async =>
      throw const MusicCatalogUnsupported();

  /// Finds overlap among the profile's saved public playlist IDs. Adapters
  /// that cannot verify public track membership can leave the shelf empty.
  Future<List<MusicPlaylist>> findPlaylistsWithSongsInCommon(
          String playlistId, List<String> savedPlaylistIds,
          {required bool Function() isCurrent}) async =>
      const [];

  /// Reads the first page of a known regional or worldwide Music chart.
  Future<List<MusicTrack>> getChartSongs(String playlistId,
          {bool Function()? isCurrent}) async =>
      throw const MusicCatalogUnsupported();

  Future<MusicCollection> getPlaylist(String id) async =>
      throw const MusicCatalogUnsupported();

  /// Publishes ordered snapshots as validated playlist pages arrive.
  Future<MusicCollection> getPlaylistProgressively(String id,
          {required void Function(MusicCollection) onProgress,
          required bool Function() isCurrent}) =>
      getPlaylist(id);
}
