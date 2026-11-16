import 'package:flutter/services.dart';

/// One native listener shared by video and podcast downloads. Creating separate
/// EventChannel streams would replace Android's sink and cancel each other.
final Stream<bool> wifiConnectivityChanges =
    const EventChannel('videre/network_changes')
        .receiveBroadcastStream()
        .map((value) => value == true);

Future<bool> isWifiConnected() async {
  try {
    return await const MethodChannel('videre/network')
            .invokeMethod<bool>('isWifiConnected') ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
