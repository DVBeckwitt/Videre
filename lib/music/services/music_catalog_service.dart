import 'dart:async';
import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:http/http.dart' as http;

part 'music_catalog_parser.dart';

MusicCatalogService musicCatalogService = MusicCatalogService();

class MusicCatalogException implements Exception {
  final String message;

  const MusicCatalogException(this.message);

  @override
  String toString() => message;
}

/// Public, unauthenticated YouTube Music metadata; playback still uses Invidious.
/// Search filters and renderer shapes were checked against dart_ytmusic_api
/// 1.3.7 and live public responses. Keep this unofficial endpoint boundary here.
class MusicCatalogService {
  final http.Client? _httpClient;
  final Duration requestTimeout;
  Future<Map<String, String>>? _configuration;

  MusicCatalogService({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _httpClient = httpClient;

  // Borrow the app transport so changes to its configured proxy also apply here.
  // Do not use Service's instance request builder: its credentials are unrelated.
  http.Client get _client => _httpClient ?? service.httpClient;

  static final _origin = Uri.parse('https://music.youtube.com/');
  static final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final _albumId = RegExp(r'^MPRE[a-zA-Z0-9_-]+$');
  static final _artistId = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
  static final _playlistId = RegExp(r'^(PL|OLAK5uy_|RD)[a-zA-Z0-9_-]+$');
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  Future<List<MusicTrack>> searchSongs(String query) =>
      _search(query, 'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo%3D', _track);

  Future<List<MusicAlbum>> searchAlbums(String query) =>
      _search(query, 'Eg-KAQwIABAAGAEgACgAMABqChAEEAMQCRAFEAo%3D', _album);

  Future<List<MusicArtist>> searchArtists(String query) =>
      _search(query, 'Eg-KAQwIABAAGAAgASgAMABqChAEEAMQCRAFEAo%3D', _artist);

  Future<List<MusicPlaylist>> searchPlaylists(String query) =>
      _search(query, 'Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D', _playlist);

  Future<List<T>> _search<T>(String query, String params,
      T? Function(Map<String, dynamic>) parseRow) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return [];
    final data = await _request('search', {
      'query': trimmedQuery,
      'params': params,
    });
    _requireSearchResponse(data);
    return _maps(data, 'musicResponsiveListItemRenderer')
        .map(parseRow)
        .whereType<T>()
        .toList();
  }

  Future<MusicArtistPage> getArtist(String id) async {
    if (!_artistId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music artist.');
    }
    final data = await _request('browse', {'browseId': id});
    final header =
        _maps(data['header'], 'musicImmersiveHeaderRenderer').firstOrNull ??
            _maps(data['header'], 'musicVisualHeaderRenderer').firstOrNull;
    if (header == null || _text(header['title']).isEmpty) {
      throw const MusicCatalogException('This music artist is unavailable.');
    }
    final artist = MusicArtist(
      id: id,
      name: _text(header['title']),
      thumbnails: _thumbnails(header['thumbnail']),
    );
    final sections =
        _maps(data['contents'], 'sectionListRenderer').firstOrNull?['contents'];
    if (sections is! List) {
      throw const MusicCatalogException(
          'The music catalog returned an invalid response.');
    }
    final songs = <MusicTrack>[];
    Map<String, dynamic>? albums;
    Map<String, dynamic>? singles;
    for (final section in sections) {
      final songShelf = _map(section)['musicShelfRenderer'];
      // Requests explicitly use English. Do not mix video, recommendation or
      // "featured on" shelves into this artist's songs and releases.
      if (songShelf is Map<String, dynamic> &&
          const {'Top songs', 'Songs'}.contains(_text(songShelf['title']))) {
        songs.addAll(
            _maps(songShelf['contents'], 'musicResponsiveListItemRenderer')
                .map((item) =>
                    _track(item, artists: [artist.name], artistLinks: [artist]))
                .whereType<MusicTrack>());
      }
      final carousel = _map(section)['musicCarouselShelfRenderer'];
      if (carousel is! Map<String, dynamic>) continue;
      final title = _text(
          _maps(carousel['header'], 'musicCarouselShelfBasicHeaderRenderer')
              .firstOrNull?['title']);
      if (title == 'Albums') albums = carousel;
      if (const {'Singles & EPs', 'Singles and EPs', 'Singles'}
          .contains(title)) {
        singles = carousel;
      }
    }
    final releases = await Future.wait([
      _artistReleases(albums, artist),
      _artistReleases(singles, artist),
    ]);
    final description = _text(header['description']);
    return MusicArtistPage(
      artist: artist,
      description: description.isEmpty ? null : description,
      songs: songs,
      albums: releases[0],
      singles: releases[1],
    );
  }

  Future<List<MusicAlbum>> _artistReleases(
      Map<String, dynamic>? shelf, MusicArtist artist) async {
    if (shelf == null) return [];
    final header =
        _maps(shelf['header'], 'musicCarouselShelfBasicHeaderRenderer')
            .firstOrNull;
    final more =
        _maps(header?['moreContentButton'], 'browseEndpoint').firstOrNull ??
            _maps(header?['title'], 'browseEndpoint').firstOrNull;
    if (more == null) {
      return _maps(shelf['contents'], 'musicTwoRowItemRenderer')
          .map((item) => _release(item, artist))
          .whereType<MusicAlbum>()
          .toList();
    }
    final browseId = _string(more['browseId']);
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(browseId)) {
      throw const MusicCatalogException(
          'The music catalog returned an invalid response.');
    }
    Object? page = await _request('browse', {
      'browseId': browseId,
      if (more['params'] is String) 'params': more['params'],
    });
    final releases = <String, MusicAlbum>{};
    final seenContinuations = <String>{};
    for (var pageNumber = 0; pageNumber < 50; pageNumber++) {
      final grid = _maps(page, 'gridRenderer').firstOrNull ??
          _maps(page, 'gridContinuation').firstOrNull;
      final items = grid?['items'] ??
          _maps(page, 'appendContinuationItemsAction')
              .firstOrNull?['continuationItems'];
      if (items is! List) {
        throw const MusicCatalogException(
            'The music catalog returned an invalid response.');
      }
      for (final item in _maps(items, 'musicTwoRowItemRenderer')) {
        final release = _release(item, artist);
        if (release != null) releases.putIfAbsent(release.id, () => release);
      }
      final continuation = _maps(grid?['continuations'], 'nextContinuationData')
              .firstOrNull?['continuation'] ??
          _maps(items, 'continuationCommand').firstOrNull?['token'];
      if (continuation is! String || continuation.isEmpty) {
        return releases.values.toList();
      }
      if (!seenContinuations.add(continuation)) break;
      page = await _request('browse', {'continuation': continuation});
    }
    throw const MusicCatalogException(
        'The artist releases could not finish loading.');
  }

