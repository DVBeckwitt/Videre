import 'dart:convert';

import 'playback_session.dart';

const namedMusicQueuesSetting = 'named-music-queues';

enum NamedMusicQueueResumeResult { restored, unavailable }

class NamedMusicQueue {
  final String id;
  final String name;
  final PlaybackSession snapshot;

  bool get usesDefaultName => name.isEmpty;

  const NamedMusicQueue(this.id, this.name, this.snapshot);

  static String encodeAll(Iterable<NamedMusicQueue> queues) => jsonEncode({
        'version': 1,
        'queues': [
          for (final queue in queues)
            {
              'id': queue.id,
              'name': queue.name,
              'session':
                  jsonDecode(queue.snapshot.encode(portableArtwork: true)),
            },
        ],
      });

  static List<NamedMusicQueue> decodeAll(String? value) {
    if (value == null) return const [];
    try {
      final data = jsonDecode(value);
      if (data is! Map || data['version'] != 1 || data['queues'] is! List) {
        return const [];
      }
      final queues = <NamedMusicQueue>[];
      final usedIds = <String>{};
      for (final entry in data['queues'] as List) {
        if (entry is! Map) continue;
        final id = entry['id'];
        final rawName = entry['name'];
        final name = rawName == '' ? '' : normalizedQueueTitle(rawName);
        if (id is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
            name == null) {
          continue;
        }
        final snapshot = PlaybackSession.decode(jsonEncode(entry['session']));
        if (snapshot?.audio == true && usedIds.add(id)) {
          queues.add(NamedMusicQueue(id, name, snapshot!));
        }
      }
      return List.unmodifiable(queues);
    } on FormatException {
      return const [];
    }
  }
}
