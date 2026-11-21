import 'dart:async';

import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/media_companion_probe.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const frontend = 'https://video.example';
const server = Server(url: frontend);
const manifest = '$frontend/api/manifest/dash/id/sample';

AdaptiveFormat audio(String url, [String bitrate = '128000']) => AdaptiveFormat(
    null,
    bitrate,
    null,
    url,
    '140',
    'audio/mp4',
    '',
    '',
    '',
    null,
    null,
    null,
    null);

FormatStream combined(String url) => FormatStream(
    url, '18', 'video/mp4', 'medium', 'mp4', 'h264', '360p', '360p', '640x360');

void main() {
  setUp(() {
    final was = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = was);
  });

  test('frontend-only probes recognize the EU DASH and audio handoffs',
      () async {
    final requests = <String>[];
    final responseBodies = <StreamController<List<int>>>[];
    var cancelled = 0;
    final client = MockClient.streaming((request, _) async {
      expect(request.url.origin, frontend);
      expect(request.followRedirects, isFalse);
      expect(request.headers['range'], 'bytes=0-0');
      expect(request.headers['X-Test-Account'], 'frontend-only');
      requests.add(request.url.path);
      final dash = request.url.path.contains('/manifest/');
      if (dash) expect(request.url.queryParameters['local'], 'true');
      final body = StreamController<List<int>>(onCancel: () => cancelled++);
      responseBodies.add(body);
      return http.StreamedResponse(body.stream, dash ? 302 : 307, headers: {
        'content-type': dash ? 'application/dash+xml' : 'text/html',
        'location': dash
            ? 'https://video-comp.example/companion/api/manifest/dash/id/sample?opaque=ignored'
            : 'https://audio-comp.example/videoplayback?opaque=ignored',
      });
    });
    final video = Video(
        videoId: 'sample',
        dashUrl: manifest,
        hlsUrl: '$frontend/live.m3u8',
        adaptiveFormats: [
          audio('$frontend/videoplayback'),
          audio('https://optional.example/audio.m4a', '32000'),
        ],
        formatStreams: [
          combined('https://alternate.example/movie.mp4')
        ]);
    final origins = await discoverSetupMediaCompanions(
        server.copyWith(customHeaders: {'X-Test-Account': 'frontend-only'}),
        video,
        client,
        isCurrent: () => true);
    expect(
        origins, {'https://video-comp.example', 'https://audio-comp.example'});
    expect(requests, ['/api/manifest/dash/id/sample', '/videoplayback']);
    expect(cancelled, 2);
    for (final body in responseBodies) {
      await body.close();
    }
  });

  test('a healthy primary route and unused alternatives produce no prompt',
      () async {
    final seen = <Uri>[];
    final client = MockClient((request) async {
      seen.add(request.url);
      return http.Response('', 206);
    });
    final video = Video(
        videoId: 'sample',
        liveNow: true,
        hlsUrl: '$frontend/live.m3u8',
        dashUrl: 'https://optional.example/static.mpd',
        adaptiveFormats: [
          audio('$frontend/audio'),
          audio('https://alternate.example/audio', '1')
        ]);
    expect(
        await discoverSetupMediaCompanions(server, video, client,
            isCurrent: () => true),
        isEmpty);
    expect(seen.map((uri) => uri.path), ['/live.m3u8', '/audio']);
  });

  test('an explicitly advertised media origin needs no outbound connection',
      () async {
    final video = Video(
        videoId: 'sample',
        dashUrl: 'https://media.example:8443/media?sig=private',
        adaptiveFormats: [
          audio('https://media.example:8443/audio?sig=private')
        ]);
    expect(
        await discoverSetupMediaCompanions(server, video, MockClient((_) async {
          fail('Direct media addresses must not be visited during setup');
        }), isCurrent: () => true),
        {'https://media.example:8443'});
  });

  test('setup skips an advertised frontend sign-in route', () async {
    final seen = <Uri>[];
    final client = MockClient((request) async {
      seen.add(request.url);
      return http.Response('', 200);
    });
    final video = Video(
        videoId: 'sample',
        dashUrl: '$frontend/auth/signin',
        adaptiveFormats: [audio('$frontend/videoplayback')]);
    final origins = await discoverSetupMediaCompanions(server, video, client,
        isCurrent: () => true);
    expect(origins, isEmpty);
    expect(seen, isEmpty);
  });

  test('a frontend sign-out redirect ends discovery before the next GET',
      () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      seen.add(request.url.path);
      return http.Response('', 302, headers: {'location': '/signout'});
    });
    final video = Video(
        videoId: 'sample',
        dashUrl: manifest,
        adaptiveFormats: [audio('$frontend/videoplayback')]);
    final origins = await discoverSetupMediaCompanions(server, video, client,
        isCurrent: () => true);
    expect(origins, isEmpty);
    expect(seen, ['/api/manifest/dash/id/sample']);
  });

  for (final (status, location, retryAfter) in [
    (401, 'https://media.example/dash.mpd', null),
    (403, 'https://media.example/dash.mpd', null),
    (429, 'https://media.example/dash.mpd', null),
    (302, 'https://media.example/dash.mpd', '10'),
    (302, 'https://identity.example/if/flow/default/', null),
    (302, 'https://identity.example/unclassified', null),
    (302, 'https://youtube.com/dash.mpd', null),
    (302, 'http://media.example/dash.mpd', null),
    (302, 'https://user@media.example/dash.mpd', null),
    (302, 'https://127.0.0.1/dash.mpd', null),
    (302, 'https://user[invalid/dash.mpd', null),
  ]) {
    test('status $status and destination $location with cooldown $retryAfter',
        () async {
      final client = MockClient((request) async {
        expect(request.url.origin, frontend);
        return http.Response('', status, headers: {
          'location': location,
          if (retryAfter != null) 'retry-after': retryAfter
        });
      });
      expect(
          await discoverSetupMediaCompanions(
              server, const Video(videoId: 'sample', dashUrl: manifest), client,
              isCurrent: () => true),
          isEmpty);
    });
  }

  test(
      'combined streams are probed once and stay on the frontend through redirects',
      () async {
    final seen = <Uri>[];
    final video = Video(
        videoId: 'sample', formatStreams: [combined('$frontend/video.mp4')]);
    final client = MockClient((request) async {
      seen.add(request.url);
      return http.Response('', 307, headers: {
        'location':
            seen.length == 1 ? '/proxied' : 'https://media.example/stream.mp4',
      });
    });
    expect(
        await discoverSetupMediaCompanions(server, video, client,
            isCurrent: () => true),
        {'https://media.example'});
    expect(seen.map((uri) => uri.toString()),
        ['$frontend/video.mp4', '$frontend/proxied']);
  });

  test('late headers are cancelled after the aggregate deadline', () async {
    final delayed = Completer<http.StreamedResponse>();
    final cancelled = Completer<void>();
    final body = StreamController<List<int>>(onCancel: cancelled.complete);
    final client = MockClient.streaming((_, __) => delayed.future);
    final result = discoverSetupMediaCompanions(
        server, const Video(videoId: 'sample', dashUrl: manifest), client,
        isCurrent: () => true);
    expect(await result.timeout(const Duration(seconds: 7)), isEmpty);
    delayed.complete(http.StreamedResponse(body.stream, 307,
        headers: {'location': 'https://media.example/stream.mpd'}));
    await cancelled.future.timeout(const Duration(seconds: 1));
    await body.close();
  });

  test('ineligible frontend and stale profile never start the optional probe',
      () async {
    final client = MockClient((_) async => fail('Probe should not run'));
    const video = Video(videoId: 'sample', dashUrl: manifest);
    expect(
        await discoverSetupMediaCompanions(
            const Server(url: 'http://instance.onion'), video, client,
            isCurrent: () => true),
        isEmpty);
    expect(
        await discoverSetupMediaCompanions(server, video, client,
            isCurrent: () => false),
        isEmpty);
  });
}
