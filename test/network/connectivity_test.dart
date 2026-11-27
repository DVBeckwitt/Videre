import 'dart:async';

import 'package:clipious/network/connectivity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('videre/network_changes');
  const network = MethodChannel('videre/network');
  const codec = StandardMethodCodec();

  test('Home and download consumers share a single native listener', () async {
    var listens = 0;
    var cancels = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    final video = <bool>[];
    final podcast = <bool>[];
    final home = <bool>[];
    final videoListener = wifiConnectivityChanges.listen(video.add);
    final podcastListener = wifiConnectivityChanges.listen(podcast.add);
    final homeListener = networkConnectivityChanges.listen(home.add);
    Future<void> event({required bool wifi, required bool? connected}) async {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          codec.encodeSuccessEnvelope({'wifi': wifi, 'connected': connected}),
          (_) => delivered.complete());
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await Future<void>.delayed(Duration.zero);
      expect(listens, 1);
      await event(wifi: true, connected: true);
      expect(video, [true]);
      expect(podcast, [true]);
      expect(home, [true]);
      await podcastListener.cancel();
      expect(cancels, 0);
      // Mobile, Ethernet and VPN can be available when Wi-Fi is absent.
      await event(wifi: false, connected: true);
      expect(video, [true, false]);
      expect(podcast, [true]);
      expect(home, [true]);
      await event(wifi: false, connected: null);
      expect(home, [true]);
      await event(wifi: false, connected: false);
      expect(home, [true, false]);
      await videoListener.cancel();
      expect(cancels, 0);
      await event(wifi: false, connected: true);
      expect(home, [true, false, true]);
      await homeListener.cancel();
      expect(cancels, 1);
    } finally {
      await podcastListener.cancel();
      await videoListener.cancel();
      await homeListener.cancel();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('network status distinguishes unavailable reporting from offline',
      () async {
    bool? connected = false;
    messenger.setMockMethodCallHandler(network, (call) async {
      expect(call.method, 'isNetworkConnected');
      return connected;
    });
    try {
      expect(await isNetworkConnected(), isFalse);
      connected = true;
      expect(await isNetworkConnected(), isTrue);
      connected = null;
      expect(await isNetworkConnected(), isNull);
      messenger.setMockMethodCallHandler(network, (_) async {
        throw PlatformException(code: 'NETWORK_UNAVAILABLE');
      });
      expect(await isNetworkConnected(), isNull);
    } finally {
      messenger.setMockMethodCallHandler(network, null);
    }
    expect(await isNetworkConnected(), isNull);
  });
}
