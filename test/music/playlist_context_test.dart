import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _first = MusicTrack(
    videoId: 'firstsong01', title: 'First song', durationSeconds: 100);
const _second = MusicTrack(
    videoId: 'secondsong2', title: 'Second song', durationSeconds: 100);
const _third = MusicTrack(
    videoId: 'thirdsong03', title: 'Third song', durationSeconds: 100);
const _collection = MusicCollection(
    id: 'PLmusicContext',
    title: 'Context playlist',
    tracks: [_first, _second, _first, _third]);

class _Catalog extends MusicCatalogService {
  @override
  Future<MusicCollection> getPlaylist(String id) async => _collection;
}

class _PlaylistCall {
  final List<Video> videos;
  final PlaylistReference reference;
  final int startIndex;
  final bool? audio;
  final Duration? startAt;

  _PlaylistCall(
      this.videos, this.reference, this.startIndex, this.audio, this.startAt);
}

class _Player extends TestPlayerCubit {
  final calls = <_PlaylistCall>[];
  int standaloneCalls = 0;

  _Player(super.initialState, super.settings);

  @override
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      PlaylistLoadSession? playlistLoader}) async {
    calls.add(_PlaylistCall(entries, reference, startIndex, audio, startAt));
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio, Duration? startAt, bool? playing}) async {
    standaloneCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MusicCatalogService previousCatalog;
  late Service previousService;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;
  late bool previousTv;

  setUp(() async {
    previousTv = isTv;
    isTv = false;
    db = await SembastSqfDb.createInMemory();
    previousCatalog = musicCatalogService;
    previousService = service;
    musicCatalogService = _Catalog();
    service = Service();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(PlayerState.init(null), settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    musicCatalogService = previousCatalog;
    service = previousService;
    isTv = previousTv;
  });

  Future<void> show(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: screen),
      ),
    ));
    await tester.pumpAndSettle();
  }

  PlaylistReference publicReference() => PlaylistReference(
      kind: PlaylistSourceKind.public,
      playlistId: _collection.id,
      profileId: db.profileId);

  Future<void> saveCheckpoint(WidgetTester tester,
      {required PlaylistReference reference,
      required List<Video> videos,
      required int index,
      bool completed = false}) async {
    final entries = assignPlaylistEntryIds(videos);
    await tester.runAsync(() async {
      await db.saveProgress(Progress(1, entries[index].videoId,
          positionSeconds: 95, durationSeconds: 100));
      await PlaylistProgressService.forProfile(db, db.profileId).save(
          reference, entries[index],
          entries: entries, completed: completed);
    });
  }

  testWidgets(
      'public Music row keeps all occurrences and selects the tapped one',
      (tester) async {
    await show(tester, const MusicScreen(playlistId: 'PLmusicContext'));
    await tester.tap(find.byKey(const ValueKey('music-song-2-firstsong01')));
    await tester.pumpAndSettle();

    final call = player.calls.single;
    expect(call.videos.map((video) => video.videoId),
        [_first.videoId, _second.videoId, _first.videoId, _third.videoId]);
    expect(call.videos.every((video) => video.musicMetadata != null), isTrue);
    expect(call.reference, publicReference());
    expect(call.startIndex, 2);
    expect(call.audio, isTrue);
    expect(call.startAt, Duration.zero);
    expect(player.standaloneCalls, 0);
  });

  testWidgets('Music Play all explicitly restarts the first occurrence',
      (tester) async {
    await saveCheckpoint(tester,
        reference: publicReference(),
        videos: _collection.tracks.map((track) => track.toVideo()).toList(),
        index: 2);
    await show(tester, const MusicScreen(playlistId: 'PLmusicContext'));
    await tester.tap(find.byKey(const ValueKey('music-play-all')));
    await tester.pumpAndSettle();

    expect(player.calls.single.startIndex, 0);
    expect(player.calls.single.startAt, Duration.zero);
    expect(player.calls.single.videos, hasLength(4));
  });

  testWidgets('explicit Music Resume keeps duplicate occurrence and exact time',
      (tester) async {
    await saveCheckpoint(tester,
        reference: publicReference(),
        videos: _collection.tracks.map((track) => track.toVideo()).toList(),
        index: 2);
    await show(tester, const MusicScreen(playlistId: 'PLmusicContext'));
    await tester.tap(find.byKey(const ValueKey('music-playlist-resume')));
    await tester.pumpAndSettle();

    expect(player.calls.single.startIndex, 2);
    expect(player.calls.single.startAt, const Duration(seconds: 95));
    expect(player.calls.single.audio, isTrue);
    expect(player.calls.single.videos, hasLength(4));
  });

  testWidgets('completed Music checkpoint advances to the next track at zero',
      (tester) async {
    await saveCheckpoint(tester,
        reference: publicReference(),
        videos: _collection.tracks.map((track) => track.toVideo()).toList(),
        index: 2,
        completed: true);
    await tester.runAsync(() => db.saveProgress(Progress(.42, _third.videoId,
        positionSeconds: 42, durationSeconds: 100)));
    await show(tester, const MusicScreen(playlistId: 'PLmusicContext'));
    await tester.tap(find.byKey(const ValueKey('music-playlist-resume')));
    await tester.pumpAndSettle();

    expect(player.calls.single.startIndex, 3);
    expect(player.calls.single.startAt, Duration.zero);
  });

  testWidgets(
      'local Music selection and Resume keep the complete local context',
      (tester) async {
    await tester.runAsync(() => MusicLibrarySession(app).createPlaylist(
        'Local context',
        [_first.toVideo(), _second.toVideo(), _third.toVideo()]));
    final playlist = service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.title == 'Local context');
    final reference = PlaylistReference.forPlaylist(playlist, db);
    await saveCheckpoint(tester,
        reference: reference, videos: playlist.videos, index: 1);
    await show(tester, const MusicLibraryPage());
    await tester.tap(find.text('Local context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second song'));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((video) => video.videoId),
        [_first.videoId, _second.videoId, _third.videoId]);
    expect(player.calls.single.reference, reference);
    expect(player.calls.single.startIndex, 1);
    expect(player.calls.single.startAt, Duration.zero);

    await tester.tap(find.byKey(const ValueKey('music-playlist-resume')));
    await tester.pumpAndSettle();
    expect(player.calls.last.startIndex, 1);
    expect(player.calls.last.startAt, const Duration(seconds: 95));
    expect(player.calls.last.audio, isTrue);
    expect(player.calls.last.videos, hasLength(3));
  });
}
