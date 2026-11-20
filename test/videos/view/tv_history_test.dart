import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/tv/screens/tv_player_view.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video_in_list.dart';
import 'package:clipious/videos/states/history.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:clipious/videos/views/components/history_video.dart';
import 'package:clipious/videos/views/components/history.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';
import 'package:clipious/videos/views/tv/components/video_item.dart';
import 'package:clipious/videos/views/tv/screens/history.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  @override
  void initState() {}

  @override
  void onReady() {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }
}

class _HistoryService extends Service {
  @override
  Future<void> syncHistory() async {}

  final serverPages = <int, List<String>>{};
  final historyRequests = <int>[];
  final metadataRequests = <String>[];
  final failingPages = <int>{};
  final failingVideos = <String>{};
  final removedVideos = <String>[];
  int clearCalls = 0;
  Future<List<String>> Function(int page)? historyResponse;
  Future<Video> Function(String videoId)? metadataResponse;

  @override
  Future<void> clearUserHistory() async {
    clearCalls++;
    serverPages.clear();
  }

  @override
  Future<void> deleteFromUserHistory(String videoId) async {
    removedVideos.add(videoId);
    for (final page in serverPages.values) {
      page.remove(videoId);
    }
  }

  @override
  Future<List<String>> getUserHistory(int page, int maxResults) async {
    historyRequests.add(page);
    if (failingPages.contains(page)) throw StateError('History unavailable');
    return await historyResponse?.call(page) ?? serverPages[page] ?? [];
  }

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      VideoLoadObserver? loadObserver,
      void Function(BackendPlayback request)? onBackendRequest}) async {
    metadataRequests.add(videoId);
    if (failingVideos.contains(videoId)) throw StateError('Video unavailable');
    return await metadataResponse?.call(videoId) ??
        Video(
            videoId: videoId,
            title: 'Video $videoId',
            author: 'A channel',
            lengthSeconds: 100);
  }
}

class _CacheManager implements cache.BaseCacheManager {
  @override
  Stream<cache.FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    yield cache.FileInfo(const LocalFileSystem().file('assets/icon.png'),
        cache.FileSource.Cache, DateTime.utc(2100), url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final calls = <({List<Video> videos, bool? audio, Duration? startAt})>[];
  bool failPlayback = false;
  final offline = <({String id, bool music})>[];

  @override
  Future<void> playOfflineVideos(List<DownloadedVideo> videos,
      {int startIndex = 0, bool fromMusic = false}) async {
    offline.add((id: videos[startIndex].videoId, music: fromMusic));
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      bool fromMusic = false}) async {
    if (failPlayback) throw StateError('Playback unavailable');
    calls.add((videos: videos, audio: audio, startAt: startAt));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Router extends AppRouter {
  _Router() : super(hasServer: true);

  final pushed = <PageRouteInfo>[];

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) {
    pushed.add(route);
    return Future<T?>.value();
  }
}

// Capture the TV player route without starting a native decoder in this test.
class _Navigator extends Navigator {
  const _Navigator({super.key, required super.onGenerateRoute});

  @override
  NavigatorState createState() => _NavigatorState();
}

class _NavigatorState extends NavigatorState {
  final pushed = <Route<dynamic>>[];
  bool failPlayback = false;

  @override
  Future<T?> push<T extends Object?>(Route<T> route) {
    if (failPlayback) {
      return Future<T?>.error(StateError('Playback unavailable'));
    }
    pushed.add(route);
    return Completer<T?>().future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CachedNetworkImageProvider.defaultCacheManager = _CacheManager();
  late Service originalService;
  late _HistoryService history;
  late _App app;

  setUp(() async {
    originalService = service;
    service = history = _HistoryService();
    db = await SembastSqfDb.createInMemory();
    app = _App();
  });

  tearDown(() async {
    await app.close();
    await db.close();
    service = originalService;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> seed(String id,
      {double progress = 0, DateTime? watchedAt, String? title}) async {
    final cached = HistoryVideoCache(
        id, title ?? 'Video $id', 'A channel', 'https://instance.example/image',
        lengthSeconds: 100);
    if (watchedAt != null) cached.created = watchedAt;
    await db.recordPlaybackHistory(PlaybackHistoryOrigin.video, cached);
    if (progress > 0) {
      await db.saveProgress(Progress.named(videoId: id, progress: progress));
    }
  }

  Future<void> mount(WidgetTester tester,
      {Future<void> Function(BuildContext, Video)? onOpenVideo,
      Size viewport = const Size(1280, 720)}) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TvHistoryScreen(onOpenVideo: onOpenVideo),
      ),
    ));
    await settle(tester);
  }

