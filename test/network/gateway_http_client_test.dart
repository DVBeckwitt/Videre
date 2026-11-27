import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/gateway_http_client.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/player/dash_manifest_resolver.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';

class _DirectOverrides extends HttpOverrides {}

class _Headers extends Fake implements HttpHeaders {
  final values = <String, List<String>>{};
  bool frozen = false;

  void _check() {
    if (frozen) throw StateError('Headers have already been sent.');
  }

  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _check();
    values[name.toLowerCase()] = value is Iterable
        ? value.map((item) => item.toString()).toList()
        : [value.toString()];
  }

  @override
  void removeAll(String name) {
    _check();
    values.remove(name.toLowerCase());
  }

  @override
  String? value(String name) {
    final entries = this[name];
    if (entries == null) return null;
    if (entries.length != 1) throw StateError('Multiple header values.');
    return entries.single;
  }

  @override
  void forEach(void Function(String, List<String>) action) =>
      values.forEach(action);
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final _Headers headers = _Headers();
  @override
  final cookies = <Cookie>[];
  @override
  bool persistentConnection = true;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool bufferOutput = true;
  @override
  Encoding encoding = utf8;
  final body = <int>[];
  final _response = Completer<HttpClientResponse>();
  final _Response response;
  bool sent = false;
  bool aborted = false;

  _Request(this.method, this.uri, this.response);

  @override
  Future<HttpClientResponse> get done => _response.future;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  void add(List<int> bytes) {
    sent = true;
    headers.frozen = true;
    body.addAll(bytes);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      add(bytes);
    }
  }

  @override
  Future<void> flush() async {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      abort(error, stackTrace);
  @override
  Future<HttpClientResponse> close() {
    sent = true;
    headers.frozen = true;
    if (!_response.isCompleted) _response.complete(response);
    return done;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
    if (!_response.isCompleted) {
      _response.completeError(
          exception ?? const HttpException('Aborted.'), stackTrace);
    }
  }
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final _Headers headers = _Headers();
  final List<int> body;
  bool listened = false;

  _Response(this.statusCode,
      {Map<String, Object> headers = const {}, String body = 'response'})
      : body = utf8.encode(body) {
    headers.forEach(this.headers.set);
  }

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    listened = true;
    return Stream.value(body).listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  int get contentLength => body.length;
  @override
  String get reasonPhrase => 'test response';
  @override
  bool get isRedirect => const {301, 302, 303, 307, 308}.contains(statusCode);
  @override
  bool get persistentConnection => true;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  List<Cookie> get cookies => const [];
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  Future<Socket> detachSocket() =>
      throw UnsupportedError('No socket in fixture.');
  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      throw StateError('Protected redirects must stay in the gateway wrapper.');
}

class _Client extends Fake implements HttpClient {
  final List<_Response> responses;
  final requests = <_Request>[];
  _Client(this.responses);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = _Request(method, url, responses[requests.length]);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final origin = Uri.parse('https://instance.example');
  final context = GatewayRequestContext.forAccount(
      'person-a', 'account-a', origin.toString())!;
  Future<GatewayResolvedSession> resolve(String _, Uri __) async =>
      const GatewayResolvedSession(
          enabled: true,
          needsSignIn: false,
          cookies: 'gateway=session; SID=gateway-sid',
          revision: 17);
  Future<void> ingest(String _, Uri __, List<String> ___,
      {required int statusCode,
      String? contentType,
      String? location,
      int? revision}) async {}

  Future<HttpClientRequest> request(GatewayHttpClient client,
      {String method = 'GET'}) async {
    final request =
        await client.openUrl(method, origin.resolve('/api/v1/auth/history'));
    request.headers.set(gatewayContextHeader, context.encoded);
    return request;
  }

