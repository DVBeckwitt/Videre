import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../globals.dart';
import '../settings/models/db/settings.dart';
import 'reloadable_http_client.dart';
import 'direct_http_client.dart';
import 'socks_proxy.dart';
import 'onion_verification.dart';

class ProxyTestNeedsServer implements Exception {}

/// Owns one Internet routing policy for foreground Dart and Android playback.
/// Workers load the same policy before making their first request.
class NetworkProxy {
  NetworkProxy._({bool? useNative, MethodChannel? channel})
      : _useNative = useNative ?? Platform.isAndroid,
        _channel = channel ?? const MethodChannel('videre/proxy');

  @visibleForTesting
  NetworkProxy.forTesting({required bool useNative, MethodChannel? channel})
      : this._(useNative: useNative, channel: channel);

  static final instance = NetworkProxy._();
  final bool _useNative;
  final MethodChannel _channel;
  final _beforeApply = <Future<void> Function()>{};
  SocksProxyConfig _config = SocksProxyConfig();
  bool _changing = false;
  bool _initialized = false;
  Object? _blocked;

  SocksProxyConfig get config => _config;

  void addBeforeApply(Future<void> Function() listener) =>
      _beforeApply.add(listener);
  void removeBeforeApply(Future<void> Function() listener) =>
      _beforeApply.remove(listener);

  Future<void> initialize({String? saved, bool configureNative = true}) async {
    try {
      if (configureNative && _useNative) {
        // Native preferences are authoritative on Android, including workers.
        // Read them instead of overwriting a valid policy from a stale DB copy.
        final native =
            await _channel.invokeMapMethod<String, dynamic>('getConfiguration');
        if (native == null) {
          throw StateError('Native proxy configuration is unavailable.');
        }
        _config = SocksProxyConfig.fromJson(native);
      } else {
        final value =
            saved ?? db.getSettings(networkSocksProxySettingName)?.value;
        _config = value == null
            ? SocksProxyConfig()
            : SocksProxyConfig.fromJson(
                jsonDecode(value) as Map<String, dynamic>);
      }
      _blocked = null;
      _initialized = true;
      await OnionVerification.instance
          .initialize(proxyEnabled: _config.enabled);
    } catch (error) {
      // Keep the UI usable for repairing a corrupt setting, but never silently
      // recover an enabled/unknown proxy configuration by connecting directly.
      _blocked = error;
      _initialized = false;
      OnionVerification.instance.reset();
    }
    ReloadableHttpClient.resetAll();
  }

  void configureClient(HttpClient client, {SecurityContext? context}) {
    if (_changing || _blocked != null) {
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (_, __, ___) => Future.error(
          const SocketException('Network proxy needs configuration.'));
      return;
    }
    configureSocksHttpClient(client, _config,
        context: context, badCertificateCallback: _allowCertificate);
  }

  static bool _allowCertificate(X509Certificate cert, String host, int port) =>
      db.getSettings(skipSslVerificationSettingName)?.value == 'true';

  Future<void> apply(SocksProxyConfig config) async {
    if (_changing) throw StateError('A proxy change is already in progress.');
    if (_initialized &&
        _blocked == null &&
        config.enabled == _config.enabled &&
        config.host == _config.host &&
        config.port == _config.port) {
      return;
    }
    _changing = true;
    OnionVerification.instance.reset();
    var phase = 'stopping playback and downloads';
    ReloadableHttpClient.resetAll();
    try {
      // Start every cancellation before waiting for native teardown. A slow
      // audio disposal must not delay cancellation of an interrupted download.
      await Future.wait([
        for (final listener in List.of(_beforeApply)) Future.sync(listener),
      ]);
      phase = 'saving the connection policy';
      if (_useNative) {
        await _channel.invokeMethod<void>('configure', config.toJson());
      } else {
        // Android's atomic native preferences are authoritative for playback,
        // workers and startup. A second DB write could fail after native policy
        // already changed, leaving the UI reporting a failed save of a live one.
        await db.saveSetting(SettingsValue(
            networkSocksProxySettingName, jsonEncode(config.toJson())));
      }
      _config = config;
      _blocked = null;
      _initialized = true;
      await OnionVerification.instance
          .initialize(proxyEnabled: _config.enabled);
    } catch (error, stack) {
      _blocked = error;
      // Record the failing phase and stack without URLs, headers or settings.
      Logger('NetworkProxy').severe(
          'Proxy change failed while $phase (${error.runtimeType}).\n$stack');
      rethrow;
    } finally {
      _changing = false;
      ReloadableHttpClient.resetAll();
    }
  }

  /// Tests the unsaved endpoint without changing any existing routing policy.
  Future<void> test(SocksProxyConfig config) async {
    if (!config.enabled) throw StateError('Enable SOCKS5 before testing.');
    final server = await db.getCurrentlySelectedServer().catchError((Object _) {
      throw ProxyTestNeedsServer();
    });
    final uri = Uri.parse('${server.url}/api/v1/stats');
    if (isProxyLoopback(uri.host)) {
      throw StateError(
          'A local instance cannot verify Internet proxy routing.');
    }
    // Construct a fresh client outside the global wrapper: this test must use
    // the form's unsaved endpoint, not the active application configuration.
    final client = createDirectHttpClient();
    try {
      configureSocksHttpClient(client, config,
          badCertificateCallback: _allowCertificate);
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 20));
      // This check must validate the selected instance itself. Automatic
      // redirects would forward arbitrary instance access headers off-origin.
      request.followRedirects = false;
      // Verification cookies are bound to the saved proxy route. Testing a
      // different, unsaved proxy must not reuse that private browser session.
      final sameRoute = _initialized &&
          _blocked == null &&
          !_changing &&
          _config.enabled &&
          config.host == _config.host &&
          config.port == _config.port;
      final headers = sameRoute
          ? server.headersForUrl(uri.toString())
          : server.customHeaders;
      headers?.forEach(request.headers.set);
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException(
            'The instance did not accept the proxy test.');
      }
      final bytes = await response.fold<List<int>>([], (body, chunk) {
        if (body.length + chunk.length > 1024 * 1024) {
          throw const HttpException('Proxy test response is too large.');
        }
        return body..addAll(chunk);
      }).timeout(const Duration(seconds: 20));
      if (jsonDecode(utf8.decode(bytes)) is! Map) {
        throw const FormatException('The instance did not return JSON.');
      }
    } finally {
      client.close(force: true);
    }
  }
}
