import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/request_cookies.dart';
import '../settings/models/db/server.dart';
import 'gateway_context.dart';
import 'gateway_session_bridge.dart';
import 'media_companion.dart';
import 'nerdvpn_access.dart';

typedef GatewaySessionResolver = Future<GatewayResolvedSession> Function(
    String context, Uri url);
typedef GatewaySessionIngest = Future<void> Function(
    String context, Uri url, List<String> setCookies,
    {required int statusCode,
    String? contentType,
    String? location,
    int? revision});
typedef NerdVpnRecovery = Future<NerdVpnAccessStatus> Function(String context,
    {required String error,
    required int statusCode,
    String? retryAfter,
    String? failedKey,
    int? revision,
    int? failedIntent,
    bool retry});

/// Keeps gateway cookies in the native account jar, including for image caches
/// and streaming downloads that use dart:io rather than the API client.
/// The internal account marker is removed before any request can be written.
class GatewayHttpClient implements HttpClient {
  static final _manifestProbeKey = Object();
  static final _discoveryKey = Object();

  /// Setup may inspect a media redirect without following it. The optional
  /// probe uses the current account without applying its response to the jar
  /// or the managed API key, just like the unsaved-proxy connection test.
  static Future<T> withCompanionDiscovery<T>(
      Server server, Uri uri, Future<T> Function() send) {
    final context = GatewayRequestContext.forAccount(
        server.profileId, server.accountId, server.url);
    if (context == null ||
        !isMediaCompanionEligibleServer(server) ||
        !context.allows(uri)) {
      throw ArgumentError('Expected a media URL on the selected HTTPS server.');
    }
    return runZoned(send, zoneValues: {_discoveryKey: (context.key, uri)});
  }

  /// Carry playback intent across package:http and dart:io without adding a
  /// header. Only the exact frontend GET and account may use this scope.
  static Future<T> withManifestProbe<T>(
      Server server, Uri uri, Future<T> Function() send) {
    if (!server.gatewayEnabled || server.mediaCompanionOrigins.isEmpty) {
      return send();
    }
    final context = GatewayRequestContext.forAccount(
        server.profileId, server.accountId, server.url);
    final origins = trustedMediaCompanionOrigins(server);
    if (context == null || !context.allows(uri) || origins.isEmpty) {
      return send();
    }
    return runZoned(send, zoneValues: {
      _manifestProbeKey: (account: context.key, uri: uri, origins: origins)
    });
  }

  static bool _isManifestHandoff(GatewayRequestContext context, Uri uri,
      String method, HttpClientResponse response, String? location) {
    final scope = Zone.current[_manifestProbeKey];
    if (scope is! ({String account, Uri uri, Set<String> origins}) ||
        scope.account != context.key ||
        scope.uri != uri ||
        method != 'GET' ||
        !response.isRedirect ||
        location == null) {
      return false;
    }
    final relative = Uri.tryParse(location);
    if (relative == null) return false;
    final target = uri.resolveUri(relative);
    return target.scheme == 'https' &&
        target.host.isNotEmpty &&
        target.userInfo.isEmpty &&
        scope.origins.contains(target.origin);
  }

  final HttpClient _delegate;
  final GatewaySessionResolver _resolve;
  final GatewaySessionIngest _ingest;
  final NerdVpnRecovery _recover;
  final bool _updateSessionFromResponse;

  GatewayHttpClient(this._delegate,
      {GatewaySessionResolver? resolve,
      GatewaySessionIngest? ingest,
      NerdVpnRecovery? recover,
      bool updateSessionFromResponse = true})
      : _resolve = resolve ?? GatewaySessionBridge.instance.resolve,
        _ingest = ingest ?? GatewaySessionBridge.instance.ingest,
        _recover = recover ?? NerdVpnAccess.instance.recover,
        _updateSessionFromResponse = updateSessionFromResponse;

  Future<HttpClientRequest> _wrap(Future<HttpClientRequest> pending) async =>
      _GatewayRequest(this, await pending);

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _wrap(_delegate.open(method, host, port, path));
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _wrap(_delegate.openUrl(method, url));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Duration get idleTimeout => _delegate.idleTimeout;
  @override
  set idleTimeout(Duration value) => _delegate.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _delegate.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _delegate.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _delegate.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) =>
      _delegate.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _delegate.autoUncompress;
  @override
  set autoUncompress(bool value) => _delegate.autoUncompress = value;
  @override
  String? get userAgent => _delegate.userAgent;
  @override
  set userAgent(String? value) => _delegate.userAgent = value;
  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)?
              value) =>
      _delegate.authenticate = value;
  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _delegate.addCredentials(url, realm, credentials);
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              value) =>
      _delegate.connectionFactory = value;
  @override
  set findProxy(String Function(Uri url)? value) => _delegate.findProxy = value;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              value) =>
      _delegate.authenticateProxy = value;
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _delegate.addProxyCredentials(host, port, realm, credentials);
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? value) =>
      _delegate.badCertificateCallback = value;
  @override
  set keyLog(Function(String line)? value) => _delegate.keyLog = value;
  @override
  void close({bool force = false}) => _delegate.close(force: force);
}

