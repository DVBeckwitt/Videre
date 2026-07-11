import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'test_app_cubit.dart';
import 'test_player_cubit.dart';
import 'test_settings_cubit.dart';

const _instanceHeaders = {'Authorization': 'Basic test'};
late final cache.BaseCacheManager _testDefaultThumbnailCacheManager;
final _thumbnailTestFile = MemoryFileSystem.test().file('thumbnail.png')
  ..writeAsBytesSync(
    const LocalFileSystem().file('assets/icon.png').readAsBytesSync(),
  );

class _TestService extends Service {
  _TestService({required this.videos});

  final List<Video> videos;

  @override
  void syncHistory() {}

  @override
  Future<bool> isLoggedIn() async => true;

  @override
  Future<List<Video>> getTrending({String? type}) async => videos;

  @override
  Future<List<Video>> getPopular() async => videos;

  @override
  Future<UserFeed> getUserFeed(
          {int? maxResults, int? page, bool saveLastSeen = true}) async =>
      UserFeed([], []);

  @override
  Future<List<Playlist>> getUserPlaylists({bool postProcessing = true}) async =>
      [];

  @override
  Future<List<String>> getUserHistory(int page, int maxResults) async => [];

  @override
  Future<VideosWithContinuation> getChannelVideos(
          String channelId, String? continuation,
          {bool saveLastSeen = true,
          ChannelSortBy sortBy = ChannelSortBy.newest}) async =>
      VideosWithContinuation([], null);
}