  Future<MusicTrack> getSong(String videoId) async {
    if (!_videoId.hasMatch(videoId)) {
      throw const MusicCatalogException('Invalid music track.');
    }
    final data = await _request('player', {'videoId': videoId});
    final details = _map(data['videoDetails']);
    final title = _string(details['title']);
    if (details['videoId'] != videoId || title.isEmpty) {
      throw const MusicCatalogException('This music track is unavailable.');
    }
    final author = _string(details['author']);
    return MusicTrack(
      videoId: videoId,
      title: title,
      artists: author.isEmpty ? [] : [author],
      // A video owner channel is not necessarily a Music artist browse ID.
      // Only explicit artist browse links from catalog rows are navigable.
      durationSeconds: int.tryParse(_string(details['lengthSeconds'])),
      thumbnails: _thumbnails(details['thumbnail']),
    );
  }

  Future<MusicCollection> getAlbum(String id) {
    if (!_albumId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music album.');
    }
    return _collection(id, isAlbum: true);
  }

  Future<MusicCollection> getPlaylist(String id) {
    final cleanId = id.startsWith('VL') ? id.substring(2) : id;
    if (!_playlistId.hasMatch(cleanId)) {
      throw const MusicCatalogException('Invalid music playlist.');
    }
    return _collection(cleanId, isAlbum: false);
  }