class _GatewayRequest implements HttpClientRequest {
  final GatewayHttpClient _client;
  final HttpClientRequest _delegate;
  final _result = Completer<HttpClientResponse>();
  Future<void> _writes = Future.value();
  Future<void>? _preparing;
  _GatewayExchange? _exchange;
  int? _resolvedRevision;
  bool? _requestedRedirects;
  bool _closed = false;
  bool _aborted = false;
  bool _addingStream = false;
  bool _startedWriting = false;

  _GatewayRequest(this._client, this._delegate) {
    // Observe connection failures immediately, even while session resolution is
    // pending. close()/done still expose the error to the caller.
    _delegate.done.then((response) async {
      try {
        final exchange = _exchange;
        final result = exchange == null
            ? response
            : await exchange.process(response, _delegate.uri, _delegate.method,
                revision: _resolvedRevision);
        if (!_result.isCompleted) _result.complete(result);
      } catch (error, stack) {
        _fail(error, stack);
      }
    }, onError: _fail);
    // Synchronous IOSink writes may fail before callers attach to done.
    unawaited(_result.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (!_result.isCompleted) _result.completeError(error, stack);
    _aborted = true;
    _delegate.abort(error, stack);
  }

  Future<void> _prepare() => _preparing ??= () async {
        final markers = _delegate.headers[gatewayContextHeader];
        final origins = _delegate.headers[instanceOriginHeader];
        _delegate.headers.removeAll(gatewayContextHeader);
        _delegate.headers.removeAll(instanceOriginHeader);
        if (markers == null && origins == null) return;
        final context = markers != null && markers.length == 1
            ? GatewayRequestContext.tryParse(markers.single)
            : null;
        final origin = origins != null && origins.length == 1
            ? Uri.tryParse(origins.single)
            : null;
        if (markers != null && (context == null || !context.allows(uri))) {
          throw const HttpException('Invalid gateway request context.');
        }
        if (origins != null &&
            (origin == null ||
                !const {'http', 'https'}.contains(origin.scheme) ||
                origin.host.isEmpty ||
                origin.userInfo.isNotEmpty ||
                origin.hasQuery ||
                origin.hasFragment ||
                (origin.path.isNotEmpty && origin.path != '/') ||
                origin.origin != uri.origin)) {
          throw const HttpException('Invalid instance request origin.');
        }
        final original = <String, List<String>>{};
        headers.forEach((name, values) => original[name] = List.of(values));
        if (cookies.isNotEmpty) {
          original.putIfAbsent(HttpHeaders.cookieHeader, () => []).add(cookies
              .map((cookie) => '${cookie.name}=${cookie.value}')
              .join('; '));
          cookies.clear();
        }
        final exchange = _GatewayExchange(_client, context, original,
            followRedirects, maxRedirects, persistentConnection,
            origin: origin);
        _exchange = exchange;
        _requestedRedirects = _delegate.followRedirects;
        _delegate.followRedirects = false;
        _resolvedRevision = await exchange.authenticate(_delegate);
        if (_aborted) throw const HttpException('Gateway request was aborted.');
      }();

  void _checkWriting() {
    if (_closed) throw StateError('The request is closed.');
    if (_addingStream) throw StateError('A stream is already being added.');
  }

  Future<void> _queue(FutureOr<void> Function() action) {
    if (_aborted) return Future.value();
    _writes = _writes.then((_) async {
      await _prepare();
      if (!_aborted) {
        // Header mutation during the asynchronous native lookup must never
        // cause internal metadata to reach the wire.
        if (!_startedWriting) {
          final marker = _delegate.headers[gatewayContextHeader];
          if (marker != null) {
            _delegate.headers.removeAll(gatewayContextHeader);
            if (_exchange == null) {
              throw const HttpException('Gateway context changed during send.');
            }
          }
        }
        _startedWriting = true;
        await action();
      }
    });
    unawaited(_writes.then<void>((_) {}, onError: _fail));
    return _writes;
  }

  @override
  void add(List<int> data) {
    _checkWriting();
    final copy = List<int>.of(data);
    _queue(() => _delegate.add(copy));
  }

  @override
  void write(Object? object) {
    _checkWriting();
    // Encode now so later encoding/header changes cannot alter queued bytes.
    add(encoding.encode(object.toString()));
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      write(objects.map((object) => object.toString()).join(separator));
  @override
  void writeln([Object? object = '']) => write('$object\n');
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _checkWriting();
    _queue(() => _delegate.addError(error, stackTrace));
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _checkWriting();
    _addingStream = true;
    return _queue(() => _delegate.addStream(stream))
        .whenComplete(() => _addingStream = false);
  }

  @override
  Future<void> flush() {
    _checkWriting();
    return _queue(() => _delegate.flush());
  }

  @override
  Future<HttpClientResponse> close() {
    if (!_closed) {
      _closed = true;
      _queue(() async {
        // The listener installed above performs cookie renewal and redirects.
        await _delegate.close();
      });
    }
    return done;
  }

  @override
  Future<HttpClientResponse> get done => _result.future;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _aborted = true;
    _fail(exception ?? const HttpException('Gateway request was aborted.'),
        stackTrace);
  }

