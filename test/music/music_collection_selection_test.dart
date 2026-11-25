import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

const _selectCollections = ValueKey('music-library-select-collections');
const _actions = ValueKey('music-collection-selection-actions');

const _sharedId = 'sharedSong1';
const _playlistOnlyId = 'playlist001';
const _albumOnlyId = 'albumSong01';
const _playlist = Playlist(
  playlistId: 'local:collection-test',
  title: 'Local playlist',
  author: '',
  videoCount: 3,
  videos: [
    Video(
        videoId: _sharedId,
        indexId: 'first-copy',
        musicMetadata: MusicMetadata(title: 'First copy', artist: 'Artist')),
    Video(
        videoId: _playlistOnlyId,
        musicMetadata: MusicMetadata(title: 'Playlist song', artist: 'Artist')),
    Video(
        videoId: _sharedId,
        indexId: 'second-copy',
        musicMetadata: MusicMetadata(title: 'Second copy', artist: 'Artist')),
  ],
);
const _albumId = 'OLAK5uy_collection_test';
const _album = MusicCollection(
  id: _albumId,
  title: 'Saved album',
  tracks: [
    MusicTrack(
        videoId: _albumOnlyId, title: 'Album song', albumPlaylistId: _albumId),
    MusicTrack(
        videoId: _sharedId, title: 'Album copy', albumPlaylistId: _albumId),
  ],
);

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void onReady() {}

  @override
  void initState() {}
}

class _Catalog extends MusicCatalogService {
  final requests = <String>[];
  Completer<MusicCollection>? pending;

  @override
  Future<MusicCollection> getPlaylist(String id) async {
    requests.add(id);
    expect(id, _albumId);
    final request = pending;
    return request == null ? _album : await request.future;
  }
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final plays = <({List<Video> tracks, bool shuffle})>[];
  final appended = <List<Video>>[];
  final playedSources = <List<PlaylistReference?>?>[];
  final appendedSources = <List<PlaylistReference?>?>[];

  @override
  int playlistGeneration = 0;

  void startMusic(Video video) {
    playlistGeneration++;
    final queue = PlayerState.init([video]);
    emit(queue.copyWith(
      currentlyPlaying: queue.videos.single,
      isAudio: true,
      isHidden: false,
      position: const Duration(seconds: 12),
    ));
  }

  @override
  Future<void> playMusicCollectionQueue(List<Video> tracks,
      {required String queueTitle,
      bool shuffle = false,
      bool Function()? isCurrent,
      List<PlaylistReference?>? recommendationSources}) async {
    expect(isCurrent?.call(), isNot(false));
    plays.add((tracks: List.of(tracks), shuffle: shuffle));
    playedSources.add(recommendationSources);
  }

  @override
  bool canEnqueueMusicSongs(List<Video> selection,
          {List<DownloadedVideo>? downloads}) =>
      selection.isNotEmpty;

  @override
  Future<bool> enqueueMusicCollectionQueue(List<Video> selection,
      {List<PlaylistReference?>? recommendationSources}) async {
    appended.add(List.of(selection));
    appendedSources.add(recommendationSources);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _App app;
  late _Catalog catalog;
  late _Player player;
  late TestSettingsCubit settings;
  late Service previousService;
  late MusicCatalogService previousCatalog;
  late bool previousTv;

  setUp(() async {
    previousService = service;
    previousCatalog = musicCatalogService;
    previousTv = app_globals.isTv;
    service = Service();
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    app = _App();
    catalog = _Catalog();
    musicCatalogService = catalog;
    player = _Player();
    settings = TestSettingsCubit(SettingsState.init(), app);
    await db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([_playlist.toJson()])));
    await MusicLibraryService.forProfile(db, db.profileId)
        .save(MusicLibraryEntry.collection(_album, album: false));
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
    musicCatalogService = previousCatalog;
    app_globals.isTv = previousTv;
  });

  Future<void> showPlaylists(WidgetTester tester) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MusicLibraryPage()),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Playlists'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseAction(WidgetTester tester, String action) async {
    await tester.tap(find.byKey(_actions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('plays a saved album and local playlist in display order',
      (tester) async {
    await showPlaylists(tester);
    await tester.tap(find.byKey(_selectCollections));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_album.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_playlist.title));
    await tester.pumpAndSettle();

    await chooseAction(tester, 'Play all');
    await tester.pumpAndSettle();

    expect(catalog.requests, [_albumId]);
    final played = player.plays.single;
    expect(played.shuffle, isFalse);
    expect(played.tracks.map((track) => track.videoId),
        [_sharedId, _playlistOnlyId, _sharedId, _albumOnlyId, _sharedId]);
    expect(played.tracks[0].musicMetadata?.title, 'First copy');
    expect(played.tracks[2].musicMetadata?.title, 'Second copy');
    expect(player.playedSources.single?.map((source) => source?.playlistId), [
      _playlist.playlistId,
      _playlist.playlistId,
      _playlist.playlistId,
      _albumId,
      _albumId
    ]);
    expect(played.tracks.map((track) => track.indexId), everyElement(isNull));
    expect(played.tracks.last.musicMetadata?.albumPlaylistId, _albumId);
    expect(player.appended, isEmpty);
  });

  testWidgets('appends all selected copies without starting playback',
      (tester) async {
    player.startMusic(_playlist.videos.first);
    final playing = player.state;
    await showPlaylists(tester);
    await tester.tap(find.byKey(_selectCollections));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();

    await chooseAction(tester, 'Add to queue');
    await tester.pumpAndSettle();

    expect(player.appended.single.map((track) => track.videoId),
        [_sharedId, _playlistOnlyId, _sharedId, _albumOnlyId, _sharedId]);
    expect(player.appendedSources.single?.map((source) => source?.playlistId), [
      _playlist.playlistId,
      _playlist.playlistId,
      _playlist.playlistId,
      _albumId,
      _albumId
    ]);
    expect(player.plays, isEmpty);
    expect(player.state, same(playing));
    expect(find.byKey(_actions), findsNothing);
  });

  testWidgets('Back cancels a pending collection load from list selection',
      (tester) async {
    catalog.pending = Completer<MusicCollection>();
    await showPlaylists(tester);
    await tester.tap(find.byTooltip('List view'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text(_album.title));
    await tester.pumpAndSettle();

    await chooseAction(tester, 'Shuffle');
    expect(catalog.requests, [_albumId]);
    await tester.binding.handlePopRoute();
    await tester.pump();
    catalog.pending!.complete(_album);
    await tester.pumpAndSettle();

    expect(player.plays, isEmpty);
    expect(player.appended, isEmpty);
    expect(find.byKey(_actions), findsNothing);
    expect(find.byKey(_selectCollections), findsOneWidget);
    expect(find.byTooltip('Grid view'), findsOneWidget);
    expect(find.text(_album.title), findsOneWidget);
  });

  testWidgets('a pending collection append never targets a replacement queue',
      (tester) async {
    catalog.pending = Completer<MusicCollection>();
    player.startMusic(_playlist.videos.first);
    await showPlaylists(tester);
    await tester.tap(find.byKey(_selectCollections));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_album.title));
    await tester.pumpAndSettle();

    await chooseAction(tester, 'Add to queue');
    expect(catalog.requests, [_albumId]);
    player.startMusic(_playlist.videos[1]);
    final replacement = player.state;
    catalog.pending!.complete(_album);
    await tester.pumpAndSettle();

    expect(player.plays, isEmpty);
    expect(player.appended, isEmpty);
    expect(player.state, same(replacement));
  });
}
