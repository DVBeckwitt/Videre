import 'dart:convert';

import 'package:clipious/music/services/music_history_transfer.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/services/spotify_music_history_import.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

const _trackUri = 'spotify:track:4PTG3Z6ehGkBFwjybzWkR8';

Map<String, Object?> _spotifyRow({
  Object? date = '2026-03-08T07:30:05Z',
  String? title = 'Track Name',
  String? artist = 'Artist',
  String? album = 'Original release',
  String? uri = _trackUri,
  int listenedMs = 180000,
}) =>
    {
      'ts': date,
      'master_metadata_track_name': title,
      'master_metadata_album_artist_name': artist,
      'master_metadata_album_album_name': album,
      'spotify_track_uri': uri,
      'ms_played': listenedMs,
    };

SpotifyMusicHistoryCandidate _candidate(
  String id, {
  String title = 'Track Name',
  String artist = 'Artist',
  String? album,
}) =>
    SpotifyMusicHistoryCandidate(
      HistoryVideoCache(
        id,
        title,
        artist,
        '',
        musicMetadata:
            MusicMetadata(title: title, artist: artist, album: album),
      ),
      MusicListeningSource.catalog,
    );

SpotifyMusicHistoryPreview _preview(
  List<Object?> rows, {
  List<SpotifyMusicHistoryCandidate> candidates = const [],
  Set<String> existingEventIds = const {},
}) =>
    SpotifyMusicHistoryImport.preview((
      text: jsonEncode(rows),
      candidates: candidates,
      existingEventIds: existingEventIds,
    ));

