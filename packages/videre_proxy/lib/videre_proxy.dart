/// Android transport integration is registered automatically by Flutter.
///
/// The application configures it through the `videre/proxy` method channel.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-private, evictable playback bytes; saved downloads are never affected.
class PlaybackCacheStatus {
  final bool supported;
  final bool enabled;
  final int maxBytes;
  final int usedBytes;

  const PlaybackCacheStatus({
    this.supported = false,
    this.enabled = false,
    this.maxBytes = 512 * 1024 * 1024,
    this.usedBytes = 0,
  });

  factory PlaybackCacheStatus.fromMap(Map<Object?, Object?> value) =>
      PlaybackCacheStatus(
        supported: value['supported'] == true,
        enabled: value['enabled'] == true,
        maxBytes: (value['maxBytes'] as num?)?.toInt() ?? 512 * 1024 * 1024,
        usedBytes: (value['usedBytes'] as num?)?.toInt() ?? 0,
      );
}

abstract final class PlaybackCache {
  static const _channel = MethodChannel('videre/proxy');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<PlaybackCacheStatus> _statusCall(String method,
      [Map<String, Object?>? arguments]) async {
    if (!supported) return const PlaybackCacheStatus();
    try {
      final value =
          await _channel.invokeMapMethod<Object?, Object?>(method, arguments);
      return PlaybackCacheStatus.fromMap(value ?? const {});
    } on MissingPluginException {
      return const PlaybackCacheStatus();
    }
  }

  static Future<PlaybackCacheStatus> status() =>
      _statusCall('playbackCacheStatus');

  static Future<PlaybackCacheStatus> configure({
    required bool enabled,
    required int maxBytes,
  }) =>
      _statusCall(
          'configurePlaybackCache', {'enabled': enabled, 'maxBytes': maxBytes});

  static Future<PlaybackCacheStatus> clear() =>
      _statusCall('clearPlaybackCache');

  static Future<List<Object?>> cachedMusicSongs(
      Map<String, Object?> owner) async {
    if (!supported) return const [];
    return await _channel.invokeListMethod<Object?>(
            'cachedMusicSongs', owner) ??
        const [];
  }

  /// Deletes only an inactive profile's byte spans and invalidates its sources.
  /// Stop that profile's playback first; other profiles continue uninterrupted.
  static Future<void> removeProfile(String profileId) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(
          'removePlaybackCacheProfile', {'profileId': profileId});
    } on MissingPluginException {
      // The host has no native playback cache.
    }
  }

  /// Call before profile/account changes. Invalidates readers, preserving bytes
  /// in their private namespaces for later use by the same owner.
  static Future<void> invalidate() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('invalidatePlaybackCache');
    } on MissingPluginException {
      // A test host or non-plugin runtime has no native cache to invalidate.
    }
  }
}
