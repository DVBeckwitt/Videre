import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef LocalMusicVideoOwner = ({String profileId, String recordingId});

class LocalMusicVideoPairing {
  static const maxOffset = Duration(days: 1);

  final String uri;
  final String name;
  final Duration offset;

  const LocalMusicVideoPairing(this.uri, this.name, this.offset);

  static LocalMusicVideoPairing? fromPlatform(Map<String, Object?>? value) {
    if (value == null) return null;
    final uri = value['uri'];
    final name = value['name'];
    final offsetMs = value['offsetMs'];
    if (uri is! String ||
        name is! String ||
        offsetMs is! int ||
        offsetMs < -maxOffset.inMilliseconds ||
        offsetMs > maxOffset.inMilliseconds) {
      return null;
    }
    final document = Uri.tryParse(uri);
    if (document == null ||
        document.scheme != 'content' ||
        document.authority.isEmpty) {
      return null;
    }
    return LocalMusicVideoPairing(uri, name, Duration(milliseconds: offsetMs));
  }
}

/// Android owns the document grant and stores its pairing on this device.
class LocalMusicVideoPairings {
  static const _channel =
      MethodChannel('com.github.dvbeckwitt.videre/local_music_video');
  static final _changes = ValueNotifier<(LocalMusicVideoOwner, Object)?>(null);

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static ValueListenable<(LocalMusicVideoOwner, Object)?> get changes =>
      _changes;

  static Map<String, Object?> _args(LocalMusicVideoOwner owner,
          [LocalMusicVideoPairing? expected]) =>
      {
        'profileId': owner.profileId,
        'recordingId': owner.recordingId,
        if (expected != null) 'expectedUri': expected.uri,
      };

  static Future<LocalMusicVideoPairing?> get(
          LocalMusicVideoOwner owner) async =>
      LocalMusicVideoPairing.fromPlatform(
          await _channel.invokeMapMethod<String, Object?>('get', _args(owner)));

  static Future<void> pick(LocalMusicVideoOwner owner) async {
    final selected =
        await _channel.invokeMapMethod<String, Object?>('pick', _args(owner));
    if (LocalMusicVideoPairing.fromPlatform(selected) != null) _changed(owner);
  }

  static Future<bool> setOffset(LocalMusicVideoOwner owner,
      LocalMusicVideoPairing pairing, Duration offset) async {
    final args = _args(owner, pairing)..['offsetMs'] = offset.inMilliseconds;
    return _edit('setOffset', owner, args);
  }

  static Future<bool> remove(
          LocalMusicVideoOwner owner, LocalMusicVideoPairing pairing) =>
      _edit('remove', owner, _args(owner, pairing));

  static Future<bool> _edit(String method, LocalMusicVideoOwner owner,
      Map<String, Object?> args) async {
    if (await _channel.invokeMethod<bool>(method, args) != true) return false;
    _changed(owner);
    return true;
  }

  static void _changed(LocalMusicVideoOwner owner) {
    // Notify on successive edits to the same pairing as well.
    _changes.value = (owner, Object());
  }

  static Future<bool> open(
          LocalMusicVideoOwner owner, LocalMusicVideoPairing pairing) async =>
      await _channel.invokeMethod<bool>('open', _args(owner, pairing)) == true;

  static Future<void> forgetProfile(String profileId) async {
    if (!supported) return;
    try {
      await _channel
          .invokeMethod<void>('forgetProfile', {'profileId': profileId});
    } on MissingPluginException {
      // There is no Android store when running without the native plugin.
    }
  }
}