  group('read-only companion discovery', () {
    const account = Server(
        url: 'https://invidious.nerdvpn.de',
        profileId: 'person',
        id: 'account',
        gatewayEnabled: true);
    final sample = Uri.parse('${account.url}/videoplayback');
    final owner = GatewayRequestContext.forAccount(
        account.profileId, account.accountId, account.url)!;

    test(
        'only the selected host receives a request and no response changes credentials',
        () async {
      for (final (status, location) in [
        (307, 'https://media.example/stream'),
        (302, 'https://sso.example/login'),
        (401, null),
        (429, null),
      ]) {
        final raw = _Client([
          _Response(status,
              headers: {
                'content-type':
                    location != null ? 'text/html' : 'application/json',
                'set-cookie': 'sample-cookie=discard',
                if (location != null) 'location': location,
                if (status == 429) 'retry-after': '30',
              },
              body: '{"error":"rate_limited"}')
        ]);
        final client = GatewayHttpClient(raw,
            resolve: resolve,
            ingest: (_, __, ___,
                    {required statusCode, contentType, location, revision}) =>
                fail('An optional probe updated the gateway session'),
            recover: (_,
                    {required error,
                    required statusCode,
                    failedKey,
                    failedIntent,
                    retryAfter,
                    revision,
                    retry = true}) =>
                fail('An optional probe recovered or replayed a credential'));
        final response = await GatewayHttpClient.withCompanionDiscovery(
            account, sample, () async {
          final req = await client.getUrl(sample);
          req.followRedirects = false;
          req.headers.set(gatewayContextHeader, owner.encoded);
          req.headers.set('Range', 'bytes=0-0');
          return req.close();
        });
        expect(response.statusCode, status);
        expect(response.headers.value('location'), location);
        if (status == 429) expect(response.headers.value('retry-after'), '30');
        expect(raw.requests.single.uri, sample);
        expect(raw.requests.single.headers.value('Cookie'),
            contains('gateway=session'));
        await response.drain<void>();
      }
    });

    test(
        'other accounts, endpoints, methods, and ordinary requests keep normal response handling',
        () async {
      final other = GatewayRequestContext.forAccount(
          account.profileId, 'another-account', account.url)!;
      for (final (scoped, uri, marker, method, follow) in [
        (false, sample, owner, 'GET', false),
        (true, sample, other, 'GET', false),
        (true, sample.resolve('/api/v1/videos/fixture'), owner, 'GET', false),
        (true, sample, owner, 'POST', false),
        (true, sample, owner, 'GET', true),
      ]) {
        final raw = _Client([_Response(403)]);
        final client = GatewayHttpClient(raw, resolve: resolve, ingest:
            (_, __, ___,
                {required statusCode, contentType, location, revision}) async {
          throw const GatewayAuthenticationRequired();
        });
        Future<HttpClientResponse> send() async {
          final req = await client.openUrl(method, uri);
          req.followRedirects = follow;
          req.headers.set(gatewayContextHeader, marker.encoded);
          return req.close();
        }

        await expectLater(
            scoped
                ? GatewayHttpClient.withCompanionDiscovery(
                    account, sample, send)
                : send(),
            throwsA(isA<GatewayAuthenticationRequired>()));
      }
      expect(
          () => GatewayHttpClient.withCompanionDiscovery(
              account,
              Uri.parse('https://media.example/sample'),
              () => fail('cross-origin probe')),
          throwsArgumentError);
    });
  });

