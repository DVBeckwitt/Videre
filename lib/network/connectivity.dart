import 'package:flutter/services.dart';

typedef DownloadConnectivity = ({bool wifi, bool online});

const _network = MethodChannel('videre/network');

// Video Home and both download consumers share Android's single event sink.
final _networkChanges =
    const EventChannel('videre/network_changes').receiveBroadcastStream();

/// Keep repeated events because a method read can see an intervening outage.
final Stream<DownloadConnectivity> downloadConnectivityChanges =
    _networkChanges.map(_decodeConnectivity);

final Stream<bool> wifiConnectivityChanges =
    downloadConnectivityChanges.map((state) => state.wifi).distinct();

/// Reports whether the app has a default network, including local and VPN routes.
final Stream<bool> networkConnectivityChanges = _networkChanges
    .map((value) => value is Map ? value['connected'] : null)
    .where((value) => value is bool)
    .cast<bool>()
    .distinct();

DownloadConnectivity _decodeConnectivity(Object? value) => switch (value) {
      Map<Object?, Object?> state => (
          wifi: state['wifi'] == true,
          online: state['online'] != false
        ),
      bool wifi => (wifi: wifi, online: true),
      _ => (wifi: false, online: true),
    };

Future<DownloadConnectivity> readDownloadConnectivity() async {
  try {
    final value = await _network.invokeMethod<Object?>('readConnectivity');
    if (value != null) return _decodeConnectivity(value);
  } on PlatformException {
    // If monitoring is unavailable, let transport errors handle reachability.
  } on MissingPluginException {
    // An older native implementation may still report Wi-Fi separately.
  }
  return (wifi: await isWifiConnected(), online: true);
}

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
