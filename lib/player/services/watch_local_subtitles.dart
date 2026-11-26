import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:river_player/river_player.dart';

typedef WatchLocalSubtitleOwner = ({String profileId, String videoId});
typedef WatchLocalSubtitlePick = ({String token, String name});

enum WatchLocalSubtitleResult { done, cancelled, invalidFile, unavailable }

class WatchLocalSubtitles {
  static const _channel = MethodChannel('videre/watch_local_subtitles');

  const WatchLocalSubtitles();

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String?> attachment(WatchLocalSubtitleOwner owner) =>
      _channel.invokeMethod<String>('attachment', _scope(owner));

  Future<WatchLocalSubtitlePick?> pick(WatchLocalSubtitleOwner owner) async {
    final document =
        await _channel.invokeMapMethod<String, Object?>('pick', _scope(owner));
    if (document == null) return null;
    final token = document['token'] as String;
    try {
      final name = document['name'] as String;
      if (!name.toLowerCase().endsWith('.srt') &&
          !name.toLowerCase().endsWith('.vtt')) {
        throw const FormatException('Unsupported subtitle extension');
      }
      final text = _decode(document['bytes'] as Uint8List);
      final cues = await BetterPlayerSubtitlesFactory.parseSubtitles(
        BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.memory,
          contentLoader: () async => text,
        ),
      );
      if (!cues.any((cue) =>
          cue.start! >= Duration.zero &&
          cue.end! > cue.start! &&
          cue.texts!.any((line) => line.trim().isNotEmpty))) {
        throw const FormatException('No readable subtitle cues');
      }
      return (token: token, name: name);
    } catch (_) {
      await discardPick(token);
      rethrow;
    }
  }

  Future<void> save(String token) =>
      _channel.invokeMethod<void>('save', {'token': token});

  Future<void> discardPick(String token) async {
    try {
      await _channel.invokeMethod<void>('discardPick', {'token': token});
    } on PlatformException {
      // The unsaved candidate has no persisted grant.
    } on MissingPluginException {
      // The activity may have detached while the picker was open.
    }
  }

  Future<String> read(WatchLocalSubtitleOwner owner) async {
    final bytes = await _channel
        .invokeMethod<Uint8List>('read', _scope(owner))
        .timeout(const Duration(seconds: 10));
    if (bytes == null) throw const FormatException('Subtitle unavailable');
    return _decode(bytes);
  }

  Future<void> remove(WatchLocalSubtitleOwner owner) =>
      _channel.invokeMethod<void>('remove', _scope(owner));

  Future<void> removeProfile(String profileId) async {
    if (!supported) return;
    try {
      await _channel
          .invokeMethod<void>('removeProfile', {'profileId': profileId});
    } on MissingPluginException {
      // Profile cleanup can also run without an attached Android activity.
    }
  }

  Map<String, String> _scope(WatchLocalSubtitleOwner owner) =>
      {'profileId': owner.profileId, 'videoId': owner.videoId};

  String _decode(Uint8List bytes) =>
      utf8.decode(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
}
