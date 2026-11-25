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
