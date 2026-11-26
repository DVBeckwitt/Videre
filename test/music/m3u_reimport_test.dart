import 'package:clipious/music/models/device_playlist_track.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

Video _track(String title, String proof, int rowId) => devicePlaylistVideo(
      LocalMusicTrack(
        uri: 'content://media/external/audio/media/$rowId',
        title: title,
        visibilityKey: List.filled(64, proof).join(),
      ),
    )!;

void main() {
  late SembastSqfDb database;
  late MockClient client;
  late Service playlists;
  const title = 'Morning walk';
  final first = _track('First', 'a', 1);
  final second = _track('Second', 'b', 2);

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    client =
        MockClient((_) async => throw StateError('Unexpected HTTP request'));
    playlists = Service(httpClient: client);
  });

  tearDown(() async {
    client.close();
    await database.close();
  });

  Playlist stored(String id, {Service? reader}) => (reader ?? playlists)
      .getLocalPlaylists(database: database)
      .singleWhere((playlist) => playlist.playlistId == id);

  Future<String> createPlaylist() async =>
      (await playlists.createLocalPlaylistWithEntries(
          title, [first, second, first],
          database: database))!;

  test('reimport retains identity, metadata, and successive repeat occurrences',
      () async {
    final id = await createPlaylist();
    final before = stored(id);
    final firstOriginal = before.videos[0].indexId;
    final secondOriginal = before.videos[1].indexId;
    final firstRepeat = before.videos[2].indexId;
    final originalIds = before.videos.map((video) => video.indexId).toSet();
    expect(originalIds, hasLength(3));
    expect(originalIds, everyElement(isNotEmpty));

    await playlists.replaceLocalDevicePlaylistEntries(
      id,
      before.videos,
      [second, first, first, first],
      database: database,
      isCurrent: () => true,
    );

    final after = stored(id, reader: Service(httpClient: client));
    expect(after.videoCount, 4);
    expect(after.videos.map((video) => video.videoId),
        [second.videoId, first.videoId, first.videoId, first.videoId]);
    expect(after.videos.map((video) => video.indexId), [
      secondOriginal,
      firstOriginal,
      firstRepeat,
      allOf(isNotEmpty, isNot(isIn(originalIds))),
    ]);
    expect(
        after.copyWith(
          videos: before.videos,
          videoCount: before.videoCount,
          updated: before.updated,
        ),
        before);
  });

  test('an approved move retains the original proof and occurrence IDs',
      () async {
    final id = await createPlaylist();
    final reviewed = stored(id);
    final moved = _track('First moved', 'c', 3);

    await playlists.replaceLocalDevicePlaylistEntries(
      id,
      reviewed.videos,
      [moved, moved],
      database: database,
      isCurrent: () => true,
      resolveDeviceId: (id) => id == first.videoId ? moved.videoId : null,
    );

    final entries = stored(id).videos;
    expect(
        entries.map((entry) => entry.videoId), [first.videoId, first.videoId]);
    expect(entries.map((entry) => entry.indexId),
        [reviewed.videos.first.indexId, reviewed.videos.last.indexId]);
    expect(entries.map((entry) => entry.title), ['First moved', 'First moved']);
  });

  test('reimport rejects a stale review when the same file was re-added',
      () async {
    final id = await createPlaylist();
    final reviewed = stored(id);
    expect(
        await playlists.removeLocalPlaylistEntry(id, reviewed.videos.last,
            database: database),
        isTrue);
    expect(
        await playlists.appendLocalPlaylistEntries(id, [first],
            allowDuplicates: true, database: database),
        1);
    final edited = stored(id);
    final savedSetting = database.getSettings(localPlaylistsSetting)!.value;
    expect(edited.videos.map((video) => video.videoId),
        reviewed.videos.map((video) => video.videoId));
    expect(edited.videos.last.indexId, isNot(reviewed.videos.last.indexId));

    await expectLater(
      playlists.replaceLocalDevicePlaylistEntries(
        id,
        reviewed.videos,
        [second],
        database: database,
        isCurrent: () => true,
      ),
      throwsStateError,
    );

    expect(database.getSettings(localPlaylistsSetting)!.value, savedSetting);
  });

  test('reimport checks its source guard before changing saved entries',
      () async {
    final id = await createPlaylist();
    final reviewed = stored(id);
    final savedSetting = database.getSettings(localPlaylistsSetting)!.value;
    var isCurrent = true;
    final pending = playlists.replaceLocalDevicePlaylistEntries(
      id,
      reviewed.videos,
      [second],
      database: database,
      isCurrent: () => isCurrent,
    );

    isCurrent = false;
    await expectLater(pending, throwsStateError);

    expect(database.getSettings(localPlaylistsSetting)!.value, savedSetting);
  });
}
