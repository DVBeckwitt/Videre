import 'dart:async';

import 'package:clipious/network/connectivity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('videre/network_changes');
  const codec = StandardMethodCodec();

  test('cancelling one download consumer preserves the other native listener',
      () async {
    var listens = 0;
    var cancels = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    final video = <bool>[];
    final podcast = <bool>[];
    final videoListener = wifiConnectivityChanges.listen(video.add);
    final podcastListener = wifiConnectivityChanges.listen(podcast.add);
    Future<void> event(bool connected) async {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(channel.name,
          codec.encodeSuccessEnvelope(connected), (_) => delivered.complete());
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await Future<void>.delayed(Duration.zero);
      expect(listens, 1);
      await event(true);
      expect(video, [true]);
      expect(podcast, [true]);
      await podcastListener.cancel();
      expect(cancels, 0);
      await event(false);
      expect(video, [true, false]);
      expect(podcast, [true]);
      await videoListener.cancel();
      expect(cancels, 1);
    } finally {
      await podcastListener.cancel();
      await videoListener.cancel();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
