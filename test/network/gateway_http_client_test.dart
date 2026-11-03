import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/gateway_http_client.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test(
      'redirect to another origin strips every caller header and gateway cookie',
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
    await (await pending.close()).drain<void>();
    expect(raw.requests.last.headers.values, isEmpty);
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
    final next = await first.redirect();
    await next.drain<void>();
    expect(raw.requests.last.headers.values, isEmpty);
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
}
