import 'dart:io';

import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/services/watch_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';

void main() {
  const videoId = 'abcdefghijk';
  const otherVideoId = 'lmnopqrstuv';

  test(
    'edited notes survive reopening and stay local to the video and profile',
    () async {
      final directory = await Directory.systemTemp.createTemp('watch-notes-');
      final path = '${directory.path}/notes.db';
      var database = SembastSqfDb(await databaseFactoryIo.openDatabase(path));
      addTearDown(() async {
        await database.close();
        await directory.delete(recursive: true);
      });
      await database.getProfiles();
      final originalProfile = database.profileId;
      final otherProfile = await database.createProfile('Another viewer');

      final notes = WatchNotes.forVideo(database, videoId);
      await notes.save(text: 'Opening thought', position: null);
      await notes.save(
        text: '  Private second note  ',
        position: const Duration(seconds: 42, milliseconds: 345),
      );
      final second = notes.list()[1];
      await notes.save(
        existing: second,
        text: 'Private second note\nEdited',
        position: second.position,
      );

      await database.close();
      database = SembastSqfDb(await databaseFactoryIo.openDatabase(path));

      final reopened = WatchNotes.forVideo(database, videoId).list();
      expect(reopened.map((note) => note.text), [
        'Opening thought',
        'Private second note\nEdited',
      ]);
      expect(reopened.first.position, isNull);
      expect(reopened[1].id, second.id);
      expect(
        reopened[1].position,
        const Duration(seconds: 42, milliseconds: 345),
      );
      expect(WatchNotes.forVideo(database, otherVideoId).list(), isEmpty);
      expect(
        database.getAllSettings().map((setting) => setting.value),
        everyElement(isNot(contains('Private second note'))),
      );
      final backup = await database.exportBackup();
      expect(backup.encode(), isNot(contains('Private second note')));

      await database.useProfile(otherProfile.id);
      expect(WatchNotes.forVideo(database, videoId).list(), isEmpty);
      await database.useProfile(originalProfile);
      expect(WatchNotes.forVideo(database, videoId).list(), hasLength(2));
    },
  );

  test(
    'overlapping saves from separate note lists keep both additions',
    () async {
      final database = await SembastSqfDb.createInMemory();
      addTearDown(database.close);
      final first = WatchNotes.forVideo(database, videoId);
      final second = WatchNotes.forVideo(database, videoId);

      await Future.wait([
        first.save(text: 'Start', position: Duration.zero),
        second.save(text: 'Without a moment', position: null),
      ]);

      final notes = first.list();
      expect(notes.map((note) => note.text), ['Start', 'Without a moment']);
      expect(notes.map((note) => note.id).toSet(), hasLength(2));
      expect(notes.map((note) => note.position), [Duration.zero, null]);

      final otherVideo = WatchNotes.forVideo(database, otherVideoId);
      final invalid = otherVideo.save(
        existing: notes.first,
        text: 'Wrong video',
        position: null,
      );
      final valid = otherVideo.save(text: 'Independent note', position: null);
      await expectLater(invalid, throwsStateError);
      await valid;
      expect(otherVideo.list().single.text, 'Independent note');
      expect(first.list().map((note) => note.text), [
        'Start',
        'Without a moment',
      ]);
    },
  );
}
