import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_playlist_folder_service.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void onReady() {}

  @override
  void initState() {}
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  PlaylistReference? source;
  List<Video> queue = const [];
  int? start;

  @override
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      bool shuffleOnce = false,
      PlaylistLoadSession? playlistLoader,
      bool fromMusic = false,
      bool songTap = false}) async {
    source = reference;
    queue = entries;
    start = startIndex;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service previousService;
  late bool previousTv;
  late _App app;
  late _Player player;
  late TestSettingsCubit settings;
  late MusicLibraryService library;
  late MusicPlaylistFolderService folders;

  setUp(() async {
    previousService = service;
    previousTv = app_globals.isTv;
    service = Service();
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(db, db.profileId);
    folders = MusicPlaylistFolderService.forProfile(db, db.profileId);
    app = _App();
    player = _Player();
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
    app_globals.isTv = previousTv;
  });

  testWidgets('nested folders browse moved playlists and keep resume and queue',
      (tester) async {
    const first = Video(
        videoId: 'abcdefghijk',
        title: 'First track',
        musicMetadata: MusicMetadata(title: 'First track', artist: 'Artist'));
    const second = Video(
        videoId: 'lmnoprstuvw',
        title: 'Second track',
        musicMetadata: MusicMetadata(title: 'Second track', artist: 'Artist'));
    const publicId = 'PLfolderTest';

    final source = (await tester.runAsync(() async {
      final id = (await service.createPlayList('Trip playlist', 'local'))!;
      await service.addVideoToPlaylist(id, first.videoId, video: first);
      await service.addVideoToPlaylist(id, second.videoId, video: second);
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.playlist,
          id: publicId,
          title: 'Public playlist'));
      final playlist =
          service.getLocalPlaylists().singleWhere((p) => p.playlistId == id);
      final reference = PlaylistReference.forPlaylist(playlist, db);
      final entries = assignPlaylistEntryIds(playlist.videos);
      expect(
          await PlaylistProgressService.forProfile(db, db.profileId)
              .save(reference, entries[1], entries: entries),
          isTrue);
      return reference;
    }))!;
    final public = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: publicId,
        profileId: db.profileId);
    final (parentId, childId) = (await tester.runAsync(() async {
      final parent = await folders.createFolder('Trips');
      final child = await folders.createFolder('Autumn', parentId: parent.id);
      return (parent.id, child.id);
    }))!;
    final localRow = find.byKey(ValueKey('music-local-${source.playlistId}'));
    final publicRow =
        find.byKey(const ValueKey('music-saved-playlist-$publicId'));

    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: settings),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: MusicLibraryPage()))));
    await tester.pumpAndSettle();

    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    await tap('music-library-tab-playlists');
    await tap('music-playlist-folder-$parentId');
    expect(
        find.byKey(ValueKey('music-playlist-folder-$childId')), findsOneWidget);
    expect(localRow, findsNothing);
    await back();
    expect(localRow, findsOneWidget);
    expect(publicRow, findsOneWidget);
    expect(
        find.byKey(ValueKey('music-playlist-folder-$childId')), findsNothing);

    await tap('music-playlist-move-${source.playlistId}');
    await tap('music-playlist-folder-destination-$parentId');
    await tap('music-playlist-folder-destination-$childId');
    final destination =
        find.byKey(const ValueKey('music-playlist-folder-move-here'));
    expect(tester.widget<TextButton>(destination).onPressed, isNotNull);
    await tester.tap(
        find.text(AppLocalizations.of(tester.element(destination))!.cancel));
    await tester.pumpAndSettle();
    expect(folders.snapshot.folderFor(source), isNull);

    await tester.runAsync(() async {
      await folders.movePlaylist(source, childId);
      await folders.movePlaylist(public, childId);
    });
    await tester.pumpAndSettle();
    expect(localRow, findsNothing);
    expect(publicRow, findsNothing);

    await tap('music-playlist-folder-$parentId');
    expect(localRow, findsNothing);
    await tap('music-playlist-folder-$childId');
    expect(localRow, findsOneWidget);
    expect(publicRow, findsOneWidget);
    await tap('music-library-layout');
    await tap('music-local-${source.playlistId}');
    await tap('music-playlist-resume');
    expect(player.source, source);
    expect(player.queue.map((entry) => entry.videoId),
        [first.videoId, second.videoId]);
    expect(player.start, 1);

    await back();
    expect(localRow, findsOneWidget);
    await back();
    expect(
        find.byKey(ValueKey('music-playlist-folder-$childId')), findsOneWidget);
    expect(localRow, findsNothing);
    await back();
    expect(find.byKey(ValueKey('music-playlist-folder-$parentId')),
        findsOneWidget);
    expect(
        find.byKey(ValueKey('music-playlist-folder-$childId')), findsNothing);
  });
}
