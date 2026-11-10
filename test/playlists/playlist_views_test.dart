import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/playlists/views/components/playlist_inner_view.dart';
import 'package:clipious/playlists/views/components/playlist_playback_actions.dart';
import 'package:clipious/playlists/views/screens/playlist.dart';
import 'package:clipious/playlists/views/tablet/playlist_inner_view.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _reference = PlaylistReference(
    kind: PlaylistSourceKind.local,
    playlistId: 'local:layout-test',
    profileId: 'default');
const _first = Video(
    videoId: 'repeated',
    queueEntryId: 'occurrence-1',
    title: 'First occurrence',
    author: 'Creator',
    lengthSeconds: 1200);
const _second = Video(
    videoId: 'repeated',
    queueEntryId: 'occurrence-2',
    title: 'Second occurrence',
    author: 'Creator',
    lengthSeconds: 1200);
const _playlist = Playlist(
    title: 'Layout test',
    playlistId: 'local:layout-test',
    author: '',
    videoCount: 2,
    videos: [_first, _second]);

class _Playlist extends PlaylistCubit {
  final PlaylistResumeTarget? target;
  bool readyToPlay;
  final starts = <bool?>[];
  final resumes = <bool>[];
  var retries = 0;

  _Playlist(super.initialState, super.player,
      {this.target, this.readyToPlay = true, super.loadSession})
      : super(reference: _reference);

  @override
  void onReady() {}

  @override
  bool get canPlayEntries => readyToPlay;

  @override
  PlaylistResumeTarget? get resumeTarget => target;

  @override
  Duration get resumePosition => const Duration(minutes: 12, seconds: 34);

  @override
  Future<void> play(bool? isAudio) async => starts.add(isAudio);

  @override
  Future<void> resume({bool acceptMissing = false}) async =>
      resumes.add(acceptMissing);

  @override
  Future<void> getAllVideos() async => retries++;
}

class _SnapshotLoader extends Fake implements PlaylistLoadSession {
  @override
  final bool complete;

  _SnapshotLoader({required this.complete});

  @override
  PlaylistReference get reference => _reference;

  @override
  Stream<PlaylistLoadSnapshot> get changes => const Stream.empty();

  @override
  void release() {}
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  final queued = <List<String>>[];

  _Downloads() : super(const DownloadManagerState());

