import 'dart:async';
import 'dart:convert';

import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_discovery.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;
import 'package:clipious/utils/models/image_object.dart';
import 'package:http/http.dart' as http;

part 'legacy_music_catalog_parser.dart';
part 'legacy_music_discovery_parser.dart';

/// Historical response classification, outside the supported production API.
class MusicCatalogRegionUnavailable extends MusicCatalogException {
  const MusicCatalogRegionUnavailable()
      : super('YouTube Music is unavailable from this connection\'s region.');
}

/// Historical direct-catalog fixture retained solely for offline parser and
/// transport regression evidence. This file is outside the application package
/// and requires an explicitly injected test client; production has no direct
/// catalog implementation.
class LegacyMusicCatalogFixture extends MusicCatalogService {
  @override
  Future<List<MusicTrack>> getTrendingSongs() async =>
      throw const MusicCatalogUnsupported();

  final http.Client _httpClient;
  final Duration? _requestTimeout;
  Future<Map<String, String>>? _configuration;
  SocksProxyConfig? _configurationProxy;

  LegacyMusicCatalogFixture({
    required http.Client httpClient,
    Duration? requestTimeout,
  })  : _httpClient = httpClient,
        _requestTimeout = requestTimeout;

  // Tor circuits can take longer to return a catalog page. Keep a bounded
  // deadline and preserve explicit caller deadlines, including short tests.
  Duration get requestTimeout =>
      _requestTimeout ??
      Duration(seconds: NetworkProxy.instance.config.enabled ? 60 : 20);

  // Tests must explicitly supply a fixture client or local transport.
  http.Client get _client => _httpClient;

  static final _origin = Uri.parse('https://music.youtube.com/');
  static final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final _albumId = RegExp(r'^MPRE[a-zA-Z0-9_-]+$');
  static final _artistId = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
  static final _playlistId = RegExp(r'^(PL|OLAK5uy_|RD)[a-zA-Z0-9_-]+$');
  static final _countryCode = RegExp(r'^[A-Z]{2}$');
  static final _browseParams = RegExp(r'^[a-zA-Z0-9_+/%=-]{1,2048}$');
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  @override
  Future<List<MusicTrack>> searchSongs(String query) =>
      _search(query, 'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo%3D', _track);

  Future<List<MusicAlbum>> searchAlbums(String query) =>
      _search(query, 'Eg-KAQwIABAAGAEgACgAMABqChAEEAMQCRAFEAo%3D', _album);

  @override
  Future<List<MusicArtist>> searchArtists(String query) =>
      _search(query, 'Eg-KAQwIABAAGAAgASgAMABqChAEEAMQCRAFEAo%3D', _artist);

  @override
  Future<List<MusicPlaylist>> searchPlaylists(String query) =>
      _search(query, 'Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D', _playlist);

  /// The public new releases grid, never search results or a personal home feed.
  Future<List<MusicAlbum>> getNewReleases() => _discoveryBrowse({
        'browseId': 'FEmusic_new_releases_albums'
      }, _discoveryAlbum, (album) => album.id, onlyGrids: true);

  Future<MusicCharts> getCharts({String country = 'ZZ'}) async {
    final code = country.toUpperCase();
    if (!_countryCode.hasMatch(code)) {
      throw const MusicCatalogException('Invalid music chart country.');
    }
    final data = await _request('browse', {
      'browseId': 'FEmusic_charts',
      'formData': {
        'selectedValues': [code]
      },
    });
    return _discoveryCharts(data, code);
  }

  Future<List<MusicMoodCategory>> getMoodCategories() async => _discoveryMoods(
      await _request('browse', {'browseId': 'FEmusic_moods_and_genres'}));

  Future<List<MusicPlaylist>> getMoodPlaylists(String params) async {
    if (!_browseParams.hasMatch(params)) {
      throw const MusicCatalogException('Invalid music mood category.');
    }
    return _discoveryBrowse(
        {'browseId': 'FEmusic_moods_and_genres_category', 'params': params},
        _discoveryPlaylist,
        (playlist) => playlist.id);
  }

