import 'package:flutter/services.dart';

import 'm3u_playlist.dart';

typedef M3uInput = ({String name, String text, M3uLocation? location});
typedef M3uOutput = ({String token, M3uLocation? location});

class M3uDocuments {
  static const _files = MethodChannel('videre/files');

  static Future<M3uInput?> open() async {
    final result = await _files.invokeMapMethod<String, Object?>('openM3u');
    if (result == null) return null;
    return (
      name: result['name'] as String,
      text: result['text'] as String,
      location: m3uLocation(result['location']),
    );
  }

  static Future<M3uOutput?> create(String title) async {
    final safe = title.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\]'), '_').trim();
    final name =
        safe.isEmpty ? 'Playlist' : String.fromCharCodes(safe.runes.take(120));
    final result = await _files
        .invokeMapMethod<String, Object?>('createM3u', {'name': '$name.m3u8'});
    if (result == null) return null;
    return (
      token: result['token'] as String,
      location: m3uLocation(result['location'])
    );
  }

  static Future<void> write(M3uOutput output, List<String> paths) =>
      _files.invokeMethod<void>('writeM3u', {
        'token': output.token,
        'text': '#EXTM3U\n${paths.join('\n')}\n',
      });

  static Future<void> discard(M3uOutput output) async {
    try {
      await _files.invokeMethod<void>('cancelM3uSave', {'token': output.token});
    } on PlatformException catch (error) {
      if (error.code != 'M3U_OUTPUT_CLOSED') rethrow;
    }
  }
}
