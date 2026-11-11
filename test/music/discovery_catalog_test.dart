import 'dart:convert';
import 'dart:io';

import 'package:clipious/music/services/music_catalog_service.dart';
import 'support/legacy_music_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = '{"INNERTUBE_CLIENT_VERSION":"1.20261108.01.00"}';
const _moodParams = 'ggMPOg1uX1JOQWZFeDByc2Jm';

Map<String, dynamic> _fixture(String name) => jsonDecode(
        File('test/music/fixtures/discovery/$name.json').readAsStringSync())
    as Map<String, dynamic>;

http.Response _response(Object body) =>
    http.Response(body is String ? body : jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

List<dynamic> _sections(Map<String, dynamic> data) => data['contents']
        ['singleColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']
    ['content']['sectionListRenderer']['contents'] as List<dynamic>;

Map<String, dynamic> _grid(Map<String, dynamic> data) =>
    _sections(data).first['gridRenderer'] as Map<String, dynamic>;

LegacyMusicCatalogFixture _catalog(Object response,
        {List<http.Request>? requests}) =>
    LegacyMusicCatalogFixture(httpClient: MockClient((request) async {
      requests?.add(request);
      return _response(request.method == 'GET' ? _config : response);
    }));

void main() {
  test('new releases uses the public release grid and preserves artist links',
      () async {
    final requests = <http.Request>[];
    final albums = await _catalog(_fixture('new_releases'), requests: requests)
        .getNewReleases();
    expect(albums, hasLength(3));
    expect(albums.first.id, 'MPREb_GNn6LPnbOZb');
    expect(albums.first.title, 'Dotober 3.5');
    expect(albums.first.artists, ['Quiet Money Dot']);
    expect(albums.first.artistLinks.single.id, 'UCLMziBtzLn8FusE0ilKF_gg');
    expect(albums.first.thumbnails, isNotEmpty);
    final body = jsonDecode(requests.last.body);
    expect(body['browseId'], 'FEmusic_new_releases_albums');
    expect(body.containsKey('query'), isFalse);
  });

  test('charts retain public playlist labels and skip album and podcast rows',
      () async {
    final global = await _catalog(_fixture('charts_global')).getCharts();
    expect(global.country, 'ZZ');
    expect(global.playlists, hasLength(2));
    expect(global.playlists.first.title, 'Daily Top Music Videos - Global');
    expect(global.playlists.first.id, 'PL4fGSI1pDJn6t3TXLGiiJdD-sZbrG3tG0');
    expect(global.artists, hasLength(2));
    expect(global.artists.first.id, 'UCptBkLZ6XRxoyn8SkUMc_Iw');
    expect(global.countries.firstWhere((item) => item.code == 'ZZ').name,
        'Global');
    expect(global.countries.firstWhere((item) => item.code == 'US').name,
        'United States');
    final requests = <http.Request>[];
    final us = await _catalog(_fixture('charts_us'), requests: requests)
        .getCharts(country: 'us');
    expect(us.country, 'US');
    expect(us.playlists, hasLength(4));
    expect(us.playlists[1].id, startsWith('OLAK5uy_'));
    expect(us.artists, hasLength(2));
    expect(us.artists.first.id, 'UCR28YDxjDE3ogQROaNdnRbQ');
    expect(
        jsonDecode(requests.last.body)['formData']['selectedValues'], ['US']);
  });

  test('a country fallback is an error rather than mislabeled charts',
      () async {
    await expectLater(
        _catalog(_fixture('charts_global')).getCharts(country: 'US'),
        throwsA(isA<MusicCatalogException>()));
    final data = _fixture('charts_us')..remove('frameworkUpdates');
    await expectLater(_catalog(data).getCharts(country: 'US'),
        throwsA(isA<MusicCatalogException>()));
  });

  test('moods keep public genres and moments but exclude personal groups',
      () async {
    final data = _fixture('moods');
    final personal = jsonDecode(jsonEncode(_sections(data).first));
    personal['gridRenderer']['header']['gridHeaderRenderer']
        ['title'] = {'simpleText': 'For you'};
    personal['gridRenderer']['items'][0]['musicNavigationButtonRenderer']
        ['clickCommand']['browseEndpoint']['params'] = 'personal-only';
    _sections(data).insert(0, personal);
    final categories = await _catalog(data).getMoodCategories();
    expect(categories, hasLength(4));
    expect(categories.first.title, 'Chill');
    expect(categories.first.params, _moodParams);
    expect(categories.map((item) => item.group).toSet(),
        {'Genres', 'Moods & moments'});
    expect(categories.any((item) => item.params == 'personal-only'), isFalse);
  });

  test('mood playlists preserve curated identities and exclude invalid cards',
      () async {
    final data = _fixture('mood_playlists');
    final first = _sections(data).first['musicCarouselShelfRenderer'];
    final rows = first['contents'] as List;
    final invalid = jsonDecode(jsonEncode(rows.first));
    invalid['musicTwoRowItemRenderer']['navigationEndpoint']['browseEndpoint']
        ['browseId'] = 'UCnot-a-playlist';
    rows.addAll([
      rows.first,
      invalid,
      {'musicTwoRowItemRenderer': {}}
    ]);
    final requests = <http.Request>[];
    final playlists =
        await _catalog(data, requests: requests).getMoodPlaylists(_moodParams);
    expect(playlists, hasLength(4));
    expect(playlists.first.title, 'Coffee Shop Blend');
    expect(playlists.first.id, 'RDCLAK5uy_nBE4bLuBHUXWZrF59ZrkPEToKt8M_I3Vc');
    expect(playlists.first.thumbnails, isNotEmpty);
    expect(jsonDecode(requests.last.body)['params'], _moodParams);
    expect(jsonDecode(requests.last.body)['browseId'],
        'FEmusic_moods_and_genres_category');
  });

  test('discovery requests remain anonymous on the public browse endpoint',
      () async {
    final requests = <http.Request>[];
    await _catalog(_fixture('moods'), requests: requests).getMoodCategories();
    for (final request in requests) {
      expect(request.url.origin, 'https://music.youtube.com');
      expect(request.followRedirects, isFalse);
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('cookie'), isFalse);
      if (request.method == 'POST') {
        expect(request.url.path, '/youtubei/v1/browse');
        final body = jsonDecode(request.body);
        expect(body['browseId'], 'FEmusic_moods_and_genres');
        expect(body['context']['client']['hl'], 'en');
      }
    }
  });

  test('invalid countries and category params are rejected before transport',
      () async {
    final catalog = LegacyMusicCatalogFixture(httpClient: MockClient((_) async {
      fail('Invalid discovery input must not access the network');
    }));
    for (final country in ['', 'USA', '../US', 'U1', ' US']) {
      await expectLater(catalog.getCharts(country: country),
          throwsA(isA<MusicCatalogException>()));
    }
    for (final params in [
      '',
      'bad\nparams',
      'https://example.com',
      'x' * 2049
    ]) {
      await expectLater(catalog.getMoodPlaylists(params),
          throwsA(isA<MusicCatalogException>()));
    }
  });

  test('valid empty grids differ from missing or malformed discovery schemas',
      () async {
    final empty = _fixture('new_releases');
    _grid(empty)['items'] = [];
    expect(await _catalog(empty).getNewReleases(), isEmpty);
    for (final data in [
      <String, dynamic>{},
      {'contents': 'invalid'}
    ]) {
      await expectLater(_catalog(data).getNewReleases(),
          throwsA(isA<MusicCatalogException>()));
      await expectLater(_catalog(data).getMoodCategories(),
          throwsA(isA<MusicCatalogException>()));
    }
    _grid(empty)['items'] = 'invalid';
    await expectLater(_catalog(empty).getNewReleases(),
        throwsA(isA<MusicCatalogException>()));
  });

  test('discovery grid continuations preserve order and deduplicate cards',
      () async {
    final data = _fixture('new_releases');
    final rows = _grid(data)['items'] as List;
    _grid(data)['items'] = [rows.first];
    _grid(data)['continuations'] = [
      {
        'nextContinuationData': {'continuation': 'page-two'}
      }
    ];
    final pages = [
      data,
      {
        'continuationContents': {
          'gridContinuation': {'items': rows}
        }
      }
    ];
    final bodies = <Map>[];
    final catalog =
        LegacyMusicCatalogFixture(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config);
      bodies.add(jsonDecode(request.body) as Map);
      return _response(pages.removeAt(0));
    }));
    final albums = await catalog.getNewReleases();
    expect(albums.map((item) => item.title),
        ['Dotober 3.5', 'War Inside', 'WHAT I CARRY AND WHAT I BURN']);
    expect(bodies.last['continuation'], 'page-two');
  });

  test('repeated or excessive discovery continuations fail without truncation',
      () async {
    for (final repeating in [true, false]) {
      final data = _fixture('new_releases');
      var requests = 0;
      final catalog =
          LegacyMusicCatalogFixture(httpClient: MockClient((request) async {
        if (request.method == 'GET') return _response(_config);
        requests++;
        _grid(data)['continuations'] = [
          {
            'nextContinuationData': {
              'continuation': repeating ? 'loop' : 'page-$requests'
            }
          }
        ];
        return _response(data);
      }));
      await expectLater(
          catalog.getNewReleases(), throwsA(isA<MusicCatalogException>()));
      expect(requests, repeating ? 2 : 10);
    }
  });
}