  Future<List<T>> _discoveryBrowse<T>(Map<String, Object?> body,
      T? Function(Map<String, dynamic>) parse, String Function(T) identity,
      {bool onlyGrids = false}) async {
    final policy = NetworkProxy.instance.config;
    final items = <String, T>{};
    final pending = <Map<String, Object?>>[body];
    final seenContinuations = <String>{};
    // Discovery can expose multiple shelves. Bound the entire operation, not
    // merely each shelf, and report incomplete results instead of truncating.
    for (var pageNumber = 0;
        pageNumber < 10 && pending.isNotEmpty;
        pageNumber++) {
      final data =
          await _request('browse', pending.removeAt(0), sourcePolicy: policy);
      for (final container
          in _discoveryContainers(data, onlyGrids: onlyGrids)) {
        final rows = container['items'] ?? container['contents'];
        if (rows is! List) _invalidDiscovery();
        for (final row in rows) {
          final card = _map(row)['musicTwoRowItemRenderer'];
          if (card is! Map<String, dynamic>) continue;
          final item = parse(card);
          if (item != null) items.putIfAbsent(identity(item), () => item);
        }
        final continuations = [
          ..._maps(container['continuations'], 'nextContinuationData')
              .map((value) => value['continuation']),
          ..._maps(rows, 'continuationCommand').map((value) => value['token']),
        ];
        for (final continuation in continuations) {
          if (continuation is! String ||
              !_browseParams.hasMatch(continuation) ||
              !seenContinuations.add(continuation)) {
            _invalidDiscovery();
          }
          pending.add({'continuation': continuation});
        }
      }
    }
    if (pending.isNotEmpty) {
      throw const MusicCatalogException(
          'Music discovery could not finish loading.');
    }
    return items.values.toList();
  }

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

  @override
  Future<MusicArtistPage> getArtist(String id) async {
    if (!_artistId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music artist.');
    }
    final policy = NetworkProxy.instance.config;
    final data =
        await _request('browse', {'browseId': id}, sourcePolicy: policy);
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
      _artistReleases(albums, artist, policy),
      _artistReleases(singles, artist, policy),
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

  Future<List<MusicAlbum>> _artistReleases(Map<String, dynamic>? shelf,
      MusicArtist artist, SocksProxyConfig policy) async {
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
    Object? page = await _request(
        'browse',
        {
          'browseId': browseId,
          if (more['params'] is String) 'params': more['params'],
        },
        sourcePolicy: policy);
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
      page = await _request('browse', {'continuation': continuation},
          sourcePolicy: policy);
    }
    throw const MusicCatalogException(
        'The artist releases could not finish loading.');
  }

  @override
  Future<MusicTrack> getSong(String videoId,
      {VideoLoadObserver? loadObserver}) async {
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

  @override
  Future<MusicCollection> getPlaylist(String id) {
    final cleanId = id.startsWith('VL') ? id.substring(2) : id;
    if (!_playlistId.hasMatch(cleanId)) {
      throw const MusicCatalogException('Invalid music playlist.');
    }
    return _collection(cleanId, isAlbum: false);
  }

  Future<MusicCollection> _collection(String id,
      {required bool isAlbum}) async {
    final policy = NetworkProxy.instance.config;
    final data = await _request('browse', {'browseId': isAlbum ? id : 'VL$id'},
        sourcePolicy: policy);
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
        final album = await _request('browse', {'browseId': albumId},
            sourcePolicy: policy);
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
      page = await _request('browse', {'continuation': continuation},
          sourcePolicy: policy);
    }
    // Avoid silently saving or playing a truncated playlist.
    throw const MusicCatalogException(
        'The music collection could not finish loading.');
  }

