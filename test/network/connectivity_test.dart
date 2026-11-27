import 'dart:async';

import 'package:clipious/network/connectivity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const events = MethodChannel('videre/network_changes');
  const methods = MethodChannel('videre/network');
  const codec = StandardMethodCodec();

  test('Home and download consumers share a single native listener', () async {
    var listens = 0;
    var cancels = 0;
    messenger.setMockMethodCallHandler(events, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(events, null));

    final video = <DownloadConnectivity>[];
    final podcast = <bool>[];
    final home = <bool>[];
    final videoListener = downloadConnectivityChanges.listen(video.add);
    final podcastListener = wifiConnectivityChanges.listen(podcast.add);
    final homeListener = networkConnectivityChanges.listen(home.add);
    addTearDown(videoListener.cancel);
    addTearDown(podcastListener.cancel);
    addTearDown(homeListener.cancel);

    Future<void> event(Object snapshot) async {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(events.name,
          codec.encodeSuccessEnvelope(snapshot), (_) => delivered.complete());
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
    }

    await Future<void>.delayed(Duration.zero);
    expect(listens, 1);
    await event({'wifi': true, 'online': true, 'connected': true});
    // Mobile, Ethernet and VPN can be available when Wi-Fi is absent.
    await event({'wifi': false, 'online': true, 'connected': true});
    await event({'wifi': false, 'online': true, 'connected': true});
    await event({'wifi': false, 'online': true, 'connected': null});
    // A default network can exist without Internet capability.
    await event({'wifi': false, 'online': false, 'connected': true});
    expect(home, [true]);
    await event({'wifi': false, 'online': false, 'connected': false});
    expect(video, [
      (wifi: true, online: true),
      (wifi: false, online: true),
      (wifi: false, online: true),
      (wifi: false, online: true),
      (wifi: false, online: false),
      (wifi: false, online: false),
    ]);
    expect(podcast, [true, false]);
    expect(home, [true, false]);

    await podcastListener.cancel();
    expect(cancels, 0);
    await event(true);
    expect(video.last, (wifi: true, online: true));
    expect(podcast, [true, false]);
    expect(home, [true, false]);

    await videoListener.cancel();
    expect(cancels, 0);
    await event({'wifi': false, 'online': true, 'connected': true});
    expect(home, [true, false, true]);
    await homeListener.cancel();
    expect(cancels, 1);
  });

  test('reads the current native connectivity snapshot', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'readConnectivity');
      return {'wifi': false, 'online': false, 'connected': true};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));

    expect(await readDownloadConnectivity(), (wifi: false, online: false));
  });

  test('falls back to the legacy Wi-Fi method when available', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'isWifiConnected') return true;
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));

    expect(await readDownloadConnectivity(), (wifi: true, online: true));

    messenger.setMockMethodCallHandler(methods, null);
    expect(await readDownloadConnectivity(), (wifi: false, online: true));
  });

  test('network status distinguishes unavailable reporting from offline',
      () async {
    bool? connected = false;
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'isNetworkConnected');
      return connected;
    });
    try {
      expect(await isNetworkConnected(), isFalse);
      connected = true;
      expect(await isNetworkConnected(), isTrue);
      connected = null;
      expect(await isNetworkConnected(), isNull);
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'NETWORK_UNAVAILABLE');
      });
      expect(await isNetworkConnected(), isNull);
    } finally {
      messenger.setMockMethodCallHandler(methods, null);
    }
    expect(await isNetworkConnected(), isNull);
  });
}
