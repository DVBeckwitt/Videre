import 'dart:async';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/on_device_music_downloads.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

class _ProbedStorage extends DownloadStorage {
  final Map<String, Future<List<MusicFileProbe>>> replies = {};

  @override
  Future<List<MusicFileProbe>> probeMusicFiles(
          String profileId, Iterable<DownloadedVideo> downloads) =>
      replies[profileId]!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const local = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const tree = 'content://documents/tree/primary%3AMusic';
  const shared = '$tree/document/primary%3AMusic%2Fshared.flac';
  const copy = '$tree/document/primary%3AMusic%2Fcopy.flac';
  const downloaded = DownloadedVideo(
    videoId: 'shared',
    title: 'Same title',
    lengthSeconds: 20,
    quality: 'audio',
    musicMetadata: MusicMetadata(title: 'Same title', artist: 'Band'),
    audioOnly: true,
    downloadComplete: true,
    storageUri: shared,
    folderUri: tree,
  );
  final proof = 'a' * 64;
  MusicFileProbe probe(DownloadedVideo file, String identity) => (
        download: file,
        uri: file.storageUri ?? 'file:///data/app/${file.videoId}.flac',
        identity: identity,
        byteLength: 777,
      );

  tearDown(() => messenger.setMockMethodCallHandler(local, null));

  test('remember a proven hidden shared copy when source access goes away',
      () async {
    var authorized = true;
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => authorized ? {'uri': tree, 'name': 'Music'} : null,
        'listTracks' => [
            {'uri': shared, 'title': 'Same title', 'visibilityKey': 'b' * 64},
            {'uri': copy, 'title': 'Same title', 'visibilityKey': 'c' * 64},
          ],
        'matchDownloadTracks' => {
            'shared': [shared]
          },
        _ => throw MissingPluginException(),
      };
    });
    final database = SembastSqfDb(
        await newDatabaseFactoryMemory().openDatabase('download-alias'));
    addTearDown(database.close);
    await database.getProfiles();
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    await library.refresh();
    final original = library.tracks.first;
    await library.hideTrack(original);

    final independent = downloaded.copyWith(
        videoId: 'private', storageUri: null, folderUri: null);
    final storage = _ProbedStorage();
    storage.replies[database.profileId] = Future.value([
      probe(downloaded, proof),
      probe(independent, 'd' * 64),
    ]);
    final downloads = OnDeviceMusicDownloads(storage: storage);
    addTearDown(downloads.dispose);
    await downloads
        .refresh(library, database.profileId, [downloaded, independent]);
    final visible = downloads.entries(library, database.profileId);
    expect(
        visible
            .where((entry) => entry.deviceTrack != null)
            .single
            .deviceTrack!
            .uri,
        copy);
    expect(visible.where((entry) => entry.download != null).single.download,
        independent);
    expect(library.hiddenDownloadProofs, {proof});

    authorized = false;
    final reopened = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(reopened.dispose);
    await reopened.initialize();
    await downloads
        .refresh(reopened, database.profileId, [downloaded, independent]);
    expect(downloads.entries(reopened, database.profileId).single.download,
        independent);

    await reopened.restoreTrack(reopened.hiddenTracks.single);
    expect(
        downloads
            .entries(reopened, database.profileId)
            .map((row) => row.download),
        [downloaded, independent]);
  });

  test('a folder rule suppresses only the currently verified download alias',
      () async {
    var authorized = true;
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => authorized ? {'uri': tree, 'name': 'Music'} : null,
        'listTracks' => [
            {
              'uri': shared,
              'title': 'Same title',
              'visibilityKey': 'b' * 64,
              'folderLocations': [
                {'key': 'c' * 64, 'label': 'Music / Drafts'},
              ],
            },
            {'uri': copy, 'title': 'Same title', 'visibilityKey': 'd' * 64},
          ],
        'matchDownloadTracks' => {
            'shared': [shared]
          },
        _ => throw MissingPluginException(),
      };
    });
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    await library.refresh();
    final original = library.tracks.first;

    final independent = downloaded.copyWith(
      videoId: 'separate',
      storageUri: '$tree/document/opaque-separate',
    );
    final private = downloaded.copyWith(
        videoId: 'private', storageUri: null, folderUri: null);
    for (final file in [downloaded, independent, private]) {
      await database.upsertDownload(file);
    }
    final storage = _ProbedStorage();
    storage.replies[database.profileId] = Future.value([
      probe(downloaded, proof),
      probe(independent, 'e' * 64),
      probe(private, 'f' * 64),
    ]);
    final downloads = OnDeviceMusicDownloads(storage: storage);
    addTearDown(downloads.dispose);
    final managed = [downloaded, independent, private];
    List<String> visible(LocalMusicLibrary source) => downloads
        .entries(source, database.profileId)
        .map((entry) => entry.deviceTrack?.uri ?? entry.download!.videoId)
        .toList();

    await downloads.refresh(library, database.profileId, managed);
    expect(visible(library), [shared, copy, 'separate', 'private']);
    await library.setFolderExcluded(original.folderLocations.single, true);
    expect(visible(library), [copy, 'separate', 'private']);
    expect(library.hiddenDownloadProofs, isEmpty);
    expect(
        database.getDownloadByVideoId(downloaded.videoId)?.storageUri, shared);

    await library.setExclusionOverride(original, true);
    expect(visible(library), [shared, copy, 'separate', 'private']);
    await library.setExclusionOverride(original, false);
    expect(visible(library), [copy, 'separate', 'private']);

    authorized = false;
    final detached = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(detached.dispose);
    await detached.initialize();
    await downloads.refresh(detached, database.profileId, managed);
    expect(visible(detached), ['shared', 'separate', 'private']);
  });

  test('late probe cannot publish an earlier profile’s downloads', () async {
    messenger.setMockMethodCallHandler(local, (call) async => null);
    final library = LocalMusicLibrary();
    addTearDown(library.dispose);
    final first = Completer<List<MusicFileProbe>>();
    final second = downloaded.copyWith(profileId: 'other', videoId: 'other');
    final storage = _ProbedStorage()
      ..replies['default'] = first.future
      ..replies['other'] = Future.value([probe(second, proof)]);
    final downloads = OnDeviceMusicDownloads(storage: storage);
    addTearDown(downloads.dispose);

    final stale = downloads.refresh(library, 'default', [downloaded]);
    await downloads.refresh(library, 'other', [downloaded, second]);
    first.complete([probe(downloaded, proof)]);
    await stale;
    expect(downloads.entries(library, 'default'), isEmpty);
    expect(downloads.entries(library, 'other').single.download, second);
  });
}