  void _checkProxy(SocksProxyConfig policy) {
    if (NetworkProxy.instance.isChanging ||
        !identical(policy, NetworkProxy.instance.config)) {
      throw const MusicCatalogException(
          'The network proxy changed. Retry the music request.');
    }
  }

  Future<Map<String, String>> _loadConfiguration(
      SocksProxyConfig policy) async {
    final response = await _send(
        http.Request('GET', _origin)
          ..headers.addAll({
            'user-agent': _userAgent,
            'accept-language': 'en-US,en;q=0.9',
          }),
        policy,
        retryConsent: true);
    if (RegExp(
            r'<title>\s*YouTube Music is not available in your area\s*</title>',
            caseSensitive: false)
        .hasMatch(response)) {
      throw const MusicCatalogRegionUnavailable();
    }
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
      String endpoint, Map<String, Object?> body,
      {SocksProxyConfig? sourcePolicy}) async {
    // Continuation tokens and related browse IDs came from the originating
    // route too. A proxy switch must restart the whole lookup, not just obtain
    // a new visitor and send an old route's continuation under that identity.
    final policy = sourcePolicy ?? NetworkProxy.instance.config;
    _checkProxy(policy);
    // Public visitor data belongs to the route that obtained it. Never carry
    // that identity from a direct connection into Tor, or between proxies.
    if (!identical(_configurationProxy, policy)) {
      _configurationProxy = policy;
      _configuration = null;
    }
    final pending = _configuration ??= _loadConfiguration(policy);
    Map<String, String> config;
    try {
      config = await pending;
    } catch (_) {
      // A late failure from an old route cannot clear newer configuration.
      if (identical(_configuration, pending)) _configuration = null;
      rethrow;
    }
    _checkProxy(policy);
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
    try {
      final response = await _send(request, policy);
      final decoded = jsonDecode(response);
      if (decoded is! Map<String, dynamic> || decoded.containsKey('error')) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      if (identical(_configuration, pending)) _configuration = null;
      throw const MusicCatalogException(
          'The music catalog returned an invalid response.');
    } catch (_) {
      if (identical(_configuration, pending)) _configuration = null;
      rethrow;
    }
  }

  Future<String> _send(http.Request request, SocksProxyConfig policy,
      {bool retryConsent = false}) async {
    // No Google account cookies, Invidious access headers, or redirects.
    request.followRedirects = false;
    var expired = false;
    try {
      return await (() async {
        _checkProxy(policy);
        final response = await _client.send(request);
        final redirect = Uri.tryParse(response.headers['location'] ?? '');
        if (retryConsent &&
            request.method == 'GET' &&
            request.url == _origin &&
            response.statusCode == 302 &&
            redirect?.scheme == 'https' &&
            redirect?.host == 'consent.youtube.com' &&
            redirect?.port == 443 &&
            redirect?.userInfo == '' &&
            redirect?.path == '/m') {
          await response.stream.drain<void>();
          // Future.timeout does not cancel a late response or its body drain.
          // Neither may dispatch a new request after the caller's deadline.
          if (expired) throw TimeoutException('Music request expired.');
          // NewPipe's anonymous default rejects non-necessary cookies. Retry
          // only our original bootstrap, never the redirect or its cookies.
          // The outer deadline still bounds both attempts; no cookie is kept.
          return _send(
              http.Request('GET', _origin)
                ..headers.addAll({...request.headers, 'cookie': 'SOCS=CAE='}),
              policy);
        }
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          throw const MusicCatalogException(
              'The music catalog is unavailable.');
        }
        final bytes = await response.stream.toBytes();
        _checkProxy(policy);
        return utf8.decode(bytes);
      })()
          .timeout(requestTimeout, onTimeout: () {
        expired = true;
        throw TimeoutException('Music request expired.');
      });
    } on MusicCatalogException {
      rethrow;
    } catch (_) {
      // Transport errors can contain request URLs or proxy details.
      throw const MusicCatalogException(
          'Could not connect to the music catalog.');
    }
  }
}
