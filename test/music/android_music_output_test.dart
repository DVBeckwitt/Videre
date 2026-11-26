import 'package:clipious/music/services/android_music_output.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'route consumers share a channel and replay only the latest selection',
    () async {
      const channel = MethodChannel('videre/music_output');
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      Future<void> flushEvents() => Future<void>.delayed(Duration.zero);
      Future<void> sendRoute(Map<String, Object> event) async {
        await messenger.handlePlatformMessage(
          channel.name,
          codec.encodeSuccessEnvelope(event),
          (_) {},
        );
        await flushEvents();
      }

      final bluetooth = <MusicBluetoothOutputEvent>[];
      final earlyWired = <int>[];
      final removedWired = <int>[];
      final bluetoothSubscription = androidMusicBluetoothOutputs.listen(
        bluetooth.add,
      );
      final earlyWiredSubscription = androidWiredHeadsetInsertions.listen(
        earlyWired.add,
      );
      final removalSubscription = androidWiredHeadsetRemovals.listen(
        removedWired.add,
      );
      addTearDown(bluetoothSubscription.cancel);
      addTearDown(earlyWiredSubscription.cancel);
      addTearDown(removalSubscription.cancel);
      await flushEvents();
      expect(calls, ['listen']);

      await sendRoute({
        'kind': 'selected',
        'id': 'headset',
        'label': 'Bluetooth headset',
        'bluetoothOutputId': 'headset',
        'bluetoothPortId': 17,
      });
      await sendRoute({
        'kind': 'bluetoothDisconnected',
        'id': 'headset',
        'bluetoothPortId': 17,
      });
      await sendRoute({'kind': 'wiredHeadsetInserted', 'id': 23});
      await sendRoute({'kind': 'wiredHeadsetRemoved', 'id': 23});
      await sendRoute({
        'kind': 'selected',
        'id': 'speaker',
        'label': 'Speaker',
      });

      expect(
        bluetooth.map(
          (route) => (route.outputId, route.portId, route.isDisconnect),
        ),
        [('headset', 17, false), ('headset', 17, true), (null, null, false)],
      );
      expect(earlyWired, [23]);
      expect(removedWired, [23]);

      final presets = <MusicOutput?>[];
      final lateWired = <int>[];
      final presetSubscription = androidMusicOutputs.listen(presets.add);
      final lateWiredSubscription = androidWiredHeadsetInsertions.listen(
        lateWired.add,
      );
      addTearDown(presetSubscription.cancel);
      addTearDown(lateWiredSubscription.cancel);
      await flushEvents();
      expect(calls, ['listen']);
      expect(presets.single?.id, 'speaker');
      expect(presets.single?.label, 'Speaker');
      expect(lateWired, isEmpty);

      await sendRoute({'kind': 'wiredHeadsetInserted', 'id': 24});
      expect(lateWired, [24]);
      expect(earlyWired, [23, 24]);
      expect(presets, hasLength(1));
      expect(bluetooth, hasLength(3));

      await bluetoothSubscription.cancel();
      await earlyWiredSubscription.cancel();
      await lateWiredSubscription.cancel();
      await removalSubscription.cancel();
      expect(calls, ['listen']);
      await presetSubscription.cancel();
      await flushEvents();
      expect(calls, ['listen', 'cancel']);
    },
  );
}
