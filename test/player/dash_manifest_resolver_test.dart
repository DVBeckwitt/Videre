import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/player/dash_manifest_resolver.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
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
const staticMpd = '<?xml version="1.0"?>'
    '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"/>';

String watchPage(String src) => '''
<!doctype html><html><body>
<video id="player"><source label="dash" type='application/dash+xml'
src="$src"></video></body></html>
''';

void main() {
  test('successful static manifest can be handed directly to this playback',
      () async {
    final bodies = <String>[];
    var calls = 0;
    final resolver = DashManifestResolver(MockClient((request) async {
      calls++;
      return http.Response(staticMpd, 200, request: request);
    }));

    expect(
        await resolver.resolve(original, videoId, server,
            onManifest: bodies.add),
        original);
    expect(bodies, [staticMpd]);
    expect(calls, 1);

    bodies.clear();
    final second = original.replaceAll(videoId, 'next-video');
    expect(
        await resolver.resolve(second, 'next-video', server,
            onManifest: bodies.add),
        second);
    expect(calls, 1);
    expect(bodies, isEmpty,
        reason: 'A healthy-route cache must never supply another video body');
  });

  test('missing-check recovery supplies only the fresh signed manifest body',
      () async {
    final bodies = <String>[];
    final requested = <Uri>[];
    var successfulManifests = 0;
    final resolver = DashManifestResolver(MockClient((request) async {
      requested.add(request.url);
      if (request.url.path == '/watch') {
        final id = request.url.queryParameters['v']!;
        return http.Response(watchPage(recovered.replaceAll(videoId, id)), 200,
            request: request);
      }
      if (!request.url.queryParameters.containsKey('check')) {
        return http.Response('No check ID.', 400, request: request);
      }
      successfulManifests++;
      return http.Response('$staticMpd<!--$successfulManifests-->', 200,
          request: request);
    }));

    expect(
        await resolver.resolve(original, videoId, server,
            onManifest: bodies.add),
        recovered);
    expect(requested, hasLength(3));
    expect(requested.first.toString(), original);
    expect(requested[1].path, '/watch');
    expect(requested.last.toString(), recovered);
    expect(bodies, ['$staticMpd<!--1-->']);

    requested.clear();
    final next = original.replaceAll(videoId, 'next-video');
    final nextSigned = recovered.replaceAll(videoId, 'next-video');
    expect(
        await resolver.resolve(next, 'next-video', server,
            onManifest: bodies.add),
        nextSigned);
    expect(requested.map((uri) => uri.path),
        ['/watch', '/companion/api/manifest/dash/id/next-video']);
    expect(requested.last.toString(), nextSigned);
    expect(bodies, ['$staticMpd<!--1-->', '$staticMpd<!--2-->']);
  });

  test('manifest reuse never crosses credentials or route-cache expiry',
      () async {
    var now = DateTime(2026);
    var calls = 0;
    final bodies = <String>[];
    final resolver = DashManifestResolver(MockClient((request) async {
      calls++;
      return http.Response('$staticMpd<!--$calls-->', 200, request: request);
    }), now: () => now);

    await resolver.resolve(original, videoId, server, onManifest: bodies.add);
    await resolver.resolve(
        original,
        videoId,
        server
            .copyWith(customHeaders: {'X-Instance-Auth': 'other-test-account'}),
        onManifest: bodies.add);
    expect(calls, 2);
    expect(bodies, ['$staticMpd<!--1-->', '$staticMpd<!--2-->']);

    now = now.add(const Duration(minutes: 3));
    await resolver.resolve(original, videoId, server, onManifest: bodies.add);
    expect(calls, 3);
    expect(bodies.last, '$staticMpd<!--3-->');
  });

  test('redirected manifest body keeps native URL loading for relative sources',
      () async {
    final bodies = <String>[];
    final requested = <Uri>[];
    final resolver = DashManifestResolver(MockClient((request) async {
      requested.add(request.url);
      if (requested.length == 1) {
        return http.Response('', 302,
            headers: {'location': '/redirected/manifest.mpd'},
            request: request);
      }
      return http.Response(staticMpd, 200, request: request);
    }));

    expect(
        await resolver.resolve(original, videoId, server,
            onManifest: bodies.add),
        original);
    expect(requested, hasLength(2));
    expect(requested.last.path, '/redirected/manifest.mpd');
    expect(bodies, isEmpty);
  });

  test('unattributed or mismatched response bodies cannot be reused', () async {
    for (final request in [
      null,
      http.Request(
          'GET', Uri.parse(original.replaceAll(videoId, 'other-video'))),
      http.Request(
          'GET', Uri.parse(original.replaceAll('inv.example', 'elsewhere'))),
    ]) {
      final bodies = <String>[];
      final resolver = DashManifestResolver(MockClient(
          (_) async => http.Response(staticMpd, 200, request: request)));
      expect(
          await resolver.resolve(original, videoId, server,
              onManifest: bodies.add),
          original);
      expect(bodies, isEmpty);
    }
  });

  for (final body in [
    mpd,
    staticMpd.replaceFirst('type="static"', 'type="dynamic"'),
    '<html><body>Sign in to this instance</body></html>',
    '<html><body><MPD type="static"/></body></html>',
    '<!-- <MPD type="static"/> --><html><body><MPD type="static"/></body></html>',
  ]) {
    test('non-static or unrecognized response preserves native loading: $body',
        () async {
      final bodies = <String>[];
      final resolver = DashManifestResolver(MockClient(
          (request) async => http.Response(body, 200, request: request)));
      expect(
          await resolver.resolve(original, videoId, server,
              onManifest: bodies.add),
          original);
      expect(bodies, isEmpty);
    });
  }

  test('inline size limit counts bytes and leaves oversized URLs usable',
      () async {
    final maximum = DashManifestResolver.maxInlineManifestBytes;
    final boundary = staticMpd.padRight(maximum);
    final oversized =
        '$staticMpd<!--${List.filled(maximum ~/ 2, 'é').join()}-->';
    expect(oversized.length, lessThan(maximum));
    for (final (body, reusable) in [(boundary, true), (oversized, false)]) {
      final bodies = <String>[];
      final resolver = DashManifestResolver(MockClient((request) async =>
          http.Response(body, 200,
              headers: {'content-type': 'application/dash+xml; charset=utf-8'},
              request: request)));
      expect(
          await resolver.resolve(original, videoId, server,
              onManifest: bodies.add),
          original);
      expect(bodies, reusable ? [body] : isEmpty);
    }
  });

  test('UTF-8 manifest text is reused exactly without a response charset',
      () async {
    const body = '<?xml version="1.0" encoding="UTF-8"?>'
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">'
        '<ProgramInformation><Title>Björk 日本語</Title></ProgramInformation>'
        '</MPD>';
    final bodies = <String>[];
    final resolver = DashManifestResolver(MockClient((request) async =>
        http.Response.bytes(utf8.encode(body), 200,
            headers: {'content-type': 'application/dash+xml'},
            request: request)));

    expect(
        await resolver.resolve(original, videoId, server,
            onManifest: bodies.add),
        original);
    expect(bodies, [body]);
  });

  test('invalid UTF-8 or unsupported XML encodings keep native loading',
      () async {
    final invalidUtf8 = [
      ...utf8.encode(staticMpd),
      ...utf8.encode('<!--'),
      0xff,
      ...utf8.encode('-->'),
    ];
    for (final bytes in [
      invalidUtf8,
      utf8.encode(staticMpd.replaceFirst(
          '<?xml version="1.0"?>', '<?xml version="1.0" encoding="UTF-16"?>')),
      utf8.encode(staticMpd.replaceFirst('<?xml version="1.0"?>',
          '<?xml version="1.0" encoding="ISO-8859-1"?>')),
    ]) {
      final bodies = <String>[];
      final resolver = DashManifestResolver(MockClient((request) async =>
          http.Response.bytes(bytes, 200, request: request)));
      expect(
          await resolver.resolve(original, videoId, server,
              onManifest: bodies.add),
          original);
      expect(bodies, isEmpty);
    }
  });

  test('a response completed after timeout cannot deliver a manifest body',
      () async {
    final pending = Completer<http.Response>();
    final started = Completer<http.Request>();
    final bodies = <String>[];
    final resolver = DashManifestResolver(MockClient((request) {
      started.complete(request);
      return pending.future;
    }), timeout: const Duration(milliseconds: 10));
    final resolving =
        resolver.resolve(original, videoId, server, onManifest: bodies.add);
    final request = await started.future;
    expect(await resolving, isNull);
    pending.complete(http.Response(staticMpd, 200, request: request));
    await Future<void>.delayed(Duration.zero);
    expect(bodies, isEmpty);
  });

  test('already signed API URLs add no startup request', () async {
    final bodies = <String>[];
    final resolver = DashManifestResolver(MockClient((_) async {
      fail('Signed sources do not need missing-check recovery');
    }));
    expect(
        await resolver.resolve(recovered, videoId, server,
            onManifest: bodies.add),
        recovered);
    expect(bodies, isEmpty);
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

  for (final status in [401, 403, 429]) {
    for (final failedStep in [1, 2, 3]) {
      test('DASH HTTP $status stops fallback at request $failedStep', () async {
        var calls = 0;
        final bodies = <String>[];
        final resolver = DashManifestResolver(MockClient((_) async {
          calls++;
          if (calls == failedStep) return http.Response('Refused', status);
          return calls == 1
              ? http.Response('No check ID.', 400)
              : http.Response(watchPage(recovered), 200);
        }));
        await expectLater(
            resolver.resolve(original, videoId, server,
                throwRetryable: true, onManifest: bodies.add),
            throwsA(isA<InvidiousServiceError>()
                .having((error) => error.statusCode, 'status', status)));
        expect(calls, failedStep);
        expect(bodies, isEmpty);
      });
    }
  }

  for (final retryAfter in ['10', 'invalid', 'Tue, 10 Nov 2026 12:00:10 GMT']) {
    test('DASH cooldown $retryAfter cannot become backend fallback', () async {
      var calls = 0;
      final bodies = <String>[];
      final resolver = DashManifestResolver(MockClient((_) async {
        calls++;
        return http.Response('Unavailable', 503,
            headers: {'retry-after': retryAfter});
      }), now: () => DateTime.utc(2026, 11, 10, 12));
      await expectLater(
          resolver.resolve(original, videoId, server,
              throwRetryable: true, onManifest: bodies.add),
          throwsA(isA<InvidiousServiceError>()
              .having(isBackendRetryable, 'backend retry', isFalse)));
      expect(calls, 1);
      expect(bodies, isEmpty);
    });
  }

  for (final retryAfter in ['0', 'Tue, 10 Nov 2026 11:59:00 GMT']) {
    test('DASH elapsed cooldown $retryAfter allows bounded backend fallback',
        () async {
      final resolver = DashManifestResolver(MockClient((_) async {
        return http.Response('Unavailable', 503,
            headers: {'retry-after': retryAfter});
      }), now: () => DateTime.utc(2026, 11, 10, 12));
      await expectLater(
          resolver.resolve(original, videoId, server, throwRetryable: true),
          throwsA(isA<BackendPlaybackFailure>()));
    });
  }

  for (final failure in [
    const HandshakeException('Certificate refused'),
    const SocketException('Privacy policy refused'),
  ]) {
    test('DASH preserves a terminal ${failure.runtimeType}', () async {
      var calls = 0;
      final resolver = DashManifestResolver(MockClient((_) async {
        calls++;
        throw failure;
      }));
      await expectLater(
          resolver.resolve(original, videoId, server, throwRetryable: true),
          throwsA(same(failure)));
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

  test('external manifests are not admitted for native playback', () async {
    final resolver = DashManifestResolver(MockClient((_) async {
      fail('External manifest must not be probed');
    }));
    const direct = 'https://r1.googlevideo.com/manifest.mpd';
    expect(await resolver.resolve(direct, videoId, server), isNull);
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
