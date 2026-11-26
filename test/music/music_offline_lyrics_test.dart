import 'dart:async';
import 'dart:convert';

import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_lyrics_match.dart';
import 'package:clipious/music/services/music_lyrics_corrections.dart';
import 'package:clipious/music/services/music_offline_lyrics.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

const _recording = 'abcdefghijk';
const _otherRecording = 'device:fixture';
const _track = MusicMetadata(title: 'The Song', artist: 'Artist', album: 'LP');
const _synced = MusicLyrics.synced(
    [
      (start: Duration(microseconds: 4000001), text: 'First line'),
      (start: Duration(microseconds: 4000001), text: 'Second line'),
      (start: Duration(seconds: 8), text: 'First line'),
    ],
    source: 'LRCLIB',
    displayTextByCue: {0: '  First line\nTranslation  '},
    breakStarts: [Duration(milliseconds: -75), Duration(seconds: 6)],
    wordsByCue: {
      1: [
        (start: Duration(microseconds: 4050001), startOffset: 0, endOffset: 6),
        (start: Duration(microseconds: 4075001), startOffset: 7, endOffset: 11),
      ],
    });

void main() {
  late SembastSqfDb database;
  late MusicOfflineLyrics offline;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    offline = MusicOfflineLyrics(database);
  });

  tearDown(() async => database.close());

  MusicLyrics? read({
    String id = _recording,
    MusicMetadata track = _track,
    int? duration = 180,
  }) =>
      offline.read(id, track: track, durationSeconds: duration);

  test('approved lyrics survive restart and stay out of a portable backup',
      () async {
    final factory = newDatabaseFactoryMemory();
    Future<SembastSqfDb> open() async {
      final store = SembastSqfDb(await factory.openDatabase('offline-lyrics'));
      await store.getProfiles();
      return store;
    }

    var store = await open();
    await MusicOfflineLyrics(store)
        .save(_recording, _synced, track: _track, durationSeconds: 180);
    await store.close();

    store = await open();
    try {
      final lyrics = MusicOfflineLyrics(store)
          .read(_recording, track: _track, durationSeconds: 180);
      expect(lyrics?.kind, MusicLyricsKind.synced);
      expect(lyrics?.cues, _synced.cues);
      expect(lyrics?.wordsByCue, _synced.wordsByCue);
      expect(lyrics?.displayTextByCue, _synced.displayTextByCue);
      expect(lyrics?.breakStarts, _synced.breakStarts);
      expect(lyrics?.source, _synced.source);

      final setting = store.getAllSettings().singleWhere(
          (setting) => setting.name.startsWith('music-offline-lyrics-v1:'));
      expect(UserBackup.validSetting(setting), isFalse);
    } finally {
      await store.close();
    }
  });

  test('a captured owner remains isolated after switching active profile',
      () async {
    final other = await database.createProfile('Another listener');
    await database.useProfile(other.id);
    final otherOffline = MusicOfflineLyrics(database);
    await Future.wait([
      offline.save(_recording, _synced, track: _track, durationSeconds: 180),
      otherOffline.save(
          _recording, const MusicLyrics.instrumental(source: 'Local tag'),
          track: _track, durationSeconds: 180),
      offline.save(_otherRecording, const MusicLyrics.plain('Local words'),
          track: _track, durationSeconds: null),
    ]);
    expect(read()?.kind, MusicLyricsKind.synced);
    expect(read(id: _otherRecording)?.text, 'Local words');
    final otherLyrics =
        otherOffline.read(_recording, track: _track, durationSeconds: 180);
    expect(otherLyrics?.kind, MusicLyricsKind.instrumental);
    expect(otherLyrics?.source, 'Local tag');
    expect(
        otherOffline.read(_otherRecording, track: _track, durationSeconds: 180),
        isNull);

    await offline.remove(_recording);
    expect(read(), isNull);
    expect(read(id: _otherRecording)?.text, 'Local words');
    expect(
        otherOffline
            .read(_recording, track: _track, durationSeconds: 180)
            ?.kind,
        MusicLyricsKind.instrumental);
  });

  test('checks recording, known labels and duration before reusing lyrics',
      () async {
    await offline.save(_recording, _synced,
        track: _track, durationSeconds: 180);

    expect(read(id: _otherRecording), isNull);
    expect(
        read(
            track: const MusicMetadata(
                title: '  THE   Song  ', artist: ' ARTIST '),
            duration: 182),
        isNotNull);
    expect(read(duration: null), isNotNull);
    expect(read(duration: 183), isNull);
    for (final changed in const [
      MusicMetadata(title: 'The Song (Live)', artist: 'Artist', album: 'LP'),
      MusicMetadata(title: 'The Song', artist: 'Other', album: 'LP'),
      MusicMetadata(title: 'The Song', artist: 'Artist', album: 'Other'),
    ]) {
      expect(read(track: changed), isNull);
    }
  });

  test('discovers catalog copies with original labels and supports old rows',
      () async {
    const legacyId = 'klmnopqrstu';
    const invalidId = '0123456789a';
    const display = MusicMetadata(
        title: 'The Singer’s Song', artist: 'The SINGER', album: 'LP');
    await offline.save(_recording, _synced,
        track: display, durationSeconds: 180);
    await offline.save(_otherRecording, _synced,
        track: _track, durationSeconds: null);
    await database.saveSettings([
      SettingsValue(
          'music-offline-lyrics-v1:$legacyId',
          jsonEncode({
            'labels': ['prior song', 'prior artist', ''],
            'duration': null,
            'kind': 'plain',
            'text': 'Prior verse',
          })),
      SettingsValue('music-offline-lyrics-v1:$invalidId',
          '{"labels":["bad",1,""],"kind":"plain","text":"Invalid"}'),
    ]);

    final recordings = {
      for (final recording in offline.catalogRecordings())
        recording.videoId: recording,
    };
    expect(recordings.keys, unorderedEquals([_recording, legacyId]));
    final current = recordings[_recording]!;
    expect(current.track.title, display.title);
    expect(current.track.artist, display.artist);
    expect(current.track.album, display.album);
    expect(current.durationSeconds, 180);
    expect(
        offline
            .read(current.videoId,
                track: current.track, durationSeconds: current.durationSeconds)
            ?.wordsByCue,
        _synced.wordsByCue);

    final legacy = recordings[legacyId]!;
    expect(legacy.track.title, 'prior song');
    expect(legacy.track.artist, 'prior artist');
    expect(legacy.track.album, isNull);
    expect(legacy.durationSeconds, isNull);
    expect(
        offline
            .read(legacy.videoId,
                track: legacy.track, durationSeconds: legacy.durationSeconds)
            ?.text,
        'Prior verse');
  });

  test('changes observe saves, correction writes, and removals by profile',
      () async {
    final owner = database.forProfile(database.profileId);
    final other = await database.createProfile('Another listener');
    final otherOffline = MusicOfflineLyrics(database.forProfile(other.id));
    final otherUpdates = StreamIterator<void>(otherOffline.changes);
    final updates = StreamIterator<void>(offline.changes);
    var ownUpdateCount = 0;
    final listener = offline.changes.listen((_) => ownUpdateCount++);
    try {
      expect(await updates.moveNext(), isTrue);
      expect(await otherUpdates.moveNext(), isTrue);
      expect(ownUpdateCount, 1);
      await otherOffline.save(_recording, _synced,
          track: _track, durationSeconds: 180);
      expect(await otherUpdates.moveNext(), isTrue);
      await owner.saveSetting(SettingsValue('unrelated-setting', 'anything'));
      await pumpEventQueue();
      expect(ownUpdateCount, 1);
      expect(offline.catalogRecordings(), isEmpty);

      await offline.save(_recording, _synced,
          track: _track, durationSeconds: 180);
      expect(await updates.moveNext(), isTrue);
      expect(offline.catalogRecordings().single.videoId, _recording);
      final corrections = MusicLyricsCorrections(owner);
      await corrections.save(
          _recording, const MusicLyricsCorrection(MusicLyrics.unavailable()));
      expect(await updates.moveNext(), isTrue);
      await corrections.clear(_recording);
      expect(await updates.moveNext(), isTrue);
      await offline.remove(_recording);
      expect(await updates.moveNext(), isTrue);
      expect(offline.catalogRecordings(), isEmpty);
      expect(otherOffline.catalogRecordings().single.videoId, _recording);
    } finally {
      await listener.cancel();
      await updates.cancel();
      await otherUpdates.cancel();
    }
  });

  test('preserves plain cues without duplicating repeated text in storage',
      () async {
    final line = 'a' * 16000;
    final cues = [
      for (var index = 0; index < 90; index++)
        (start: Duration(seconds: index), text: line),
    ];
    await offline.save(
        _recording, MusicLyrics.plainCues(cues, source: 'My sidecar'),
        track: _track, durationSeconds: null);
    final setting = database.getAllSettings().single;
    expect(setting.value.length, lessThan(20000));
    expect(read()?.kind, MusicLyricsKind.plain);
    expect(read()?.source, 'My sidecar');
    expect(read()?.cues, cues);
  });

  test('unavailable and malformed saves preserve prior lyrics', () async {
    await offline.save(_recording, _synced,
        track: _track, durationSeconds: 180);
    for (final invalid in const [
      MusicLyrics.unavailable(),
      MusicLyrics.plain('  '),
      MusicLyrics.synced([
        (start: Duration(seconds: 5), text: 'Second'),
        (start: Duration(seconds: 4), text: 'First'),
      ]),
    ]) {
      await expectLater(
          offline.save(_recording, invalid,
              track: _track, durationSeconds: 180),
          throwsArgumentError);
      expect(read()?.cues, _synced.cues);
    }
  });

  test('corrupt persisted data does not render partial lyrics', () async {
    await offline.save(_recording, _synced,
        track: _track, durationSeconds: 180);
    final setting = database.getAllSettings().single;
    final valid = jsonDecode(setting.value) as Map<String, dynamic>;
    for (final invalid in [
      '{',
      jsonEncode({...valid, 'duration': '180'}),
      jsonEncode({...valid, 'source': 5}),
      jsonEncode({
        ...valid,
        'cues': [
          [4000001, 50],
        ],
      }),
    ]) {
      await database.saveSetting(SettingsValue(setting.name, invalid));
      expect(read(), isNull);
    }
  });
}
