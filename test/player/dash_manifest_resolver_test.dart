import 'dart:async';

import 'package:clipious/player/dash_manifest_resolver.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const server = Server(
  url: 'https://inv.example',
  customHeaders: {'X-Instance-Auth': 'test-only'},
);
const videoId = 'dQw4w9WgXcQ';
const original = 'https://inv.example/companion/api/manifest/dash/id/$videoId'
    '?local=true';
const recovered = 'https://inv.example/companion/api/manifest/dash/id/$videoId'
    '?local=true&unique_res=1&check=test%2Bsignature%3D';
const mpd = '<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"/>';

String watchPage(String src) => '''
<!doctype html><html><body>
<video id="player"><source label="dash" type='application/dash+xml'
src="$src"></video></body></html>
''';

void main() {
  test('already signed API URLs add no startup request', () async {
    final resolver = DashManifestResolver(MockClient((_) async {
      fail('Signed sources do not need missing-check recovery');
    }));
    expect(await resolver.resolve(recovered, videoId, server), recovered);
  });

  test('healthy routes skip repeated probes, expire, and respect credentials',
      () async {
    var now = DateTime(2026);
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((_) async {
      calls++;
      return http.Response(mpd, 200);
    }), now: () => now);
    await resolver.resolve(original, videoId, server);
    final second = original.replaceAll(videoId, 'next-video');
    expect(await resolver.resolve(second, 'next-video', server), second);
    expect(calls, 1);
    await resolver.resolve(
        second, 'next-video', server.copyWith(customHeaders: {}));
    expect(calls, 2);
    await resolver.resolve(
        second.replaceAll('local=true', 'local=false'), 'next-video', server);
    expect(calls, 3);
    resolver.invalidate(second, server);
    await resolver.resolve(second, 'next-video', server);
    expect(calls, 4);
    now = now.add(const Duration(minutes: 3));
    await resolver.resolve(second, 'next-video', server);
    expect(calls, 5);
  });

  test('known affected routes get fresh signatures without repeating the 400',
      () async {
    final paths = <String>[];
    final resolver = DashManifestResolver(MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/watch') {
        final id = request.url.queryParameters['v']!;
        return http.Response(watchPage(recovered.replaceAll(videoId, id)), 200);
      }
      return request.url.queryParameters.containsKey('check')
          ? http.Response(mpd, 200)
          : http.Response('No check ID.', 400);
    }));
    expect(await resolver.resolve(original, videoId, server), recovered);
    paths.clear();
    expect(
        await resolver.resolve(
            original.replaceAll(videoId, 'next-video'), 'next-video', server),
        recovered.replaceAll(videoId, 'next-video'));
    expect(paths, ['/watch', '/companion/api/manifest/dash/id/next-video']);
  });

  test('a video-specific server failure does not blacklist other videos',
      () async {
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((_) async {
      calls++;
      return calls == 1
          ? http.Response('Unavailable', 500)
          : http.Response(mpd, 200);
    }));
    expect(await resolver.resolve(original, videoId, server), isNull);
    final second = original.replaceAll(videoId, 'next-video');
    expect(await resolver.resolve(second, 'next-video', server), second);
    expect(calls, 2);
  });

  test('fixed instance uses the normal API URL without fetching a page',
      () async {
    final requests = <http.Request>[];
    final resolver = DashManifestResolver(MockClient((request) async {
      requests.add(request);
      return http.Response(mpd, 200);
    }));
    expect(await resolver.resolve(original, videoId, server), original);
    expect(requests.map((r) => r.url.toString()), [original]);
    expect(requests.single.headers['X-Instance-Auth'], 'test-only');
    expect(requests.single.followRedirects, isFalse);
  });

  for (final src in [
    recovered,
    recovered.replaceAll('&', '&amp;'),
    recovered.replaceFirst('https://inv.example', ''),
    recovered.replaceFirst('https:', '').replaceAll('&', '&#38;'),
  ]) {
    test('recovers the player source, decoding HTML: $src', () async {
      final requests = <http.Request>[];
      final resolver = DashManifestResolver(MockClient((request) async {
        requests.add(request);
        switch (requests.length) {
          case 1:
            return http.Response('No check ID.\n', 400);
          case 2:
            expect(request.url.path, '/watch');
            expect(request.url.queryParameters,
                {'v': videoId, 'quality': 'dash', 'local': 'true'});
            return http.Response(watchPage(src), 200);
          default:
            expect(request.url.toString(), recovered);
            return http.Response(mpd, 200);
        }
      }));
      expect(await resolver.resolve(original, videoId, server), recovered);
      expect(requests, hasLength(3));
      expect(requests.every((r) => !r.followRedirects), isTrue);
      expect(requests.every((r) => r.headers['X-Instance-Auth'] == 'test-only'),
          isTrue);
    });
  }

  for (final failure in [
    (400, 'Invalid check ID.'),
    (403, 'No check ID.'),
    (500, 'No check ID.'),
  ]) {
    test('does not scrape for unrelated error $failure', () async {
      var calls = 0;
      final resolver = DashManifestResolver(MockClient((request) async {
        calls++;
        return http.Response(failure.$2, failure.$1);
      }));
      expect(await resolver.resolve(original, videoId, server), isNull);
      expect(calls, 1);
    });
  }

  for (final page in [
    '<html>Page layout changed</html>',
    '<!-- ${watchPage(recovered)} -->',
    '<script>${watchPage(recovered)}</script>',
    watchPage(recovered.replaceFirst('inv.example', 'evil.example')),
    watchPage(recovered.replaceFirst('https:', 'http:')),
    watchPage(recovered.replaceFirst('inv.example', 'inv.example:444')),
    watchPage(
        recovered.replaceFirst('inv.example', 'user:password@inv.example')),
    watchPage(recovered.replaceFirst(videoId, 'another-video')),
    watchPage(recovered.replaceFirst('local=true', 'local=false')),
    watchPage(original),
    watchPage('javascript:alert(1)'),
  ]) {
    test('fails safely for absent or untrusted player source: $page', () async {
      var calls = 0;
      final resolver = DashManifestResolver(MockClient((request) async {
        calls++;
        return calls == 1
            ? http.Response('No check ID.', 400)
            : http.Response(page, 200);
      }));
      expect(await resolver.resolve(original, videoId, server), isNull);
      expect(calls, 2);
    });
  }

  test('failed recovery is retried only once', () async {
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((request) async {
      calls++;
      return calls == 2
          ? http.Response(watchPage(recovered), 200)
          : http.Response('No check ID.', 400);
    }));
    expect(await resolver.resolve(original, videoId, server), isNull);
    expect(calls, 3);
  });

  test('same-origin redirects can recover missing check ID before native setup',
      () async {
    final requests = <http.Request>[];
    final resolver = DashManifestResolver(MockClient((request) async {
      requests.add(request);
      switch (requests.length) {
        case 1:
          return http.Response('', 302,
              headers: {'location': '/companion/unsigned'});
        case 2:
          expect(request.url.path, '/companion/unsigned');
          return http.Response('No check ID.', 400);
        case 3:
          return http.Response(watchPage(recovered), 200);
        default:
          return http.Response(mpd, 200);
      }
    }));
    expect(await resolver.resolve(original, videoId, server), recovered);
    expect(requests, hasLength(4));
    expect(requests.every((r) => !r.followRedirects), isTrue);
  });

  test('same-origin redirect loops are bounded', () async {
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((_) async {
      calls++;
      return http.Response('', 302, headers: {'location': original});
    }));
    expect(await resolver.resolve(original, videoId, server), original);
    expect(calls, 4);
  });

  test('failed watch-page request uses fallback', () async {
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((request) async {
      calls++;
      return calls == 1
          ? http.Response('No check ID.', 400)
          : http.Response('Unavailable', 503);
    }));
    expect(await resolver.resolve(original, videoId, server), isNull);
    expect(calls, 2);
  });

  test('external manifests keep native handling without instance headers',
      () async {
    final resolver = DashManifestResolver(MockClient((_) async {
      fail('External manifest must not be probed');
    }));
    const direct = 'https://r1.googlevideo.com/manifest.mpd';
    expect(await resolver.resolve(direct, videoId, server), direct);
  });

  test('redirects retain native handling without forwarding credentials',
      () async {
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((_) async {
      calls++;
      return http.Response('', 302,
          headers: {'location': 'https://elsewhere/'});
    }));
    expect(await resolver.resolve(original, videoId, server), original);
    expect(calls, 1);
  });

  test('network failure and timeout use fallback', () async {
    final resolver = DashManifestResolver(MockClient((_) async {
      throw http.ClientException('offline');
    }));
    expect(await resolver.resolve(original, videoId, server), isNull);
    final pending = Completer<http.Response>();
    final slow = DashManifestResolver(MockClient((_) => pending.future),
        timeout: const Duration(milliseconds: 10));
    expect(await slow.resolve(original, videoId, server), isNull);
    pending.complete(http.Response(mpd, 200));
  });

  test('supports instances hosted under a path prefix', () async {
    const nestedServer = Server(url: 'https://inv.example/invidious/');
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('No check ID.', 400);
      if (calls == 2) {
        expect(request.url.path, '/invidious/watch');
        return http.Response(
            watchPage('companion/api/manifest/dash/id/'
                '$videoId?local=true&check=nested'),
            200);
      }
      expect(request.url.path,
          '/invidious/companion/api/manifest/dash/id/$videoId');
      return http.Response(mpd, 200);
    }));
    expect(
        await resolver.resolve(original, videoId, nestedServer),
        'https://inv.example/invidious/companion/api/manifest/dash/id/'
        '$videoId?local=true&check=nested');
  });
}
