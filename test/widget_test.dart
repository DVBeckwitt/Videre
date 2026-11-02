import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/comments/models/comment.dart';
import 'package:clipious/comments/models/video_comments.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/player/views/screens/video_queue.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/app_customizer.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_item_list.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';
import 'package:clipious/videos/views/screens/video.dart';
import 'package:clipious/videos/views/tv/screens/video_grid_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final List<String> transcriptRequests = [];
  bool loggedIn = true;
  List<Comment> comments = [];
  List<Video> feedVideos = [];
  final feedRequests = <int>[];
  bool failNextFeed = false;

  @override
  Future<VideoTranscript> getTranscript(
    String videoId,
    Caption caption,
  ) async {
    transcriptRequests.add(caption.label);
    if (caption.label == 'Spanish') {
      return const VideoTranscript(
        label: 'Spanish',
        languageCode: 'es',
        lines: [
          VideoTranscriptLine(
            type: VideoTranscriptLineType.regular,
            startMs: 2000,
            endMs: 4000,
            text: 'Hola mundo',
          ),
        ],
      );
    }
    return const VideoTranscript(
      label: 'English',
      languageCode: 'en',
      lines: [
        VideoTranscriptLine(
          type: VideoTranscriptLineType.heading,
          startMs: 0,
          endMs: 1000,
          text: 'Intro',
        ),
        VideoTranscriptLine(
          type: VideoTranscriptLineType.regular,
          startMs: 1000,
          endMs: 5000,
          text: 'Hello world',
        ),
        VideoTranscriptLine(
          type: VideoTranscriptLineType.regular,
          startMs: 5000,
          endMs: 8000,
          text: 'Second line',
        ),
      ],
    );
  }

  @override
  void syncHistory() {}

  @override
  Future<bool> isLoggedIn() async => loggedIn;

  @override
  Future<List<Video>> getTrending({String? type}) async => videos;

  @override
  Future<List<Video>> getPopular() async => videos;

  @override
  Future<Video> getVideo(String videoId,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest}) async =>
      videos.singleWhere((video) => video.videoId == videoId);

  @override
  Future<VideoComments> getComments(String videoId,
          {String? continuation, String? sortBy, String? source}) async =>
      VideoComments(comments.length, videoId, null, comments);

  @override
  Future<bool> isSubscribedToChannel(String channelId) async => false;

  @override
  Future<UserFeed> getUserFeed(
      {int? maxResults, int? page, bool saveLastSeen = true}) async {
    feedRequests.add(page ?? 1);
    if (failNextFeed) {
      failNextFeed = false;
      throw StateError('temporary feed failure');
    }
    return UserFeed(
        [],
        feedVideos
            .skip(((page ?? 1) - 1) * (maxResults ?? 50))
            .take(maxResults ?? 50)
            .toList());
  }

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

class _QueueSelectionPlayer extends TestPlayerCubit {
  _QueueSelectionPlayer(super.initialState, super.settings);

  @override
  Future<void> skipToVideo(int index) async {
    emit(state.videos.isNotEmpty
        ? state.copyWith(currentlyPlaying: state.videos[index])
        : state.copyWith(offlineCurrentlyPlaying: state.offlineVideos[index]));
  }
}