  Future<void> selectControl(WidgetTester tester, String key) async {
    final button = find.byKey(ValueKey(key));
    final align =
        find.descendant(of: button, matching: find.byType(Align)).first;
    Focus.of(tester.element(align)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
  }

  Finder card(String id) => find.byWidgetPredicate(
      (widget) => widget is TvVideoItem && widget.video.videoId == id);

  BuildContext cardContext(WidgetTester tester, String id) =>
      tester.element(find
          .descendant(of: card(id), matching: find.byType(GestureDetector))
          .first);

  Future<void> focusCard(WidgetTester tester, String id) async {
    Focus.of(cardContext(tester, id)).requestFocus();
    await tester.pump();
  }

  testWidgets('an empty phone history can refresh after a new play',
      (tester) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: HistoryView()),
      ),
    ));
    await settle(tester);
    await tester.runAsync(() => seed('first'));
    await tester.tap(find.byTooltip('Refresh'));
    await settle(tester);
    expect(find.byKey(const ValueKey('first')), findsOneWidget);
  });

  testWidgets('phone history swipes preserve rows and holding offers deletion',
      (tester) async {
    await tester.runAsync(() async {
      await seed('keep');
      await seed('held');
    });
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HistoryView()),
      ),
    ));
    await settle(tester);
    final row = find.byKey(const ValueKey('held'));
    await tester.drag(row, const Offset(-700, 0));
    await settle(tester);
    await tester.drag(row, const Offset(700, 0));
    await settle(tester);
    expect(db.getHistoryVideoByVideoId('held'), isNotNull);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.longPress(row);
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(db.getHistoryVideoByVideoId('held'), isNotNull);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settle(tester);
    expect(db.getHistoryVideoByVideoId('held'), isNotNull);

    await tester.longPress(row);
    await settle(tester);
    // Inserting another item cannot retarget the held row's delete action.
    await tester.runAsync(() => seed('newest'));
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await settle(tester);
    expect(db.getHistoryVideoByVideoId('held'), isNull);
    expect(db.getHistoryVideoByVideoId('keep'), isNotNull);
    expect(db.getHistoryVideoByVideoId('newest'), isNotNull);
    expect(row, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'video history keeps legacy entries in the combined view and deletes only video plays',
      (tester) async {
    await tester.runAsync(() async {
      await seed('both', progress: 0.4, title: 'Watched as a video');
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.music,
          HistoryVideoCache('both', 'Played from Music', '', ''));
      await db.upsertHistoryVideo(
          HistoryVideoCache('legacy', 'Earlier history', '', ''));
    });
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HistoryView()),
        )));
    await settle(tester);
    expect(find.text('Watched as a video'), findsOneWidget);
    expect(find.text('Played from Music'), findsNothing);
    expect(find.byKey(const ValueKey('legacy')), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('both')));
    await settle(tester);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Watched as a video')),
        findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await settle(tester);
    expect(find.byKey(const ValueKey('both')), findsNothing);
    expect(db.getVideoProgress('both'), 0.4);
    await tester.tap(find.byKey(const ValueKey('history-source')));
    await settle(tester);
    await tester.tap(find.text('All history on this device').last);
    await settle(tester);
    expect(find.text('Played from Music'), findsOneWidget);
    expect(find.byKey(const ValueKey('legacy')), findsOneWidget);
    expect(history.removedVideos, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final changeAccount in [false, true]) {
    testWidgets(
        'phone pending history hold guards account change: $changeAccount',
        (tester) async {
      const server = Server(
          url: 'https://instance.example',
          authToken: 'test-token',
          inUse: true);
      await tester.runAsync(() => db.upsertServer(server));
      app.setServer(server);
      history.serverPages[1] = ['pending'];
      final pending = Completer<Video>();
      history.metadataResponse = (_) => pending.future;
      await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HistoryView()),
        ),
      ));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('history-source')));
      await settle(tester);
      await tester.tap(find.text('All history on your server').last);
      await settle(tester);
      await tester.longPress(find.byKey(const ValueKey('pending')));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('pending'), findsOneWidget);
      if (changeAccount) {
        app.setServer(const Server(
            url: 'https://instance.example', authToken: 'other-test-token'));
        await settle(tester);
      }
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await settle(tester);
      expect(history.removedVideos, changeAccount ? isEmpty : ['pending']);
      expect(find.byKey(const ValueKey('pending')),
          changeAccount ? findsOneWidget : findsNothing);
      pending.complete(const Video(videoId: 'pending', title: 'Late metadata'));
      await settle(tester);
      expect(db.getHistoryVideoByVideoId('pending'), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final changeAccount in [false, true]) {
    testWidgets(
        'phone bulk history confirmation guards account change: $changeAccount',
        (tester) async {
      const server = Server(
          url: 'https://instance.example',
          authToken: 'test-token',
          inUse: true);
      await tester.runAsync(() => db.upsertServer(server));
      app.setServer(server);
      history.serverPages[1] = ['pending-clear'];
      await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HistoryView()),
        ),
      ));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('history-source')));
      await settle(tester);
      await tester.tap(find.text('All history on your server').last);
      await settle(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(history.clearCalls, 0);

      if (changeAccount) {
        app.setServer(const Server(
            url: 'https://instance.example', authToken: 'other-test-token'));
        await settle(tester);
      }
      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await settle(tester);
      expect(history.clearCalls, changeAccount ? 0 : 1);
      expect(history.serverPages.isEmpty, !changeAccount);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final transition in ['unchanged', 'profile', 'disposed']) {
    testWidgets('phone bulk local history confirmation guards $transition',
        (tester) async {
      final originalProfile = db.profileId;
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.runAsync(() => seed('original-history'));
      await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, showHistory, _) =>
                  showHistory ? const HistoryView() : const SizedBox.shrink(),
            ),
          ),
        ),
      ));
      await settle(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      if (transition == 'profile') {
        await tester.runAsync(() async {
          final next = await db.createProfile('Next person');
          await db.useProfile(next.id);
          await seed('next-history');
        });
      } else if (transition == 'disposed') {
        visible.value = false;
      }
      await settle(tester);
      // A dialog can remain on its Navigator after the originating history
      // list has been removed or the active person's database has changed.
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await settle(tester);

      expect(
          db
              .forProfile(originalProfile)
              .getHistoryVideoByVideoId('original-history'),
          transition == 'unchanged' ? isNull : isNotNull);
      if (transition == 'profile') {
        expect(db.getHistoryVideoByVideoId('next-history'), isNotNull);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final tv in [false, true]) {
    for (final selection in [
      'Music',
      'video',
      'unavailable Music',
      'saved Music',
      'saved video'
    ]) {
      testWidgets('${tv ? 'TV' : 'phone'} history opens $selection selection',
          (tester) async {
        final originalIsTv = app_main.isTv;
        app_main.isTv = tv;
        addTearDown(() => app_main.isTv = originalIsTv);
        const music = MusicMetadata(
            title: 'Saved song', artist: 'Artist', album: 'Album');
        final musicSource = !selection.endsWith('video');
        final saved = selection.startsWith('saved');
        if (saved) {
          await tester.runAsync(() => db.upsertDownload(const DownloadedVideo(
              videoId: 'song',
              title: 'Saved file',
              lengthSeconds: 105,
              quality: 'audio',
              accountId: 'source-account',
              audioOnly: true,
              downloadComplete: true)));
        }
        await tester.runAsync(() => db.recordPlaybackHistory(
            musicSource
                ? PlaybackHistoryOrigin.music
                : PlaybackHistoryOrigin.video,
            HistoryVideoCache('song', 'Saved song', 'Artist', '',
                musicMetadata: musicSource ? music : null,
                playedFromDownload: saved,
                downloadAccountId: saved ? 'source-account' : null)));
        final player = _Player()
          ..failPlayback = selection == 'unavailable Music';
        final router = _Router();
        final navigator = GlobalKey<_NavigatorState>();
        addTearDown(player.close);
        addTearDown(router.dispose);
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MultiBlocProvider(
          providers: [
            BlocProvider<AppCubit>.value(value: app),
            BlocProvider<PlayerCubit>.value(value: player),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: StackRouterScope(
              controller: router,
              stateHash: 0,
              child: _Navigator(
                key: navigator,
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => tv
                      ? TvHistoryScreen(music: musicSource)
                      : Scaffold(
                          body: HistoryVideoView(
                              videoId: 'song',
                              source: musicSource
                                  ? HistorySource.music
                                  : HistorySource.video)),
                ),
              ),
            ),
          ),
        ));
        await settle(tester);
        navigator.currentState!.failPlayback = selection == 'unavailable Music';

        if (tv) {
          await focusCard(tester, 'song');
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          tester.widget<CompactVideo>(find.byType(CompactVideo)).onTap!();
        }
        await settle(tester);

        if (saved) {
          expect(player.calls, isEmpty);
          expect(router.pushed, isEmpty);
          if (tv) {
            final route = navigator.currentState!.pushed.single
                as MaterialPageRoute<void>;
            final screen = route.builder(cardContext(tester, 'song'));
            expect(screen, isA<TvPlayerScreen>());
            route.dispose();
          } else {
            expect(player.offline, [(id: 'song', music: musicSource)]);
          }
        } else if (selection == 'video') {
          expect(router.pushed.single.routeName,
              tv ? TvVideoRoute.name : VideoRoute.name);
          expect(player.calls, isEmpty);
          expect(navigator.currentState!.pushed, isEmpty);
        } else if (selection == 'unavailable Music') {
          final context = tv
              ? cardContext(tester, 'song')
              : tester.element(find.byType(HistoryVideoView));
          expect(find.text(AppLocalizations.of(context)!.musicPlaybackError),
              findsOneWidget);
          expect(router.pushed, isEmpty);
        } else if (tv) {
          expect(navigator.currentState!.pushed, hasLength(1));
          final route =
              navigator.currentState!.pushed.single as MaterialPageRoute<void>;
          final dynamic screen = route.builder(cardContext(tester, 'song'));
          final videos = screen.videos as List<Video>;
          expect(videos.single.musicMetadata?.album, 'Album');
          expect(player.calls, isEmpty);
          route.dispose();
        } else {
          expect(player.calls, hasLength(1));
          expect(
              player.calls.single.videos.single.musicMetadata?.album, 'Album');
          expect(player.calls.single.audio, isTrue);
          expect(player.calls.single.startAt, Duration.zero);
        }
        if (selection != 'video') expect(router.pushed, isEmpty);
        expect(history.metadataRequests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('guest TV history uses cached videos and opens with the remote',
      (tester) async {
    await tester.runAsync(() => seed('offline', progress: 0.37));
    final opened = <String>[];
    await mount(tester,
        onOpenVideo: (_, video) async => opened.add(video.videoId));

    expect(find.text('All history on your server'), findsNothing);
    expect(card('offline'), findsOneWidget);
    expect(history.metadataRequests, isEmpty);
    expect(history.historyRequests, isEmpty);
    expect(
        cardContext(tester, 'offline').read<VideoInListCubit>().state.progress,
        0.37);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(Focus.of(cardContext(tester, 'offline')).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);

    expect(opened, ['offline']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow TV history fits a two-line title and channel name',
      (tester) async {
    const title = 'A long video title that wraps across two lines on TV';
    await tester.runAsync(() => seed('long-title', title: title));
    final opened = <String>[];
    await mount(tester,
        viewport: const Size(720, 360),
        onOpenVideo: (_, video) async => opened.add(video.videoId));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(Focus.of(cardContext(tester, 'long-title')).hasFocus, isTrue);
    expect(tester.getRect(find.text('A channel')).bottom,
        lessThanOrEqualTo(tester.getRect(card('long-title')).bottom));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(opened, ['long-title']);
    expect(tester.takeException(), isNull);
  });

  Widget tightCard(Video video) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            // Simulate a 1.5-pixel line-metric shortfall with test fonts.
            child: SizedBox(
              width: 208,
              height: 183,
              child: TvVideoItem(video: video, autoFocus: true),
            ),
          ),
        ),
      );

  testWidgets('TV card fits mixed-script metadata when line metrics run tall',
      (tester) async {
    await tester.pumpWidget(tightCard(const Video(
      videoId: '9bZkp7q19f0',
      title: 'PSY - GANGNAM STYLE(강남스타일) M/V',
      author: 'officialpsy',
      lengthSeconds: 253,
    )));
    await settle(tester);

    final bounds = tester.getRect(find.byType(TvVideoItem));
    expect(tester.getRect(find.text('officialpsy')).bottom,
        lessThanOrEqualTo(bounds.bottom));
    expect(tester.getSize(find.byType(VideoThumbnailView)).aspectRatio,
        closeTo(16 / 9, 0.0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV card shows duration for an expired premiere', (tester) async {
    await tester.pumpWidget(tightCard(const Video(
      videoId: 'expired-premiere',
      title: 'An earlier premiere',
      author: 'Channel',
      lengthSeconds: 253,
      isUpcoming: true,
      premiereTimestamp: 1,
    )));
    await settle(tester);

    expect(find.text('04:13'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server browsing never adds unwatched videos to device history',
      (tester) async {
    await tester.runAsync(() => seed('local', progress: 0.42));
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    history.serverPages[1] = ['remote'];
    await mount(tester);

    await selectControl(tester, 'tv-history-server');
    expect(card('remote'), findsOneWidget);
    expect(card('local'), findsNothing);
    expect(db.getLocalHistory().map((video) => video.videoId), ['local']);
    expect(db.getVideoProgress('local'), 0.42);
    expect(db.getVideoProgress('remote'), 0);

    await selectControl(tester, 'tv-history-local');
    expect(card('local'), findsOneWidget);
    expect(card('remote'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history request failure offers a working remote retry',
      (tester) async {
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    history.serverPages[1] = ['recovered'];
    history.failingPages.add(1);
    await mount(tester);
    await selectControl(tester, 'tv-history-server');

    expect(find.text('Could not fetch data'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    history.failingPages.clear();
    final retry =
        find.ancestor(of: find.text('Retry'), matching: find.byType(TvButton));
    final align =
        find.descendant(of: retry, matching: find.byType(Align)).first;
    Focus.of(tester.element(align)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);

    expect(history.historyRequests, [1, 1]);
    expect(card('recovered'), findsOneWidget);
    expect(find.text('Could not fetch data'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one unavailable video does not block its playable neighbors',
      (tester) async {
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    history.serverPages[1] = ['missing', 'available'];
    history.failingVideos.add('missing');
    await mount(tester);
    await selectControl(tester, 'tv-history-server');

    expect(card('available'), findsOneWidget);
    expect(card('missing'), findsNothing);
    expect(find.byKey(const ValueKey('tv-history-video-retry-missing')),
        findsOneWidget);
    history.failingVideos.clear();
    await selectControl(tester, 'tv-history-video-retry-missing');

    expect(card('available'), findsOneWidget);
    expect(card('missing'), findsOneWidget);
    expect(history.metadataRequests.where((id) => id == 'available').length, 1);
    expect(db.getLocalHistory(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('revisited video moves to the front without losing focus',
      (tester) async {
    await tester.runAsync(() async {
      await seed('resume', progress: 0.25, watchedAt: DateTime.utc(2026, 1, 1));
      await seed('recent', watchedAt: DateTime.utc(2026, 1, 2));
    });
    final returned = Completer<void>();
    await mount(tester, onOpenVideo: (_, video) => returned.future);
    await focusCard(tester, 'resume');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.runAsync(() =>
        seed('resume', progress: 0.61, watchedAt: DateTime.utc(2026, 1, 3)));
    returned.complete();
    await settle(tester);

    final context = cardContext(tester, 'resume');
    expect(
        tester
            .widgetList<TvVideoItem>(find.byType(TvVideoItem))
            .map((item) => item.video.videoId),
        ['resume', 'recent']);
    expect(context.read<VideoInListCubit>().state.progress, 0.61);
    expect(Focus.of(context).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'returning to a deeply scrolled video keeps its new position visible',
      (tester) async {
    await tester.runAsync(() async {
      for (var index = 0; index < 24; index++) {
        await seed('entry-$index',
            progress: 0.25, watchedAt: DateTime.utc(2026, 1, 24 - index));
      }
    });
    final returned = Completer<void>();
    await mount(tester, onOpenVideo: (_, video) => returned.future);
    await tester.scrollUntilVisible(find.text('Video entry-15'), 400,
        scrollable: find.descendant(
            of: find.byType(GridView), matching: find.byType(Scrollable)));
    await settle(tester);
    await focusCard(tester, 'entry-15');
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.runAsync(() =>
        seed('entry-15', progress: 0.61, watchedAt: DateTime.utc(2026, 2, 1)));
    returned.complete();
    await settle(tester);

    final viewport = tester.getRect(find.byType(GridView));
    final selected = tester.getRect(card('entry-15'));
    expect(selected.top, greaterThanOrEqualTo(viewport.top));
    expect(selected.bottom, lessThanOrEqualTo(viewport.bottom));
    final context = cardContext(tester, 'entry-15');
    expect(Focus.of(context).hasFocus, isTrue);
    expect(context.read<VideoInListCubit>().state.progress, 0.61);
    expect(db.getLocalHistory().first.videoId, 'entry-15');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a failed next page retries that page without losing earlier videos',
      (tester) async {
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    history.serverPages[1] = List.generate(20, (index) => 'page1-$index');
    history.serverPages[2] = ['tail'];
    history.failingPages.add(2);
    await mount(tester);
    await selectControl(tester, 'tv-history-server');
    await selectControl(tester, 'tv-history-more');

    expect(history.historyRequests, [1, 2]);
    expect(card('page1-0'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    history.failingPages.clear();
    await selectControl(tester, 'tv-history-more');
    expect(history.historyRequests, [1, 2, 2]);
    expect(card('page1-0'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.scrollUntilVisible(find.text('Video tail'), 400,
        scrollable: find.descendant(
            of: find.byType(GridView), matching: find.byType(Scrollable)));
    await settle(tester);

    expect(card('tail'), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-history-more')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'overlapping history pages keep unique cards and continue pagination',
      (tester) async {
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    history.serverPages[1] = List.generate(20, (index) => 'page-$index');
    // A newly watched video on another device can shift the page boundary.
    history.serverPages[2] = List.generate(20, (index) => 'page-${index + 19}');
    history.serverPages[3] = ['tail'];
    await mount(tester);
    await selectControl(tester, 'tv-history-server');
    await selectControl(tester, 'tv-history-more');
    await tester.scrollUntilVisible(find.text('Video page-18'), 400,
        scrollable: find.descendant(
            of: find.byType(GridView), matching: find.byType(Scrollable)));
    await settle(tester);

    expect(card('page-19'), findsOneWidget);
    expect(history.historyRequests, [1, 2]);
    expect(find.byKey(const ValueKey('tv-history-more')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await selectControl(tester, 'tv-history-more');
    await tester.scrollUntilVisible(find.text('Video tail'), 400,
        scrollable: find.descendant(
            of: find.byType(GridView), matching: find.byType(Scrollable)));
    await settle(tester);
    expect(history.historyRequests, [1, 2, 3]);
    expect(card('tail'), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-history-more')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'changing accounts does not show a late response from the old account',
      (tester) async {
    app.setServer(const Server(
        url: 'https://instance.example', authToken: 'test-account-a'));
    final pending = Completer<List<String>>();
    history.historyResponse = (_) => pending.future;
    await mount(tester);
    await selectControl(tester, 'tv-history-server');
    history.historyResponse = (_) async => ['account-b'];
    app.setServer(const Server(
        url: 'https://instance.example', authToken: 'test-account-b'));
    await settle(tester);
    pending.complete(['account-a']);
    await settle(tester);

    expect(card('account-b'), findsOneWidget);
    expect(card('account-a'), findsNothing);
    expect(history.metadataRequests, ['account-b']);
    expect(db.getLocalHistory(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing source discards a late server response',
      (tester) async {
    await tester.runAsync(() => seed('local'));
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    final pending = Completer<List<String>>();
    history.historyResponse = (_) => pending.future;
    await mount(tester);
    await selectControl(tester, 'tv-history-server');
    await selectControl(tester, 'tv-history-local');
    pending.complete(['stale']);
    await settle(tester);

    expect(card('local'), findsOneWidget);
    expect(card('stale'), findsNothing);
    expect(history.metadataRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signing out while history loads restores device history',
      (tester) async {
    await tester.runAsync(() => seed('local'));
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    final pending = Completer<List<String>>();
    history.historyResponse = (_) => pending.future;
    await mount(tester);
    await selectControl(tester, 'tv-history-server');
    app.setServer(const Server(url: 'https://instance.example'));
    await settle(tester);
    pending.complete(['private']);
    await settle(tester);

    expect(find.text('All history on your server'), findsNothing);
    expect(card('local'), findsOneWidget);
    expect(card('private'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'closing history while metadata loads does not update disposed UI',
      (tester) async {
    app.setServer(
        const Server(url: 'https://instance.example', authToken: 'test-token'));
    history.serverPages[1] = ['pending'];
    final pending = Completer<Video>();
    history.metadataResponse = (_) => pending.future;
    await mount(tester);
    await selectControl(tester, 'tv-history-server');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(const Video(videoId: 'pending', title: 'Late response'));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(db.getLocalHistory(), isEmpty);
  });
}

Future<void> settle(WidgetTester tester) async {
  // Bounded pumping also handles intentionally unresolved requests in race tests.
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
