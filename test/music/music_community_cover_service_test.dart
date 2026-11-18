import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clipious/globals.dart';
import 'package:clipious/music/services/music_community_cover_preferences.dart';
import 'package:clipious/music/services/music_community_cover_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/rejecting_socks.dart';

const _track = MusicMetadata(
    title: 'Artist - Song (Official Video)',
    artist: 'Artist - Topic',
    album: 'Album');
const _group = '22222222-2222-4222-8222-222222222222';
const _item = 'mbid-33333333-3333-4333-8333-333333333333';
const _file = '$_item/$_item-12345_thumb500.jpg';
const _archive = 'https://archive.org/download/$_file';
const _storage = 'https://dn721604.ca.archive.org/0/items/$_file';
const _caa = 'https://coverartarchive.org/release-group/$_group/front-500';

http.Response _match() => http.Response(
    jsonEncode({
      'count': 1,
      'offset': 0,
      'recordings': [
        {
          'id': '11111111-1111-4111-8111-111111111111',
          'title': 'Song',
          'length': 180000,
          'artist-credit': [
            {'name': 'Artist'}
          ],
          'releases': [
            {
              'title': 'Album',
              'status': 'Official',
              'release-group': {'id': _group, 'primary-type': 'Album'}
            }
          ]
        }
      ]
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});
http.Response _redirect(String location) =>
    http.Response('', 307, headers: {'location': location});

Future<Uint8List> _image({int width = 2}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff342a74), ui.BlendMode.src);
  final drawing = recorder.endRecording();
  final image = await drawing.toImage(width, 2);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    drawing.dispose();
  }
}

