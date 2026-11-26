import 'package:clipious/music/services/device_music_artwork_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const limit = 24 * 1024 * 1024;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'reads usage and clears without opening the device music source',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        expect(call.arguments, isNull);
        return switch (call.method) {
          'artworkCacheStatus' => {
              'usedBytes': 47,
              'limitBytes': limit,
              'canClear': true,
            },
          'clearArtworkCache' => {
              'usedBytes': 0,
              'limitBytes': limit,
              'canClear': false,
            },
          _ => throw MissingPluginException(),
        };
      });

      expect(await deviceMusicArtworkCache.read(), (
        usedBytes: 47,
        limitBytes: limit,
        canClear: true,
      ));
      expect(await deviceMusicArtworkCache.clear(), (
        usedBytes: 0,
        limitBytes: limit,
        canClear: false,
      ));
      expect(calls, ['artworkCacheStatus', 'clearArtworkCache']);
    },
  );

  test('propagates native errors and rejects incomplete usage', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clearArtworkCache') {
        throw PlatformException(code: 'ARTWORK_CACHE_UNAVAILABLE');
      }
      return {'usedBytes': 47, 'limitBytes': limit};
    });

    await expectLater(deviceMusicArtworkCache.read(), throwsFormatException);
    await expectLater(
      deviceMusicArtworkCache.clear(),
      throwsA(isA<PlatformException>()),
    );
  });
}
