import 'package:flutter/services.dart';

/// Compatibility boundary for old callers. A separately installed browser does
/// not inherit Videre's destination restrictions, so no external app is opened.
/// The interface now presents a copyable address instead.
class TorBrowser {
  static final instance = TorBrowser();
  final MethodChannel channel;

  TorBrowser({this.channel = const MethodChannel('videre/tor_browser')});

  Future<bool> openApp() async => false;

  static bool isOnionAddress(Uri url) => url.host
      .toLowerCase()
      .replaceFirst(RegExp(r'\.+$'), '')
      .endsWith('.onion');

  Future<bool> openOnionUrl(Uri url) async => false;

  Future<bool> openNerdVpnPreferences(String serverUrl) async => false;
}