  @override
  Encoding get encoding => _delegate.encoding;
  @override
  set encoding(Encoding value) => _delegate.encoding = value;
  @override
  bool get persistentConnection => _delegate.persistentConnection;
  @override
  set persistentConnection(bool value) =>
      _delegate.persistentConnection = value;
  @override
  bool get followRedirects => _requestedRedirects ?? _delegate.followRedirects;
  @override
  set followRedirects(bool value) {
    if (_exchange == null) _delegate.followRedirects = value;
    _requestedRedirects = value;
  }

  @override
  int get maxRedirects => _delegate.maxRedirects;
  @override
  set maxRedirects(int value) => _delegate.maxRedirects = value;
  @override
  String get method => _delegate.method;
  @override
  Uri get uri => _delegate.uri;
  @override
  int get contentLength => _delegate.contentLength;
  @override
  set contentLength(int value) => _delegate.contentLength = value;
  @override
  bool get bufferOutput => _delegate.bufferOutput;
  @override
  set bufferOutput(bool value) => _delegate.bufferOutput = value;
  @override
  HttpHeaders get headers => _delegate.headers;
  @override
  List<Cookie> get cookies => _delegate.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _delegate.connectionInfo;
}

class _GatewayExchange {
  final GatewayHttpClient client;
  final GatewayRequestContext? context;
  final Uri origin;
  final Map<String, List<String>> originalHeaders;
  final bool followRedirects;
  final int maxRedirects;
  final bool persistentConnection;
  final redirects = <RedirectInfo>[];
  final visited = <Uri>{};
  String? _apiKey;
  int? _apiKeyRevision;
  int? _apiKeyIntent;
  bool _recoveredKey = false;

  bool get _isNerdVpn => context != null && isNerdVpnUrl(origin.toString());

  bool _allows(Uri target) =>
      const {'http', 'https'}.contains(target.scheme) &&
      target.userInfo.isEmpty &&
      target.origin == origin.origin;

  _GatewayExchange(this.client, this.context, this.originalHeaders,
      this.followRedirects, this.maxRedirects, this.persistentConnection,
      {Uri? origin})
      : origin = origin ?? context!.origin;

