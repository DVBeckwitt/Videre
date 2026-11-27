import 'package:flutter/services.dart';

const _network = MethodChannel('videre/network');

// Video Home and both download consumers share Android's single event sink.
final _networkChanges =
    const EventChannel('videre/network_changes').receiveBroadcastStream();

final Stream<bool> wifiConnectivityChanges = _networkChanges
    .map((value) => (value is Map ? value['wifi'] : value) == true);

/// Reports when the app gains or loses a default network, across transports.
/// This also allows local instances and VPN routes to work without requiring
/// Android's public internet validation.
final Stream<bool> networkConnectivityChanges = _networkChanges
    .map((value) => value is Map ? value['connected'] : null)
    .where((value) => value is bool)
    .cast<bool>()
    .distinct();

Future<bool> isWifiConnected() async {
  try {
    return await _network.invokeMethod<bool>('isWifiConnected') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Reads the current default network independently of the shared event stream.
/// Null indicates that the platform could not report connectivity.
Future<bool?> isNetworkConnected() async {
  try {
    return await _network.invokeMethod<bool>('isNetworkConnected');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
