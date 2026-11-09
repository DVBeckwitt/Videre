import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config =
    '<script>ytcfg.set({"INNERTUBE_CLIENT_VERSION":"1.20261108.01.00",'
    '"INNERTUBE_API_KEY":"public-key","VISITOR_DATA":"public-visitor"});</script>';
const _albumId = 'MPREb_K8qWMWVqXGi';

http.Response _response(String body, int status) => http.Response(body, status,
    headers: {'content-type': 'application/json; charset=utf-8'});

String _fixture(String name) =>
    File('test/music/fixtures/$name.json').readAsStringSync();

MusicCatalogService _catalog(String response) => MusicCatalogService(
      httpClient: MockClient((request) async =>
          _response(request.method == 'GET' ? _config : response, 200)),
    );

void main() {
  test('song search preserves all artists, album and duration from live shape',
      () async {
    final tracks = await _catalog(_fixture('songs')).searchSongs('Get Lucky');
    expect(tracks, hasLength(2));
    final track = tracks.first;
    expect(track.videoId, '4D7u5KF7SP8');
    expect(track.artists, ['Daft Punk', 'Pharrell Williams', 'Nile Rodgers']);
    expect(track.albumId, _albumId);
    expect(track.albumTitle, 'Random Access Memories');
    expect(track.durationSeconds, 370);
    expect(track.thumbnails, hasLength(2));
    final video = track.toVideo();
    expect(video.musicMetadata?.title, track.title);
    expect(video.musicMetadata?.artist,
        'Daft Punk, Pharrell Williams, Nile Rodgers');
    expect(video.musicMetadata?.album, track.albumTitle);
    expect(video.videoThumbnails.first.url, track.thumbnails.first.url);
  });

  test('album search uses the album endpoint, not an artist or menu ID',
      () async {
    final albums = await _catalog(_fixture('albums'))
        .searchAlbums('Random Access Memories');
    expect(albums, hasLength(2));
    expect(albums.first.id, _albumId);
    expect(albums.first.title, 'Random Access Memories');
    expect(albums.first.artists, ['Daft Punk']);
  });

  test(
      'album browse preserves all 13 tracks in album order and inherits artwork',
      () async {
    final album = await _catalog(_fixture('album')).getAlbum(_albumId);
    expect(album.tracks, hasLength(13));
    expect(album.title, 'Random Access Memories');
    expect(album.tracks.first.title, 'Give Life Back to Music');
    expect(album.tracks[3].title, 'Within');
    expect(album.tracks.last.title, 'Contact');
    expect(album.tracks.first.durationSeconds, 276);
    for (final track in album.tracks) {
      expect(track.albumId, _albumId);
      expect(track.albumTitle, album.title);
      expect(track.thumbnails.map((image) => image.url),
          album.thumbnails.map((image) => image.url));
    }
  });

  test('bad and unavailable rows do not discard valid search results',
      () async {
    final data = jsonDecode(_fixture('songs')) as Map<String, dynamic>;
    final shelf = data['contents']['tabbedSearchResultsRenderer']['tabs'][0]
            ['tabRenderer']['content']['sectionListRenderer']['contents'][0]
        ['musicShelfRenderer'];
    final rows = shelf['contents'] as List;
    final unavailable = jsonDecode(jsonEncode(rows.first));
    unavailable['musicResponsiveListItemRenderer']
            ['musicItemRendererDisplayPolicy'] =
        'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT';
    rows.addAll([
      {'musicResponsiveListItemRenderer': {}},
      {
        'musicResponsiveListItemRenderer': {'flexColumns': 'invalid'}
      },
      unavailable,
    ]);
    expect(await _catalog(jsonEncode(data)).searchSongs('Get Lucky'),
        hasLength(2));
  });

  test('empty search makes no network request', () async {
    final catalog = MusicCatalogService(httpClient: MockClient((_) async {
      fail('Empty search must not access the network');
    }));
    expect(await catalog.searchSongs('   '), isEmpty);
    expect(await catalog.searchAlbums(''), isEmpty);
  });

  test('valid empty search is distinct from an unexpected server schema',
      () async {
    expect(
        await _catalog('{"contents":{"tabbedSearchResultsRenderer":{}}}')
            .searchSongs('no results'),
        isEmpty);
    await expectLater(_catalog('{}').searchSongs('query'),
        throwsA(isA<MusicCatalogException>()));
  });

  test('transport remains on public origin with no credentials or redirects',
      () async {
    final requests = <http.Request>[];
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      requests.add(request);
      return _response(
          request.method == 'GET' ? _config : _fixture('songs'), 200);
    }));
    await Future.wait(
        [catalog.searchSongs(' Get Lucky '), catalog.searchSongs('Daft Punk')]);
    expect(requests.where((request) => request.method == 'GET'), hasLength(1));
    for (final request in requests) {
      expect(request.url.origin, 'https://music.youtube.com');
      expect(request.followRedirects, isFalse);
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('cookie'), isFalse);
    }
    final search = requests.firstWhere((request) => request.method == 'POST');
    expect(jsonDecode(search.body)['query'], 'Get Lucky');
    expect(jsonDecode(search.body)['context']['client']['clientName'],
        'WEB_REMIX');
  });

  test('failed initialization retries and never leaks transport exception text',
      () async {
    var attempts = 0;
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET' && attempts++ == 0) {
        throw http.ClientException('proxy-user:private-password@proxy.invalid');
      }
      return _response(
          request.method == 'GET' ? _config : _fixture('songs'), 200);
    }));
    try {
      await catalog.searchSongs('query');
      fail('The first request should fail');
    } on MusicCatalogException catch (error) {
      expect(error.toString(), isNot(contains('private-password')));
    }
    expect(await catalog.searchSongs('query'), hasLength(2));
    expect(attempts, 2);
  });

  test('HTTP, consent HTML and malformed JSON failures are explicit', () async {
    for (final response in [
      _response('rate limited', 429),
      _response('<html>consent</html>', 200),
      _response('[]', 200)
    ]) {
      final catalog = MusicCatalogService(
          httpClient: MockClient((request) async =>
              request.method == 'GET' ? _response(_config, 200) : response));
      await expectLater(
          catalog.searchSongs('query'), throwsA(isA<MusicCatalogException>()));
    }
    final consent = MusicCatalogService(
        httpClient:
            MockClient((_) async => _response('<html>consent</html>', 200)));
    await expectLater(
        consent.searchSongs('query'), throwsA(isA<MusicCatalogException>()));
  });

  test('request deadline terminates a stalled catalog lookup', () async {
    final pending = Completer<http.Response>();
    final catalog = MusicCatalogService(
      httpClient: MockClient((_) => pending.future),
      requestTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(
        catalog.searchSongs('query'), throwsA(isA<MusicCatalogException>()));
    pending.complete(_response(_config, 200));
  });

  test('song links validate identity and use metadata without stream URLs',
      () async {
    final data = jsonEncode({
      'videoDetails': {
        'videoId': '4D7u5KF7SP8',
        'title': 'Get Lucky',
        'author': 'Daft Punk',
        'channelId': 'UC_kRDKYrUlrbtrSiyu5Tflg',
        'lengthSeconds': '370',
      },
      'streamingData': {
        'formats': [
          {'url': 'https://ignored.invalid/stream'}
        ]
      }
    });
    final song = await _catalog(data).getSong('4D7u5KF7SP8');
    expect(song.durationSeconds, 370);
    expect(song.artistLinks, isEmpty);
    expect(song.toVideo().formatStreams, isNull);
    await expectLater(_catalog(data).getSong('IluRBvnYMoY'),
        throwsA(isA<MusicCatalogException>()));
  });

  test('invalid IDs never reach the network', () async {
    final catalog = MusicCatalogService(httpClient: MockClient((_) async {
      fail('Invalid IDs must not access the network');
    }));
    await expectLater(
        catalog.getSong('../bad'), throwsA(isA<MusicCatalogException>()));
    expect(() => catalog.getAlbum('UCartist'),
        throwsA(isA<MusicCatalogException>()));
    expect(() => catalog.getPlaylist('https://evil.invalid'),
        throwsA(isA<MusicCatalogException>()));
  });

  test('a missing collection shelf is an error, not an empty album', () async {
    final data = jsonDecode(_fixture('album'));
    data['contents']['twoColumnBrowseResultsRenderer']
        .remove('secondaryContents');
    await expectLater(_catalog(jsonEncode(data)).getAlbum(_albumId),
        throwsA(isA<MusicCatalogException>()));
  });

  test('playlist continuation retains duplicates and original sequence',
      () async {
    final source = jsonDecode(_fixture('album'));
    final album = source['contents']['twoColumnBrowseResultsRenderer'];
    final header = album['tabs'][0]['tabRenderer']['content']
        ['sectionListRenderer']['contents'][0];
    final rows = album['secondaryContents']['sectionListRenderer']['contents']
        [0]['musicShelfRenderer']['contents'] as List;
    final pages = [
      {
        'header': header,
        'contents': {
          'musicPlaylistShelfRenderer': {
            'contents': [rows[0], rows[1]],
            'continuations': [
              {
                'nextContinuationData': {'continuation': 'page-two'}
              }
            ],
          }
        }
      },
      {
        'onResponseReceivedActions': [
          {
            'appendContinuationItemsAction': {
              'continuationItems': [rows[0]],
            }
          }
        ]
      },
    ];
    final bodies = <Map>[];
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config, 200);
      bodies.add(jsonDecode(request.body) as Map);
      return _response(jsonEncode(pages.removeAt(0)), 200);
    }));
    final playlist = await catalog.getPlaylist('PLtestPlaylist');
    expect(playlist.tracks.map((track) => track.title), [
      'Give Life Back to Music',
      'The Game of Love',
      'Give Life Back to Music'
    ]);
    expect(playlist.tracks.first.albumTitle, isNull);
    expect(bodies.first['browseId'], 'VLPLtestPlaylist');
    expect(bodies.last['continuation'], 'page-two');
  });

  test('album playlist without header fetches labels and keeps playlist IDs',
      () async {
    final search = jsonDecode(_fixture('songs'));
    final rows = search['contents']['tabbedSearchResultsRenderer']['tabs'][0]
            ['tabRenderer']['content']['sectionListRenderer']['contents'][0]
        ['musicShelfRenderer']['contents'];
    final pages = [
      jsonEncode({
        'contents': {
          'musicPlaylistShelfRenderer': {'contents': rows}
        }
      }),
      _fixture('album'),
    ];
    final catalog = MusicCatalogService(
        httpClient: MockClient((request) async => _response(
            request.method == 'GET' ? _config : pages.removeAt(0), 200)));
    final playlist = await catalog.getPlaylist('OLAK5uy_testAlbum');
    expect(playlist.title, 'Random Access Memories');
    expect(playlist.tracks, hasLength(2));
    expect(playlist.tracks.first.videoId, '4D7u5KF7SP8');
  });

  test('headerless album playlist finds labels after unavailable leading rows',
      () async {
    final search = jsonDecode(_fixture('songs'));
    final rows = search['contents']['tabbedSearchResultsRenderer']['tabs'][0]
            ['tabRenderer']['content']['sectionListRenderer']['contents'][0]
        ['musicShelfRenderer']['contents'] as List;
    final unavailable = jsonDecode(jsonEncode(rows.first));
    unavailable['musicResponsiveListItemRenderer']
            ['musicItemRendererDisplayPolicy'] =
        'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT';
    final pages = [
      jsonEncode({
        'contents': {
          'musicPlaylistShelfRenderer': {
            'contents': [
              unavailable,
              {'musicResponsiveListItemRenderer': <String, dynamic>{}},
              ...rows,
            ],
          }
        }
      }),
      _fixture('album'),
    ];
    final browseIds = <String>[];
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      if (request.method == 'GET') return _response(_config, 200);
      browseIds.add((jsonDecode(request.body) as Map)['browseId'] as String);
      return _response(pages.removeAt(0), 200);
    }));

    final playlist = await catalog.getPlaylist('OLAK5uy_testAlbum');

    expect(browseIds, ['VLOLAK5uy_testAlbum', _albumId]);
    expect(playlist.title, 'Random Access Memories');
    expect(playlist.tracks.map((track) => track.videoId),
        ['4D7u5KF7SP8', 'Rgrt_8mXrK8']);
  });
}