void main() {
  test('imported IDs survive profile backup and portable history round trips',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    final history = MusicListeningHistory.forProfile(database, owner.profileId);
    final event = _preview(
      [_spotifyRow()],
      candidates: [_candidate('match000000')],
    ).events.single;
    expect(await history.merge([event, event]), 1);

    final portable = MusicHistoryTransfer.encode(history.events());
    expect(MusicHistoryTransfer.decode(portable).single.id, event.id);
    final backup = UserBackup.parse((await owner.exportBackup()).encode());
    expect(backup.sections['musicListeningEvents']!.single['id'], event.id);
    final other = await database.createProfile('Backup destination');
    final restoredOwner = database.forProfile(other.id);
    final restored = MusicListeningHistory.forProfile(database, other.id);
    expect(restored.events(), isEmpty);
    await restoredOwner.restoreBackup(backup);
    expect(restored.events().single.playedAt, event.playedAt);
    expect(await restored.merge([event]), 0);
    expect(history.events().single.id, event.id);
  });

  test('uses exact labels and prioritizes exact known albums', () {
    final original = _candidate('original000', album: ' ORIGINAL   Release ');
    final other = _candidate('different00', album: 'Other release');
    final unknown = _candidate('unknown0000');
    final near = _candidate('similar0000', title: 'Track Name (live)');
    final noAccent = _candidate('noaccent000', title: 'Cancion');
    final result = _preview(
      [
        _spotifyRow(title: ' track    NAME  ', artist: 'ARTIST'),
        _spotifyRow(album: 'Third release', date: '2026-03-09T07:30:05Z'),
        _spotifyRow(album: null, date: '2026-03-10T07:30:05Z'),
        _spotifyRow(title: 'Track Name (remastered)', uri: null),
        _spotifyRow(title: 'Canción', uri: null),
      ],
      candidates: [near, unknown, other, original, noAccent, original],
    );

    expect(result.rows.map((row) => row.number), [1, 2, 3, 4, 5]);
    expect(result.rows.map((row) => row.status), [
      SpotifyMusicHistoryStatus.matched,
      SpotifyMusicHistoryStatus.matched,
      SpotifyMusicHistoryStatus.ambiguous,
      SpotifyMusicHistoryStatus.unmatched,
      SpotifyMusicHistoryStatus.unmatched,
    ]);
    expect(result.rows[0].matches, [original]);
    expect(result.rows[1].matches, [unknown]);
    expect(result.rows[2].matches, [unknown, other, original]);
    expect(result.events.map((event) => event.trackId), [
      original.entry.videoId,
      unknown.entry.videoId,
    ]);
    expect(
      _preview([_spotifyRow()], candidates: [other]).rows.single.status,
      SpotifyMusicHistoryStatus.unmatched,
    );
  });

  test('normalizes explicit offsets and validates calendar dates', () {
    final candidate = _candidate('match000000');
    final result = _preview(
      [
        _spotifyRow(date: '2026-03-08T01:30:05.123456-06:00'),
        _spotifyRow(date: '2026-03-08T07:30:05.123456Z'),
        _spotifyRow(date: '2026-03-08T07:30:05'),
        _spotifyRow(date: '2025-02-29T07:30:05Z'),
        _spotifyRow(date: '2026-03-08T07:30:05+00:90'),
        _spotifyRow(date: '2026-03-08T07:30:05Z\n'),
        _spotifyRow(date: null),
      ],
      candidates: [candidate],
    );

    final timestamp = DateTime.utc(2026, 3, 8, 7, 30, 5, 123, 456);
    expect(result.events.single.playedAt, timestamp);
    expect(result.events.single.entry.created, timestamp);
    expect(result.rows.map((row) => row.playedAt), [
      timestamp,
      timestamp,
      null,
      null,
      null,
      null,
      null,
    ]);
    expect(result.rows.map((row) => row.status), [
      SpotifyMusicHistoryStatus.matched,
      SpotifyMusicHistoryStatus.duplicate,
      ...List.filled(5, SpotifyMusicHistoryStatus.invalid),
    ]);
    expect(result.events.single.entry, isNot(same(candidate.entry)));
  });

  test('deduplicates Spotify events across imports and changed matches', () {
    final result = _preview(
      [
        _spotifyRow(),
        _spotifyRow(),
        _spotifyRow(listenedMs: 10000),
        _spotifyRow(date: '2026-03-08T07:31:05Z'),
      ],
      candidates: [_candidate('first001000')],
    );
    expect(result.rows[1].status, SpotifyMusicHistoryStatus.duplicate);
    final ids = result.events.map((event) => event.id).toSet();
    expect(ids, hasLength(3));
    expect(ids.every(isSpotifyMusicHistoryEventId), isTrue);
    final newProfile = _preview(
      [_spotifyRow()],
      candidates: [_candidate('another0000')],
    );
    expect(newProfile.events.single.id, result.events.first.id);
    final reimport = _preview(
      [_spotifyRow()],
      candidates: [_candidate('another0000')],
      existingEventIds: ids,
    );
    expect(reimport.rows.single.status, SpotifyMusicHistoryStatus.duplicate);
    expect(reimport.events, isEmpty);
  });

  test('deduplicates missing track URIs by normalized labels', () {
    final result = _preview(
      [
        _spotifyRow(uri: null),
        _spotifyRow(
          title: 'Track   name',
          artist: ' ARTIST ',
          album: 'original RELEASE ',
          uri: null,
        ),
      ],
      candidates: [_candidate('match000000')],
    );
    expect(result.events, hasLength(1));
    expect(result.rows.last.status, SpotifyMusicHistoryStatus.duplicate);
  });

  test('redacts private rows and does not import podcasts or zero plays', () {
    final result = _preview(
      [
        {..._spotifyRow(title: 'private label'), 'incognito_mode': true},
        {..._spotifyRow(title: 'private label'), 'incognito_mode': 'true'},
        {
          ..._spotifyRow(title: null, artist: null, uri: null),
          'spotify_episode_uri': 'spotify:episode:placeholder',
          'episode_name': 'private podcast',
        },
        _spotifyRow(listenedMs: 0),
        {
          ..._spotifyRow(),
          'username': 'private name',
          'ip_addr': '192.0.2.101',
          'user_agent_decrypted': 'private device',
        },
      ],
      candidates: [_candidate('match000000')],
    );
    expect(result.rows.map((row) => row.status), [
      SpotifyMusicHistoryStatus.skipped,
      SpotifyMusicHistoryStatus.invalid,
      SpotifyMusicHistoryStatus.skipped,
      SpotifyMusicHistoryStatus.skipped,
      SpotifyMusicHistoryStatus.matched,
    ]);
    for (final row in result.rows.take(2)) {
      expect((
        row.title,
        row.artist,
        row.album,
        row.playedAt
      ), (
        null,
        null,
        null,
        null,
      ));
      expect(row.matches, isEmpty);
    }
    expect(result.rows[2].title, isNull);
    final saved = jsonEncode(result.events.single.toJson());
    expect(saved, isNot(contains('private')));
    expect(saved, isNot(contains('192.0.2.101')));
    expect(saved, isNot(contains(_trackUri)));
  });

  test('rejects unrelated schemas and bounds UTF-8 bytes', () {
    expect(_preview([]).rows, isEmpty);
    expect(
      () => _preview([
        {
          'endTime': '2026-03-08 07:30',
          'trackName': 'Track Name',
          'artistName': 'Artist',
        },
      ]),
      throwsFormatException,
    );
    expect(
      () => SpotifyMusicHistoryImport.preview((
        text: '{private data',
        candidates: [],
        existingEventIds: {},
      )),
      throwsA(isA<FormatException>()
          .having((error) => error.source, 'source', isNull)),
    );
    expect(
      () => SpotifyMusicHistoryImport.preview((
        text: 'é' * (UserBackup.maxBytes ~/ 2 + 1),
        candidates: [],
        existingEventIds: {},
      )),
      throwsA(isA<MusicHistoryFileTooLarge>()),
    );
  });
}