  group('protected playback manifest probes', () {
    const server = Server(
        url: 'https://instance.example',
        id: 'account-a',
        profileId: 'person-a',
        gatewayEnabled: true,
        mediaCompanionOrigins: ['https://media.example']);
    const path = '/api/manifest/dash/id/video';
    const companion = 'https://media.example/stream';
    final manifest = origin.resolve('$path?local=true');

    test('HTML redirects between two frontend media routes keep the session',
        () async {
      const next = '/instance/api/manifest/hls_variant/sample.m3u8';
      final raw = _Client([
        _Response(302, headers: {
          'location': next,
          'content-type': 'text/html',
          'set-cookie': 'gateway=renewed'
        }),
        _Response(307, headers: {
          'location': companion,
          'content-type': 'text/html',
        })
      ]);
      final ingested = <(Uri, String?, String?, String)>[];
      final client = GatewayHttpClient(raw, resolve: resolve, ingest:
          (_, uri, cookies,
              {required statusCode, contentType, location, revision}) async {
        ingested.add((uri, contentType, location, cookies.join(',')));
      });
      expect(
          await DashManifestResolver(IOClient(client))
              .loadTrackManifest(manifest.toString(), server),
          isNull);
      expect(ingested, [
        (manifest, null, next, 'gateway=renewed'),
        (origin.resolve(next), null, companion, '')
      ]);
      expect(raw.requests.map((request) => request.uri),
          [manifest, origin.resolve(next)]);
    });

    test(
        'HLS track discovery leaves an approved HTML handoff to native playback',
        () async {
      final playlist = origin.resolve('/api/manifest/hls_playlist/video');
      final raw = _Client([
        _Response(307, headers: {
          'location': companion,
          'content-type': 'text/html',
          'set-cookie': 'gateway=renewed'
        }),
        _Response(200, body: '#EXTM3U')
      ]);
      final ingested = <int>[];
      final client = GatewayHttpClient(raw, resolve: resolve, ingest:
          (key, uri, cookies,
              {required statusCode, contentType, location, revision}) async {
        ingested.add(statusCode);
        if (statusCode == 307) {
          expect(key, context.encoded);
          expect(uri, playlist);
          expect(contentType, isNull);
          expect(location, companion);
          expect(cookies, ['gateway=renewed']);
          expect(revision, 17);
        }
      });
      final resolver = DashManifestResolver(IOClient(client));
      expect(await resolver.loadTrackManifest(playlist.toString(), server),
          isNull);
      expect(await resolver.loadTrackManifest(companion, server), isNull);
      expect(await resolver.loadTrackManifest(playlist.toString(), server),
          '#EXTM3U');
      expect(ingested, [307, 200]);
      expect(raw.requests.map((r) => r.uri), [playlist, playlist]);
    });

    for (final signed in [false, true]) {
      test('approved HTML redirect keeps the session (signed=$signed)',
          () async {
        final recovered = origin.resolve('$path?local=true&check=signature');
        final raw = _Client([
          if (signed) ...[
            _Response(400, body: 'No check ID.'),
            _Response(200,
                body: '<video id="player"><source '
                    'type="application/dash+xml" src="$recovered"></video>'),
          ],
          _Response(302, headers: {
            'location': companion,
            'content-type': 'text/html',
            'set-cookie': 'gateway=renewed'
          }),
        ]);
        var handoffs = 0;
        final client = GatewayHttpClient(raw, resolve: resolve, ingest:
            (key, uri, cookies,
                {required statusCode, contentType, location, revision}) async {
          if (statusCode == 302) {
            handoffs++;
            expect(key, context.encoded);
            expect(uri, signed ? recovered : manifest);
            expect(cookies, ['gateway=renewed']);
            expect(revision, 17);
            expect(location, companion);
            expect(contentType, isNull);
          }
        });
        final resolver = DashManifestResolver(IOClient(client));
        final result = await resolver.resolve(
            manifest.toString(), 'video', server,
            onMediaOriginBlocked: () => fail('Approved host blocked'));
        expect(result, (signed ? recovered : manifest).toString());
        expect(handoffs, 1);
        expect(
            raw.requests.every((r) => r.uri.origin == origin.origin), isTrue);
      });
    }

    test('foreign login Location is retained for the native sign-in check',
        () async {
      const location = 'https://media.example/login';
      final raw = _Client([
        _Response(307,
            headers: {'location': location, 'content-type': 'text/html'})
      ]);
      var signInRequired = false;
      final client = GatewayHttpClient(raw, resolve: resolve, ingest:
          (_, __, ___,
              {required statusCode, contentType, location, revision}) async {
        if (statusCode == 307 && Uri.parse(location!).path == '/login') {
          signInRequired = true;
          throw const GatewayAuthenticationRequired();
        }
      });
      final result = await DashManifestResolver(IOClient(client)).resolve(
          manifest.toString(), 'video', server,
          onMediaOriginBlocked: () {});
      expect(signInRequired, isTrue);
      expect(result, isNull);
      expect(raw.requests.single.uri, manifest);
    });

    test('unapproved hosts and other callers retain HTML authentication checks',
        () async {
      final otherAccount = GatewayRequestContext.forAccount(
          'person-a', 'another-account', server.url)!;
      for (final (scoped, target, url, owner, status) in [
        (false, companion, manifest, context, 302),
        (true, 'https://unapproved.example/stream', manifest, context, 302),
        (true, 'https://media.example/signin', manifest, context, 302),
        (true, '/unclassified', manifest, context, 302),
        (true, '/auth/return.mpd', manifest, context, 302),
        (true, companion, origin.resolve('/api/v1/videos/video'), context, 302),
        (true, companion, manifest, otherAccount, 302),
        (true, companion, manifest, context, 403),
      ]) {
        final raw = _Client([
          _Response(status,
              headers: {'location': target, 'content-type': 'text/html'})
        ]);
        final client = GatewayHttpClient(raw, resolve: resolve, ingest:
            (_, __, ___,
                {required statusCode, contentType, location, revision}) async {
          expect(contentType, 'text/html');
          throw const GatewayAuthenticationRequired();
        });
        Future<HttpClientResponse> send() async {
          final req = await client.getUrl(url);
          req.followRedirects = false;
          req.headers.set(gatewayContextHeader, owner.encoded);
          return req.close();
        }

        await expectLater(
            scoped
                ? GatewayHttpClient.withManifestProbe(server, manifest, send)
                : send(),
            throwsA(isA<GatewayAuthenticationRequired>()));
        expect(raw.requests.single.uri, url);
      }
    });

    test('frontend redirect exemption requires a media route and manual GET',
        () async {
      for (final (source, autoFollow) in [
        (origin.resolve('/api/v1/videos/video'), false),
        (manifest, true),
      ]) {
        final raw = _Client([
          _Response(302, headers: {
            'location': '/api/manifest/hls_playlist/video',
            'content-type': 'text/html'
          })
        ]);
        String? observedType;
        final client = GatewayHttpClient(raw, resolve: resolve, ingest:
            (_, __, ___,
                {required statusCode, contentType, location, revision}) async {
          observedType = contentType;
          throw const GatewayAuthenticationRequired();
        });
        await expectLater(
            GatewayHttpClient.withManifestProbe(server, source, () async {
              final request = await client.getUrl(source);
              request.followRedirects = autoFollow;
              request.headers.set(gatewayContextHeader, context.encoded);
              return request.close();
            }),
            throwsA(isA<GatewayAuthenticationRequired>()));
        expect(observedType, 'text/html');
        expect(raw.requests.single.uri, source);
      }
    });
  });

