import 'dart:convert';
import 'dart:io';

import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _artistId = 'UCRr1xG_2WIDs18a6cIiCxeA';
const _config = '{"INNERTUBE_CLIENT_VERSION":"1.20261108.01.00"}';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/music/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

http.Response _response(Object data) =>
    http.Response(data is String ? data : jsonEncode(data), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

List<dynamic> _sections(Map<String, dynamic> artist) => artist['contents']
        ['singleColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']
    ['content']['sectionListRenderer']['contents'] as List<dynamic>;

Map<String, dynamic> _grid(Map<String, dynamic> page) =>
    page['contents']['singleColumnBrowseResultsRenderer']['tabs'][0]
            ['tabRenderer']['content']['sectionListRenderer']['contents'][0]
        ['gridRenderer'] as Map<String, dynamic>;

MusicCatalogService _catalog({
  Map<String, dynamic>? artist,
  Map<String, dynamic>? albums,
  Map<String, dynamic>? singles,
  List<Map<String, dynamic>>? requests,
}) =>
    MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests?.add(body);
      if (body['browseId'] == _artistId) {
        return _response(artist ?? _fixture('artist'));
      }
      return _response(body['params'] == 'ggMIegYIARoCAQI%3D'
          ? albums ?? _fixture('artist_albums')
          : singles ?? _fixture('artist_singles'));
    }));

