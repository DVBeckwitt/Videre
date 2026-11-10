import 'dart:convert';

import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late PlaylistProgressService progress;
  const reference = PlaylistReference(
      kind: PlaylistSourceKind.public,
      playlistId: 'PLone',
      profileId: 'default');
  const otherReference = PlaylistReference(
      kind: PlaylistSourceKind.public,
      playlistId: 'PLtwo',
      profileId: 'default');
  final entries = assignPlaylistEntryIds(const [
    Video(videoId: 'first', indexId: 'first'),
    Video(videoId: 'repeat', indexId: 'repeat-one'),
    Video(videoId: 'repeat', indexId: 'repeat-two'),
    Video(videoId: 'last', indexId: 'last'),
  ]);

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    progress = PlaylistProgressService.forProfile(database, database.profileId);
  });
  tearDown(() async => database.close());

  test(
      'a playlist remembers its exact repeated occurrence after other playback',
      () async {
    await progress.save(reference, entries[2], entries: entries);
    await progress.save(otherReference, entries[0], entries: entries);
    final reopened = PlaylistProgressService.forProfile(database, 'default');
    expect(reopened.get(reference)!.resolve(entries)!.index, 2);
    expect(reopened.get(otherReference)!.resolve(entries)!.index, 0);
    final stored =
        jsonDecode(database.getSettings(playlistProgressSettingName)!.value)
            as Map;
    expect((stored['entries'] as List).first, isNot(contains('seconds')));
  });

  test('stable occurrence follows reordering instead of its previous index',
      () async {
    await progress.save(reference, entries[2], entries: entries);
    final reordered = [entries[2], entries[0], entries[1], entries[3]];
    final target = progress.get(reference)!.resolve(reordered)!;
    expect(target.index, 0);
    expect(target.video.indexId, 'repeat-two');
    expect(target.missing, isFalse);
  });

  test('each playlist retains its audio mode after other playback', () async {
    await progress.save(reference, entries[1], entries: entries, audio: true);
    await progress.save(otherReference, entries[0],
        entries: entries, audio: false);
    final reopened = PlaylistProgressService.forProfile(database, 'default');
    expect(reopened.get(reference)!.audio, isTrue);
    expect(reopened.get(reference)!.resolve(entries)!.index, 1);
    expect(reopened.get(otherReference)!.audio, isFalse);
    await progress.save(reference, entries[1], entries: entries, audio: false);
    expect(reopened.get(reference)!.audio, isFalse);
  });

  test('legacy checkpoints omit audio mode and malformed modes are rejected',
      () async {
    await progress.save(reference, entries[0], entries: entries);
    final legacy = progress.get(reference)!.toJson();
    expect(legacy.containsKey('audio'), isFalse);
    expect(PlaylistCheckpoint.tryParse(legacy)!.audio, isNull);
    expect(
        PlaylistCheckpoint.tryParse({...legacy, 'audio': null})!.audio, isNull);
    expect(PlaylistCheckpoint.tryParse({...legacy, 'audio': 'true'}), isNull);
  });

  test('restored queue occurrence still follows its stable source ID',
      () async {
    final restored =
        entries.map((video) => video.copyWith(indexId: null)).toList();
    await progress.save(reference, restored[2], entries: restored);
    final reordered = [entries[2], entries[0], entries[1], entries[3]];
    expect(progress.get(reference)!.resolve(reordered)!.index, 0);
  });

  test('deleted occurrence offers a known successor, never a replacement index',
      () async {
    await progress.save(reference, entries[2], entries: entries);
    final changed = [
      entries[0],
      entries[1],
      const Video(videoId: 'replacement', indexId: 'replacement'),
      entries[3],
    ];
    final target = progress.get(reference)!.resolve(changed)!;
    expect(target.video.videoId, 'last');
    expect(target.index, 3);
    expect(target.missing, isTrue);
    expect(progress.get(reference)!.resolve(changed.take(3).toList()), isNull);
  });

  test('a removed duplicate without stable IDs is not replaced by the first',
      () async {
    final source = assignPlaylistEntryIds(const [
      Video(videoId: 'repeat'),
      Video(videoId: 'repeat'),
      Video(videoId: 'next'),
    ]);
    await progress.save(reference, source[1], entries: source);
    final changed = const [Video(videoId: 'repeat'), Video(videoId: 'next')];
    final target = progress.get(reference)!.resolve(changed)!;
    expect(target.video.videoId, 'next');
    expect(target.missing, isTrue);
    expect(progress.get(reference)!.resolve(changed.take(1).toList()), isNull);
    await progress.save(reference, source[0], entries: source);
    expect(progress.get(reference)!.resolve(changed)!.index, 0);
    expect(progress.get(reference)!.resolve(changed)!.missing, isFalse);
  });

  test('completion advances cursor while filtered entries are never resumed',
      () async {
    await progress.save(reference, entries[1],
        entries: entries, completed: true);
    final changed = [...entries]..[2] = entries[2].copyWith(filtered: true);
    expect(progress.get(reference)!.resolve(changed)!.video.videoId, 'last');
    await progress.save(reference, entries.last,
        entries: entries, completed: true);
    expect(progress.get(reference)!.resolve(entries), isNull);
  });

  test('profile ownership isolates cursors and concurrent saves preserve both',
      () async {
    await Future.wait([
      progress.save(reference, entries[0], entries: entries),
      progress.save(otherReference, entries[1], entries: entries),
    ]);
    expect(progress.get(reference), isNotNull);
    expect(progress.get(otherReference), isNotNull);
    final person = await database.createProfile('Other');
    final other = PlaylistProgressService.forProfile(database, person.id);
    expect(other.get(reference), isNull);
    await expectLater(other.save(reference, entries[0]), throwsStateError);
  });

  test('fixed database views share updates for the same person', () async {
    final view = PlaylistProgressService.forProfile(
        database.forProfile('default'), 'default');
    var updates = 0;
    void changed() => updates++;
    progress.changes.addListener(changed);
    addTearDown(() => progress.changes.removeListener(changed));
    await Future.wait([
      view.save(reference, entries[0], entries: entries),
      progress.save(otherReference, entries[1], entries: entries),
    ]);
    expect(updates, 2);
    expect(view.get(reference), isNotNull);
    expect(view.get(otherReference), isNotNull);
  });

  test('reset one video preserves other playlists and rejects queued old saves',
      () async {
    await progress.save(reference, entries[1], entries: entries);
    await progress.save(otherReference, entries[0], entries: entries);
    late Future<bool> lateSave;
    await database.db.transaction((transaction) async {
      lateSave = progress.save(reference, entries[1], entries: entries);
      final record = database.settingsStore.record(playlistProgressSettingName);
      final value = await record.get(transaction);
      await record.put(
          transaction,
          SettingsValue(
                  playlistProgressSettingName,
                  resetPlaylistProgress(value?['value'] as String?,
                      videoId: 'repeat'))
              .toJson());
    });
    expect(await lateSave, isFalse);
    expect(progress.get(reference), isNull);
    expect(progress.get(otherReference), isNotNull);
  });

  test('watch revision and active playback guard reject obsolete callbacks',
      () async {
    await stringMapStoreFactory
        .store('watchState:default')
        .record('first')
        .put(database.db, {'revision': 2});
    expect(
        await progress.save(reference, entries[0],
            entries: entries, watchRevision: 1),
        isFalse);
    expect(progress.get(reference), isNull);
    expect(
        await progress.save(reference, entries[0],
            entries: entries, watchRevision: 2, isCurrent: () => false),
        isFalse);
    expect(progress.get(reference), isNull);
    expect(
        await progress.save(reference, entries[0],
            entries: entries, watchRevision: 2),
        isTrue);
    expect(progress.get(reference), isNotNull);
    await progress.clear();
    expect(progress.get(reference), isNull);
  });

  test('corrupt optional progress is ignored and an explicit save repairs it',
      () async {
    await database
        .saveSetting(SettingsValue(playlistProgressSettingName, '{bad'));
    expect(progress.get(reference), isNull);
    await progress.save(reference, entries[0], entries: entries);
    expect(progress.get(reference)!.resolve(entries)!.index, 0);
    await progress.removeForVideo('first');
    expect(progress.get(reference), isNull);
    await progress.save(reference, entries[1], entries: entries);
    await progress.remove(reference);
    expect(progress.get(reference), isNull);
  });
}
