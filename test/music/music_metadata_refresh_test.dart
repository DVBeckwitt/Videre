import 'dart:async';

import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'abcdefghijk';
final _original = MusicLibraryEntry(
  kind: MusicLibraryKind.song,
  id: _id,
  title: 'Old song title',
  subtitle: 'Artists A and B',
  artistCredits: [
    MusicArtistCredit(name: 'Artist A', id: 'UCaaaaaaaaaaaaaaaaaaaaaa'),
    MusicArtistCredit(name: 'Artist B', id: 'UCbbbbbbbbbbbbbbbbbbbbbb'),
  ],
  album: 'Selected release',
  albumPlaylistId: 'OLAK5uy_release1',
  durationSeconds: 42,
  thumbnails: [
    ImageObject(null, 'https://lh3.googleusercontent.com/cover', 60, 60)
  ],
);
final _fresh = MusicLibraryEntry(
  kind: MusicLibraryKind.song,
  id: _id,
  title: 'Current song title',
  subtitle: 'Uploader',
  album: 'Stock release',
  durationSeconds: 43,
  thumbnails: [ImageObject(null, '/vi/abcdefghijk/mqdefault.jpg', 320, 180)],
  usesVideoThumbnails: true,
);

void main() {
  late SembastSqfDb database;
  late MusicLibraryService library;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(database, database.profileId);
    await library.save(_original);
  });

  tearDown(() => database.close());

  test('refresh updates one bookmark in place and preserves richer metadata',
      () async {
    const another = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'aaaaaaaaaaa', title: 'Another song');
    await library.save(another);
    final original = library.entries.last;
    expect(
        await library.refreshSongMetadata(_id,
            load: (_) async => _fresh, isCurrent: () => true),
        isTrue);
    final refreshed = library.entries.last;
    expect(library.entries.map((entry) => entry.id), [another.id, _id]);
    expect(refreshed.title, _fresh.title);
    expect(refreshed.subtitle, original.subtitle);
    expect(refreshed.toJson()['artistCredits'],
        original.toJson()['artistCredits']);
    expect(refreshed.album, original.album);
    expect(refreshed.albumPlaylistId, original.albumPlaylistId);
    expect(refreshed.durationSeconds, _fresh.durationSeconds);
    expect(refreshed.toJson()['thumbnails'], original.toJson()['thumbnails']);
    expect(refreshed.toVideo().videoId, _id);
  });

  test('refresh preserves a display title edited while loading', () async {
    final response = Completer<MusicLibraryEntry>();
    final refresh = library.refreshSongMetadata(_id,
        load: (_) => response.future, isCurrent: () => true);
    expect(
        await library.setSavedSongTitle(_id, 'My saved title',
            isCurrent: () => true),
        isTrue);
    response.complete(_fresh);

    expect(await refresh, isTrue);
    expect(library.entries.single.title, _fresh.title);
    expect(library.entries.single.savedTitle, 'My saved title');
  });

  test('refresh replaces the stock fields present in the source response',
      () async {
    await library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: _id,
        title: 'Old',
        subtitle: 'Old author'));
    expect(
        await library.refreshSongMetadata(_id,
            load: (_) async => _fresh, isCurrent: () => true),
        isTrue);
    expect(library.entries.single.toJson(), _fresh.toJson());
  });

  test('missing, failed and wrong-ID replies do not modify the bookmark',
      () async {
    final before = library.entries.single.toJson();
    for (final load in <Future<MusicLibraryEntry?> Function(bool Function())>[
      (_) async => null,
      (_) async => throw StateError('Connection failed'),
      (_) async => const MusicLibraryEntry(
          kind: MusicLibraryKind.song, id: 'zzzzzzzzzzz', title: 'Wrong song'),
    ]) {
      await expectLater(
          library.refreshSongMetadata(_id, load: load, isCurrent: () => true),
          throwsStateError);
      expect(library.entries.single.toJson(), before);
    }
  });

  test('refresh discards replies after the active session changes', () async {
    final response = Completer<MusicLibraryEntry>();
    var current = true;
    final attempt = library.refreshSongMetadata(_id,
        load: (_) => response.future, isCurrent: () => current);
    current = false;
    response.complete(_fresh);
    expect(await attempt, isFalse);
    expect(library.entries.single.toJson(), _original.toJson());
  });

  test('an older refresh cannot overwrite a newer request in the same profile',
      () async {
    final response = Completer<MusicLibraryEntry>();
    final oldAttempt = library.refreshSongMetadata(_id,
        load: (_) => response.future, isCurrent: () => true);
    final sameProfile =
        MusicLibraryService.forProfile(database, database.profileId);
    expect(
        await sameProfile.refreshSongMetadata(_id,
            load: (_) async => _fresh, isCurrent: () => true),
        isTrue);
    response.complete(_original);
    expect(await oldAttempt, isFalse);
    expect(library.entries.single.title, _fresh.title);
  });

  test('removing and re-saving identical data invalidates an in-flight refresh',
      () async {
    final response = Completer<MusicLibraryEntry>();
    final removal = library.remove(MusicLibraryKind.song, _id);
    final replacing = library.save(_original);
    final attempt = library.refreshSongMetadata(_id,
        load: (_) => response.future, isCurrent: () => true);
    await removal;
    await replacing;
    response.complete(_fresh);
    expect(await attempt, isFalse);
    expect(library.entries.single.toJson(), _original.toJson());
  });

  test('a refresh started during a replacement cannot overwrite it', () async {
    final transactionStarted = Completer<void>();
    final releaseTransaction = Completer<void>();
    final blocker = database.db.transaction((_) async {
      transactionStarted.complete();
      await releaseTransaction.future;
    });
    await transactionStarted.future;

    const replacement = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: _id, title: 'Newly saved recording');
    final save = library.save(replacement);
    await Future<void>.delayed(Duration.zero);
    expect(library.entries.single.title, _original.title);
    final response = Completer<MusicLibraryEntry>();
    final request = library.refreshSongMetadata(_id,
        load: (_) => response.future, isCurrent: () => true);

    releaseTransaction.complete();
    await blocker;
    await save;
    response.complete(_fresh);
    expect(await request, isFalse);
    expect(library.entries.single.toJson(), replacement.toJson());
  });
}