  Future<MusicCollection> _collection(String id,
      {required bool isAlbum}) async {
    final data = await _request('browse', {'browseId': isAlbum ? id : 'VL$id'});
    var header = _maps(data, 'musicResponsiveHeaderRenderer').firstOrNull ??
        _maps(data, 'musicDetailHeaderRenderer').firstOrNull;
    // Album playlist links can omit their header while supplying album links on
    // each track. Fetch only the album's labels; retain the playlist's track IDs.
    if (header == null && !isAlbum && id.startsWith('OLAK5uy_')) {
      final albumId = _maps(data, 'musicResponsiveListItemRenderer')
          .map((row) => _track(row)?.albumId)
          .whereType<String>()
          .firstOrNull;
      if (albumId != null) {
        final album = await _request('browse', {'browseId': albumId});
        header = _maps(album, 'musicResponsiveHeaderRenderer').firstOrNull ??
            _maps(album, 'musicDetailHeaderRenderer').firstOrNull;
      }
    }
    if (header == null || _text(header['title']).isEmpty) {
      throw const MusicCatalogException(
          'This music collection is unavailable.');
    }
    final title = _text(header['title']);
    final artists = _artists(header['straplineTextOne'] ?? header['subtitle']);
    final artistLinks =
        _artistLinks(header['straplineTextOne'] ?? header['subtitle']);
    final thumbnails = _thumbnails(header['thumbnail']);
    final tracks = <MusicTrack>[];
    final seenContinuations = <String>{};
    Object? page = data;
    for (var pageNumber = 0; pageNumber < 50; pageNumber++) {
      final shelf = _maps(page, 'musicPlaylistShelfRenderer').firstOrNull ??
          _maps(page, 'musicShelfRenderer').firstOrNull ??
          _maps(page, 'musicPlaylistShelfContinuation').firstOrNull ??
          _maps(page, 'musicShelfContinuation').firstOrNull;
      // Modern playlist continuations use appendContinuationItemsAction.
      final contents = shelf?['contents'] ??
          _maps(page, 'appendContinuationItemsAction')
              .firstOrNull?['continuationItems'];
      if (contents is! List) {
        throw const MusicCatalogException(
            'The music catalog returned an invalid response.');
      }
      for (final item in _maps(contents, 'musicResponsiveListItemRenderer')) {
        final track = _track(item,
            albumId: isAlbum ? id : null,
            albumTitle: isAlbum ? title : null,
            artists: artists,
            artistLinks: artistLinks,
            thumbnails: isAlbum ? thumbnails : const []);
        if (track != null) tracks.add(track);
      }
      final continuation =
          _maps(shelf?['continuations'], 'nextContinuationData')
                  .firstOrNull?['continuation'] ??
              _maps(contents, 'continuationCommand').firstOrNull?['token'];
      if (continuation is! String || continuation.isEmpty) {
        return MusicCollection(
            id: id,
            title: title,
            artists: artists,
            artistLinks: artistLinks,
            thumbnails: thumbnails,
            tracks: tracks);
      }
      if (!seenContinuations.add(continuation)) break;
      page = await _request('browse', {'continuation': continuation});
    }
    // Avoid silently saving or playing a truncated playlist.
    throw const MusicCatalogException(
        'The music collection could not finish loading.');
  }

  Future<Map<String, String>> _loadConfiguration() async {
    final response = await _send(http.Request('GET', _origin)
      ..headers.addAll({
        'user-agent': _userAgent,
        'accept-language': 'en-US,en;q=0.9',
      }));
    final result = <String, String>{};
    for (final key in [
      'INNERTUBE_CLIENT_VERSION',
      'INNERTUBE_API_KEY',
      'VISITOR_DATA',
    ]) {
      final match =
          RegExp('"$key"\\s*:\\s*"([^"\\r\\n]+)"').firstMatch(response);
      if (match != null) result[key] = match.group(1)!;
    }
    if (result['INNERTUBE_CLIENT_VERSION'] == null) {
      throw const MusicCatalogException('The music catalog is unavailable.');
    }
    return result;
  }

  Future<Map<String, dynamic>> _request(
      String endpoint, Map<String, Object?> body) async {
    Map<String, String> config;
    try {
      config = await (_configuration ??= _loadConfiguration());
    } catch (_) {
      _configuration = null; // A failed initialization must be retryable.
      rethrow;
    }
    final request = http.Request(
        'POST',
        _origin.replace(path: 'youtubei/v1/$endpoint', queryParameters: {
          'alt': 'json',
          if (config['INNERTUBE_API_KEY'] != null)
            'key': config['INNERTUBE_API_KEY']!,
        }))
      ..headers.addAll({
        'user-agent': _userAgent,
        'content-type': 'application/json',
        'origin': _origin.origin,
        'x-youtube-client-name': '67',
        'x-youtube-client-version': config['INNERTUBE_CLIENT_VERSION']!,
        if (config['VISITOR_DATA'] != null)
          'x-goog-visitor-id': config['VISITOR_DATA']!,
      })
      ..body = jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': config['INNERTUBE_CLIENT_VERSION'],
            'hl': 'en',
            'gl': 'US',
          },
          'user': {'lockedSafetyMode': false},
        },
        ...body,
      });
    final response = await _send(request);
    try {
      final decoded = jsonDecode(response);
      if (decoded is! Map<String, dynamic> || decoded.containsKey('error')) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      _configuration = null;
      throw const MusicCatalogException(
          'The music catalog returned an invalid response.');
    }
  }

  Future<String> _send(http.Request request) async {
    // No Google account cookies, Invidious access headers, or redirects.
    request.followRedirects = false;
    try {
      return await (() async {
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          _configuration = null;
          throw const MusicCatalogException(
              'The music catalog is unavailable.');
        }
        return utf8.decode(await response.stream.toBytes());
      })()
          .timeout(requestTimeout);
    } on MusicCatalogException {
      rethrow;
    } catch (_) {
      // Transport errors can contain request URLs or proxy details.
      throw const MusicCatalogException(
          'Could not connect to the music catalog.');
    }
  }
}