  Future<int?> authenticate(HttpClientRequest request) async {
    request.headers.removeAll(gatewayContextHeader);
    request.headers.removeAll(instanceOriginHeader);
    final context = this.context;
    if (context == null) {
      final cookies = originalHeaders.entries
          .where((entry) => entry.key.toLowerCase() == HttpHeaders.cookieHeader)
          .expand((entry) => entry.value)
          .join('; ');
      request.headers.removeAll(HttpHeaders.cookieHeader);
      if (cookies.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookies);
      }
      return null;
    }
    if (!context.allows(request.uri)) return null;
    final session = await client._resolve(context.encoded, request.uri);
    if (session.needsSignIn) throw const GatewayAuthenticationRequired();
    if (_isNerdVpn) {
      if (_recoveredKey &&
          (session.apiKeyIntent == null ||
              session.apiKeyIntent != _apiKeyIntent)) {
        throw const NerdVpnAccessRequired('superseded');
      }
      final manualKey = request.headers.value('X-Invidious-Token');
      final manualAccess = manualKey?.isNotEmpty == true &&
          session.apiKeyRevision == 0 &&
          const {'missing', 'signInRequired'}.contains(session.accessError);
      if (session.accessError != null && !manualAccess) {
        throw NerdVpnAccessRequired(session.accessError!);
      }
      _apiKey = session.apiKey ?? manualKey;
      _apiKeyRevision = session.apiKeyRevision;
      _apiKeyIntent = session.apiKeyIntent;
      if (session.apiKey != null) {
        request.headers.set('X-Invidious-Token', session.apiKey!);
      }
    }
    final explicitCookies = originalHeaders.entries
        .where((entry) => entry.key.toLowerCase() == HttpHeaders.cookieHeader)
        .expand((entry) => entry.value)
        .join('; ');
    final headers = mergeRequestCookies(
        {if (session.cookies?.isNotEmpty == true) 'Cookie': session.cookies!},
        explicitCookies);
    request.headers.removeAll(HttpHeaders.cookieHeader);
    final cookies = headers['Cookie'];
    if (cookies != null) request.headers.set(HttpHeaders.cookieHeader, cookies);
    return session.revision;
  }

  Future<HttpClientResponse> process(
      HttpClientResponse response, Uri uri, String method,
      {bool? follow, int? revision}) async {
    visited.add(uri);
    final context = this.context;
    final discovery = context != null &&
        method == 'GET' &&
        !(follow ?? followRedirects) &&
        Zone.current[GatewayHttpClient._discoveryKey] == (context.key, uri);
    final updateSession = client._updateSessionFromResponse && !discovery;
    if (updateSession && context != null && context.allows(uri)) {
      try {
        final location = response.headers.value(HttpHeaders.locationHeader);
        // An HTML redirect body describes the handoff, not a login page.
        // Native ingestion still checks Location and applies every Set-Cookie.
        final handoff = GatewayHttpClient._isManifestHandoff(
            context, uri, method, response, location);
        await client._ingest(context.encoded, uri,
            response.headers[HttpHeaders.setCookieHeader] ?? const [],
            statusCode: response.statusCode,
            contentType: handoff
                ? null
                : response.headers.value(HttpHeaders.contentTypeHeader),
            location: location,
            revision: revision);
      } catch (_) {
        await response.listen(null).cancel();
        rethrow;
      }
    }
    final status = response.statusCode;
    if (updateSession &&
        context != null &&
        _isNerdVpn &&
        context.allows(uri) &&
        !const {'/api/v1/token', '/api/v1/auth/api_key'}.contains(uri.path) &&
        const {401, 403, 429, 503}.contains(status) &&
        (response.headers.value(HttpHeaders.contentTypeHeader) ?? '')
            .toLowerCase()
            .contains('json')) {
      final inspected = await _inspectBody(response);
      final bytes = inspected.bytes;
      String? error;
      if (bytes != null) {
        try {
          final value = jsonDecode(utf8.decode(bytes));
          if (value is Map && value['error'] is String) {
            error = value['error'] as String;
          }
        } on FormatException {
          // Preserve malformed or oversized responses for the original caller.
        }
      }
      if (const {
        'credentials_required',
        'invalid_credentials',
        'access_denied',
        'rate_limited',
        'unavailable'
      }.contains(error)) {
        final recovered = await client._recover(context.encoded,
            error: error!,
            statusCode: status,
            retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
            failedKey: _apiKey,
            revision: _apiKeyRevision,
            failedIntent: _apiKeyIntent,
            retry: !_recoveredKey);
        if (!_recoveredKey &&
            recovered.retryAllowed &&
            const {'credentials_required', 'invalid_credentials'}
                .contains(error) &&
            (method == 'GET' || method == 'HEAD')) {
          _recoveredKey = true;
          return _send(uri, method);
        }
      }
      return _GatewayResponse(response, this, uri, method,
          body: inspected.stream);
    }
    final canRedirect = method == 'GET' ||
        method == 'HEAD' ||
        (method == 'POST' && status == HttpStatus.seeOther);
    final location = response.headers.value(HttpHeaders.locationHeader);
    if ((follow ?? followRedirects) &&
        canRedirect &&
        const {301, 302, 303, 307, 308}.contains(status) &&
        location != null) {
      if (redirects.length >= maxRedirects) {
        await response.listen(null).cancel();
        throw RedirectException(
            'Maximum HTTP redirects exceeded.', List.of(redirects));
      }
      await response.drain<void>();
      return redirect(uri, method, status, uri.resolve(location), false);
    }
    return _GatewayResponse(response, this, uri, method);
  }

  Future<HttpClientResponse> redirect(
      Uri from, String method, int status, Uri target, bool followLoops) async {
    if (!const {'https', 'http'}.contains(target.scheme) ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty) {
      throw const HttpException('Invalid HTTP redirect.');
    }
    if (!_allows(target)) {
      throw const HttpException(
          'Redirects must stay on the selected Invidious instance.');
    }
    if (!followLoops && visited.contains(target)) {
      throw RedirectException('HTTP redirect loop.', List.of(redirects));
    }
    final nextMethod = method == 'POST' && status == 303 ? 'GET' : method;
    redirects.add(_GatewayRedirect(status, nextMethod, target));
    return _send(target, nextMethod);
  }

  Future<HttpClientResponse> _send(Uri target, String method) async {
    final request = await client._delegate.openUrl(method, target);
    // Authentication can abort before close() observes the request's error.
    unawaited(
        request.done.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    request.followRedirects = false;
    request.persistentConnection = persistentConnection;
    // No supplied headers leave the protected origin. Fresh transport defaults
    // (e.g. User-Agent and Accept-Encoding) remain the HTTP client's concern.
    if (_allows(target)) {
      for (final entry in originalHeaders.entries) {
        if (!const {
          'host',
          'content-length',
          'transfer-encoding',
          'connection',
          'cookie'
        }.contains(entry.key.toLowerCase())) {
          request.headers.set(entry.key, entry.value);
        }
      }
    }
    try {
      final revision = await authenticate(request);
      return process(await request.close(), target, method, revision: revision);
    } catch (error, stack) {
      request.abort(error, stack);
      rethrow;
    }
  }
}

