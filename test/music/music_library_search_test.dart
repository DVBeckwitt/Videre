import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_library_search.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/on_device_music_downloads.dart';
import 'package:clipious/music/views/components/music_library_search_results.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import '../test_app_cubit.dart';

class _Storage extends DownloadStorage {
  _Storage(this.probe);

  final Future<List<MusicFileProbe>> Function(
      String profileId, List<DownloadedVideo> files) probe;

  @override
  Future<List<MusicFileProbe>> probeMusicFiles(
          String profileId, Iterable<DownloadedVideo> downloads) =>
      probe(profileId, downloads.toList(growable: false));
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads(super.initialState);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const local = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const tree = 'content://documents/tree/primary%3AMusic';
  const shared = '$tree/document/primary%3AMusic%2Fshared.m4a';
  const copy = '$tree/document/primary%3AMusic%2Fcopy.m4a';
  const saved = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'saved-song1',
    title: 'Canción',
    subtitle: 'Ensemble',
    album: 'Été',
  );
  const downloaded = DownloadedVideo(
    videoId: 'saved-song1',
    title: 'Canción',
    lengthSeconds: 20,
    quality: 'audio',
    musicMetadata: MusicMetadata(title: 'Canción', artist: 'Ensemble'),
    audioOnly: true,
    downloadComplete: true,
  );
  late SembastSqfDb database;
  late Service originalService;
  late int networkCalls;

  MusicFileProbe proof(DownloadedVideo file, String identity) => (
        download: file,
        uri: file.storageUri ?? 'file:///data/app/${file.videoId}.m4a',
        identity: identity,
        byteLength: 777,
      );

  setUp(() async {
    originalService = service;
    networkCalls = 0;
    service = Service(httpClient: MockClient((_) async {
      networkCalls++;
      throw StateError('Library Search must not query the catalog.');
    }));
    database = await SembastSqfDb.createInMemory();
    messenger.setMockMethodCallHandler(local, (_) async => null);
  });

  tearDown(() async {
    expect(networkCalls, 0);
    messenger.setMockMethodCallHandler(local, null);
    service.httpClient.close();
    service = originalService;
    await database.close();
  });

  List<MusicLibrarySearchHit> search(MusicLibrarySearch reader, String query,
          {MusicLibrarySearchType type = MusicLibrarySearchType.all}) =>
      reader.search(query,
          database: database, profileId: database.profileId, type: type);

  test('matches saved songs and Music playlists within the active profile',
      () async {
    final reader = MusicLibrarySearch(deviceLibrary: LocalMusicLibrary());
    addTearDown(reader.dispose);
    final profile = database.profileId;
    final library = MusicLibraryService.forProfile(database, profile);
    await library.save(saved);
    await library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.playlist,
        id: 'PLrecordings',
        title: 'Canción radio',
        subtitle: 'Dúo'));
    await library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: 'artist', title: 'Ensemble'));
    await library.markLocalPlaylist('local:songs');
    await database.saveSetting(SettingsValue(
        localPlaylistsSetting,
        jsonEncode([
          const Playlist(
                  playlistId: 'local:songs',
                  title: 'Canción offline',
                  author: 'Été',
                  videoCount: 0)
              .toJson(),
          const Playlist(
                  playlistId: 'local:video',
                  title: 'Canción videos',
                  author: 'Ensemble',
                  videoCount: 0)
              .toJson(),
        ])));

    expect(search(reader, 'CANCIÓN été').map((hit) => hit.key),
        ['bookmark:song:saved-song1', 'playlist:local:songs']);
    expect(
        search(reader, 'cancion ete', type: MusicLibrarySearchType.songs)
            .map((hit) => hit.key),
        ['bookmark:song:saved-song1']);
    expect(
        search(reader, 'cancion', type: MusicLibrarySearchType.playlists)
            .map((hit) => hit.key),
        ['bookmark:playlist:PLrecordings', 'playlist:local:songs']);
    expect(
        search(reader, 'cancion ete', type: MusicLibrarySearchType.playlists)
            .single
            .key,
        'playlist:local:songs');
    expect(search(reader, 'duo radio').single.key,
        'bookmark:playlist:PLrecordings');
    expect(search(reader, 'ensemble').single.key, 'bookmark:song:saved-song1');
    expect(search(reader, 'missing cancion'), isEmpty);
    expect(search(reader, '   '), isEmpty);
    final person = await database.createProfile('Other');
    await database.useProfile(person.id);
    expect(search(reader, 'cancion'), isEmpty);
    expect(reader.search('cancion', database: database, profileId: profile),
        isEmpty);
  });

  test(
      'keeps separate readable copies and reacts to visibility and lost access',
      () async {
    var authorized = true;
    var pickCalls = 0;
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => authorized,
        'listTracks' => [
            {
              'uri': shared,
              'title': 'Canción',
              'artist': 'Ensemble',
              'visibilityKey': 'b' * 64,
            },
            {
              'uri': copy,
              'title': 'Canción',
              'artist': 'Ensemble',
              'visibilityKey': 'c' * 64,
            },
          ],
        'matchDownloadTracks' => {
            'shared': [shared],
          },
        'pickFolder' => ++pickCalls,
        _ => null,
      };
    });
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    final sharedRecord = downloaded.copyWith(
        videoId: 'shared', storageUri: shared, folderUri: tree);
    final missing = downloaded.copyWith(videoId: 'missing');
    final queued =
        downloaded.copyWith(videoId: 'pending', downloadComplete: false);
    final storage = _Storage((profile, files) async {
      expect(files, [sharedRecord, downloaded, missing]);
      return [
        if (authorized) proof(sharedRecord, 'a' * 64),
        proof(downloaded, 'd' * 64),
      ];
    });
    final reader = MusicLibrarySearch(
        deviceLibrary: library,
        downloads: OnDeviceMusicDownloads(storage: storage));
    addTearDown(reader.dispose);
    await MusicLibraryService.forProfile(database, database.profileId)
        .save(saved);
    Future<void> refresh() => reader.refreshFiles(
        database: database,
        profileId: database.profileId,
        downloads: [sharedRecord, downloaded, missing, queued],
        force: true);
    List<MusicLibrarySearchFile> files() => search(reader, 'Ensemble canción')
        .whereType<MusicLibrarySearchFile>()
        .toList();

    await refresh();
    expect(search(reader, 'cancion').whereType<MusicLibrarySearchBookmark>(),
        hasLength(1));
    expect(files().map((hit) => hit.entry.deviceTrack?.uri),
        unorderedEquals([shared, copy, null]));
    expect(files().map((hit) => hit.key).toSet(), hasLength(3));
    expect(
        search(reader, 'Ensemble canción', type: MusicLibrarySearchType.songs)
            .map((hit) => hit.key),
        search(reader, 'Ensemble canción').map((hit) => hit.key));
    expect(
        search(reader, 'Ensemble canción',
            type: MusicLibrarySearchType.playlists),
        isEmpty);
    expect(
        files()
            .singleWhere((hit) => hit.entry.download != null)
            .entry
            .downloadFileProof,
        'd' * 64);
    await library.hideTrack(
        library.visibleTracks.singleWhere((track) => track.uri == copy));
    expect(files().map((hit) => hit.entry.deviceTrack?.uri),
        unorderedEquals([shared, null]));

    authorized = false;
    await refresh();
    expect(files().single.entry.download, downloaded);
    expect(pickCalls, 0);
  });

  test('a pending earlier profile probe cannot publish after a switch',
      () async {
    final firstEntered = Completer<void>();
    final firstProof = Completer<List<MusicFileProbe>>();
    final initialProfile = database.profileId;
    final other = await database.createProfile('Other');
    final newDownload =
        downloaded.copyWith(profileId: other.id, videoId: 'new-copy');
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    final storage = _Storage((profile, files) {
      if (profile == initialProfile) {
        firstEntered.complete();
        return firstProof.future;
      }
      return Future.value([proof(newDownload, 'f' * 64)]);
    });
    final reader = MusicLibrarySearch(
        deviceLibrary: library,
        downloads: OnDeviceMusicDownloads(storage: storage));
    addTearDown(reader.dispose);
    final stale = reader.refreshFiles(
        database: database, profileId: initialProfile, downloads: [downloaded]);
    await firstEntered.future;
    await database.useProfile(other.id);
    expect(search(reader, 'cancion'), isEmpty);
    await reader.refreshFiles(
        database: database,
        profileId: other.id,
        downloads: [downloaded, newDownload]);
    firstProof.complete([proof(downloaded, 'e' * 64)]);
    await stale;
    final hit = search(reader, 'cancion').single as MusicLibrarySearchFile;
    expect(hit.entry.download, newDownload);
    expect(hit.entry.downloadFileProof, 'f' * 64);
  });

  test('retiring Search during alias lookup leaves the hidden proof unchanged',
      () async {
    final started = Completer<void>();
    final matched = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(local, (call) async {
      if (call.method == 'matchDownloadTracks') {
        if (!started.isCompleted) started.complete();
        return matched.future;
      }
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => true,
        'listTracks' => [
            {'uri': shared, 'title': 'Canción', 'visibilityKey': 'b' * 64},
          ],
        _ => null,
      };
    });
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    await library.refresh();
    final hidden = await library.hideTrack(library.visibleTracks.single);
    expect(hidden, isNotNull);
    final sharedRecord =
        downloaded.copyWith(storageUri: shared, folderUri: tree);
    final identity = 'a' * 64;
    final storage = _Storage((_, __) async => [proof(sharedRecord, identity)]);
    final reader = MusicLibrarySearch(
        deviceLibrary: library,
        downloads: OnDeviceMusicDownloads(storage: storage));
    addTearDown(reader.dispose);

    var current = true;
    Future<void> refresh() => reader.refreshFiles(
        database: database,
        profileId: database.profileId,
        downloads: [sharedRecord],
        isCurrent: () => current);
    final retired = refresh();
    await started.future;
    current = false;
    matched.complete({
      sharedRecord.videoId: [shared],
    });
    await retired;
    expect(library.hiddenDownloadProofs, isEmpty);
    expect(search(reader, 'cancion'), isEmpty);

    current = true;
    await refresh();
    expect(library.hiddenDownloadProofs, {identity});
    expect(search(reader, 'cancion'), isEmpty);
  });

  testWidgets('resuming Library cannot publish the earlier shared file proof',
      (tester) async {
    const channel = MethodChannel('videre/download_storage');
    db = database;
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    final file = downloaded.copyWith(storageUri: shared, folderUri: tree);
    final manager = _Downloads(DownloadManagerState(videos: [file]));
    addTearDown(app.close);
    addTearDown(manager.close);
    final earlier = Completer<Map<String, Object>>();
    var probes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'probeMusicFiles') return null;
      probes++;
      // The older call captured availability before the grant was revoked.
      return probes == 1 ? earlier.future : <String, Object>{};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<DownloadManagerCubit>.value(value: manager),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: MusicLibrarySearchResults(query: 'cancion', active: true),
        ),
      ),
    ));
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    expect(probes, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    earlier.complete({
      file.videoId: {'identity': 'a' * 64, 'byteLength': 777},
    });
    await tester.pumpAndSettle();
    expect(probes, 2);
    expect(find.text(file.title), findsNothing);
    expect(find.text('No results found.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