  test(
      'request body waits for its account cookies and marker never reaches wire',
      () async {
    final raw = _Client([_Response(200)]);
    final ready = Completer<GatewayResolvedSession>();
    final client = GatewayHttpClient(raw,
        resolve: (_, __) => ready.future, ingest: ingest);
    final pending = await request(client, method: 'POST');
    pending.headers.set('Cookie', 'SID=invidious-session; preference=kept');
    pending.headers.set('Authorization', 'Bearer invidious-token');
    pending.write('first:');
    pending.add(utf8.encode('second'));
    final completed = pending.close();
    await Future<void>.delayed(Duration.zero);
    expect(raw.requests.single.sent, isFalse);
    expect(raw.requests.single.headers[gatewayContextHeader], isNull);
    ready.complete(await resolve('', origin));
    final response = await completed;
    expect(await response.transform(utf8.decoder).join(), 'response');
    final sent = raw.requests.single;
    expect(utf8.decode(sent.body), 'first:second');
    expect(sent.headers.value('Cookie'),
        'gateway=session; SID=invidious-session; preference=kept');
    expect(sent.headers.value('Authorization'), 'Bearer invidious-token');
    expect(sent.headers[gatewayContextHeader], isNull);
    expect(sent.followRedirects, isFalse);
    expect(pending.followRedirects, isTrue);
  });

  test(
      'streamed body completes before closing without resending frozen headers',
      () async {
    final raw = _Client([_Response(200)]);
    final client = GatewayHttpClient(raw, resolve: resolve, ingest: ingest);
    final pending = await request(client, method: 'POST');
    await pending.addStream(Stream.fromIterable([
      [1, 2],
      [3, 4]
    ]));
    await pending.flush();
    await (await pending.close()).drain<void>();
    expect(raw.requests.single.body, [1, 2, 3, 4]);
  });

  test(
      'same-origin redirect ingests every Set-Cookie and resolves fresh session',
      () async {
    const cookies = [
      'gateway=renewed; Expires=Wed, 09 Jun 2032 10:18:14 GMT; Secure; HttpOnly',
      'second=value; Path=/; Secure',
    ];
    final raw = _Client([
      _Response(302, headers: {'location': '/next', 'set-cookie': cookies}),
      _Response(200),
    ]);
    var current = 'gateway=original';
    var revision = 3;
    final lookups = <Uri>[];
    final received = <({List<String> cookies, int? revision})>[];
    final client = GatewayHttpClient(raw, resolve: (_, url) async {
      lookups.add(url);
      return GatewayResolvedSession(
          enabled: true,
          needsSignIn: false,
          cookies: current,
          revision: revision);
    }, ingest: (_, __, setCookies,
        {required statusCode, contentType, location, revision}) async {
      received.add((cookies: List.of(setCookies), revision: revision));
      if (setCookies.isNotEmpty) current = 'gateway=renewed; second=value';
    });
    final pending = await request(client);
    final response = await pending.close();
    await response.drain<void>();
    expect(lookups,
        [origin.resolve('/api/v1/auth/history'), origin.resolve('/next')]);
    expect(received.first.cookies, cookies);
    expect(received.map((value) => value.revision), [3, 3]);
    expect(raw.requests.last.headers.value('Cookie'),
        'gateway=renewed; second=value');
    expect(response.redirects.single.location, origin.resolve('/next'));
    expect(
        raw.requests
            .every((request) => request.headers[gatewayContextHeader] == null),
        isTrue);
  });

  test('redirect to another origin is rejected before opening another request',
      () async {
    final raw = _Client([
      _Response(302, headers: {'location': 'https://media.example/segment'}),
      _Response(200),
    ]);
    final lookups = <Uri>[];
    final client = GatewayHttpClient(raw, resolve: (context, uri) {
      lookups.add(uri);
      return resolve(context, uri);
    }, ingest: ingest);
    final pending = await request(client);
    pending.headers.set('X-Custom-Secret', 'private');
    pending.headers.set('Authorization', 'Bearer private');
    pending.headers.set('Cookie', 'SID=private');
    await expectLater(pending.close(), throwsA(isA<HttpException>()));
    expect(raw.requests, hasLength(1));
    expect(lookups, [origin.resolve('/api/v1/auth/history')]);
  });

  test('manual redirect uses the same account and origin boundary', () async {
    final raw = _Client([
      _Response(302,
          headers: {'location': 'https://other.example/destination'}),
      _Response(200),
    ]);
    final client = GatewayHttpClient(raw, resolve: resolve, ingest: ingest);
    final pending = await request(client)
      ..followRedirects = false;
    pending.headers.set('X-Custom-Secret', 'private');
    final first = await pending.close();
    expect(raw.requests, hasLength(1));
    await first.drain<void>();
    await expectLater(first.redirect(), throwsA(isA<HttpException>()));
    expect(raw.requests, hasLength(1));
  });

