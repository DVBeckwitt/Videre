import 'package:flutter/services.dart';

typedef DownloadConnectivity = ({bool wifi, bool online});

const _network = MethodChannel('videre/network');

/// One native listener shared by video and podcast downloads. Creating separate
/// EventChannel streams would replace Android's sink and cancel each other.
/// Keep repeated events because a method read can see an intervening outage.
final Stream<DownloadConnectivity> downloadConnectivityChanges =
    const EventChannel('videre/network_changes')
        .receiveBroadcastStream()
        .map(_decodeConnectivity);

final Stream<bool> wifiConnectivityChanges =
    downloadConnectivityChanges.map((state) => state.wifi).distinct();

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