Future<void> _pumpHomepage(
  WidgetTester tester,
  Size size, {
  PlayerState? playerState,
  SettingsState? settingsState,
  PlayerCubit Function(SettingsCubit)? createPlayer,
  int firstIndex = 0,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.runAsync(() => globals.db
      .saveSetting(SettingsValue(onOpenSettingName, firstIndex.toString())));
  final appCubit = TestAppCubit(AppState(firstIndex, null, HomeLayout()));
  final settingsCubit =
      TestSettingsCubit(settingsState ?? SettingsState.init(), appCubit);

  await tester.pumpWidget(MultiBlocProvider(
    providers: [
      BlocProvider<AppCubit>.value(value: appCubit),
      BlocProvider<SettingsCubit>.value(value: settingsCubit),
      BlocProvider<PlayerCubit>(
        create: (context) =>
            createPlayer?.call(settingsCubit) ??
            TestPlayerCubit(
                playerState ?? PlayerState.init(null), settingsCubit),
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

  if (settle) await tester.pumpAndSettle();
}

Future<void> _pumpExpandedPlayer(
  WidgetTester tester,
  Size size, {
  bool distractionFree = false,
  int selectedIndex = 3,
  int videoIndex = 0,
}) async {
  final video = (globals.service as _TestService).videos[videoIndex];
  final settingsState = SettingsState.init();
  await _pumpHomepage(
    tester,
    size,
    settingsState: distractionFree
        ? settingsState.copyWith(settings: {
            ...settingsState.settings,
            distractionFreeModeSettingName:
                SettingsValue(distractionFreeModeSettingName, 'true'),
          })
        : settingsState,
    playerState: PlayerState.init([video]).copyWith(
      currentlyPlaying: video,
      isMini: false,
      isHidden: false,
      selectedFullScreenIndex: selectedIndex,
      top: 0,
    ),
  );
}

Future<void> _pumpVideo(WidgetTester tester, Size size,
    {PlayerState? playerState}) async {
  tester.platformDispatcher.textScaleFactorTestValue = 0.9;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await _pumpHomepage(tester, size, playerState: playerState);
  unawaited(appRouter.push(VideoRoute(videoId: 'video-0')));
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
  List<ImageObject>? images,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          child: VideoThumbnailView(
            videoId: 'video-thumbnail-test',
            thumbnails: thumbnails,
            images: images,
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
          captions: index == 0
              ? [
                  Caption('Spanish', 'es', '/captions/spanish'),
                  Caption('English', 'en', '/captions/english'),
                ]
              : const [],
        ),
      ),
    );
    globals.packageInfo = PackageInfo(
        appName: 'Videre',
        packageName: 'com.github.dvbeckwitt.videre',
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await globals.db.close();
  });

  testWidgets(
      'phone navigation opens search with keyboard focus and returns to the selected tab',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    final navigation = find.byType(NavigationBar);
    expect(
        tester
            .widget<NavigationBar>(navigation)
            .destinations
            .cast<NavigationDestination>()
            .map((destination) => destination.label),
        ['Home', 'Subscriptions', 'History', 'Search']);
    final searchButton =
        find.descendant(of: navigation, matching: find.byIcon(Icons.search));
    expect(searchButton, findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.byIcon(Icons.search)),
        findsNothing);

    await tester.tap(find.descendant(
        of: navigation, matching: find.byIcon(Icons.subscriptions)));
    await tester.pumpAndSettle();
    final selectedIndex =
        tester.widget<NavigationBar>(navigation).selectedIndex;
    await tester.tap(searchButton);
    await tester.pumpAndSettle();

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(navigation).selectedIndex, selectedIndex);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'phone navigation keeps search available with a single configured tab',
      (tester) async {
    final settings = SettingsState.init();
    await _pumpHomepage(tester, const Size(390, 844),
        settingsState: settings.copyWith(settings: {
          ...settings.settings,
          appLayoutSettingName: SettingsValue(appLayoutSettingName, 'home'),
        }));
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
        hasLength(2));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tablet navigation keeps search in the app bar', (tester) async {
    await _pumpHomepage(tester, const Size(1024, 768));
    expect(find.byType(NavigationBar), findsNothing);
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.byIcon(Icons.search)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(NavigationRail),
            matching: find.byIcon(Icons.playlist_play)),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone navigation preserves a saved History startup tab',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844), firstIndex: 3);
    final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final destination = navigation.destinations[navigation.selectedIndex]
        as NavigationDestination;
    expect(destination.label, 'History');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone layout editor preserves saved indexes for visible tabs',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browsing'));
    await tester.pumpAndSettle();
    expect(find.text('Home, Subscriptions, History, Search'), findsOneWidget);
    await tester.tap(find.text('Customize app sections'));
    await tester.pumpAndSettle();
    expect(find.text('Playlists'), findsNothing);
    expect(find.text('Search'), findsNothing);

    final context = tester.element(find.byType(AppCustomizer));
    final settings = context.read<SettingsCubit>();
    final historyRow =
        find.ancestor(of: find.text('History'), matching: find.byType(Row));
    await tester.tap(find.descendant(
        of: historyRow, matching: find.byIcon(Icons.home_outlined)));
    await tester.pumpAndSettle();
    expect(settings.state.onOpen, 3);

    final reorder = tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorder;
    final originalLayout = settings.state.appLayout;
    reorder(2, 2);
    reorder(2, 3);
    await tester.pumpAndSettle();
    expect(settings.state.appLayout, originalLayout);
    expect(settings.state.onOpen, 3);

    reorder(2, 0);
    await tester.pumpAndSettle();
    expect(settings.state.appLayout.first, HomeDataSource.history);
    expect(settings.state.appLayout, contains(HomeDataSource.playlist));
    expect(settings.state.onOpen, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup selection skips a disabled search history section',
      (tester) async {
    final settings = SettingsState.init();
    await _pumpHomepage(tester, const Size(390, 844),
        firstIndex: 2,
        settingsState: settings.copyWith(settings: {
          ...settings.settings,
          appLayoutSettingName: SettingsValue(
              appLayoutSettingName, 'home,searchHistory,history,playlist'),
          useSearchHistorySettingName:
              SettingsValue(useSearchHistorySettingName, 'false'),
        }));
    final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final destination = navigation.destinations[navigation.selectedIndex]
        as NavigationDestination;
    expect(destination.label, 'History');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone navigation falls back from a saved Playlists startup tab',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844), firstIndex: 2);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    await tester.tap(find.byTooltip('Playlists'));
    await tester.pumpAndSettle();
    expect(find.text('Playlists'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'phone navigation opens playlists from the top and returns to history',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    final navigation = find.byType(NavigationBar);
    expect(
        find.descendant(
            of: navigation, matching: find.byIcon(Icons.playlist_play)),
        findsNothing);
    await tester.tap(
        find.descendant(of: navigation, matching: find.byIcon(Icons.history)));
    await tester.pumpAndSettle();
    final selectedIndex =
        tester.widget<NavigationBar>(navigation).selectedIndex;
    await tester.tap(find.byTooltip('Playlists'));
    await tester.pumpAndSettle();
    expect(find.text('Playlists'), findsOneWidget);
    expect(navigation, findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(navigation).selectedIndex, selectedIndex);
    expect(find.text('History'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'phone navigation keeps playlists reachable for a playlist-only layout',
      (tester) async {
    final settings = SettingsState.init();
    await _pumpHomepage(tester, const Size(390, 844),
        settingsState: settings.copyWith(settings: {
          ...settings.settings,
          appLayoutSettingName: SettingsValue(appLayoutSettingName, 'playlist'),
        }));
    await tester.tap(find.byTooltip('Playlists'));
    await tester.pumpAndSettle();
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone queue shortcut fits between downloads and playlists',
      (tester) async {
    await _pumpHomepage(tester, const Size(320, 640));
    final navigation = find.byType(NavigationBar);
    await tester.tap(find.descendant(
        of: navigation, matching: find.byIcon(Icons.subscriptions)));
    await tester.pumpAndSettle();
    final selectedIndex =
        tester.widget<NavigationBar>(navigation).selectedIndex;
    final queue = find.byTooltip('Video queue');
    expect(tester.getCenter(find.byIcon(Icons.download)).dx,
        lessThan(tester.getCenter(queue).dx));
    expect(tester.getCenter(queue).dx,
        lessThan(tester.getCenter(find.byTooltip('Playlists')).dx));
    expect(tester.takeException(), isNull);

    await tester.tap(queue);
    await tester.pumpAndSettle();
    expect(find.byType(VideoQueueScreen), findsOneWidget);
    expect(find.text('Your queue is empty'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(navigation).selectedIndex, selectedIndex);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'download folder can be selected, cancelled and reset from an empty library',
      (tester) async {
    const channel = MethodChannel('videre/download_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
              'uri': 'content://documents/tree/primary%3AVidere',
              'name': 'Videre files'
            });
    await _pumpHomepage(tester, const Size(390, 844));
    await tester.tap(find.byIcon(Icons.download));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download folder'));
    await tester.pumpAndSettle();
    expect(find.text('App storage (private)'), findsOneWidget);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(find.text('Videre files'), findsOneWidget);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(find.text('Videre files'), findsOneWidget);
    messenger.setMockMethodCallHandler(channel,
        (_) async => throw PlatformException(code: 'PICKER_UNAVAILABLE'));
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('No folder picker is available.'), findsOneWidget);
    await tester.tap(find.text('Use app storage'));
    await tester.pumpAndSettle();
    expect(find.text('App storage (private)'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'subscription setting hides watched videos and restores them on opt-out',
      (tester) async {
    final service = globals.service as _TestService;
    service.feedVideos = service.videos;
    await tester.runAsync(() async {
      await globals.db.saveProgress(Progress(1, 'video-0'));
      await globals.db.saveProgress(Progress(0.89, 'video-1'));
    });
    await _pumpHomepage(tester, const Size(390, 844), firstIndex: 1);
    expect(find.text('Video 0'), findsOneWidget);
    expect(find.text('Video 1'), findsOneWidget);
    final settings = tester.element(find.byType(Player)).read<SettingsCubit>();
    unawaited(appRouter.push(const BrowsingSettingsRoute()));
    await tester.pumpAndSettle();
    final toggle = find.text('Hide watched subscription videos');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.state.hideWatchedSubscriptions, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Video 0'), findsNothing);
    expect(find.text('Video 1'), findsOneWidget);
    await tester
        .runAsync(() => globals.db.saveProgress(Progress(0.9, 'video-1')));
    await tester.pumpAndSettle();
    expect(find.text('Video 1'), findsNothing);
    await tester.runAsync(() => settings.setHideWatchedSubscriptions(false));
    await tester.pumpAndSettle();
    expect(find.text('Video 0'), findsOneWidget);
    expect(find.text('Video 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final surface in ['phone', 'TV row', 'TV grid']) {
    testWidgets(
        'fully hidden subscription pages retry and load older videos ($surface)',
        (tester) async {
      final tv = surface != 'phone';
      final service = globals.service as _TestService;
      service.feedVideos = List.generate(
          51,
          (i) => Video(
              videoId: 'feed-$i',
              title: 'Feed $i',
              author: 'Creator',
              lengthSeconds: 60));
      await tester.runAsync(() async {
        await globals.db.saveSetting(
            SettingsValue(hideWatchedSubscriptionsSettingName, 'true'));
        for (var i = 0; i < 50; i++) {
          await globals.db.saveProgress(Progress(1, 'feed-$i'));
        }
      });
      if (tv) {
        app_main.isTv = true;
        await tester.pumpWidget(MaterialApp(
          locale: const Locale('en', 'US'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: surface == 'TV grid'
              ? TvGridScreen(
                  title: 'Subscriptions',
                  paginatedVideoList: SubscriptionVideoList())
              : Scaffold(
                  body: TvHorizontalVideoList(
                      paginatedVideoList: SubscriptionVideoList())),
        ));
        await tester.pumpAndSettle();
      } else {
        await _pumpHomepage(tester, const Size(390, 844), firstIndex: 1);
      }
      expect(find.text('Feed 0'), findsNothing);
      expect(find.text('Load more'), findsOneWidget);
      service.failNextFeed = true;
      if (tv) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(find.text('Load more'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Feed 50'), findsNothing);
      expect(service.feedRequests, [1, 2]);
      if (tv) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(find.text(
            AppLocalizations.of(tester.element(find.byType(Player)))!
                .couldntFetchVideos));
      }
      await tester.pumpAndSettle();
      expect(service.feedRequests, [1, 2, 2]);
      expect(find.text('Feed 50'), findsOneWidget);
      expect(find.text('Feed 0'), findsNothing);
      expect(find.text('Load more'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('open queue updates when videos are added and cleared',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    await tester.tap(find.byTooltip('Video queue'));
    await tester.pumpAndSettle();
    final player =
        tester.element(find.byType(VideoQueueScreen)).read<PlayerCubit>();
    final videos = (globals.service as _TestService).videos.take(2).toList();
    player.queueVideos(videos);
    await tester.pumpAndSettle();
    expect(find.text('Your queue is empty'), findsNothing);
    expect(find.text('Video 0'), findsOneWidget);
    expect(find.text('Video 1'), findsOneWidget);

    tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorder(0, 2);
    await tester.pumpAndSettle();
    expect(player.state.videos.map((video) => video.videoId),
        ['video-1', 'video-0']);
    expect(tester.getTopLeft(find.text('Video 1')).dy,
        lessThan(tester.getTopLeft(find.text('Video 0')).dy));

    player.removeVideoFromQueue('video-0');
    await tester.pumpAndSettle();
    expect(find.text('Video 0'), findsNothing);
    player.hide();
    await tester.pumpAndSettle();
    expect(find.text('Your queue is empty'), findsOneWidget);
    expect(find.byType(ReorderableListView), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final offline in [false, true]) {
    testWidgets('opening queue preserves playback (offline=$offline)',
        (tester) async {
      final videos = (globals.service as _TestService).videos.take(2).toList();
      final downloads = videos
          .map((video) => DownloadedVideo(
              videoId: video.videoId,
              title: video.title!,
              lengthSeconds: 60,
              quality: '720p'))
          .toList();
      await _pumpHomepage(tester, const Size(390, 844),
          playerState: PlayerState.init(offline ? null : videos).copyWith(
            offlineVideos: offline ? downloads : [],
            currentlyPlaying: offline ? null : videos.first,
            offlineCurrentlyPlaying: offline ? downloads.first : null,
            isHidden: false,
            isPlaying: true,
            position: const Duration(seconds: 23),
          ));
      final player = tester.element(find.byType(Player)).read<PlayerCubit>();
      final before = player.state;
      await tester.tap(find.byTooltip('Video queue'));
      await tester.pumpAndSettle();
      expect(find.byType(VideoQueueScreen), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(VideoQueueScreen),
              matching: find.text('Video 1')),
          findsOneWidget);
      expect(player.state, same(before));
      final scrollController = tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .scrollController!;
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(player.state, same(before));
      expect(() => scrollController.addListener(() {}), throwsFlutterError);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final offline in [false, true]) {
    testWidgets(
        'selecting a restored queue item reveals the mini player (offline=$offline)',
        (tester) async {
      final videos = (globals.service as _TestService).videos.take(2).toList();
      final initialState = offline
          ? PlayerState.init(null).copyWith(
              offlineVideos: videos
                  .map((video) => DownloadedVideo(
                      videoId: video.videoId,
                      title: video.title!,
                      lengthSeconds: 60,
                      quality: '720p',
                      audioOnly: true))
                  .toList())
          : PlayerState.init(videos);
      await _pumpHomepage(tester, const Size(390, 844),
          createPlayer: (settings) =>
              _QueueSelectionPlayer(initialState, settings));
      await tester.tap(find.byTooltip('Video queue'));
      await tester.pumpAndSettle();
      final player =
          tester.element(find.byType(VideoQueueScreen)).read<PlayerCubit>();
      expect(player.state.isHidden, isTrue);
      await tester.tap(find.text('Video 1'));
      await tester.pumpAndSettle();
      expect(
          player.state.currentlyPlaying?.videoId ??
              player.state.offlineCurrentlyPlaying?.videoId,
          'video-1');
      expect(player.state.isHidden, isFalse);
      expect(player.state.isMini, isTrue);
      expect(find.byType(VideoQueueScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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

  testWidgets('expanded player transcript supports select, search, copy, seek',
      (tester) async {
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });

    await _pumpExpandedPlayer(tester, const Size(390, 844));
    final testService = globals.service as _TestService;
    final openButton = find.byKey(const ValueKey('video-transcript-open'));

    expect(openButton, findsOneWidget);
    expect(testService.transcriptRequests, isEmpty);

    await tester.tap(openButton);
    await tester.pumpAndSettle();

    expect(testService.transcriptRequests, ['English']);
    final language = find.byKey(
      const ValueKey('video-transcript-language'),
    );
    expect(
      tester.widget<DropdownButtonFormField<int>>(language).initialValue,
      1,
    );
    expect(find.text('Hello world'), findsOneWidget);
    expect(find.text('Second line'), findsOneWidget);

    final search = find.byKey(const ValueKey('video-transcript-search'));
    await tester.enterText(search, 'hello');
    await tester.pump();
    expect(find.text('Hello world'), findsOneWidget);
    expect(find.text('Second line'), findsNothing);

    await tester.enterText(search, '');
    await tester.pump();
    expect(find.text('Second line'), findsOneWidget);

    await tester.tap(language);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spanish').last);
    await tester.pumpAndSettle();
    expect(testService.transcriptRequests, ['English', 'Spanish']);
    expect(find.text('Hola mundo'), findsOneWidget);

    await tester.tap(language);
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(testService.transcriptRequests, ['English', 'Spanish']);

    await tester.enterText(search, 'second');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('video-transcript-copy')));
    await tester.pumpAndSettle();
    expect(copiedText, 'Intro\n\nHello world\nSecond line');
    expect(find.text('Transcript copied'), findsOneWidget);

    final player = tester.element(language).read<PlayerCubit>();
    await tester.tap(
      find.byKey(const ValueKey('video-transcript-seek-5000')),
    );
    await tester.pump();
    expect(player.state.position, const Duration(seconds: 5));
    expect(language, findsOneWidget);
  });

  testWidgets('expanded player hides transcript when captions are unavailable',
      (tester) async {
    await _pumpExpandedPlayer(
      tester,
      const Size(390, 844),
      videoIndex: 1,
    );

    expect(
      find.byKey(const ValueKey('video-transcript-open')),
      findsNothing,
    );
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

    final trailingEdgeDrag = await tester.startGesture(const Offset(350, 400));
    await trailingEdgeDrag.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(tabPosition.pixels, greaterThan(tabPosition.maxScrollExtent));
    await trailingEdgeDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(2);
    expect(find.byType(TextField), findsNothing);

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

  testWidgets('landscape home shows the feed without automatic resume sections',
      (tester) async {
    await tester.runAsync(() async {
      await globals.db.upsertHistoryVideo(HistoryVideoCache('video-0',
          'Resume this video', 'Channel', 'https://example.com/resume.png'));
      await globals.db.saveProgress(Progress(0.5, 'video-0'));
    });

    await _pumpHomepage(tester, const Size(640, 360));
    expect(tester.takeException(), isNull);
    expect(find.text('Continue Watching'), findsNothing);
    expect(find.text('Resume queue'), findsNothing);
    expect(find.text('Resume this video'), findsNothing);
    expect(find.text('Popular').hitTestable(), findsOneWidget);
    expect(find.text('Trending').hitTestable(), findsOneWidget);

    final summaries = find.ancestor(
        of: find.text('Popular'), matching: find.byType(SingleChildScrollView));
    await tester.drag(summaries, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('Trending').hitTestable(), findsOneWidget);
    await tester.drag(summaries, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(find.text('Popular').hitTestable(), findsOneWidget);
    expect(find.text('Trending').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('phone video tabs swipe and stay synchronized with navigation',
      (tester) async {
    await _pumpVideo(tester, const Size(390, 844));

    void expectSelectedTab(int index) {
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        index,
      );
    }

    Future<void> swipeLeft() async {
      await tester.dragFrom(const Offset(350, 500), const Offset(-320, 0));
      await tester.pumpAndSettle();
    }

    Future<void> swipeRight() async {
      await tester.dragFrom(const Offset(40, 500), const Offset(320, 0));
      await tester.pumpAndSettle();
    }

    Finder destination(String label) => find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        );

    expectSelectedTab(0);

    await swipeLeft();
    expectSelectedTab(1);
    await swipeLeft();
    expectSelectedTab(2);
    await swipeRight();
    expectSelectedTab(1);
    await swipeRight();
    expectSelectedTab(0);

    await tester.tap(destination('Recommended'));
    await tester.pumpAndSettle();
    expectSelectedTab(2);
    await tester.tap(destination('Info'));
    await tester.pumpAndSettle();
    expectSelectedTab(0);

    await tester.drag(find.byType(VideoThumbnailView), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expectSelectedTab(0);
  });

  testWidgets('tablet video tabs ignore horizontal swipes', (tester) async {
    await _pumpVideo(tester, const Size(1024, 768));

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller!.index, 0);

    await tester.dragFrom(const Offset(900, 400), const Offset(-800, 0));
    await tester.pumpAndSettle();

    expect(tabBar.controller!.index, 0);
  });

  testWidgets(
      'phone expanded player tabs swipe and stay synchronized with navigation',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844));

    final expandedPlayer = find.byType(ExpandedPlayer);
    final navigationBar = find.descendant(
      of: expandedPlayer,
      matching: find.byType(NavigationBar),
    );

    void expectSelectedTab(int index) {
      expect(
        tester.widget<NavigationBar>(navigationBar).selectedIndex,
        index,
      );
    }

    Future<void> swipeLeft() async {
      await tester.dragFrom(const Offset(350, 500), const Offset(-320, 0));
      await tester.pumpAndSettle();
    }

    Future<void> swipeRight() async {
      await tester.dragFrom(const Offset(40, 500), const Offset(320, 0));
      await tester.pumpAndSettle();
    }

    Finder destination(String label) => find.descendant(
          of: navigationBar,
          matching: find.text(label),
        );

    expectSelectedTab(3);

    await swipeRight();
    expectSelectedTab(2);
    await swipeRight();
    expectSelectedTab(1);
    await swipeRight();
    expectSelectedTab(0);
    await swipeLeft();
    expectSelectedTab(1);
    await swipeLeft();
    expectSelectedTab(2);
    await swipeLeft();
    expectSelectedTab(3);

    await tester.tap(destination('Info'));
    await tester.pumpAndSettle();
    expectSelectedTab(0);
    await tester.tap(destination('Video queue'));
    await tester.pumpAndSettle();
    expectSelectedTab(3);
    await tester.tap(destination('Info'));
    await tester.pumpAndSettle();
    expectSelectedTab(0);
  });

  testWidgets('portrait tablet expanded player tabs ignore horizontal swipes',
      (tester) async {
    await _pumpExpandedPlayer(
      tester,
      const Size(768, 1024),
      selectedIndex: 0,
    );

    final navigationBar = find.descendant(
      of: find.byType(ExpandedPlayer),
      matching: find.byType(NavigationBar),
    );

    expect(tester.widget<NavigationBar>(navigationBar).selectedIndex, 0);

    await tester.dragFrom(const Offset(700, 600), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(tester.widget<NavigationBar>(navigationBar).selectedIndex, 0);
  });

  testWidgets(
      'distraction-free expanded player maps swipes to its two visible tabs',
      (tester) async {
    await _pumpExpandedPlayer(
      tester,
      const Size(390, 844),
      distractionFree: true,
      selectedIndex: 0,
    );

    final expandedPlayer = find.byType(ExpandedPlayer);
    final player = tester.element(expandedPlayer).read<PlayerCubit>();
    final navigationBar = find.descendant(
      of: expandedPlayer,
      matching: find.byType(NavigationBar),
    );

    void expectSelection({required int tab, required int destination}) {
      expect(player.state.selectedFullScreenIndex, tab);
      expect(
        tester.widget<NavigationBar>(navigationBar).selectedIndex,
        destination,
      );
    }

    Finder destination(String label) => find.descendant(
          of: navigationBar,
          matching: find.text(label),
        );

    expect(destination('Info'), findsOneWidget);
    expect(destination('Comments'), findsNothing);
    expect(destination('Recommended'), findsNothing);
    expect(destination('Video queue'), findsOneWidget);
    expectSelection(tab: 0, destination: 0);

    await tester.dragFrom(const Offset(350, 500), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expectSelection(tab: 3, destination: 1);

    await tester.dragFrom(const Offset(40, 500), const Offset(320, 0));
    await tester.pumpAndSettle();
    expectSelection(tab: 0, destination: 0);

    await tester.tap(destination('Video queue'));
    await tester.pumpAndSettle();
    expectSelection(tab: 3, destination: 1);

    await tester.tap(destination('Info'));
    await tester.pumpAndSettle();
    expectSelection(tab: 0, destination: 0);
  });

  testWidgets(
      'expanded player minimizes only for a downward swipe on the video',
      (tester) async {
    await _pumpExpandedPlayer(
      tester,
      const Size(390, 844),
      selectedIndex: 0,
    );

    final expandedPlayer = find.byType(ExpandedPlayer);
    final player = tester.element(expandedPlayer).read<PlayerCubit>();
    final videoSurface = find.ancestor(
      of: find.byKey(const ValueKey('player')),
      matching: find.byType(AspectRatio),
    );

    expect(player.state.isMini, isFalse);

    final videoCenter = tester.getCenter(videoSurface);

    await tester.dragFrom(videoCenter, const Offset(-260, 0));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(player.state.selectedFullScreenIndex, 0);

    await tester.dragFrom(videoCenter, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);

    await tester.dragFrom(videoCenter, const Offset(0, 260));
    await tester.pumpAndSettle();

    expect(player.state.isMini, isTrue);
    expect(player.state.top, isNull);
    expect(
      find.descendant(
        of: expandedPlayer,
        matching: find.byType(NavigationBar),
      ),
      findsNothing,
    );
  });

  testWidgets('mini player opens on tap without intercepting its controls',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    player.showMiniPlayer();
    await tester.pumpAndSettle();
    final playerView = find.byType(Player);
    await tester.tap(find.descendant(
        of: playerView, matching: find.byIcon(Icons.fast_forward)));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isTrue);

    final video = player.state.currentlyPlaying!;
    await tester.tap(find.descendant(
        of: playerView,
        matching: find.text('${video.title} - ${video.author}')));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(player.state.isHidden, isFalse);

    player.showMiniPlayer();
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: playerView, matching: find.byIcon(Icons.clear)));
    await tester.pumpAndSettle();
    expect(player.state.isHidden, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final loggedIn in [false, true]) {
    for (final tab in [0, 1]) {
      testWidgets(
          'pulling down ${tab == 0 ? 'description' : 'comments'} at the top minimizes (${loggedIn ? 'account' : 'guest'})',
          (tester) async {
        final service = globals.service as _TestService;
        service.loggedIn = loggedIn;
        service.videos[0] = service.videos[0].copyWith(
          description:
              List.filled(60, 'A line from the description.').join('\n'),
        );
        service.comments = List.generate(
          20,
          (index) => Comment(
              'Viewer $index',
              [],
              'viewer-$index',
              '',
              false,
              'A comment about this video.',
              'Today',
              0,
              '$index',
              false,
              null,
              null),
        );
        await _pumpExpandedPlayer(tester, const Size(390, 844),
            selectedIndex: tab);
        final player =
            tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
        final content = find
            .descendant(
              of: find.byType(ExpandedPlayer),
              matching: find.byType(SingleChildScrollView),
            )
            .hitTestable()
            .first;
        final position = tester
            .state<ScrollableState>(find
                .descendant(
                  of: content,
                  matching: find.byType(Scrollable),
                )
                .first)
            .position;
        final start = tester.getTopLeft(content) + const Offset(180, 90);

        await tester.dragFrom(
            start + const Offset(0, 150), const Offset(0, -260));
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(0));
        expect(player.state.isMini, isFalse);

        // Reaching the top during a scroll should not also dismiss the player.
        position.jumpTo(80);
        await tester.pump();
        await tester.dragFrom(start, const Offset(0, 260));
        await tester.pumpAndSettle();
        expect(position.pixels, 0);
        expect(player.state.isMini, isFalse);

        await tester.dragFrom(start, const Offset(0, 260));
        await tester.pumpAndSettle();
        expect(player.state.isMini, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('empty comments can be pulled down from the blank area',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 1);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New').last);
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'new');

    await tester.dragFrom(const Offset(180, 470), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    await tester.dragFrom(const Offset(180, 470), const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isTrue);
  });

  for (final selectionGesture in [
    'long press',
    'double tap',
    'long press with second touch'
  ]) {
    for (final scrollOffset
        in selectionGesture == 'long press' ? [0.0, 200.0] : [0.0]) {
      testWidgets(
          '$selectionGesture selection at offset $scrollOffset does not minimize',
          (tester) async {
        final service = globals.service as _TestService;
        service.videos[0] = service.videos[0].copyWith(
          description:
              List.filled(60, 'A line from the description.').join('\n'),
        );
        await _pumpExpandedPlayer(tester, const Size(390, 844),
            selectedIndex: 0);
        final player =
            tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
        final content = find
            .descendant(
                of: find.byType(ExpandedPlayer),
                matching: find.byType(SingleChildScrollView))
            .hitTestable()
            .first;
        final position = tester
            .state<ScrollableState>(find
                .descendant(of: content, matching: find.byType(Scrollable))
                .first)
            .position;
        position.jumpTo(scrollOffset);
        await tester.pump();
        final text = find
            .descendant(of: content, matching: find.byType(EditableText))
            .first;
        final textTop = tester.getTopLeft(text);
        final contentTop = tester.getTopLeft(content);
        final start = Offset(textTop.dx + 80,
            (textTop.dy > contentTop.dy ? textTop.dy : contentTop.dy) + 20);
        if (selectionGesture == 'double tap') {
          await tester.tapAt(start);
          await tester.pump(const Duration(milliseconds: 100));
        }
        final selection = await tester.startGesture(start);
        if (selectionGesture == 'double tap') {
          // Start word selection before extending it vertically across lines.
          await selection.moveBy(const Offset(40, 0));
          await tester.pump();
        } else {
          await tester.pump(const Duration(milliseconds: 600));
        }
        expect(
            tester.widget<EditableText>(text).controller.selection.isCollapsed,
            isFalse);
        if (selectionGesture == 'long press with second touch') {
          final secondTouch = await tester
              .startGesture(contentTop + const Offset(4, 10), pointer: 2);
          await secondTouch.moveBy(const Offset(0, 40));
          await tester.pump();
          await secondTouch.up();
        }
        await selection.moveBy(const Offset(0, 230),
            timeStamp: const Duration(milliseconds: 600));
        await tester.pump();
        await selection.up();
        await tester.pumpAndSettle();
        expect(player.state.isMini, isFalse);
      });
    }
  }

  testWidgets('PiP fills the window and restores the mini player layout',
      (tester) async {
    final video = (globals.service as _TestService).videos[0];
    await _pumpHomepage(tester, const Size(390, 844),
        playerState: PlayerState.init([video])
            .copyWith(currentlyPlaying: video, isMini: true, isHidden: false));
    final playerView = find.byType(Player);
    final player = tester.element(playerView).read<PlayerCubit>();
    final videoSurface = find.ancestor(
      of: find.byKey(const ValueKey('player')),
      matching: find.byType(AspectRatio),
    );
    final miniWidth = tester.getSize(videoSurface).width;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
        'puntito.simple_pip_mode',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('onPipEntered')),
        (_) {});
    await tester.pumpAndSettle();
    expect(tester.getSize(videoSurface).width, 390);
    final positioned = tester.widget<AnimatedPositioned>(find.descendant(
        of: playerView, matching: find.byType(AnimatedPositioned)));
    expect(positioned.top, 0);
    expect(positioned.bottom, 0);
    expect(player.state.isMini, isTrue);
    expect(player.state.fullScreenState, FullScreenState.notFullScreen);
    expect(find.descendant(of: playerView, matching: find.byType(AppBar)),
        findsNothing);

    await messenger.handlePlatformMessage(
        'puntito.simple_pip_mode',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('onPipExited')),
        (_) {});
    await tester.pumpAndSettle();
    expect(tester.getSize(videoSurface).width, miniWidth);
    expect(tester.takeException(), isNull);
  });

  for (final tab in [0, 1]) {
    testWidgets('routed video tab $tab pulls down without starting playback',
        (tester) async {
      final service = globals.service as _TestService;
      service.videos[0] = service.videos[0].copyWith(
        description: List.filled(60, 'A line from the description.').join('\n'),
      );
      service.comments = List.generate(
        20,
        (index) => Comment(
            'Viewer $index',
            [],
            'viewer-$index',
            '',
            false,
            'A comment about this video.',
            'Today',
            0,
            '$index',
            false,
            null,
            null),
      );
      // An existing mini player should survive dismissing a different preview.
      final playing = tab == 1 ? service.videos[1] : null;
      await _pumpVideo(tester, const Size(390, 844),
          playerState: playing == null
              ? null
              : PlayerState.init([playing]).copyWith(
                  currentlyPlaying: playing, isMini: true, isHidden: false));
      final screen = find.byType(VideoScreen);
      final player = tester.element(screen).read<PlayerCubit>();
      if (tab == 1) {
        await tester.tap(find.descendant(
            of: find.byType(NavigationBar).last,
            matching: find.text('Comments')));
        await tester.pumpAndSettle();
      }
      final content = find
          .descendant(of: screen, matching: find.byType(SingleChildScrollView))
          .hitTestable()
          .first;
      final position = tester
          .state<ScrollableState>(find
              .descendant(of: content, matching: find.byType(Scrollable))
              .first)
          .position;
      final start = tester.getTopLeft(content) + const Offset(180, 90);

      position.jumpTo(80);
      await tester.pump();
      await tester.dragFrom(start, const Offset(0, 260));
      await tester.pumpAndSettle();
      expect(screen, findsOneWidget);
      expect(position.pixels, 0);

      await tester.dragFrom(start, const Offset(0, 260));
      await tester.pumpAndSettle();
      expect(screen, findsNothing);
      expect(player.state.currentlyPlaying, playing);
      expect(tester.takeException(), isNull);
    });
  }

  group('VideoThumbnailView controls', () {
    testWidgets('shared image failures advance every mounted thumbnail',
        (tester) async {
      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Row(children: [
          for (final host in ['yt3.googleusercontent.com', 'yt3.ggpht.com'])
            Thumbnail(
              width: 40,
              height: 40,
              thumbnails: [
                'https://$host/avatar=s176',
                'https://$host/avatar=s88'
              ],
              decoration: const BoxDecoration(),
            ),
        ]))));
        await _pumpUntilRequestCount(tester, cacheManager, 1);
        cacheManager.failRequest(0);
        await _pumpUntilRequestCount(tester, cacheManager, 2);
        cacheManager.succeedRequest(1);
        await _pumpUntilThumbnailSettles(tester);

        expect(
            tester
                .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
                .map((image) => image.imageUrl),
            [
              'https://example.com/ggpht/avatar=s88',
              'https://example.com/ggpht/avatar=s88'
            ]);
        expect(find.byIcon(Icons.error_outline), findsNothing);
        expect(cacheManager.requests, hasLength(2));
      });
    });

    testWidgets(
        'selects a source for physical pixels and resizes the painted image',
        (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await _pumpVideoThumbnail(tester,
            thumbnails: const ['/maxres.jpg', '/medium.jpg'],
            images: [
              ImageObject('maxres', '/maxres.jpg', 1280, 720),
              ImageObject('medium', '/medium.jpg', 800, 450),
            ],
            onPressed: () {});
        await _pumpUntilRequestCount(tester, cacheManager, 1);
        expect(
            cacheManager.requests.single.url, 'https://example.com/medium.jpg');
        final loader =
            tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
        expect(loader.memCacheWidth, 640);
        expect(loader.memCacheHeight, isNull);
        cacheManager.succeedRequest(0);
        await _pumpUntilThumbnailSettles(tester);
        final decoration = tester
            .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
            .map((container) => container.decoration)
            .whereType<BoxDecoration>()
            .singleWhere((decoration) => decoration.image != null);
        final painted = decoration.image!.image as ResizeImage;
        expect(painted.width, loader.memCacheWidth);
        expect(painted.height, loader.memCacheHeight);
        expect(cacheManager.requests, hasLength(1));
      });
    });

    testWidgets(
        'cover decode retains aspect ratio and advances sized fallbacks',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Thumbnail(
          width: 100,
          height: 100,
          images: [
            ImageObject('maxres', '/large.jpg', 800, 400),
            ImageObject('medium', '/wide.jpg', 400, 200),
          ],
          decoration: const BoxDecoration(),
        ))));
        await _pumpUntilRequestCount(tester, cacheManager, 1);
        expect(
            cacheManager.requests.single.url, 'https://example.com/wide.jpg');
        var loader =
            tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
        expect(loader.memCacheWidth, isNull);
        expect(loader.memCacheHeight, 100);
        cacheManager.failRequest(0);
        await _pumpUntilRequestCount(tester, cacheManager, 2);
        expect(cacheManager.requests.last.url, 'https://example.com/large.jpg');
        loader =
            tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
        expect(loader.memCacheWidth, isNull);
        expect(loader.memCacheHeight, 100);
        cacheManager.succeedRequest(1);
        await _pumpUntilThumbnailSettles(tester);
        expect(find.byIcon(Icons.error_outline), findsNothing);
      });
    });

    testWidgets('equivalent image URLs do not stall the next fallback',
        (tester) async {
      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await _pumpVideoThumbnail(
          tester,
          thumbnails: const [
            'https://yt3.googleusercontent.com/avatar=s176',
            'https://yt3.ggpht.com/avatar=s176',
            '/ggpht/avatar=s176',
            'https://yt3.ggpht.com/avatar=s88',
          ],
          onPressed: () {},
        );
        await _pumpUntilRequestCount(tester, cacheManager, 1);
        cacheManager.failRequest(0);
        await _pumpUntilRequestCount(tester, cacheManager, 2);
        expect(cacheManager.requests.last.url,
            'https://example.com/ggpht/avatar=s88');
        cacheManager.succeedRequest(1);
        await _pumpUntilThumbnailSettles(tester);
        expect(find.byIcon(Icons.error_outline), findsNothing);
        expect(cacheManager.requests, hasLength(2));
      });
    });

    testWidgets('Google image fallbacks stay on the instance', (tester) async {
      await _withThumbnailCacheManager(tester, (cacheManager) async {
        await _pumpVideoThumbnail(
          tester,
          thumbnails: const [
            'https://yt3.googleusercontent.com/avatar=s176',
            '//yt3.ggpht.com/avatar=s88',
            'https://i.ytimg.com/vi/video-id/default.jpg',
          ],
          onPressed: () {},
        );

        const expectedUrls = [
          'https://example.com/ggpht/avatar=s176',
          'https://example.com/ggpht/avatar=s88',
          'https://example.com/vi/video-id/default.jpg',
        ];
        for (var index = 0; index < expectedUrls.length; index++) {
          await _pumpUntilRequestCount(tester, cacheManager, index + 1);
          expect(cacheManager.requests[index].url, expectedUrls[index]);
          expect(cacheManager.requests[index].headers, _instanceHeaders);
          cacheManager.failRequest(index);
        }
        await tester.pumpAndSettle();
        expect(cacheManager.requests, hasLength(expectedUrls.length));
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
      });
    });

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
