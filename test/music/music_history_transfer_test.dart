import 'dart:convert';

import 'package:clipious/music/services/music_history_transfer.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = 'abcdefghijk';
const _firstId = '8914440d-05c2-49f8-a136-fe11e4b61117';
const _secondId = '4e52cd69-0007-494e-9894-2cc7c1e0c58b';
final _firstDate = DateTime.utc(2025, 5, 6, 4, 30);
final _secondDate = DateTime.utc(2025, 5, 7, 4, 30);

HistoryVideoCache _songAt(DateTime date, {bool download = false}) =>
    HistoryVideoCache(
      _song,
      'Song',
      'Artist',
      'https://example.com/private-artwork?key=private',
      playedFromDownload: download,
      downloadAccountId: download ? 'private-account' : null,
    )..created = date;

MusicListeningEvent _play(String id, DateTime date, {bool download = false}) =>
    MusicListeningEvent(
      id: id,
      entry: _songAt(date, download: download),
      source: download
          ? MusicListeningSource.download
          : MusicListeningSource.catalog,
    );

String _backup({required List<Object?> legacy, List<Object?>? events}) =>
    jsonEncode({
      'format': 'videre',
      'version': 1,
      'musicHistory': legacy,
      if (events != null) 'musicListeningEvents': events,
      'videoHistory': [_songAt(DateTime.utc(2002)).toJson()],
      'settings': [
        {'name': 'unrelated', 'value': 'ignored'},
      ],
    });

void main() {
  test('exports dated rows and derived counts without download access', () {
    final file = MusicHistoryTransfer.encode([
      _play(_firstId, _firstDate, download: true),
      _play(_secondId, _secondDate),
    ]);
    expect(file, isNot(contains('private')));
    expect((jsonDecode(file) as Map)['playCounts'], [
      {'trackId': _song, 'title': 'Song', 'artist': 'Artist', 'playCount': 2},
    ]);
    final decoded = MusicHistoryTransfer.decode(file);
    expect(decoded.map((event) => event.id), [_secondId, _firstId]);
    expect(decoded.map((event) => event.playedAt), [_secondDate, _firstDate]);
    expect(decoded.last.source, MusicListeningSource.download);
    expect(decoded.last.entry.playedFromDownload, isFalse);
    expect(decoded.last.entry.downloadAccountId, isNull);
    expect(MusicHistoryTransfer.encode(decoded), file);
  });

  test('v1 backups import both Music sections and ignore other sections', () {
    final file = _backup(
      legacy: [_songAt(_firstDate).toJson()],
      events: [_play(_secondId, _secondDate).toJson()],
    );
    final decoded = MusicHistoryTransfer.decode(file);
    expect(decoded.map((event) => event.playedAt), [_secondDate, _firstDate]);
    expect(decoded.last.isLegacy, isTrue);
    expect(decoded.last.entry.thumbnail, isEmpty);
  });

  test(
    'rejects invalid documents before merge and ignores count summaries',
    () {
      final row = _play(_firstId, _firstDate).toJson();
      final invalid = _backup(
        legacy: [],
        events: [
          row,
          {...row, 'id': 'bad'},
        ],
      );
      expect(() => MusicHistoryTransfer.decode(invalid), throwsFormatException);
      expect(
        () => MusicHistoryTransfer.decode('{"format":"videre","version":2}'),
        throwsFormatException,
      );
      expect(
        MusicHistoryTransfer.decode(
          jsonEncode({
            'format': 'videre-music-history',
            'version': 1,
            'events': [],
            'playCounts': [
              {'trackId': _song, 'playCount': 500},
            ],
          }),
        ),
        isEmpty,
      );
    },
  );

  test('reimports are atomic and scoped with recording paused', () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final source = MusicListeningHistory.forProfile(
      database,
      database.profileId,
    );
    final second = await database.createProfile('Other listener');
    final target = MusicListeningHistory.forProfile(database, second.id);
    await target.setRecordingPaused(true);
    await source.merge([_play(_firstId, _firstDate)]);

    final first = _songAt(_firstDate).toJson();
    final secondDate = _songAt(_secondDate).toJson();
    final overlappingImport = _backup(
      legacy: [first, secondDate],
      events: [_play(_firstId, _firstDate).toJson()],
    );
    final events = MusicHistoryTransfer.decode(overlappingImport);
    final added = await Future.wait([
      target.merge(events),
      target.merge(events),
    ]);
    expect(added, unorderedEquals([2, 0]));
    expect(target.recordingPaused, isTrue);
    expect(target.events().map((event) => event.playedAt), [
      _secondDate,
      _firstDate,
    ]);
    expect(source.events().map((event) => event.id), [_firstId]);

    // The offset form refers to the same old listen as the UTC form.
    final equivalent = MusicHistoryTransfer.decode(
      _backup(
        legacy: [
          {...secondDate, 'created': '2025-05-06T23:30:00-05:00'},
        ],
      ),
    );
    expect(await target.merge(equivalent), 0);
    expect(await target.merge([_play(_secondId, _firstDate)]), 1);
    expect(target.events(), hasLength(3));
  });
}