Future<void> _pumpHomepage(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final appCubit = TestAppCubit(AppState(0, null, HomeLayout()));
  final settingsCubit = TestSettingsCubit(SettingsState.init(), appCubit);

  await tester.pumpWidget(MultiBlocProvider(
    providers: [
      BlocProvider<AppCubit>.value(value: appCubit),
      BlocProvider<SettingsCubit>.value(value: settingsCubit),
      BlocProvider<PlayerCubit>(
        create: (context) =>
            TestPlayerCubit(PlayerState.init(null), settingsCubit),
      ),
      BlocProvider<DownloadManagerCubit>(
        create: (context) => DownloadManagerCubit(
            const DownloadManagerState(), context.read<PlayerCubit>()),
      ),
    ],
    child: MaterialApp.router(
      routerConfig: appRouter.config(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  ));

  await tester.pumpAndSettle();
}

ScrollPosition _tabPosition(WidgetTester tester) {
  return tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .map((state) => state.position)
      .singleWhere((position) => position is PageMetrics);
}

class _ThumbnailTestCacheManager implements cache.BaseCacheManager {
  final List<
      ({
        String url,
        Map<String, String>? headers,
        Completer<cache.FileInfo?> response,
      })> requests = [];

  void failRequest(int index) {
    final request = requests[index];
    if (!request.response.isCompleted) {
      request.response.completeError(cache.HttpExceptionWithStatus(
        404,
        'Thumbnail not found',
        uri: Uri.parse(request.url),
      ));
    }
  }

  void succeedRequest(int index) {
    final request = requests[index];
    final response = request.response;
    if (!response.isCompleted) {
      response.complete(cache.FileInfo(
        _thumbnailTestFile,
        cache.FileSource.Cache,
        DateTime.utc(2100),
        request.url,
      ));
    }
  }

  void releasePendingRequests() {
    for (final request in requests) {
      if (!request.response.isCompleted) {
        request.response.complete();
      }
    }
  }

  @override
  Stream<cache.FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    final response = Completer<cache.FileInfo?>();
    requests.add((
      url: url,
      headers: headers == null ? null : Map.unmodifiable(headers),
      response: response,
    ));
    yield cache.DownloadProgress(url, null, 0);
    final result = await response.future;
    if (result != null) {
      yield result;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _withThumbnailCacheManager(
  WidgetTester tester,
  Future<void> Function(_ThumbnailTestCacheManager cacheManager) body,
) async {
  final cacheManager = _ThumbnailTestCacheManager();
  CachedNetworkImageProvider.defaultCacheManager = cacheManager;

  try {
    await body(cacheManager);
  } finally {
    cacheManager.releasePendingRequests();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    CachedNetworkImageProvider.defaultCacheManager =
        _testDefaultThumbnailCacheManager;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

Future<void> _pumpUntilRequestCount(
  WidgetTester tester,
  _ThumbnailTestCacheManager cacheManager,
  int count,
) async {
  for (var attempt = 0;
      attempt < 20 && cacheManager.requests.length < count;
      attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(cacheManager.requests, hasLength(count));
}

Future<void> _pumpUntilThumbnailSettles(WidgetTester tester) async {
  for (var attempt = 0;
      attempt < 20 &&
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      attempt++) {
    await tester.runAsync(
      () => Future<void>(() {}),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpVideoThumbnail(
  WidgetTester tester, {
  required List<String> thumbnails,
  required VoidCallback onPressed,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          child: VideoThumbnailView(
            videoId: 'video-thumbnail-test',
            thumbnails: thumbnails,
            child: TextButton(
              key: const ValueKey('video-thumbnail-control'),
              onPressed: onPressed,
              child: const Text('Play'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _testDefaultThumbnailCacheManager = _ThumbnailTestCacheManager();
  CachedNetworkImageProvider.defaultCacheManager =
      _testDefaultThumbnailCacheManager;

  setUp(() async {
    app_main.isTv = false;
    globals.service = _TestService(
      videos: List.generate(
        6,
        (index) => Video(
          videoId: 'video-$index',
          title: 'Video $index',
          author: 'Channel $index',
          authorId: 'channel-$index',
          lengthSeconds: 60,
        ),
      ),
    );
    globals.packageInfo = PackageInfo(
        appName: 'Videre',
        packageName: 'com.github.lamarios.clipious',
        version: '1.0.0',
        buildNumber: '1');
    globals.db = await SembastSqfDb.createInMemory();

    final server = Server(
      url: 'https://example.com',
      sidCookie: 'SID=test',
      customHeaders: _instanceHeaders,
    );
    await globals.db.upsertServer(server);
    await globals.db.useServer(server);
    appRouter = AppRouter(hasServer: true);
  });

  tearDown(() async {
    await globals.db.close();
  });

  group('Server.headersForUrl', () {
    const server = Server(
      url: 'https://example.com',
      customHeaders: _instanceHeaders,
    );

    test('returns headers for the exact normalized HTTP origin', () {
      expect(
        server.headersForUrl('https://example.com/video'),
        equals(_instanceHeaders),
      );
      expect(
        server.headersForUrl('https://EXAMPLE.com:443/video'),
        equals(_instanceHeaders),
      );
    });

    test('rejects invalid and mismatched target origins', () {
      for (final targetUrl in [
        'https://example.com.evil/video',
        'https://cdn.example.com/video',
        'https://example.com:444/video',
        'http://example.com/video',
        'ftp://example.com/video',
        '/video',
        'not a URL',
        '::Not valid URI::',
      ]) {
        expect(
          server.headersForUrl(targetUrl),
          isNull,
          reason: targetUrl,
        );
      }
    });

    test('requires a valid HTTP server origin', () {
      for (final serverUrl in [
        'ftp://example.com',
        '/relative-server',
        'not a URL',
      ]) {
        final invalidServer = Server(
          url: serverUrl,
          customHeaders: _instanceHeaders,
        );

        expect(
          invalidServer.headersForUrl('$serverUrl/video'),
          isNull,
          reason: serverUrl,
        );
      }
    });
  });

  testWidgets('phone homepage tabs swipe fluidly and bounce at both edges',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    final tabPosition = _tabPosition(tester);

    void expectSelectedTab(int index) {
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        index,
      );
    }

    Future<void> swipeLeft() async {
      await tester.dragFrom(const Offset(350, 400), const Offset(-320, 0));
      await tester.pumpAndSettle();
    }

    Future<void> swipeRight() async {
      await tester.dragFrom(const Offset(40, 400), const Offset(320, 0));
      await tester.pumpAndSettle();
    }

    expectSelectedTab(0);

    final leadingEdgeDrag =
        await tester.startGesture(tester.getCenter(find.text('Trending')));
    await leadingEdgeDrag.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(tabPosition.pixels, lessThan(0));
    await leadingEdgeDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(0);

    final pageDrag =
        await tester.startGesture(tester.getCenter(find.text('Trending')));
    await pageDrag.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(
        tabPosition.pixels, inExclusiveRange(0, tabPosition.viewportDimension));
    await pageDrag.moveBy(const Offset(-200, 0));
    await pageDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(1);
    await swipeLeft();
    expectSelectedTab(2);
    await swipeLeft();
    expectSelectedTab(3);

    final trailingEdgeDrag = await tester.startGesture(const Offset(350, 400));
    await trailingEdgeDrag.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(tabPosition.pixels, greaterThan(tabPosition.maxScrollExtent));
    await trailingEdgeDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(3);

    await swipeRight();
    expectSelectedTab(2);
    await swipeRight();
    expectSelectedTab(1);
    await swipeRight();
    expectSelectedTab(0);
  });

  testWidgets('phone homepage preserves horizontal carousel gestures',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));

    final firstCarouselVideo = find.byKey(const ValueKey('video-0-true'));
    expect(firstCarouselVideo, findsOneWidget);

    final carousel = find.ancestor(
      of: firstCarouselVideo,
      matching: find.byType(GridView),
    );
    final carouselScrollable = find.descendant(
      of: carousel,
      matching: find.byType(Scrollable),
    );
    final carouselPosition =
        tester.state<ScrollableState>(carouselScrollable).position;

    expect(carouselPosition.pixels, 0);

    await tester.drag(firstCarouselVideo, const Offset(-200, 0));
    await tester.pumpAndSettle();

    expect(carouselPosition.pixels, greaterThan(0));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );

    await tester.dragFrom(const Offset(350, 400), const Offset(-320, 0));
    await tester.pumpAndSettle();

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
  });

  testWidgets('tablet homepage tabs ignore horizontal swipes', (tester) async {
    await _pumpHomepage(tester, const Size(1024, 768));
    final tabPosition = _tabPosition(tester);

    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        0);
    await tester.dragFrom(const Offset(900, 400), const Offset(-800, 0));
    await tester.pumpAndSettle();

    expect(tabPosition.pixels, 0);
    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        0);
  });

  group('VideoThumbnailView controls', () {
    testWidgets('remain tappable when no thumbnail is available',
        (tester) async {
      var taps = 0;
      await _pumpVideoThumbnail(
        tester,
        thumbnails: const [],
        onPressed: () => taps++,
      );
      await tester.pumpAndSettle();

      final control = find.byKey(const ValueKey('video-thumbnail-control'));
      expect(control, findsOneWidget);
      await tester.tap(control);
      await tester.pump();

      expect(taps, 1);
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio).last).aspectRatio,
        16 / 9,
      );
    });

    testWidgets('stay tappable through same-origin fallback and success',
        (tester) async {
      const maxresUrl = 'https://example.com/maxres.jpg';
      const fallbackUrl = 'https://example.com/maxresdefault.jpg';
      var taps = 0;

      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await _pumpVideoThumbnail(
          tester,
          thumbnails: const ['/maxres.jpg', '/maxresdefault.jpg'],
          onPressed: () => taps++,
        );
        await _pumpUntilRequestCount(tester, cacheManager, 1);

        expect(cacheManager.requests.single.url, maxresUrl);
        expect(cacheManager.requests.single.headers, equals(_instanceHeaders));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        final control = find.byKey(const ValueKey('video-thumbnail-control'));
        expect(control, findsOneWidget);
        await tester.tap(control);
        await tester.pump();
        expect(taps, 1);

        cacheManager.failRequest(0);
        await _pumpUntilRequestCount(tester, cacheManager, 2);

        expect(
          cacheManager.requests.map((request) => request.url),
          [maxresUrl, fallbackUrl],
        );
        expect(cacheManager.requests.last.headers, equals(_instanceHeaders));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(control, findsOneWidget);
        await tester.tap(control);
        await tester.pump();
        expect(taps, 2);

        cacheManager.succeedRequest(1);
        await _pumpUntilThumbnailSettles(tester);

        expect(cacheManager.requests, hasLength(2));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.error_outline), findsNothing);
        await tester.tap(control);
        await tester.pump();
        expect(taps, 3);
      });
    });

    testWidgets('successful first response does not request a fallback',
        (tester) async {
      var taps = 0;

      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await _pumpVideoThumbnail(
          tester,
          thumbnails: const ['/maxres.jpg', '/maxresdefault.jpg'],
          onPressed: () => taps++,
        );
        await _pumpUntilRequestCount(tester, cacheManager, 1);

        cacheManager.succeedRequest(0);
        await _pumpUntilThumbnailSettles(tester);

        expect(cacheManager.requests, hasLength(1));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.error_outline), findsNothing);
        final control = find.byKey(const ValueKey('video-thumbnail-control'));
        expect(control, findsOneWidget);
        await tester.tap(control);
        await tester.pump();
        expect(taps, 1);
      });
    });

    testWidgets('strip instance headers from every off-origin request',
        (tester) async {
      const thumbnailUrls = [
        'https://example.com.evil/lookalike.jpg',
        'http://example.com/scheme.jpg',
        'https://example.com:444/port.jpg',
        'https://cdn.example.com/external.jpg',
      ];
      var taps = 0;

      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await _pumpVideoThumbnail(
          tester,
          thumbnails: thumbnailUrls,
          onPressed: () => taps++,
        );

        for (var index = 0; index < thumbnailUrls.length; index++) {
          await _pumpUntilRequestCount(tester, cacheManager, index + 1);
          expect(cacheManager.requests[index].url, thumbnailUrls[index]);
          expect(cacheManager.requests[index].headers, isNull);
          cacheManager.failRequest(index);
        }

        for (var attempt = 0;
            attempt < 20 && find.byIcon(Icons.error_outline).evaluate().isEmpty;
            attempt++) {
          await tester.idle();
          await tester.pump(const Duration(milliseconds: 10));
        }

        expect(cacheManager.requests, hasLength(thumbnailUrls.length));
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        final control = find.byKey(const ValueKey('video-thumbnail-control'));
        expect(control, findsOneWidget);
        await tester.tap(control);
        await tester.pump();
        expect(taps, 1);
      });
    });
  });
}