  for (final sameOrigin in [true, false]) {
    test('plain HTTP asset redirects retain selected origin ($sameOrigin)',
        () async {
      const server = Server(
          url: 'http://selected.example:8080',
          customHeaders: {
            'X-Instance-Access': 'fixture',
            'Cookie': 'SID=fixture'
          });
      final raw = _Client([
        _Response(302, headers: {
          'location': sameOrigin ? '/next' : 'http://other.example/cover.jpg'
        }),
        _Response(200),
      ]);
      final client = GatewayHttpClient(raw,
          resolve: (_, __) =>
              throw StateError('Plain origin has no auth context'),
          ingest: ingest);
      final url = Uri.parse('${server.url}/cover.jpg');
      final pending = await client.getUrl(url);
      server.headersForUrl(url.toString())!.forEach(pending.headers.set);
      if (sameOrigin) {
        await (await pending.close()).drain<void>();
        expect(raw.requests, hasLength(2));
        expect(raw.requests.last.headers.value('X-Instance-Access'), 'fixture');
        expect(raw.requests.last.headers.value('Cookie'), 'SID=fixture');
      } else {
        await expectLater(pending.close(), throwsA(isA<HttpException>()));
        expect(raw.requests, hasLength(1));
      }
      expect(
          raw.requests.every((request) =>
              request.headers[instanceOriginHeader] == null &&
              request.headers[gatewayContextHeader] == null),
          isTrue);
    });
  }

  test('plain origin marker does not authorize a different request origin',
      () async {
    final raw = _Client([_Response(200)]);
    final client = GatewayHttpClient(raw, resolve: resolve, ingest: ingest);
    final pending =
        await client.getUrl(Uri.parse('http://other.example/cover'));
    pending.headers.set(instanceOriginHeader, 'http://selected.example');
    await expectLater(pending.close(), throwsA(isA<HttpException>()));
    expect(raw.requests.single.sent, isFalse);
  });

  test('POST redirects never replay a body and only 303 changes it to GET',
      () async {
    for (final status in [302, 303, 307, 308]) {
      final raw = _Client([
        _Response(status, headers: {'location': '/after'}),
        _Response(200),
      ]);
      final client = GatewayHttpClient(raw, resolve: resolve, ingest: ingest);
      final pending = await request(client, method: 'POST');
      pending.contentLength = 6;
      pending.headers.set('Content-Length', '6');
      pending.write('secret');
      await (await pending.close()).drain<void>();
      expect(raw.requests, hasLength(status == 303 ? 2 : 1));
      if (status == 303) {
        expect(raw.requests.last.method, 'GET');
        expect(raw.requests.last.body, isEmpty);
        expect(raw.requests.last.headers['Content-Length'], isNull);
      }
    }
  });

  test('expired session and malformed marker fail before sending request',
      () async {
    for (final invalidMarker in [false, true]) {
      final raw = _Client([_Response(200)]);
      final client = GatewayHttpClient(raw,
          resolve: (_, __) async =>
              const GatewayResolvedSession(enabled: true, needsSignIn: true),
          ingest: ingest);
      final pending = await request(client);
      if (invalidMarker) pending.headers.set(gatewayContextHeader, 'malformed');
      await expectLater(
          pending.close(),
          throwsA(invalidMarker
              ? isA<HttpException>()
              : isA<GatewayAuthenticationRequired>()));
      expect(raw.requests.single.sent, isFalse);
      expect(raw.requests.single.headers[gatewayContextHeader], isNull);
    }
  });

  test('abort while resolving cookies never starts delayed body write',
      () async {
    final raw = _Client([_Response(200)]);
    final ready = Completer<GatewayResolvedSession>();
    final client = GatewayHttpClient(raw,
        resolve: (_, __) => ready.future, ingest: ingest);
    final pending = await request(client, method: 'POST');
    pending.write('body');
    final result = expectLater(pending.close(), throwsA(isA<HttpException>()));
    await Future<void>.delayed(Duration.zero);
    pending.abort();
    ready.complete(await resolve('', origin));
    await result;
    await Future<void>.delayed(Duration.zero);
    expect(raw.requests.single.sent, isFalse);
  });

  test('an unmarked request retains ordinary HTTP client behavior', () async {
    final raw = _Client([_Response(200)]);
    final client = GatewayHttpClient(raw,
        resolve: (_, __) => throw StateError('No session lookup expected.'),
        ingest: (_, __, ___,
                {required statusCode, contentType, location, revision}) =>
            throw StateError('No cookie ingestion expected.'));
    final pending =
        await client.getUrl(Uri.parse('https://public.example/video'));
    pending.headers.set('X-Public', 'kept');
    await (await pending.close()).drain<void>();
    expect(raw.requests.single.headers.value('X-Public'), 'kept');
    expect(raw.requests.single.followRedirects, isTrue);
  });