  @override
  Future<int> addDownloads(Iterable<String> videoIds,
      {String quality = '720p',
      bool audioOnly = false,
      Map<String, Video> videosById = const {}}) async {
    queued.add(videoIds.toList());
    return videoIds.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late _Downloads downloads;
  _Playlist? playlist;

  setUp(() async {
    app_main.darkColorScheme = const ColorScheme.dark();
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    downloads = _Downloads();
  });

  tearDown(() async {
    await playlist?.close();
    playlist = null;
    await downloads.close();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget child,
      {Size size = const Size(390, 650),
      bool loading = false,
      String error = '',
      bool readyToPlay = true,
      Playlist data = _playlist,
      PlaylistLoadSession? loadSession,
      PlaylistResumeTarget? resume}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    playlist = _Playlist(
        PlaylistState(
            playlist: data,
            loading: loading,
            loadingProgress: loading ? 0.5 : 1,
            error: error),
        player,
        target: resume,
        readyToPlay: readyToPlay,
        loadSession: loadSession);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<DownloadManagerCubit>.value(value: downloads),
        BlocProvider<PlaylistCubit>.value(value: playlist!),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('loaded entries remain playable during metadata paging',
      (tester) async {
    await pump(tester, const PlaylistPlaybackActions(), loading: true);
    expect(playlist!.starts, isEmpty);
    await tester
        .tap(find.byKey(const ValueKey('playlist-play-from-beginning')));
    await tester.pump();
    expect(playlist!.starts, [null]);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resume shows its time and stays distinct from start over',
      (tester) async {
    await pump(tester, const PlaylistPlaybackActions(),
        resume: const PlaylistResumeTarget(1, _second));
    expect(find.text('Second occurrence · 12:34'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-resume')));
    await tester.pump();
    expect(playlist!.resumes, [false]);
    expect(playlist!.starts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared playback actions honor TV callbacks and audio mode',
      (tester) async {
    final starts = <bool?>[];
    final resumes = <bool>[];
    await pump(
        tester,
        PlaylistPlaybackActions(
          onPlayFromBeginning: (audio) async => starts.add(audio),
          onResume: (missing) async => resumes.add(missing),
        ),
        resume: const PlaylistResumeTarget(1, _second, missing: true));
    await tester.tap(find.byIcon(Icons.audiotrack));
    await tester
        .tap(find.byKey(const ValueKey('playlist-play-from-beginning')));
    await tester.tap(find.byKey(const ValueKey('playlist-resume')));
    await tester.pump();
    expect(starts, [true, null]);
    expect(resumes, [true]);
    expect(playlist!.starts, isEmpty);
    expect(playlist!.resumes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('checkpoint refresh rechecks playback and queue eligibility',
      (tester) async {
    await pump(tester, const PlaylistPlaybackActions());
    expect(find.byIcon(Icons.playlist_add), findsOneWidget);
    playlist!.readyToPlay = false;
    playbackHistoryRevision.value++;
    await tester.pump();
    final start = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('playlist-play-from-beginning')));
    expect(start.onPressed, isNull);
    expect(find.byIcon(Icons.playlist_add), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing resume asks through a separate next available action',
      (tester) async {
    await pump(tester, const PlaylistPlaybackActions(),
        resume: const PlaylistResumeTarget(1, _second, missing: true));
    expect(find.text('Continue with next available'), findsOneWidget);
    expect(find.textContaining('no longer available'), findsOneWidget);
    expect(playlist!.resumes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('playlist-resume')));
    await tester.pump();
    expect(playlist!.resumes, [true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist failure offers retry while retaining play action',
      (tester) async {
    await pump(tester, const PlaylistPlaybackActions(), error: 'offline');
    await tester.tap(find.byKey(const ValueKey('playlist-retry')));
    await tester.pump();
    expect(playlist!.retries, 1);
    await tester
        .tap(find.byKey(const ValueKey('playlist-play-from-beginning')));
    await tester.pump();
    expect(playlist!.starts, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone preserves repeated entries and scrolls on a short screen',
      (tester) async {
    final selected = <String?>[];
    await pump(
      tester,
      PlaylistInnerView(
        canDeleteVideos: false,
        openVideo: (_, video) => selected.add(video.queueEntryId),
        removeVideoFromPlaylist: (_, __) {},
      ),
      size: const Size(390, 360),
    );
    await tester.scrollUntilVisible(find.text('Second occurrence'), 100);
    await tester.tap(find.text('Second occurrence'));
    await tester.pump();
    expect(selected, ['occurrence-2']);
    expect(find.byKey(const ValueKey('swipe-occurrence-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('swipe-occurrence-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet keeps duplicate occurrences independently selectable',
      (tester) async {
    final selected = <String?>[];
    await pump(
      tester,
      TabletPlaylistInnerView(
        canDeleteVideos: false,
        openVideo: (_, video) => selected.add(video.queueEntryId),
        removeVideoFromPlaylist: (_, __) {},
      ),
      size: const Size(1024, 500),
      loading: true,
    );
    await tester.tap(find.text('First occurrence'));
    await tester.tap(find.text('Second occurrence'));
    await tester.pump();
    expect(selected, ['occurrence-1', 'occurrence-2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'tablet reveals a filtered entry before playing its revealed copy',
      (tester) async {
    final selected = <Video>[];
    await pump(
      tester,
      TabletPlaylistInnerView(
        canDeleteVideos: false,
        openVideo: (_, video) => selected.add(video),
        removeVideoFromPlaylist: (_, __) {},
      ),
      size: const Size(1024, 500),
      data: _playlist
          .copyWith(videos: [_first.copyWith(filtered: true), _second]),
    );

    await tester.tap(find.text('Tap to reveal'));
    await tester.pump();
    expect(selected, isEmpty);
    expect(find.text('Tap to reveal'), findsNothing);

    await tester.tap(find.text('First occurrence'));
    await tester.pump();
    expect(selected, hasLength(1));
    expect(selected.single.queueEntryId, 'occurrence-1');
    expect(selected.single.filtered, isFalse);
    expect(playlist!.state.playlist.videos.first.filtered, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final snapshot in [
    (
      name: 'cached previews after refresh fails',
      ready: false,
      complete: false
    ),
    (name: 'partial pages after loading fails', ready: true, complete: false),
  ]) {
    testWidgets('playlist download rejects ${snapshot.name}', (tester) async {
      late BuildContext context;
      await pump(tester, Builder(builder: (value) {
        context = value;
        return const SizedBox.shrink();
      }),
          error: 'offline',
          readyToPlay: snapshot.ready,
          loadSession: _SnapshotLoader(complete: snapshot.complete));

      await const PlaylistViewScreen(
              playlist: _playlist, canDeleteVideos: false)
          .downloadPlaylist(context);
      await tester.pump();
      expect(downloads.queued, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('complete playlist download queues each video once',
      (tester) async {
    late BuildContext context;
    await pump(tester, Builder(builder: (value) {
      context = value;
      return const SizedBox.shrink();
    }), loadSession: _SnapshotLoader(complete: true));

    await const PlaylistViewScreen(playlist: _playlist, canDeleteVideos: false)
        .downloadPlaylist(context);
    await tester.pump();
    expect(downloads.queued, [
      ['repeated']
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only playlist entries retain details and queue actions',
      (tester) async {
    await pump(
      tester,
      PlaylistInnerView(
        canDeleteVideos: false,
        openVideo: (_, __) {},
        removeVideoFromPlaylist: (_, __) {},
      ),
    );
    await tester.tap(find.byType(PlaylistEntryMenu).first);
    await tester.pumpAndSettle();
    expect(find.text('View details'), findsOneWidget);
    expect(find.byIcon(Icons.playlist_add), findsWidgets);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached previews wait for refresh before playback or queuing',
      (tester) async {
    final selected = <String?>[];
    await pump(
      tester,
      PlaylistInnerView(
        canDeleteVideos: false,
        openVideo: (_, video) => selected.add(video.queueEntryId),
        removeVideoFromPlaylist: (_, __) {},
      ),
      loading: true,
      readyToPlay: false,
    );
    final play = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('playlist-play-from-beginning')));
    expect(play.onPressed, isNull);
    await tester.tap(find.text('First occurrence'));
    expect(selected, isEmpty);
    await tester.tap(find.byType(PlaylistEntryMenu).first);
    await tester.pump(const Duration(milliseconds: 400));
    final queueItem = tester.widget<ListTile>(find.ancestor(
        of: find.byIcon(Icons.playlist_add), matching: find.byType(ListTile)));
    expect(queueItem.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });
}