bool _active() => true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final proxy = NetworkProxy.instance;
  setUp(() => proxy.initialize(saved: '{}', configureNative: false));
  tearDown(() => proxy.initialize(saved: '{}', configureNative: false));

  test(
      'coalesces callers, sends only public labels and fetches the CAA archive thumbnail',
      () async {
    final bytes = await _image();
    final calls = <Uri>[];
    final waitForSearch = Completer<void>();
    var firstActive = true;
    final provider = CommunityMusicCoverService(
        createClient: () => MockClient((request) async {
              final url = request.url;
              calls.add(url);
              expect(request.followRedirects, isFalse);
              expect(request.headers.keys,
                  unorderedEquals(['accept', 'user-agent']));
              expect(request.headers['user-agent'],
                  contains('github.com/DVBeckwitt/Videre'));
              if (url.host == 'musicbrainz.org') {
                expect(url.path, '/ws/2/recording');
                expect(url.queryParameters.keys,
                    unorderedEquals(['query', 'limit', 'fmt']));
                await waitForSearch.future;
                return _match();
              }
              if (url.toString() == _caa) return _redirect(_archive);
              if (url.toString() == _archive) return _redirect(_storage);
              expect(url.toString(), _storage);
              return http.Response.bytes(bytes, 200,
                  headers: {'content-type': 'image/png'});
            }));
    final first = provider.fetch(_track, 180, isCurrent: () => firstActive);
    final second = provider.fetch(_track, 180, isCurrent: _active);
    firstActive = false;
    waitForSearch.complete();
    expect(await first, isNull);
    expect((await second)!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(calls.map((uri) => uri.host), [
      'musicbrainz.org',
      'coverartarchive.org',
      'archive.org',
      'dn721604.ca.archive.org'
    ]);
  });

  for (final target in [
    'https://i.ytimg.com/vi/abcdefghijk/default.jpg',
    'https://archive.org.example/download/$_file',
    'https://other.archive.org/download/$_file',
    'https://archive.org/download/other/file.jpg',
    'http://archive.org/download/$_file',
    'https://account@archive.org/download/$_file',
    'https://archive.org:444/download/$_file',
    'https://archive.org/download/$_file?token=private',
    'https://musicbrainz.org/ws/2/recording?query=unexpected',
  ]) {
    test('rejects unapproved CAA redirect before dispatch ($target)', () async {
      final calls = <Uri>[];
      final provider = CommunityMusicCoverService(
          createClient: () => MockClient((request) async {
                calls.add(request.url);
                return calls.length == 1 ? _match() : _redirect(target);
              }));
      await expectLater(provider.fetch(_track, 180, isCurrent: _active),
          throwsA(isA<MusicCommunityCoverException>()));
      expect(
          calls.map((u) => u.host), ['musicbrainz.org', 'coverartarchive.org']);
    });
  }

  for (final action in ['consent', 'proxy']) {
    test('drops an admitted CAA redirect when $action changes before the hop',
        () async {
      var active = true;
      final calls = <Uri>[];
      final provider = CommunityMusicCoverService(
          createClient: () => MockClient((request) async {
                calls.add(request.url);
                if (calls.length == 1) return _match();
                if (action == 'consent') {
                  active = false;
                } else {
                  await proxy.initialize(
                      saved: '{"enabled":true,"port":9999}',
                      configureNative: false);
                }
                return _redirect(_archive);
              }));
      expect(
          await provider.fetch(_track, 180, isCurrent: () => active), isNull);
      expect(
          calls.map((u) => u.host), ['musicbrainz.org', 'coverartarchive.org']);
    });
  }

  test(
      'paces different recordings and honors provider cooldown without retrying',
      () async {
    var elapsed = 0;
    final starts = <int>[];
    final provider = CommunityMusicCoverService(
        milliseconds: () => elapsed,
        wait: (delay) async {
          elapsed += delay.inMilliseconds;
        },
        createClient: () => MockClient((request) async {
              starts.add(elapsed);
              return starts.length == 1
                  ? http.Response('', 404)
                  : http.Response('', 503, headers: {'retry-after': '20'});
            }));
    final second = const MusicMetadata(
        title: 'Second Song', artist: 'Artist', album: 'Album');
    final first = provider.fetch(_track, 180, isCurrent: _active);
    final secondResult = expectLater(
        provider.fetch(second, 180, isCurrent: _active),
        throwsA(isA<MusicCommunityCoverException>()));
    expect(await first, isNull);
    await secondResult;
    await expectLater(provider.fetch(second, 180, isCurrent: _active),
        throwsA(isA<MusicCommunityCoverException>()));
    expect(starts, [0, 1000]);
  });

  test('a departed listener’s CAA cooldown stops a queued metadata search',
      () async {
    var elapsed = 0;
    var listening = true;
    var searches = 0;
    final imageStarted = Completer<void>();
    final imageResponse = Completer<http.Response>();
    final waiting = Completer<void>();
    final resume = Completer<void>();
    final provider = CommunityMusicCoverService(
        milliseconds: () => elapsed,
        wait: (delay) async {
          waiting.complete();
          await resume.future;
          elapsed += delay.inMilliseconds;
        },
        createClient: () => MockClient((request) async {
              if (request.url.host == 'musicbrainz.org') {
                searches++;
                return _match();
              }
              if (imageStarted.isCompleted) return http.Response('', 404);
              imageStarted.complete();
              return imageResponse.future;
            }));
    final first = provider.fetch(_track, 180, isCurrent: () => listening);
    await imageStarted.future;
    const next = MusicMetadata(title: 'Another song', artist: 'Artist');
    final second = expectLater(provider.fetch(next, 180, isCurrent: _active),
        throwsA(isA<MusicCommunityCoverException>()));
    await waiting.future;
    listening = false;
    imageResponse
        .complete(http.Response('', 429, headers: {'retry-after': '90'}));
    expect(await first, isNull);
    resume.complete();
    await second;
    expect(searches, 1);
  });

  test('overlapping Archive responses retain the longest provider cooldown',
      () async {
    var elapsed = 0;
    final started = [Completer<void>(), Completer<void>()];
    final replies = [Completer<http.Response>(), Completer<http.Response>()];
    var searches = 0;
    var images = 0;
    final provider = CommunityMusicCoverService(
        milliseconds: () => elapsed,
        wait: (delay) async {
          elapsed += delay.inMilliseconds;
        },
        createClient: () => MockClient((request) async {
              if (request.url.host == 'musicbrainz.org') {
                searches++;
                return _match();
              }
              if (request.url.host == 'coverartarchive.org') {
                return _redirect(_archive);
              }
              if (images >= replies.length) return http.Response('', 404);
              final index = images++;
              started[index].complete();
              return replies[index].future;
            }));
    final refused = throwsA(isA<MusicCommunityCoverException>());
    final first =
        expectLater(provider.fetch(_track, 180, isCurrent: _active), refused);
    await started[0].future;
    // A one-second duration difference is an independent search for the same recording.
    final second =
        expectLater(provider.fetch(_track, 181, isCurrent: _active), refused);
    await started[1].future;
    replies[0].complete(http.Response('', 503, headers: {'retry-after': '90'}));
    await first;
    replies[1].complete(http.Response('', 429, headers: {'retry-after': '2'}));
    await second;
    elapsed += 3000;
    await expectLater(provider.fetch(_track, 180, isCurrent: _active), refused);
    expect(searches, 2);
    expect(images, 2);
  });

  test('rejects oversized and disguised images before returning bytes',
      () async {
    for (final data in [
      utf8.encode('<svg/>'),
      await _image(width: 1025),
      Uint8List(2 * 1024 * 1024 + 1)
    ]) {
      final provider = CommunityMusicCoverService(
          createClient: () => MockClient((request) async =>
              request.url.host == 'musicbrainz.org'
                  ? _match()
                  : http.Response.bytes(data, 200,
                      headers: {'content-type': 'image/png'})));
      await expectLater(provider.fetch(_track, 180, isCurrent: _active),
          throwsA(isA<MusicCommunityCoverException>()));
    }
  });

  test(
      'a missing cover is a normal result and MusicBrainz redirects are refused',
      () async {
    for (final redirect in [false, true]) {
      final calls = <Uri>[];
      final provider = CommunityMusicCoverService(
          createClient: () => MockClient((request) async {
                calls.add(request.url);
                if (redirect) return _redirect(_caa);
                return calls.length == 1 ? _match() : http.Response('', 404);
              }));
      final result = provider.fetch(_track, 180, isCurrent: _active);
      if (redirect) {
        await expectLater(result, throwsA(isA<MusicCommunityCoverException>()));
        expect(calls, hasLength(1));
      } else {
        expect(await result, isNull);
        expect(calls, hasLength(2));
      }
    }
  });

  test(
      'production cover transport sends musicbrainz.org:443 to the saved SOCKS proxy',
      () async {
    db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    await proxy.initialize(
        saved: jsonEncode(
            SocksProxyConfig(enabled: true, port: server.port).toJson()),
        configureNative: false);
    var fallback = 0;
    await HttpOverrides.runZoned(() async {
      expect(await fetchCommunityMusicCover(_track, 180, isCurrent: _active),
          isNull);
      await setCommunityCoverArtEnabled(true);
      final destination = server.first
          .timeout(const Duration(seconds: 5))
          .then(rejectSocksConnect);
      await Future.wait([
        expectLater(destination, completion(('musicbrainz.org', 443))),
        expectLater(fetchCommunityMusicCover(_track, 180, isCurrent: _active),
            throwsA(isA<MusicCommunityCoverException>()))
      ]);
    }, findProxyFromEnvironment: (_, __) {
      fallback++;
      throw StateError('Unexpected direct connection');
    });
    expect(fallback, 0);
  });
}