void main() {
  test('artist and playlist search parse live identities and playlist authors',
      () async {
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config);
      final body = jsonDecode(request.body);
      return _response(_fixture(
          body['params'] == 'Eg-KAQwIABAAGAAgASgAMABqChAEEAMQCRAFEAo%3D'
              ? 'artists'
              : 'playlists_search'));
    }));
    final artists = await catalog.searchArtists('Daft Punk');
    expect(artists, hasLength(2));
    expect(artists.first.id, _artistId);
    expect(artists.first.name, 'Daft Punk');
    expect(artists.first.thumbnails, isNotEmpty);
    final playlists = await catalog.searchPlaylists('Daft Punk');
    expect(playlists, hasLength(2));
    expect(playlists.first.id, 'PLwO8Yaz8URbq0HdSG3VFeCIUSGpsjbCtH');
    expect(playlists.first.title, 'Every Daft Punk Song');
    expect(playlists.first.author, 'Adam Is very weird');
    expect(playlists.first.thumbnails, isNotEmpty);
  });

  test(
      'artist page follows complete release shelves and excludes featured albums',
      () async {
    final requests = <Map<String, dynamic>>[];
    final page = await _catalog(requests: requests).getArtist(_artistId);
    expect(page.artist.id, _artistId);
    expect(page.artist.name, 'Daft Punk');
    expect(page.artist.thumbnails, isNotEmpty);
    expect(page.description, 'Artist biography fixture.');
    expect(page.songs, hasLength(2));
    // The artist preview fixture has one item in each shelf, full grids have three.
    expect(page.albums, hasLength(3));
    expect(page.singles, hasLength(3));
    expect(
        page.albums.first.title, 'Random Access Memories (Drumless Edition)');
    expect(page.singles.first.title, 'GLBTM (Studio Outtakes)');
    for (final release in [...page.albums, ...page.singles]) {
      expect(release.artists, ['Daft Punk']);
      expect(release.artistLinks.single.id, _artistId);
    }
    expect(requests.map((request) => request['browseId']),
        [_artistId, 'MPAD$_artistId', 'MPAD$_artistId']);
    expect(requests.skip(1).map((request) => request['params']),
        containsAll(['ggMIegYIARoCAQI%3D', 'ggMIegYIAhoCAQI%3D']));
  });

  test('artist shelves without more links retain the available releases',
      () async {
    final artist = _fixture('artist');
    for (final section in _sections(artist)) {
      final header = section['musicCarouselShelfRenderer']?['header']
          ?['musicCarouselShelfBasicHeaderRenderer'];
      if (header == null) continue;
      header.remove('moreContentButton');
      for (final run in header['title']['runs']) {
        run.remove('navigationEndpoint');
      }
    }
    final requests = <Map<String, dynamic>>[];
    final page =
        await _catalog(artist: artist, requests: requests).getArtist(_artistId);
    expect(page.albums, hasLength(1));
    expect(page.singles, hasLength(1));
    expect(requests, hasLength(1));
  });

  test('a valid artist with no released music is empty, not a schema error',
      () async {
    final artist = _fixture('artist');
    _sections(artist).clear();
    final page = await _catalog(artist: artist).getArtist(_artistId);
    expect(page.songs, isEmpty);
    expect(page.albums, isEmpty);
    expect(page.singles, isEmpty);
  });

  test('missing artist header or sections is an explicit failure', () async {
    final noHeader = _fixture('artist')..remove('header');
    final noSections = _fixture('artist')..remove('contents');
    for (final data in [noHeader, noSections]) {
      await expectLater(_catalog(artist: data).getArtist(_artistId),
          throwsA(isA<MusicCatalogException>()));
    }
  });

  test(
      'a malformed full release shelf cannot silently fall back to its preview',
      () async {
    await expectLater(_catalog(albums: {}).getArtist(_artistId),
        throwsA(isA<MusicCatalogException>()));
  });

  test(
      'release pagination handles gridContinuation, keeps order and deduplicates',
      () async {
    final artist = _fixture('artist');
    _sections(artist).removeWhere((section) =>
        section['musicCarouselShelfRenderer']?['header']
                ?['musicCarouselShelfBasicHeaderRenderer']?['title']?['runs']
            ?[0]?['text'] !=
        'Albums');
    final albums = _fixture('artist_albums');
    final rows = _grid(albums)['items'] as List;
    final first = {
      'contents': {
        'gridRenderer': {
          'items': [rows[0]],
          'continuations': [
            {
              'nextContinuationData': {'continuation': 'second-page'}
            }
          ]
        }
      }
    };
    final next = {
      'continuationContents': {
        'gridContinuation': {
          'items': [rows[0], rows[1], rows[2]],
        }
      }
    };
    final bodies = <Map>[];
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config);
      final body = jsonDecode(request.body) as Map;
      bodies.add(body);
      return _response(body['browseId'] == _artistId
          ? artist
          : body['continuation'] == 'second-page'
              ? next
              : first);
    }));
    final page = await catalog.getArtist(_artistId);
    expect(page.albums, hasLength(3));
    expect(
        page.albums.map((album) => album.id),
        rows.map((row) => row['musicTwoRowItemRenderer']['navigationEndpoint']
            ['browseEndpoint']['browseId']));
    expect(bodies.last['continuation'], 'second-page');
  });

  test(
      'a repeated release continuation fails instead of returning partial albums',
      () async {
    final artist = _fixture('artist');
    _sections(artist).removeWhere((section) =>
        section['musicCarouselShelfRenderer']?['header']
                ?['musicCarouselShelfBasicHeaderRenderer']?['title']?['runs']
            ?[0]?['text'] !=
        'Albums');
    final albums = _fixture('artist_albums');
    _grid(albums)['continuations'] = [
      {
        'nextContinuationData': {'continuation': 'loop'}
      }
    ];
    var requests = 0;
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config);
      requests++;
      final body = jsonDecode(request.body);
      return _response(body['browseId'] == _artistId ? artist : albums);
    }));
    await expectLater(
        catalog.getArtist(_artistId), throwsA(isA<MusicCatalogException>()));
    expect(requests, 3);
  });

  test('empty searches and invalid artist IDs make no requests', () async {
    final catalog = MusicCatalogService(httpClient: MockClient((_) async {
      fail('No request expected');
    }));
    expect(await catalog.searchArtists(' '), isEmpty);
    expect(await catalog.searchPlaylists(''), isEmpty);
    await expectLater(catalog.getArtist('UC../invalid'),
        throwsA(isA<MusicCatalogException>()));
  });

  test(
      'catalog tracks and albums keep artist navigation IDs and existing labels',
      () async {
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config);
      final body = jsonDecode(request.body);
      final fixture = body['browseId'] != null ? 'album' : body['query'];
      return _response(_fixture(fixture));
    }));
    final tracks = await catalog.searchSongs('songs');
    expect(tracks.first.artistLinks.map((artist) => artist.name),
        tracks.first.artists);
    expect(tracks.first.artistLinks.first.id, _artistId);
    final albums = await catalog.searchAlbums('albums');
    expect(albums.first.artistLinks.single.id, _artistId);
    final album = await catalog.getAlbum('MPREb_K8qWMWVqXGi');
    expect(album.artistLinks.single.id, _artistId);
    expect(album.tracks.first.artistLinks.single.id, _artistId);
  });

  test('a track uploader is not replaced by the collection artist link',
      () async {
    final album = _fixture('album');
    final row = album['contents']['twoColumnBrowseResultsRenderer']
                ['secondaryContents']['sectionListRenderer']['contents'][0]
            ['musicShelfRenderer']['contents'][0]
        ['musicResponsiveListItemRenderer'];
    final author = row['flexColumns'][1]
        ['musicResponsiveListItemFlexColumnRenderer']['text']['runs'][0];
    author['text'] = 'Channel uploader';
    author['navigationEndpoint']['browseEndpoint']
                ['browseEndpointContextSupportedConfigs']
            ['browseEndpointContextMusicConfig']['pageType'] =
        'MUSIC_PAGE_TYPE_USER_CHANNEL';
    final catalog = MusicCatalogService(
        httpClient: MockClient((request) async =>
            _response(request.method == 'GET' ? _config : album)));
    final collection = await catalog.getAlbum('MPREb_K8qWMWVqXGi');
    expect(collection.tracks.first.artists, ['Channel uploader']);
    expect(collection.tracks.first.artistLinks, isEmpty);
    expect(collection.artistLinks.single.id, _artistId);
  });
}