  test('real socket requests preserve streaming POST and response behavior',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<String>();
    server.listen((request) async {
      received.complete(
          await request.cast<List<int>>().transform(utf8.decoder).join());
      request.response.write('accepted');
      await request.response.close();
    });
    final client = GatewayHttpClient(_DirectOverrides().createHttpClient(null));
    addTearDown(() => client.close(force: true));
    final pending = await client
        .postUrl(Uri.parse('http://127.0.0.1:${server.port}/upload'));
    pending.headers.contentType =
        ContentType('text', 'plain', charset: 'utf-8');
    pending.write('first');
    await pending.addStream(Stream.value(utf8.encode('-second')));
    final response = await pending.close();
    expect(await response.transform(utf8.decoder).join(), 'accepted');
    expect(await received.future, 'first-second');
  });

  test(
      'gateway rejection on a response closes its stream and exposes auth state',
      () async {
    final response = _Response(401);
    final raw = _Client([response]);
    final client = GatewayHttpClient(raw, resolve: resolve, ingest: (_, __, ___,
        {required statusCode, contentType, location, revision}) async {
      throw const GatewayAuthenticationRequired();
    });
    final pending = await request(client);
    await expectLater(
        pending.close(), throwsA(isA<GatewayAuthenticationRequired>()));
    expect(response.listened, isTrue);
  });

  test('redirect limit stops before starting an extra request', () async {
    final raw = _Client([
      _Response(302, headers: {'location': '/second'}),
      _Response(302, headers: {'location': '/third'}),
    ]);
    final client = GatewayHttpClient(raw, resolve: resolve, ingest: ingest);
    final pending = await request(client)
      ..maxRedirects = 1;
    await expectLater(pending.close(), throwsA(isA<RedirectException>()));
    expect(raw.requests, hasLength(2));
  });

  for (final originUrl in [
    'https://invidious.nerdvpn.de',
    'http://$nerdVpnOnionHost',
    'https://$nerdVpnOnionHost',
  ]) {
    group('NerdVPN access $originUrl', () {
      final nerdOrigin = Uri.parse(originUrl);
      final nerdContext = GatewayRequestContext.forAccount(
          'person-a', 'account-a', nerdOrigin.toString())!;
      const oldKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';
      const newKey = 'nvpn_123456789abcdefghijklmnopqrstuv0';

      Future<HttpClientRequest> nerdRequest(GatewayHttpClient client,
          {String method = 'GET',
          String path = '/api/v1/videos/example'}) async {
        final pending = await client.openUrl(method, nerdOrigin.resolve(path));
        pending.headers.set(gatewayContextHeader, nerdContext.encoded);
        return pending;
      }

      _Response failure(String error, int status, {String? retryAfter}) =>
          _Response(status,
              headers: {
                'content-type': 'application/json',
                if (retryAfter != null) 'retry-after': retryAfter,
              },
              body: jsonEncode({'error': error}));

      test('recovers a key once and sends a fresh header on its read retry',
          () async {
        for (final secondFailure in [false, true]) {
          var currentKey = oldKey;
          var currentRevision = 5;
          final retries = <bool>[];
          final raw = _Client([
            failure('invalid_credentials', 401),
            secondFailure
                ? failure('invalid_credentials', 401)
                : _Response(200, body: 'accepted'),
          ]);
          final client = GatewayHttpClient(raw,
              resolve: (_, __) async => GatewayResolvedSession(
                  enabled: false,
                  needsSignIn: false,
                  apiKey: currentKey,
                  apiKeyRevision: currentRevision,
                  apiKeyIntent: 3),
              ingest: ingest,
              recover: (encoded,
                  {required error,
                  required statusCode,
                  retryAfter,
                  failedKey,
                  revision,
                  failedIntent,
                  retry = true}) async {
                expect(encoded, nerdContext.encoded);
                expect(error, 'invalid_credentials');
                expect(statusCode, 401);
                expect(failedKey, currentKey);
                expect(revision, currentRevision);
                expect(failedIntent, 3);
                retries.add(retry);
                currentKey = newKey;
                currentRevision = 6;
                return NerdVpnAccessStatus(retry ? 'ready' : 'signInRequired',
                    retryAllowed: retry);
              });
          final response = await (await nerdRequest(client)).close();
          expect(await response.transform(utf8.decoder).join(),
              secondFailure ? '{"error":"invalid_credentials"}' : 'accepted');
          expect(raw.requests, hasLength(2));
          expect(raw.requests.first.headers.value(nerdVpnKeyHeader), oldKey);
          expect(raw.requests.last.headers.value(nerdVpnKeyHeader), newKey);
          expect(raw.requests.last.uri, raw.requests.first.uri);
          expect(response.redirects, isEmpty);
          expect(retries, secondFailure ? [true, false] : [true]);
        }
      });

      test('recovers failed writes without replaying their bodies', () async {
        final raw = _Client([failure('credentials_required', 401)]);
        var recoveries = 0;
        final client = GatewayHttpClient(raw,
            resolve: (_, __) async => const GatewayResolvedSession(
                enabled: false, needsSignIn: false, apiKeyRevision: 1),
            ingest: ingest,
            recover: (_,
                {required error,
                required statusCode,
                retryAfter,
                failedKey,
                revision,
                failedIntent,
                retry = true}) async {
              recoveries++;
              return const NerdVpnAccessStatus('ready', retryAllowed: true);
            });
        final pending = await nerdRequest(client, method: 'POST');
        pending.write('{"videoId":"example"}');
        final response = await pending.close();
        expect(response.statusCode, 401);
        expect(await response.transform(utf8.decoder).join(),
            '{"error":"credentials_required"}');
        expect(recoveries, 1);
        expect(raw.requests, hasLength(1));
        expect(utf8.decode(raw.requests.single.body), '{"videoId":"example"}');
      });

      test('an older request is not replayed after a different sign-in',
          () async {
        final raw = _Client([failure('invalid_credentials', 401)]);
        var resolveCalls = 0;
        final client = GatewayHttpClient(raw,
            resolve: (_, __) async {
              resolveCalls++;
              return const GatewayResolvedSession(
                  enabled: false,
                  needsSignIn: false,
                  apiKey: oldKey,
                  apiKeyRevision: 4,
                  apiKeyIntent: 2);
            },
            ingest: ingest,
            recover: (_,
                {required error,
                required statusCode,
                retryAfter,
                failedKey,
                revision,
                failedIntent,
                retry = true}) async {
              expect(failedIntent, 2);
              expect(revision, 4);
              // Native has a ready key for a newer sign-in, but rejects this
              // request's previous intent so its bearer token is never replayed.
              return const NerdVpnAccessStatus('ready', retryAllowed: false);
            });
        final pending = await nerdRequest(client);
        pending.headers.set('Authorization', 'Bearer previous-account');
        final response = await pending.close();
        expect(response.statusCode, 401);
        expect(await response.transform(utf8.decoder).join(),
            '{"error":"invalid_credentials"}');
        expect(raw.requests, hasLength(1));
        expect(resolveCalls, 1);
      });

      test('keeps redirects and the managed key on their approved origin',
          () async {
        final raw = _Client([
          _Response(302, headers: {'location': '/media'}),
          _Response(302, headers: {'location': 'https://media.example/video'}),
          _Response(200),
        ]);
        final client = GatewayHttpClient(raw,
            resolve: (_, __) async => const GatewayResolvedSession(
                enabled: false, needsSignIn: false, apiKey: newKey),
            ingest: ingest);
        final pending = await nerdRequest(client);
        await expectLater(pending.close(), throwsA(isA<HttpException>()));
        expect(raw.requests, hasLength(2));
        expect(
            raw.requests.take(2).map((r) => r.headers.value(nerdVpnKeyHeader)),
            [newKey, newKey]);
      });

      test('does not share credentials with another managed origin', () async {
        for (final destination in [
          'https://invidious.nerdvpn.de',
          'http://$nerdVpnOnionHost',
          'https://$nerdVpnOnionHost',
        ].where((value) => value != originUrl)) {
          final raw = _Client([
            _Response(302, headers: {'location': '$destination/media'}),
            _Response(200),
          ]);
          var lookups = 0;
          final client = GatewayHttpClient(raw, resolve: (_, url) async {
            expect(url.origin, nerdOrigin.origin);
            lookups++;
            return const GatewayResolvedSession(
                enabled: true,
                needsSignIn: false,
                cookies: 'session=synthetic',
                apiKey: newKey);
          }, ingest: ingest);
          final pending = await nerdRequest(client);
          pending.headers.set('Authorization', 'Bearer synthetic');
          await expectLater(pending.close(), throwsA(isA<HttpException>()));
          expect(lookups, 1);
          expect(raw.requests.first.headers.value(nerdVpnKeyHeader), newKey);
          expect(raw.requests, hasLength(1));
        }
      });

      test('a sign-in completed after recovery prevents the pending retry',
          () async {
        final raw = _Client([
          failure('invalid_credentials', 401),
          _Response(200),
        ]);
        var resolveCalls = 0;
        final client = GatewayHttpClient(raw,
            resolve: (_, __) async {
              final firstRequest = resolveCalls++ == 0;
              return GatewayResolvedSession(
                  enabled: false,
                  needsSignIn: false,
                  apiKey: firstRequest ? oldKey : newKey,
                  apiKeyRevision: firstRequest ? 4 : 6,
                  apiKeyIntent: firstRequest ? 2 : 3);
            },
            ingest: ingest,
            recover: (_,
                {required error,
                required statusCode,
                retryAfter,
                failedKey,
                revision,
                failedIntent,
                retry = true}) async {
              expect(failedIntent, 2);
              return const NerdVpnAccessStatus('ready',
                  retryAllowed: true, apiKeyIntent: 2);
            });
        final pending = await nerdRequest(client);
        pending.headers.set('Authorization', 'Bearer previous-account');
        await expectLater(
            pending.close(),
            throwsA(isA<NerdVpnAccessRequired>()
                .having((e) => e.state, 'state', 'superseded')));
        expect(raw.requests, hasLength(2));
        expect(raw.requests.first.sent, isTrue);
        expect(raw.requests.last.sent, isFalse);
        expect(raw.requests.last.headers.value(nerdVpnKeyHeader), isNull);
      });

      test(
          'pauses blocked access before sending and permits a legacy manual key',
          () async {
        for (final state in [
          'waiting',
          'disabled',
          'denied',
          'unavailable',
          'proxyRequired'
        ]) {
          final raw = _Client([_Response(200)]);
          final client = GatewayHttpClient(raw,
              resolve: (_, __) async => GatewayResolvedSession(
                  enabled: false, needsSignIn: false, accessError: state),
              ingest: ingest);
          final pending = await nerdRequest(client);
          await expectLater(
              pending.close(),
              throwsA(isA<NerdVpnAccessRequired>()
                  .having((e) => e.state, 'state', state)));
          expect(raw.requests.single.sent, isFalse);
        }
        final raw = _Client([_Response(200)]);
        final client = GatewayHttpClient(raw,
            resolve: (_, __) async => const GatewayResolvedSession(
                enabled: false,
                needsSignIn: false,
                accessError: 'missing',
                apiKeyRevision: 0),
            ingest: ingest);
        final pending = await nerdRequest(client);
        pending.headers.set(nerdVpnKeyHeader, oldKey);
        await (await pending.close()).drain<void>();
        expect(raw.requests.single.headers.value(nerdVpnKeyHeader), oldKey);
      });

      test('a legacy header cannot revive access after logout', () async {
        final raw = _Client([_Response(200)]);
        final client = GatewayHttpClient(raw,
            resolve: (_, __) async => const GatewayResolvedSession(
                enabled: false,
                needsSignIn: false,
                accessError: 'missing',
                apiKeyRevision: 4),
            ingest: ingest);
        final pending = await nerdRequest(client);
        pending.headers.set(nerdVpnKeyHeader, oldKey);
        await expectLater(
            pending.close(),
            throwsA(isA<NerdVpnAccessRequired>()
                .having((e) => e.state, 'state', 'missing')));
        expect(raw.requests.single.sent, isFalse);
      });

      test('returns the original response and records only service outages',
          () async {
        for (final entry in [(429, 'rate_limited'), (503, 'unavailable')]) {
          final raw = _Client([failure(entry.$2, entry.$1, retryAfter: '12')]);
          var observed = false;
          final client = GatewayHttpClient(raw,
              resolve: (_, __) async => const GatewayResolvedSession(
                  enabled: false, needsSignIn: false, apiKey: oldKey),
              ingest: ingest,
              recover: (_,
                  {required error,
                  required statusCode,
                  retryAfter,
                  failedKey,
                  revision,
                  failedIntent,
                  retry = true}) async {
                observed = true;
                expect(error, entry.$2);
                expect(statusCode, entry.$1);
                expect(retryAfter, '12');
                return const NerdVpnAccessStatus('unavailable');
              });
          final response = await (await nerdRequest(client)).close();
          expect(await response.transform(utf8.decoder).join(),
              jsonEncode({'error': entry.$2}));
          expect(response.statusCode, entry.$1);
          expect(response.headers.value('retry-after'), '12');
          expect(observed, entry.$1 == 503);
          expect(raw.requests, hasLength(1));
        }
      });

      test('preserves malformed and oversized JSON errors without recovery',
          () async {
        for (final body in ['{broken', 'x' * 70000]) {
          final raw = _Client([
            _Response(401,
                headers: {'content-type': 'application/json'}, body: body),
          ]);
          final client = GatewayHttpClient(raw,
              resolve: (_, __) async => const GatewayResolvedSession(
                  enabled: false, needsSignIn: false, apiKey: oldKey),
              ingest: ingest,
              recover: (_,
                      {required error,
                      required statusCode,
                      retryAfter,
                      failedKey,
                      revision,
                      failedIntent,
                      retry = true}) =>
                  throw StateError('Unexpected recovery'));
          final response = await (await nerdRequest(client)).close();
          expect(await response.transform(utf8.decoder).join(), body);
        }
      });

      test('bootstrap endpoint errors do not trigger recursive recovery',
          () async {
        final raw = _Client([failure('rate_limited', 429)]);
        final client = GatewayHttpClient(raw,
            resolve: (_, __) async => const GatewayResolvedSession(
                enabled: false, needsSignIn: false),
            ingest: ingest,
            recover: (_,
                    {required error,
                    required statusCode,
                    retryAfter,
                    failedKey,
                    revision,
                    failedIntent,
                    retry = true}) =>
                throw StateError('Bootstrap must not recover itself'));
        final response = await (await nerdRequest(client,
                method: 'POST', path: '/api/v1/token'))
            .close();
        expect(response.statusCode, 429);
        expect(await response.transform(utf8.decoder).join(),
            '{"error":"rate_limited"}');
      });
    });
  }
}
