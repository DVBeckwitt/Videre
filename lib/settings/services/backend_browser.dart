import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../network/network_proxy.dart';
import '../models/db/server.dart';
import 'backend_discovery.dart';

class BackendBrowserProxyUnsupported implements Exception {
  const BackendBrowserProxyUnsupported();
}

class BackendBrowserPage {
  final Uri uri;
  final String source;
  const BackendBrowserPage(this.uri, this.source);
}

/// Reads public selector markup in a visible browser. Browser session cookies
/// stay in WebView and are never returned to Dart or used for API/playback.
class BackendBrowser {
  static const _channel = MethodChannel('videre/backend_discovery');

  static bool supports(Server server) {
    final uri = Uri.tryParse(server.url);
    return !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.port == 443 &&
        const {'invidious.nerdvpn.de', 'www.invidious.nerdvpn.de'}
            .contains(uri.host) &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (uri.path.isEmpty || uri.path == '/');
  }

  static Future<BackendBrowserPage?> open(
      Server server, AppLocalizations locals) async {
    if (!supports(server)) {
      throw const BackendDiscoveryException();
    }
    final connection = NetworkProxy.instance.config;
    Future<void> close() => _channel.invokeMethod<void>('close');
    NetworkProxy.instance.addBeforeApply(close);
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('open', {
        'url': Uri.parse(server.url).replace(path: '/').toString(),
        'title': locals.backendBrowserOpen,
        'usePage': locals.backendBrowserUsePage,
        'cancel': locals.cancel,
        'help': locals.backendBrowserHelp,
        'noOptions': locals.backendBrowserNoOptions,
      });
      if (data == null) return null;
      final url = data['url'];
      final source = data['html'];
      if (url is! String ||
          source is! String ||
          !identical(NetworkProxy.instance.config, connection)) {
        throw const BackendDiscoveryException();
      }
      final uri = Uri.tryParse(url);
      if (uri == null) throw const BackendDiscoveryException();
      return BackendBrowserPage(uri, source);
    } on PlatformException catch (error) {
      if (error.code == 'BROWSER_PROXY_UNSUPPORTED') {
        throw const BackendBrowserProxyUnsupported();
      }
      throw const BackendDiscoveryException();
    } on MissingPluginException {
      throw const BackendDiscoveryException();
    } finally {
      NetworkProxy.instance.removeBeforeApply(close);
    }
  }
}
