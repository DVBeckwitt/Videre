import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const repeated = Video(
    videoId: 'abcdefghijk',
    musicMetadata: MusicMetadata(title: 'Same song', artist: 'Artist'),
  );
  const ordinary = Video(videoId: '12345678901');
  const other = Video(
    videoId: 'lmnoprstuvw',
    musicMetadata: MusicMetadata(title: 'Other song', artist: 'Artist'),
  );
  const extra = Video(videoId: 'ZYXWVUTSRQP');
  const initial = Playlist(
    playlistId: 'local:music-test',
    title: 'Music test',
    author: '',
    videoCount: 4,
    videos: [repeated, ordinary, other, repeated],
  );
  late Service api;
  late PlaylistReference reference;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    api = Service();
    reference = PlaylistReference.forPlaylist(initial, db);
    final legacy = initial.toJson()..remove('localEditLocked');
    await db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([legacy])));
  });
  tearDown(() => db.close());

  Playlist read([Service? service]) => (service ?? api)
      .getLocalPlaylists()
      .singleWhere((playlist) => playlist.playlistId == initial.playlistId);

  List<String> ids(Playlist playlist) =>
      [for (final video in playlist.videos) video.indexId!];

  test('moving one copy persists its ID and preserves the resume target',
      () async {
    final progress = PlaylistProgressService.forProfile(db, db.profileId);
    final oldRows = assignPlaylistEntryIds(initial.videos);
    await progress.save(reference, oldRows.last, entries: oldRows);
    final original = read();
    final order = ids(original);
    final moved = [order[3], order[1], order[2], order[0]];
    expect(order.toSet(), hasLength(4));

    expect(
      await api.reorderLocalPlaylist(reference,
          expectedOrder: order, order: moved, isCurrent: () => true),
      isTrue,
    );

    final reopened = read(Service());
    expect(ids(reopened), moved);
    expect(reopened.videos[1].videoId, ordinary.videoId);
    expect(reopened.videos[0].queueEntryId, original.videos[3].queueEntryId);
    final target = progress.get(reference)!.resolve(reopened.videos)!;
    expect(target.index, 0);
    expect(target.video.indexId, order[3]);

    expect(
      await api.reorderLocalPlaylist(reference,
          expectedOrder: moved, order: order, isCurrent: () => true),
      isTrue,
    );
    expect(ids(read(Service())), order);
  });

  test('bulk undo restores exact occurrences while preserving a later rename',
      () async {
    final original = read();
    final order = ids(original);
    final undo = await api.removeLocalPlaylistSongs(reference,
        entryIds: {order[0], order[2]}, isCurrent: () => true);

    expect(undo, isNotNull);
    final reduced = read(Service());
    expect(ids(reduced), [order[1], order[3]]);
    expect(reduced.videoCount, 2);
    expect(reduced.videos.last.queueEntryId, original.videos.last.queueEntryId);

    expect(
      await api.renameLocalPlaylist(reference, 'Renamed',
          isCurrent: () => true),
      isTrue,
    );
    expect(
      await api.undoLocalPlaylistSongRemoval(undo!, isCurrent: () => true),
      isTrue,
    );

    final restored = read(Service());
    expect(restored.title, 'Renamed');
    expect(restored.videoCount, original.videoCount);
    expect(ids(restored), order);
    expect(jsonEncode(restored.videos), jsonEncode(original.videos));
    expect(
      await api.undoLocalPlaylistSongRemoval(undo, isCurrent: () => true),
      isFalse,
    );
  });

  test('bulk removal with a missing occurrence leaves every row in place',
      () async {
    final order = ids(read());

    expect(
      await api.removeLocalPlaylistSongs(reference,
          entryIds: {order.first, 'missing'}, isCurrent: () => true),
      isNull,
    );

    expect(ids(read(Service())), order);
  });

  test('a stale removal preview preserves a replacement at the same occurrence',
      () async {
    final preview = read();
    final order = ids(preview);
    final replacement = repeated.copyWith(
      videoId: 'replacement',
      indexId: order.last,
    );
    final updated = preview.copyWith(
      videos: [...preview.videos.take(order.length - 1), replacement],
    );
    await db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([updated.toJson()])));
    expect(ids(read()), order);

    expect(
      await api.removeLocalPlaylistSongs(
        reference,
        entryIds: {order.last},
        expectedEntries: preview.videos,
        isCurrent: () => true,
      ),
      isNull,
    );

    final reopened = read(Service());
    expect(ids(reopened), order);
    expect(reopened.videos.last.videoId, replacement.videoId);
  });

  test('a serialized lock rejects bulk removal and undo', () async {
    final order = ids(read());
    Future<bool> setLocked(bool locked) =>
        api.setLocalPlaylistEditLocked(reference,
            locked: locked, isCurrent: () => true);
    final entries = {order[0], order[2]};

    final initialLock = setLocked(true);
    final blockedRemoval = api.removeLocalPlaylistSongs(reference,
        entryIds: entries, isCurrent: () => true);
    expect(await initialLock, isTrue);
    expect(await blockedRemoval, isNull);
    expect(ids(read(Service())), order);

    expect(await setLocked(false), isTrue);
    final undo = await api.removeLocalPlaylistSongs(reference,
        entryIds: entries, isCurrent: () => true);
    expect(undo, isNotNull);

    final laterLock = setLocked(true);
    final blockedUndo =
        api.undoLocalPlaylistSongRemoval(undo!, isCurrent: () => true);
    expect(await laterLock, isTrue);
    expect(await blockedUndo, isFalse);
    expect(read(Service()).isEditLocked, isTrue);
    expect(ids(read()), [order[1], order[3]]);
  });

  test('bulk undo preserves an intervening addition', () async {
    final order = ids(read());
    final undo = await api.removeLocalPlaylistSongs(reference,
        entryIds: {order[0], order[2]}, isCurrent: () => true);
    expect(undo, isNotNull);

    final adding = api.addVideoToPlaylist(reference.playlistId, extra.videoId,
        video: extra);
    final undoing =
        api.undoLocalPlaylistSongRemoval(undo!, isCurrent: () => true);
    await adding;
    expect(await undoing, isFalse);

    final edited = read(Service());
    expect(ids(edited).take(2), [order[1], order[3]]);
    expect(edited.videos.last.videoId, extra.videoId);
    expect(edited.videoCount, 3);
  });

  test('reorder undo preserves a newer order of the same occurrences',
      () async {
    final original = ids(read());
    final reordered = [original[3], original[1], original[2], original[0]];
    final edited = [original[2], original[1], original[3], original[0]];
    Future<bool> move(List<String> expectedOrder, List<String> order) =>
        api.reorderLocalPlaylist(reference,
            expectedOrder: expectedOrder, order: order, isCurrent: () => true);

    expect(await move(original, reordered), isTrue);
    expect(await move(reordered, edited), isTrue);
    expect(await move(reordered, original), isFalse);
    expect(ids(read(Service())), edited);
  });

  test('replacing one legacy copy uses its latest slot and preserves order',
      () async {
    final reviewed = assignPlaylistEntryIds(initial.videos).last;
    final original = read();
    final order = ids(original);
    final moved = [order[0], order[3], order[1], order[2]];
    expect(
      await api.reorderLocalPlaylist(reference,
          expectedOrder: order, order: moved, isCurrent: () => true),
      isTrue,
    );

    final replacement = other.copyWith(
        indexId: 'another-playlist-entry',
        queueEntryId: 'another-queue-entry',
        dashUrl: 'https://example.com/temporary-manifest');
    expect(
      await api.replaceLocalPlaylistMusicEntry(reference, reviewed, replacement,
          isCurrent: () => true),
      isTrue,
    );

    final reopened = read(Service());
    expect(ids(reopened), moved);
    expect(reopened.videoCount, original.videoCount);
    expect(jsonEncode(reopened.videos[0]), jsonEncode(original.videos[0]));
    expect(jsonEncode(reopened.videos[2]), jsonEncode(original.videos[1]));
    expect(jsonEncode(reopened.videos[3]), jsonEncode(original.videos[2]));
    final changed = reopened.videos[1];
    expect(changed.videoId, other.videoId);
    expect(changed.musicMetadata?.toJson(), other.musicMetadata?.toJson());
    expect(changed.dashUrl, isNull);
    expect(changed.queueEntryId, playlistSourceEntryId(changed));
    expect(changed.queueEntryId, isNot(reopened.videos[3].queueEntryId));

    expect(
      await api.replaceLocalPlaylistMusicEntry(
          reference, reviewed, repeated.copyWith(videoId: 'NEWRECORD01'),
          isCurrent: () => true),
      isFalse,
    );
    expect(jsonEncode(read().videos), jsonEncode(reopened.videos));
  });

  test('replacement rejects inactive, locked and ineligible occurrences',
      () async {
    final original = read();
    final selected = original.videos.last;
    Future<bool> replace(Video entry, Video replacement,
            {bool current = true}) =>
        api.replaceLocalPlaylistMusicEntry(reference, entry, replacement,
            isCurrent: () => current);

    expect(await replace(selected, other, current: false), isFalse);
    expect(await replace(selected, repeated), isFalse);
    expect(await replace(selected, ordinary), isFalse);
    expect(await replace(original.videos[1], other), isFalse);
    final locking = api.setLocalPlaylistEditLocked(reference,
        locked: true, isCurrent: () => true);
    final replacing = replace(selected, other);
    expect(await locking, isTrue);
    expect(await replacing, isFalse);
    expect(jsonEncode(read().videos), jsonEncode(original.videos));
  });

  test('lock is persisted and serialized with concurrent membership edits',
      () async {
    final order = ids(read());
    final locking = api.setLocalPlaylistEditLocked(reference,
        locked: true, isCurrent: () => true);
    final moving = api.reorderLocalPlaylist(reference,
        expectedOrder: order,
        order: order.reversed.toList(),
        isCurrent: () => true);
    expect(await locking, isTrue);
    expect(await moving, isFalse);
    expect(read(Service()).isEditLocked, isTrue);
    await expectLater(
        api.addVideoToPlaylist(reference.playlistId, extra.videoId,
            video: extra),
        throwsStateError);
    await expectLater(
        api.removeLocalPlaylistEntry(reference.playlistId, read().videos.last),
        throwsStateError);
    await expectLater(
        api.deleteUserPlaylist(reference.playlistId), throwsStateError);
    await expectLater(
        api.deleteMusicPlaylist(reference.playlistId, isCurrent: () => true),
        throwsStateError);
    expect(api.getRecentlyDeletedMusicPlaylists(), isEmpty);
    expect(ids(read()), order);

    expect(
      await api.setLocalPlaylistEditLocked(reference,
          locked: false, isCurrent: () => true),
      isTrue,
    );
    expect(read(Service()).isEditLocked, isFalse);
    await api.addVideoToPlaylist(reference.playlistId, extra.videoId,
        video: extra);
    expect(read().videos.last.videoId, extra.videoId);
    expect(
      await api.reorderLocalPlaylist(reference,
          expectedOrder: order,
          order: order.reversed.toList(),
          isCurrent: () => true),
      isFalse,
    );
    expect(ids(read()).take(order.length), order);
    expect(read().videos.last.videoId, extra.videoId);
  });
}
