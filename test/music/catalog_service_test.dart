import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config =
    '<script>ytcfg.set({"INNERTUBE_CLIENT_VERSION":"1.20261108.01.00",'
    '"INNERTUBE_API_KEY":"public-key","VISITOR_DATA":"public-visitor"});</script>';
const _albumId = 'MPREb_K8qWMWVqXGi';
const _consentLocation =
    'https://consent.youtube.com/m?continue=https%3A%2F%2Fmusic.youtube.com%2F';
const _regionalBootstrap = '<html><head>'
    '<title>YouTube Music is not available in your area</title></head>'
    '<body><script>{"INNERTUBE_API_KEY":"page-key",'
    '"VISITOR_DATA":"page-visitor"}</script></body></html>';

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

  test('regional bootstrap reports its exit-region failure without a POST',
      () async {
    final requests = <http.Request>[];
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      requests.add(request);
      return _response(
          request.method == 'GET' ? _regionalBootstrap : _fixture('songs'),
          200);
    }));
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(catalog.searchSongs('Get Lucky'),
          throwsA(isA<MusicCatalogRegionUnavailable>()));
    }
    expect(requests.map((request) => request.method), ['GET', 'GET']);
    for (final request in requests) {
      expect(request.url.origin, 'https://music.youtube.com');
      expect(request.followRedirects, isFalse);
      expect(request.url.queryParameters.containsKey('key'), isFalse);
      for (final header in ['authorization', 'cookie', 'x-goog-visitor-id']) {
        expect(request.headers.containsKey(header), isFalse);
      }
    }
  });

  test('consent retry rejects optional cookies only on the original bootstrap',
      () async {
    final requests = <http.Request>[];
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      requests.add(request);
      if (requests.length == 1) {
        return http.Response('', 302, headers: {
          'location': _consentLocation,
          'set-cookie': 'unrelated=must-not-follow',
        });
      }
      return _response(
          request.method == 'GET' ? _config : _fixture('songs'), 200);
    }));

    expect(await catalog.searchSongs('Get Lucky'), hasLength(2));
    expect(await catalog.searchSongs('Daft Punk'), hasLength(2));
    expect(requests.map((request) => request.method),
        ['GET', 'GET', 'POST', 'POST']);
    expect(requests.map((request) => request.headers['cookie']),
        [null, 'SOCS=CAE=', null, null]);
    for (final request in requests) {
      expect(request.url.origin, 'https://music.youtube.com');
      expect(request.followRedirects, isFalse);
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('x-invidious-token'), isFalse);
      if (request.method == 'GET') {
        expect(request.url.toString(), 'https://music.youtube.com/');
        expect(request.headers.containsKey('x-goog-visitor-id'), isFalse);
      }
    }
  });

  for (final repeated in [false, true]) {
    test(
        'consent retry stays bounded and preserves region errors '
        '(repeated=$repeated)', () async {
      var requests = 0;
      final catalog =
          MusicCatalogService(httpClient: MockClient((request) async {
        requests++;
        expect(request.method, 'GET');
        if (requests == 1 || repeated) {
          return http.Response('', 302,
              headers: {'location': _consentLocation});
        }
        return _response(_regionalBootstrap, 200);
      }));
      await expectLater(
          catalog.searchSongs('Get Lucky'),
          throwsA(repeated
              ? isA<MusicCatalogException>()
              : isA<MusicCatalogRegionUnavailable>()));
      expect(requests, 2);
    });
  }

  for (final (status, location) in [
    (301, _consentLocation),
    (302, 'https://consent.youtube.com.attacker.example/m'),
    (302, 'http://consent.youtube.com/m'),
    (302, 'https://consent.youtube.com:8443/m'),
    (302, 'https://user@consent.youtube.com/m'),
    (302, 'https://consent.youtube.com/other'),
    (302, '/m'),
  ]) {
    test('unrecognized bootstrap redirect is rejected ($status $location)',
        () async {
      var requests = 0;
      final catalog =
          MusicCatalogService(httpClient: MockClient((request) async {
        requests++;
        expect(request.headers.containsKey('cookie'), isFalse);
        return http.Response('', status, headers: {'location': location});
      }));
      await expectLater(catalog.searchSongs('Get Lucky'),
          throwsA(isA<MusicCatalogException>()));
      expect(requests, 1);
    });
  }

  test('catalog POST never uses the bootstrap consent retry', () async {
    var requests = 0;
    final catalog = MusicCatalogService(httpClient: MockClient((request) async {
      requests++;
      expect(request.headers.containsKey('cookie'), isFalse);
      return request.method == 'GET'
          ? _response(_config, 200)
          : http.Response('', 302, headers: {'location': _consentLocation});
    }));
    await expectLater(catalog.searchSongs('Get Lucky'),
        throwsA(isA<MusicCatalogException>()));
    expect(requests, 2);
  });

  test('late consent redirect cannot retry across a proxy change', () async {
    final proxy = NetworkProxy.instance;
    await proxy.initialize(saved: '{}', configureNative: false);
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final requests = <http.Request>[];
    final catalog = MusicCatalogService(httpClient: MockClient((request) {
      requests.add(request);
      if (requests.length == 1) {
        started.complete();
        return pending.future;
      }
      return Future.value(_response(
          request.method == 'GET' ? _config : _fixture('songs'), 200));
    }));
    final rejected = expectLater(catalog.searchSongs('old route'),
        throwsA(isA<MusicCatalogException>()));
    await started.future;
    await proxy.initialize(saved: '{}', configureNative: false);
    pending.complete(
        http.Response('', 302, headers: {'location': _consentLocation}));
    await rejected;
    expect(requests, hasLength(1));
    expect(await catalog.searchSongs('new route'), hasLength(2));
    expect(requests.map((request) => request.headers['cookie']),
        [null, null, null]);
  });

  for (final latePart in ['headers', 'body']) {
    test('timed-out consent $latePart cannot start a retry', () async {
      final pending = Completer<http.StreamedResponse>();
      final body = latePart == 'body' ? StreamController<List<int>>() : null;
      var requests = 0;
      final catalog = MusicCatalogService(
          requestTimeout: const Duration(milliseconds: 10),
          httpClient: MockClient.streaming((request, stream) {
            requests++;
            return pending.future;
          }));
      final rejected = expectLater(catalog.searchSongs('Get Lucky'),
          throwsA(isA<MusicCatalogException>()));
      if (latePart == 'body') {
        pending.complete(http.StreamedResponse(body!.stream, 302,
            headers: {'location': _consentLocation}));
      }
      await rejected;
      if (latePart == 'headers') {
        pending.complete(http.StreamedResponse(const Stream.empty(), 302,
            headers: {'location': _consentLocation}));
      }
      await body?.close();
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
    });
  }

  test('HTTP denial and unrelated HTML do not claim a regional failure',
      () async {
    for (final response in [
      _response(_regionalBootstrap, 403),
      _response(_regionalBootstrap, 429),
      _response('<html><title>Consent required</title></html>', 200),
    ]) {
      final requests = <http.Request>[];
      final catalog =
          MusicCatalogService(httpClient: MockClient((request) async {
        requests.add(request);
        return response;
      }));
      await expectLater(
          catalog.searchSongs('Get Lucky'),
          throwsA(allOf(isA<MusicCatalogException>(),
              isNot(isA<MusicCatalogRegionUnavailable>()))));
      expect(requests.map((request) => request.method), ['GET']);
    }
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

  for (final completion in ['success', 'HTTP error', 'transport error']) {
    test('late configuration $completion cannot survive a proxy change',
        () async {
      final proxy = NetworkProxy.instance;
      await proxy.initialize(saved: '{}', configureNative: false);
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      var configurations = 0;
      final visitors = <String?>[];
      final catalog = MusicCatalogService(httpClient: MockClient((request) {
        if (request.method == 'GET') {
          configurations++;
          if (configurations == 1) {
            started.complete();
            return pending.future;
          }
          return Future.value(_response(
              _config.replaceAll('public-visitor', 'new-route-visitor'), 200));
        }
        visitors.add(request.headers['x-goog-visitor-id']);
        return Future.value(_response(_fixture('songs'), 200));
      }));

      final old = catalog.searchSongs('old route');
      final rejected = expectLater(old, throwsA(isA<MusicCatalogException>()));
      await started.future;
      await proxy.initialize(saved: '{}', configureNative: false);
      expect(await catalog.searchSongs('new route'), hasLength(2));

      switch (completion) {
        case 'success':
          pending.complete(_response(_config, 200));
        case 'HTTP error':
          pending.complete(_response('unavailable', 503));
        case 'transport error':
          pending.completeError(http.ClientException('old connection closed'));
      }
      await rejected;
      expect(visitors, ['new-route-visitor'],
          reason: 'The old configuration must never start a POST');
      expect(await catalog.searchSongs('new route again'), hasLength(2));
      expect(configurations, 2,
          reason: 'The old completion must not clear the new configuration');
      expect(visitors, ['new-route-visitor', 'new-route-visitor']);
    });
  }

  test('a late search response cannot publish results from an old proxy',
      () async {
    final proxy = NetworkProxy.instance;
    await proxy.initialize(saved: '{}', configureNative: false);
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    var configurations = 0;
    final catalog = MusicCatalogService(httpClient: MockClient((request) {
      if (request.method == 'GET') {
        configurations++;
        return Future.value(_response(_config, 200));
      }
      if (jsonDecode(request.body)['query'] == 'old route') {
        started.complete();
        return pending.future;
      }
      return Future.value(_response(_fixture('songs'), 200));
    }));

    final old = catalog.searchSongs('old route');
    final rejected = expectLater(old, throwsA(isA<MusicCatalogException>()));
    await started.future;
    await proxy.initialize(saved: '{}', configureNative: false);
    expect(await catalog.searchSongs('new route'), hasLength(2));
    pending.complete(_response(_fixture('songs'), 200));
    await rejected;
    expect(await catalog.searchSongs('new route again'), hasLength(2));
    expect(configurations, 2);
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

  test('catalog deadlines follow SOCKS while preserving explicit overrides',
      () async {
    final proxy = NetworkProxy.instance;
    await proxy.initialize(saved: '{}', configureNative: false);
    addTearDown(() => proxy.initialize(saved: '{}', configureNative: false));
    final catalog = MusicCatalogService();
    final custom =
        MusicCatalogService(requestTimeout: const Duration(milliseconds: 123));
    expect(catalog.requestTimeout, const Duration(seconds: 20));
    expect(custom.requestTimeout, const Duration(milliseconds: 123));

    await proxy.initialize(saved: '{"enabled":true}', configureNative: false);
    expect(catalog.requestTimeout, const Duration(seconds: 60));
    expect(custom.requestTimeout, const Duration(milliseconds: 123));

    await proxy.initialize(saved: '{}', configureNative: false);
    expect(catalog.requestTimeout, const Duration(seconds: 20));
  });

  test('a timed-out configuration cannot clear its successful retry', () async {
    final pending = Completer<http.Response>();
    var configurations = 0;
    final catalog = MusicCatalogService(
      httpClient: MockClient((request) {
        if (request.method == 'GET') {
          configurations++;
          if (configurations == 1) return pending.future;
          return Future.value(_response(_config, 200));
        }
        return Future.value(_response(_fixture('songs'), 200));
      }),
      requestTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(catalog.searchSongs('timed out'),
        throwsA(isA<MusicCatalogException>()));
    expect(await catalog.searchSongs('retry'), hasLength(2));
    pending.complete(_response('unavailable', 503));
    // Let the timed-out operation consume its late HTTP error before checking
    // whether it invalidated the newer successful bootstrap.
    await Future<void>.delayed(Duration.zero);
    expect(await catalog.searchSongs('cached retry'), hasLength(2));
    expect(configurations, 2);
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

  test('playlist continuations never cross a completed proxy switch', () async {
    final proxy = NetworkProxy.instance;
    final source = jsonDecode(_fixture('album'));
    final album = source['contents']['twoColumnBrowseResultsRenderer'];
    final header = album['tabs'][0]['tabRenderer']['content']
        ['sectionListRenderer']['contents'][0];
    final firstPage = jsonEncode({
      'header': header,
      'contents': {
        'musicPlaylistShelfRenderer': {
          'contents': [],
          'continuations': [
            {
              'nextContinuationData': {'continuation': 'old-route-token'}
            }
          ],
        }
      }
    });
    final lastPage = _response(
        jsonEncode({
          'contents': {
            'musicPlaylistShelfContinuation': {'contents': []}
          }
        }),
        200);
    http.StreamedResponse streamed(http.Response response) =>
        http.StreamedResponse(
            Stream.value(response.bodyBytes), response.statusCode);

    // Exercise the boundary after receiving page one but before dispatching
    // page two, as well as changes during either request. The next page stays
    // pending until the policy changes, so every lookup must reject its result.
    for (var microtasks = 1; microtasks <= 24; microtasks++) {
      await proxy.initialize(saved: '{}', configureNative: false);
      final original = proxy.config;
      final changed = Completer<void>();
      final continuation = Completer<http.StreamedResponse>();
      var crossedRoute = false;
      void switchAfter(int remaining) {
        scheduleMicrotask(() {
          if (remaining > 0) {
            switchAfter(remaining - 1);
          } else {
            unawaited(proxy
                .initialize(saved: '{}', configureNative: false)
                .then((_) => changed.complete()));
          }
        });
      }

      // Observe dispatch synchronously, before consuming the request stream.
      // The regular MockClient handler waits for the body first, which can
      // falsely label an already-dispatched request as using the new route.
      final catalog = MusicCatalogService(
          httpClient: MockClient.streaming((request, bodyStream) {
        if (request.method == 'GET') {
          return Future.value(streamed(_response(_config, 200)));
        }
        final body = jsonDecode((request as http.Request).body) as Map;
        if (body['continuation'] != null) {
          crossedRoute = !identical(original, proxy.config);
          return continuation.future;
        }
        switchAfter(microtasks);
        return Future.value(streamed(_response(firstPage, 200)));
      }));
      final rejected = expectLater(catalog.getPlaylist('PLtestPlaylist'),
          throwsA(isA<MusicCatalogException>()),
          reason: 'Proxy switch after $microtasks microtasks');
      await changed.future;
      continuation.complete(streamed(lastPage));
      await rejected;
      expect(crossedRoute, isFalse,
          reason: 'Old continuation sent after $microtasks microtasks');
    }
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
