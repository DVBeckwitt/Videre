import 'dart:io';

/// Keeps clients held by image caches, package:http and Dio usable after a
/// network policy change, without retaining connections made under the old one.
class ReloadableHttpClient implements HttpClient {
  static final _instances = <WeakReference<ReloadableHttpClient>>{};
  static final _clients = <WeakReference<HttpClient>>{};

  final HttpClient Function() _create;
  final _settings = <Object, void Function(HttpClient)>{};
  late final WeakReference<ReloadableHttpClient> _reference;
  HttpClient? _client;
  bool _closed = false;

  ReloadableHttpClient(this._create) {
    _instances.removeWhere((reference) => reference.target == null);
    _reference = WeakReference(this);
    _instances.add(_reference);
  }

  /// Aborts old requests and drops every connection pool. New requests use the
  /// factory again, so its current policy applies even to long-lived wrappers.
  static void resetAll() {
    // Responses can outlive their wrapper, either after normal close() or
    // after the wrapper is collected. Their underlying clients still own
    // active connections and must participate in a routing-policy reset.
    for (final reference in _clients) {
      reference.target?.close(force: true);
    }
    _clients.clear();
    for (final reference in _instances.toList()) {
      final instance = reference.target;
      if (instance == null) {
        _instances.remove(reference);
      } else {
        instance._client = null;
      }
    }
  }

  HttpClient get _delegate {
    if (_closed) throw StateError('HttpClient is closed');
    return _client ??= _newClient();
  }

  HttpClient _newClient() {
    final client = _create();
    try {
      for (final setting in _settings.values) {
        setting(client);
      }
      _clients.removeWhere((reference) => reference.target == null);
      _clients.add(WeakReference(client));
      return client;
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  void _set(Object key, void Function(HttpClient) update) {
    if (_closed) throw StateError('HttpClient is closed');
    final client = _client;
    if (client != null) update(client);
    _settings[key] = update;
  }

  @override
  Duration get idleTimeout => _delegate.idleTimeout;
  @override
  set idleTimeout(Duration value) =>
      _set('idleTimeout', (client) => client.idleTimeout = value);

  @override
  Duration? get connectionTimeout => _delegate.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) =>
      _set('connectionTimeout', (client) => client.connectionTimeout = value);

  @override
  int? get maxConnectionsPerHost => _delegate.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _set('maxConnectionsPerHost',
      (client) => client.maxConnectionsPerHost = value);

  @override
  bool get autoUncompress => _delegate.autoUncompress;
  @override
  set autoUncompress(bool value) =>
      _set('autoUncompress', (client) => client.autoUncompress = value);

  @override
  String? get userAgent => _delegate.userAgent;
  @override
  set userAgent(String? value) =>
      _set('userAgent', (client) => client.userAgent = value);

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)?
              value) =>
      _set('authenticate', (client) => client.authenticate = value);

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _set(('credentials', url, realm),
          (client) => client.addCredentials(url, realm, credentials));

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              value) =>
      _set('connectionFactory', (client) => client.connectionFactory = value);

  @override
  set findProxy(String Function(Uri url)? value) =>
      _set('findProxy', (client) => client.findProxy = value);

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              value) =>
      _set('authenticateProxy', (client) => client.authenticateProxy = value);

  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _set(
          ('proxyCredentials', host, port, realm),
          (client) =>
              client.addProxyCredentials(host, port, realm, credentials));

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? value) =>
      _set('badCertificateCallback',
          (client) => client.badCertificateCallback = value);

  @override
  set keyLog(Function(String line)? value) =>
      _set('keyLog', (client) => client.keyLog = value);

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _delegate.open(method, host, port, path);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _delegate.openUrl(method, url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _delegate.get(host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _delegate.getUrl(url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _delegate.post(host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _delegate.postUrl(url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _delegate.put(host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _delegate.putUrl(url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _delegate.delete(host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _delegate.deleteUrl(url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _delegate.patch(host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _delegate.patchUrl(url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _delegate.head(host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _delegate.headUrl(url);

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _instances.remove(_reference);
    _client?.close(force: force);
    _client = null;
    _settings.clear();
  }
}
