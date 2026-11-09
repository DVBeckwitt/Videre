import 'package:flutter/services.dart';

import 'nerdvpn_access.dart';

/// Opens the separately installed Tor Browser. No browser or Tor runtime is
/// bundled, and a missing Tor Browser never falls back to the default browser.
class TorBrowser {
  static final instance = TorBrowser();
  final MethodChannel channel;

  TorBrowser({this.channel = const MethodChannel('videre/tor_browser')});

  /// Current Tor Browser versions may reject links from other apps. This opens
  /// only the browser; the user can paste the copied preferences address there.
  Future<bool> openApp() => _open('openApp');

  Future<bool> openNerdVpnPreferences(String serverUrl) async {
    final uri = Uri.tryParse(serverUrl);
    if (!NerdVpnAccess.supportsUrl(serverUrl) ||
        !isNerdVpnOnionUrl(serverUrl) ||
        uri == null ||
        serverUrl.contains('@')) {
      return false;
    }
    return _open('openNerdVpnPreferences', {'serverUrl': uri.origin});
  }

  Future<bool> _open(String method, [Map<String, String>? arguments]) async {
    try {
      return await channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