/// Inspect at most 64 KiB, preserving every consumed chunk for callers when the
/// response is oversized. Error responses can use chunked transfer encoding.
Future<({List<int>? bytes, Stream<List<int>> stream})> _inspectBody(
    HttpClientResponse response) async {
  final iterator = StreamIterator(response);
  final chunks = <List<int>>[];
  var length = 0;
  try {
    while (await iterator.moveNext()) {
      final chunk = iterator.current;
      chunks.add(chunk);
      length += chunk.length;
      if (length > 65536) {
        Stream<List<int>> remaining() async* {
          try {
            yield* Stream.fromIterable(chunks);
            while (await iterator.moveNext()) {
              yield iterator.current;
            }
          } finally {
            await iterator.cancel();
          }
        }

        return (bytes: null, stream: remaining());
      }
    }
    final bytes = chunks.expand((chunk) => chunk).toList(growable: false);
    return (bytes: bytes, stream: Stream.value(bytes));
  } catch (_) {
    await iterator.cancel();
    rethrow;
  }
}

class _GatewayResponse extends Stream<List<int>> implements HttpClientResponse {
  final HttpClientResponse _delegate;
  final _GatewayExchange _exchange;
  final Uri _uri;
  final String _method;
  final Stream<List<int>>? _body;
  _GatewayResponse(this._delegate, this._exchange, this._uri, this._method,
      {Stream<List<int>>? body})
      : _body = body;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      (_body ?? _delegate).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  Future<HttpClientResponse> redirect(
      [String? method, Uri? url, bool? followLoops]) {
    final location = headers.value(HttpHeaders.locationHeader);
    final target = url ?? (location == null ? null : _uri.resolve(location));
    if (target == null) {
      throw const HttpException('Missing HTTP redirect target.');
    }
    return _exchange.redirect(
        _uri, method ?? _method, statusCode, target, followLoops ?? false);
  }

  @override
  int get statusCode => _delegate.statusCode;
  @override
  String get reasonPhrase => _delegate.reasonPhrase;
  @override
  int get contentLength => _delegate.contentLength;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _delegate.compressionState;
  @override
  bool get persistentConnection => _delegate.persistentConnection;
  @override
  bool get isRedirect => _delegate.isRedirect;
  @override
  List<RedirectInfo> get redirects => List.unmodifiable(_exchange.redirects);
  @override
  HttpHeaders get headers => _delegate.headers;
  @override
  Future<Socket> detachSocket() => _delegate.detachSocket();
  @override
  List<Cookie> get cookies => _delegate.cookies;
  @override
  X509Certificate? get certificate => _delegate.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => _delegate.connectionInfo;
}

class _GatewayRedirect implements RedirectInfo {
  @override
  final int statusCode;
  @override
  final String method;
  @override
  final Uri location;
  const _GatewayRedirect(this.statusCode, this.method, this.location);
}
