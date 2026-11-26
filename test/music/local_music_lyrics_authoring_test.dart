import 'dart:async';

import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_lyrics_authoring.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

const _draft = '[00:01.250]<00:01.250>Hello <00:02.500>again';
const _edited = '[00:02.000]Edited line';
const _identity =
    '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
const _track = LocalMusicTrack(
  uri: 'content://media/external/audio/media/1',
  title: 'Recording',
  durationMs: 4000,
  identityKey: _identity,
);

void main() {
  late SembastSqfDb database;
  var current = true;

  LocalMusicLyricsAuthoring authoring([LocalMusicTrack track = _track]) =>
      LocalMusicLyricsAuthoring.forTrack(
          database: database, track: track, isCurrent: () => current)!;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    current = true;
  });
  tearDown(() async => database.close());

  test('saves and resolves by recording identity within the active profile',
      () async {
    final originalProfile = database.profileId;
    final editor = authoring();
    expect(await editor.save(_draft, previousDraft: null), isTrue);
    final reopened = authoring(const LocalMusicTrack(
      uri: 'content://media/external/audio/media/2',
      title: 'Renamed recording',
      durationMs: 4000,
      identityKey: _identity,
    ));
    expect(reopened.readDraft(), _draft);
    final lyrics = reopened.load(source: 'Authored')!;
    expect(lyrics.source, 'Authored');
    expect(lyrics.cues.single.text, 'Hello again');
    expect(
        lyrics.wordsByCue[0]!.last.start, const Duration(milliseconds: 2500));
    expect(musicTimedLyricsDraftFrom(lyrics), _draft);

    final secondProfile = await database.createProfile('Other listener');
    await database.useProfile(secondProfile.id);
    expect(editor.readDraft(), isNull);
    final secondEditor = authoring();
    expect(secondEditor.readDraft(), isNull);
    expect(await secondEditor.save(_edited, previousDraft: null), isTrue);
    final deletedStore = database.authoredMusicLyricsStore;
    await database.useProfile(originalProfile);
    expect(authoring().readDraft(), _draft);
    await database.deleteProfile(secondProfile.id);
    expect(
        await deletedStore.record(_track.playbackId).get(database.db), isNull);
  });

  test('rejects invalid drafts and stale editors, and removes an override',
      () async {
    final editor = authoring();
    expect(await editor.save(_draft, previousDraft: null), isTrue);
    expect(await editor.save('[00:05.000]Out of range', previousDraft: _draft),
        isFalse);
    expect(await editor.save(_edited, previousDraft: null), isFalse);
    expect(await editor.save(_edited, previousDraft: _draft), isTrue);
    expect(await editor.remove(previousDraft: _draft), isFalse);
    expect(await editor.remove(previousDraft: _edited), isTrue);
    expect(editor.load(source: 'Authored'), isNull);
  });

  test('saves and reopens authored breaks alongside timed words', () async {
    const draft = '$_draft\n[00:03.000]\n[00:03.500]Last line';
    final editor = authoring();
    expect(await editor.save(draft, previousDraft: null), isTrue);
    final lyrics = editor.load(source: 'Authored')!;
    expect(lyrics.cues.map((cue) => cue.text), ['Hello again', 'Last line']);
    expect(lyrics.wordsByCue.keys, [0]);
    expect(lyrics.breakStarts, [const Duration(seconds: 3)]);
    expect(musicTimedLyricsDraftFrom(lyrics), draft);
    expect(await editor.save('$draft\n[00:04.100]', previousDraft: draft),
        isFalse);
  });

  test('stores plain and timed lyrics independently in the current profile',
      () async {
    final originalProfile = database.profileId;
    final editor = authoring();
    const plain = 'First line\n\nCafé 🙂';

    expect(await editor.save(_draft, previousDraft: null), isTrue);
    expect(editor.readPlainDraft(), isNull);
    expect(await editor.savePlain(_draft, previousDraft: null), isFalse);
    expect(await editor.savePlain(' \t\n', previousDraft: null), isFalse);
    expect(await editor.savePlain('First line\u0000', previousDraft: null),
        isFalse);
    expect(await editor.savePlain(plain, previousDraft: null), isTrue);
    expect(await editor.savePlain('Stale edit', previousDraft: null), isFalse);
    expect(editor.readPlainDraft(), plain);
    expect(editor.readDraft(), _draft);

    final secondProfile = await database.createProfile('Other listener');
    await database.useProfile(secondProfile.id);
    expect(authoring().readPlainDraft(), isNull);
    expect(await editor.removePlain(previousDraft: plain), isFalse);
    await database.useProfile(originalProfile);

    final reopened = authoring();
    expect(await reopened.remove(previousDraft: _draft), isTrue);
    expect(reopened.readPlainDraft(), plain);
    expect(await reopened.save(_edited, previousDraft: null), isTrue);
    expect(await reopened.removePlain(previousDraft: plain), isTrue);
    expect(reopened.readPlainDraft(), isNull);
    expect(reopened.readDraft(), _edited);
  });

  test('checks the recording again after acquiring the database transaction',
      () async {
    final editor = authoring();
    final started = Completer<void>();
    final release = Completer<void>();
    final transaction = database.db.transaction((_) async {
      started.complete();
      await release.future;
    });
    await started.future;
    final save = editor.save(_draft, previousDraft: null);
    current = false;
    release.complete();
    await transaction;
    expect(await save, isFalse);
    current = true;
    expect(editor.readDraft(), isNull);
  });
}
