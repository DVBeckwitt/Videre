import 'package:flutter/services.dart';

typedef DeviceMusicArtworkCacheStatus = ({
  int usedBytes,
  int limitBytes,
  bool canClear,
});

const deviceMusicArtworkCache = DeviceMusicArtworkCache();

/// Android's device-wide cache of thumbnails extracted from local music.
class DeviceMusicArtworkCache {
  const DeviceMusicArtworkCache();

  static const _channel = MethodChannel(
    'com.github.dvbeckwitt.videre/local_music',
  );

  Future<DeviceMusicArtworkCacheStatus> read() =>
      _request('artworkCacheStatus');

  Future<DeviceMusicArtworkCacheStatus> clear() =>
      _request('clearArtworkCache');

  Future<DeviceMusicArtworkCacheStatus> _request(String method) async {
    final result = await _channel.invokeMapMethod<String, Object?>(method);
    if (result
        case {
          'usedBytes': final int usedBytes,
          'limitBytes': final int limitBytes,
          'canClear': final bool canClear,
        } when usedBytes >= 0 && limitBytes > 0) {
      return (usedBytes: usedBytes, limitBytes: limitBytes, canClear: canClear);
    }
    throw const FormatException('Invalid device artwork cache status');
  }
}
