import 'dart:async';
import 'dart:collection';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/comments/models/comment.dart';
import 'package:clipious/comments/models/video_comments.dart';
import 'package:clipious/comments/views/components/comments_container.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/content_mode.dart';
import 'package:clipious/home/models/phone_navigation.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_layout.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_mode.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/mini_player_controls.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/player/views/screens/video_queue.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/app_customizer.dart';
import 'package:clipious/settings/views/components/phone_navigation_editor.dart';
import 'package:clipious/subscription_management/models/subscription.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_item_list.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/text_linkified.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
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
const _navigationSong = Video(
  videoId: 'musicnav001',
  title: 'Preview song',
  lengthSeconds: 60,
  musicMetadata: MusicMetadata(title: 'Preview song', artist: 'Artist'),
);
final _instanceRequestHeaders = gatewayContextHeaders(
    profileId: 'default',
    accountId: 'https://example.com',
    serverUrl: 'https://example.com',
    targetUrl: 'https://example.com',
    headers: _instanceHeaders);
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
  final commentSorts = <String?>[];
  List<Video> feedVideos = [];
  final feedRequests = <int>[];
  int discoveryRequests = 0;
  bool failNextFeed = false;

  @override
  Future<VideoTranscript> getTranscript(
    String videoId,
    Caption caption, {
    Server? serverOverride,
  }) async {
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
  Future<void> syncHistory() async {}

  @override
  Future<bool> isLoggedIn() async => loggedIn;

  @override
  Future<List<Subscription>> getRecommendationSubscriptions({
    required Server server,
    required Future<void> Function() beforeRequest,
  }) async {
    await beforeRequest();
    return const [];
  }

  @override
  Future<List<Video>> getTrending({String? type}) async {
    discoveryRequests++;
    return videos;
  }

  @override
  Future<List<Video>> getPopular() async {
    discoveryRequests++;
    return videos;
  }

  @override
  Future<Video> getVideo(String videoId,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest,
          VideoLoadObserver? loadObserver}) async =>
      videos.singleWhere((video) => video.videoId == videoId);

  @override
  Future<VideoComments> getComments(String videoId,
      {String? continuation, String? sortBy, String? source}) async {
    commentSorts.add(sortBy);
    return VideoComments(comments.length, videoId, null, comments);
  }

  @override
  Future<bool> isSubscribedToChannel(String channelId) async => false;

  @override
  Future<UserFeed> getUserFeed(
      {int? maxResults,
      int? page,
      bool saveLastSeen = true,
      Server? serverOverride}) async {
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
          Server? serverOverride,
          ChannelSortBy sortBy = ChannelSortBy.newest}) async =>
      VideosWithContinuation([], null);
}

class _PendingNavigationSettings extends TestSettingsCubit {
  _PendingNavigationSettings(super.initialState, super.appCubit);
  Completer<void>? pending;

  @override
  Future<void> setPhoneNavigation(PhoneNavigation layout) async {
    await pending?.future;
    await super.setPhoneNavigation(layout);
  }
}

class _SessionApp extends TestAppCubit {
  _SessionApp() : super(AppState(0, null, HomeLayout()));

  void restartSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));
}

class _TestMusicCatalog extends MusicCatalogService {
  int trendingCalls = 0;
  int searchSongCalls = 0;
  int searchSongCount = 1;
  Completer<void>? pendingArtist;

  List<MusicTrack> discoverySongs = const [];

  @override
  Future<List<MusicTrack>> getDiscoverySongs(
      {String? artist,
      bool Function()? isCurrent,
      void Function(InvidiousServiceError)? onInstanceFailure}) async {
    return isCurrent?.call() == false ? const [] : discoverySongs;
  }

  @override
  Future<List<MusicTrack>> getTrendingSongs() async {
    trendingCalls++;
    return [const MusicTrack(videoId: 'freshsong01', title: 'Fresh song')];
  }

  @override
  Future<List<MusicTrack>> searchSongs(String query) async {
    searchSongCalls++;
    return [
      MusicTrack(
          videoId: 'searchsong1',
          title: 'Search result $query',
          artists: const [
            'Music channel'
          ],
          artistLinks: const [
            MusicArtist(id: 'UCmusic', name: 'Music channel')
          ]),
      for (var index = 1; index < searchSongCount; index++)
        MusicTrack(
          videoId: 'result${index.toString().padLeft(5, '0')}',
          title: 'Search result $query $index',
          artists: const ['Music channel'],
        ),
    ];
  }

  @override
  Future<List<MusicArtist>> searchArtists(String query) async =>
      const [MusicArtist(id: 'UCmusic', name: 'Music channel')];

  @override
  Future<MusicTrack> getSong(String videoId,
          {VideoLoadObserver? loadObserver}) async =>
      MusicTrack(videoId: videoId, title: 'Fresh song');

  @override
  Future<MusicArtistPage> getArtist(String id) async {
    await pendingArtist?.future;
    return const MusicArtistPage(
        artist: MusicArtist(id: 'UCmusic', name: 'Music channel'),
        description: 'Channel uploads',
        songs: [MusicTrack(videoId: 'freshsong01', title: 'Fresh song')]);
  }

  @override
  Future<List<MusicPlaylist>> searchPlaylists(String query) async =>
      const [MusicPlaylist(id: 'PLpublic', title: 'Public playlist')];

  @override
  Future<MusicCollection> getPlaylist(String id) async => MusicCollection(
      id: id,
      title: 'Public playlist',
      tracks: const [MusicTrack(videoId: 'freshsong01', title: 'Fresh song')]);
}

Finder _phoneTab(PhoneNavigationItem item) =>
    find.byKey(ValueKey('main-navigation-${item.name}'));

final _musicNavigation = find.byKey(const ValueKey('music-destination-bar'));

final _phoneNavigation = find.byWidgetPredicate((widget) =>
    widget is NavigationBar &&
    widget.destinations.any((destination) {
      final key = destination.key;
      return key is ValueKey<String> &&
          key.value.startsWith('main-navigation-');
    }));

Future<void> _selectPhoneTab(
    WidgetTester tester, PhoneNavigationItem item) async {
  await tester.tap(_phoneTab(item));
  await tester.pumpAndSettle();
}

Finder _musicSection(MusicDestination section) =>
    find.byKey(ValueKey('music-section-${section.name}'));

void _expectMusicSection(WidgetTester tester, MusicDestination section) {
  final row = tester.widget<NavigationBar>(_musicNavigation);
  expect(row.destinations[row.selectedIndex].key,
      ValueKey('music-section-${section.name}'));
}

Future<void> _selectMusicSection(
    WidgetTester tester, MusicDestination section) async {
  final target = _musicSection(section).hitTestable();
  expect(target, findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _openPhoneQueue(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More shortcuts'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Video queue'));
  await tester.pumpAndSettle();
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

class _LauncherShufflePlayer extends TestPlayerCubit {
  _LauncherShufflePlayer(super.initialState, super.settings);

  final requests = <List<String>>[];

  @override
  Future<void> shuffleLocalMusic(List<LocalMusicTrack> tracks,
      {required String queueTitle, required bool Function() isCurrent}) async {
    expect(isCurrent(), isTrue);
    requests.add(tracks.map((track) => track.title).toList());
  }
}

class _WatchSelectionPlayer extends TestPlayerCubit {
  _WatchSelectionPlayer(super.initialState, super.settings);

  final selection = <(String, bool?)>[];

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      PlaylistReference? recommendationSource,
      bool fromMusic = false,
      bool songTap = false,
      bool collectionDetail = false}) async {
    selection.add((videos.single.videoId, audio));
  }
}

Future<void> _pumpHomepage(
  WidgetTester tester,
  Size size, {
  PlayerState? playerState,
  SettingsState? settingsState,
  PlayerCubit Function(SettingsCubit)? createPlayer,
  SettingsCubit Function(SettingsState, AppCubit)? createSettings,
  AppCubit? initialApp,
  ThemeData? theme,
  int firstIndex = 0,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.runAsync(() => globals.db
      .saveSetting(SettingsValue(onOpenSettingName, firstIndex.toString())));
  final appCubit =
      initialApp ?? TestAppCubit(AppState(firstIndex, null, HomeLayout()));
  final initialSettings = settingsState ?? SettingsState.init();
  final settingsCubit = createSettings?.call(initialSettings, appCubit) ??
      TestSettingsCubit(initialSettings, appCubit);

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
      theme: theme,
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
  SettingsState? settingsState,
}) async {
  final video = (globals.service as _TestService).videos[videoIndex];
  final initialSettings = settingsState ?? SettingsState.init();
  await _pumpHomepage(
    tester,
    size,
    settingsState: distractionFree
        ? initialSettings.copyWith(settings: {
            ...initialSettings.settings,
            distractionFreeModeSettingName:
                SettingsValue(distractionFreeModeSettingName, 'true'),
          })
        : initialSettings,
    playerState: PlayerState.init([video]).copyWith(
      currentlyPlaying: video,
      isMini: false,
      isHidden: false,
      selectedFullScreenIndex: selectedIndex,
      top: 0,
    ),
  );
}

void _mockVideoWakelock() {
  const channel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler(
      channel, (_) async => const StandardMessageCodec().encodeMessage([null]));
  addTearDown(() => messenger.setMockMessageHandler(channel, null));
}

Future<void> _pumpVideo(WidgetTester tester, Size size,
    {PlayerState? playerState, SettingsState? settingsState}) async {
  tester.platformDispatcher.textScaleFactorTestValue = 0.9;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await _pumpHomepage(tester, size,
      playerState: playerState, settingsState: settingsState);
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
  late MusicCatalogService previousCatalog;
  const localMusicChannel =
      MethodChannel('com.github.dvbeckwitt.videre/local_music');

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (_) async => throw MissingPluginException());
    app_main.isTv = false;
    previousCatalog = musicCatalogService;
    musicCatalogService = _TestMusicCatalog();
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
    globals.db = await createPlayerTestDatabase();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(localMusicChannel, (call) async {
      return switch (call.method) {
        'getFolder' => null,
        'pendingRenames' => const <Object?>[],
        _ => throw MissingPluginException(call.method),
      };
    });
    // The app retains this Future across pages. Complete it before entering the
    // first widget's fake clock so later shortcut routes can await it.
    await LocalMusicLibrary.instance.initialize();

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
        .setMockMethodCallHandler(
            const MethodChannel('videre/recommendations'), null);
    musicCatalogService = previousCatalog;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(localMusicChannel, null);
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
        ['Home', 'Subscriptions', 'History', 'Music', 'Search']);
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
        hasLength(3));
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

  testWidgets('tablet layout editor preserves saved indexes for visible tabs',
      (tester) async {
    await _pumpHomepage(tester, const Size(1024, 768));
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browsing'));
    await tester.pumpAndSettle();
    expect(
        find.text('Home, Subscriptions, Playlists, History'), findsOneWidget);
    await tester.tap(find.text('Customize app sections'));
    await tester.pumpAndSettle();
    expect(find.text('Playlists'), findsOneWidget);
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
    reorder(3, 3);
    reorder(3, 4);
    await tester.pumpAndSettle();
    expect(settings.state.appLayout, originalLayout);
    expect(settings.state.onOpen, 3);

    reorder(3, 0);
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

  testWidgets(
      'home editor drags navigation between areas, reorders and restores defaults',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    unawaited(appRouter.push(const EditHomeLayoutRoute()));
    await tester.pumpAndSettle();
    final settings = tester
        .element(find.byKey(const ValueKey('navigation-item-home')))
        .read<SettingsCubit>();

    Future<void> drag(String item, Offset target) async {
      final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('navigation-item-$item'))));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(target);
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    final top =
        tester.getRect(find.byKey(const ValueKey('navigation-area-top')));
    await drag('history', Offset(top.center.dx, top.bottom - 20));
    expect(
        settings.state.phoneNavigation.top.last, PhoneNavigationItem.history);
    await drag('playlist',
        tester.getCenter(find.byKey(const ValueKey('navigation-item-search'))));
    expect(settings.state.phoneNavigation.bottom, [
      PhoneNavigationItem.home,
      PhoneNavigationItem.subscription,
      PhoneNavigationItem.music,
      PhoneNavigationItem.playlist,
      PhoneNavigationItem.search
    ]);
    await drag('music',
        tester.getCenter(find.byKey(const ValueKey('navigation-item-home'))));
    await drag('search',
        tester.getCenter(find.byKey(const ValueKey('navigation-item-home'))));
    expect(settings.state.phoneNavigation.bottom.take(2),
        [PhoneNavigationItem.music, PhoneNavigationItem.search]);
    expect(SettingsState.init().phoneNavigation.encode(),
        settings.state.phoneNavigation.encode());
    await tester.pageBack();
    await tester.pumpAndSettle();
    var navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(
        navigation.destinations
            .cast<NavigationDestination>()
            .map((item) => item.label),
        ['Music', 'Search', 'Home', 'Subscriptions', 'Playlists']);
    expect(navigation.selectedIndex, 2);
    await tester.tap(find.byTooltip('More shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('History'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    unawaited(appRouter.push(const EditHomeLayoutRoute()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Restore default navigation'), 240,
        scrollable: find
            .descendant(
                of: find.byType(PhoneNavigationEditor),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Restore default navigation'));
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.encode(),
        PhoneNavigation.defaults().encode());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'navigation drag back onto the same item does not reorder or save',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    unawaited(appRouter.push(const EditHomeLayoutRoute()));
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('navigation-item-home'));
    final settings = tester.element(item).read<SettingsCubit>();
    final original = settings.state.phoneNavigation.encode();
    final point = tester.getCenter(item);
    final gesture = await tester.startGesture(point);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(5, 0));
    await gesture.moveTo(point);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.encode(), original);
    expect(settings.state.savedPhoneNavigation, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('navigation drag keeps scrolling while held at the edge',
      (tester) async {
    globals.service = _TestService(videos: []);
    await _pumpHomepage(tester, const Size(320, 640));
    unawaited(appRouter.push(const EditHomeLayoutRoute()));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
            of: find.byType(PhoneNavigationEditor),
            matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final gesture = await tester.startGesture(tester
        .getCenter(find.byKey(const ValueKey('navigation-item-downloads'))));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(const Offset(280, 630));
    for (var frame = 0; frame < 25; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(position.pixels, greaterThan(200));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'navigation drag released after scrolling uses the visible drop area',
      (tester) async {
    globals.service = _TestService(videos: []);
    await _pumpHomepage(tester, const Size(320, 640));
    unawaited(appRouter.push(const EditHomeLayoutRoute()));
    await tester.pumpAndSettle();
    final settings = tester
        .element(find.byType(PhoneNavigationEditor))
        .read<SettingsCubit>();
    final point = const Offset(280, 620);
    final gesture = await tester.startGesture(tester
        .getCenter(find.byKey(const ValueKey('navigation-item-downloads'))));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(point);
    final hidden = find.byKey(const ValueKey('navigation-area-hidden'));
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (hidden.evaluate().isNotEmpty &&
          tester.getRect(hidden).contains(point)) {
        break;
      }
    }
    expect(tester.getRect(hidden).contains(point), isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.hidden,
        contains(PhoneNavigationItem.downloads));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('home layout editor fits a landscape phone', (tester) async {
    globals.service = _TestService(videos: []);
    await _pumpHomepage(tester, const Size(640, 320));
    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Home tabs'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    unawaited(appRouter.push(const EditHomeLayoutRoute()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'navigation save failure preserves layout and retry survives closing the editor',
      (tester) async {
    late _PendingNavigationSettings settings;
    await _pumpHomepage(tester, const Size(390, 844),
        createSettings: (initial, app) =>
            settings = _PendingNavigationSettings(initial, app));
    unawaited(appRouter.push(const EditHomeLayoutRoute()));
    await tester.pumpAndSettle();
    final original = settings.state.phoneNavigation.encode();
    Future<void> hideQueue() async {
      await tester.tap(find.byKey(const ValueKey('navigation-item-queue')));
      await tester.pumpAndSettle();
      settings.pending = Completer<void>();
      await tester.tap(find.text('Hidden').last);
      await tester.pump();
    }

    await hideQueue();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    settings.pending!.completeError(StateError('storage unavailable'));
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.encode(), original);
    expect(find.text('Could not save the navigation layout. Please try again.'),
        findsOneWidget);
    await hideQueue();
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 1));
    settings.pending!.complete();
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.hidden,
        contains(PhoneNavigationItem.queue));
    expect(SettingsState.init().phoneNavigation.encode(),
        settings.state.phoneNavigation.encode());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'removing the selected navigation tab and disabling search history keeps navigation usable',
      (tester) async {
    globals.service = _TestService(videos: []);
    await _pumpHomepage(tester, const Size(390, 844), firstIndex: 3);
    final settings =
        tester.element(find.byType(NavigationBar)).read<SettingsCubit>();
    var layout = settings.state.phoneNavigation
        .move(PhoneNavigationItem.history, NavigationArea.top)!;
    await tester.runAsync(() => settings.setPhoneNavigation(layout));
    await tester.pumpAndSettle();
    var navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(
        navigation.destinations[navigation.selectedIndex],
        isA<NavigationDestination>().having(
            (destination) => destination.label, 'selected label', 'Home'));
    layout = PhoneNavigation(
        [PhoneNavigationItem.searchHistory, PhoneNavigationItem.search],
        [PhoneNavigationItem.home]);
    await tester.runAsync(() => settings.setPhoneNavigation(layout));
    await tester.pumpAndSettle();
    await tester.runAsync(() => settings.setUseSearchHistory(false));
    await tester.pumpAndSettle();
    navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(
        navigation.destinations
            .cast<NavigationDestination>()
            .map((item) => item.label),
        ['Home', 'Search']);
    expect(navigation.selectedIndex, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'custom phone actions and overflow preserve selected tab and search focus',
      (tester) async {
    final layout = PhoneNavigation([
      PhoneNavigationItem.playlist,
      PhoneNavigationItem.home,
      PhoneNavigationItem.downloads,
      PhoneNavigationItem.queue,
      PhoneNavigationItem.subscription,
    ], [
      PhoneNavigationItem.search,
      PhoneNavigationItem.history,
      PhoneNavigationItem.popular,
      PhoneNavigationItem.trending
    ]);
    final initial = SettingsState.init();
    await _pumpHomepage(tester, const Size(320, 640),
        settingsState: initial.copyWith(settings: {
          ...initial.settings,
          phoneNavigationSettingName:
              SettingsValue(phoneNavigationSettingName, layout.encode()),
        }));
    final navigation = find.byType(NavigationBar);
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);
    expect(tester.widget<NavigationBar>(navigation).destinations.length, 5);
    for (final icon in [Icons.queue_music, Icons.download]) {
      await tester
          .tap(find.descendant(of: navigation, matching: find.byIcon(icon)));
      await tester.pumpAndSettle();
      expect(navigation, findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);
    }
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trending'));
    await tester.pumpAndSettle();
    expect(find.text('Trending'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'phone shortcut overflow fits large text and opens a long-label item',
      (tester) async {
    globals.service = _TestService(videos: []);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final layout = PhoneNavigation([
      PhoneNavigationItem.home,
      PhoneNavigationItem.search,
    ], [
      PhoneNavigationItem.downloads,
      PhoneNavigationItem.queue,
      PhoneNavigationItem.searchHistory,
      PhoneNavigationItem.history,
    ]);
    final initial = SettingsState.init();
    await _pumpHomepage(tester, const Size(320, 640),
        settingsState: initial.copyWith(settings: {
          ...initial.settings,
          phoneNavigationSettingName:
              SettingsValue(phoneNavigationSettingName, layout.encode()),
        }));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('More shortcuts'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Search history'));
    await tester.pumpAndSettle();
    expect(find.text('Search history'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'navigation editor supports small screens, hidden items and startup changes',
      (tester) async {
    globals.service = _TestService(videos: []);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpHomepage(tester, const Size(320, 640));
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browsing'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Customize app sections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customize app sections'));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
            of: find.byType(PhoneNavigationEditor),
            matching: find.byType(Scrollable))
        .first;
    final settings = tester
        .element(find.byType(PhoneNavigationEditor))
        .read<SettingsCubit>();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('navigation-item-history')), 200,
        scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-item-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open this tab at startup'));
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.startup, PhoneNavigationItem.history);
    await tester.tap(find.byKey(const ValueKey('navigation-item-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden').last);
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.hidden,
        contains(PhoneNavigationItem.history));
    expect(settings.state.phoneNavigation.startup, PhoneNavigationItem.home);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('navigation-item-popular')), 200,
        scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-item-popular')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bottom tabs').last);
    await tester.pumpAndSettle();
    expect(settings.state.phoneNavigation.bottom.last,
        PhoneNavigationItem.popular);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone navigation falls back from a saved Playlists startup tab',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844), firstIndex: 2);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    await tester.tap(find.byTooltip('More shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists'));
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
    await tester.tap(find.byTooltip('More shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists'));
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
    await tester.tap(find.byTooltip('More shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone queue stays reachable in overflow and preserves the tab',
      (tester) async {
    await _pumpHomepage(tester, const Size(320, 640));
    final navigation = find.byType(NavigationBar);
    await tester.tap(find.descendant(
        of: navigation, matching: find.byIcon(Icons.subscriptions)));
    await tester.pumpAndSettle();
    final selectedIndex =
        tester.widget<NavigationBar>(navigation).selectedIndex;
    expect(tester.getCenter(find.byIcon(Icons.download)).dx,
        lessThan(tester.getCenter(find.byTooltip('More shortcuts')).dx));
    expect(tester.takeException(), isNull);

    await _openPhoneQueue(tester);
    expect(find.byType(VideoQueueScreen), findsOneWidget);
    expect(find.text('Your queue is empty'), findsOneWidget);
    final settings =
        tester.element(find.byType(VideoQueueScreen)).read<SettingsCubit>();
    expect(settings.state.autoplayQueue, isTrue);
    await tester.tap(find.text('Autoplay next in queue'));
    await tester.pumpAndSettle();
    expect(settings.state.autoplayQueue, isFalse);
    expect(SettingsState.init().autoplayQueue, isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
        tester.widget<NavigationBar>(navigation).selectedIndex, selectedIndex);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Music is a primary phone tab and retains its section pages',
      (tester) async {
    await _pumpHomepage(tester, const Size(320, 640));
    final navigation = _phoneNavigation;
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    final historyIndex = tester.widget<NavigationBar>(navigation).selectedIndex;
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    expect(find.byType(MusicModeScreen), findsOneWidget);
    expect(find.byType(SegmentedButton<HomeContentMode>), findsNothing);
    expect(navigation, findsOneWidget);
    expect(_musicNavigation, findsOneWidget);
    expect(find.text('Saved songs'), findsOneWidget);
    expect((musicCatalogService as _TestMusicCatalog).trendingCalls, 0);
    final primary = tester.widget<NavigationBar>(navigation);
    expect(
        primary.destinations
            .cast<NavigationDestination>()
            .map((item) => item.label),
        ['Home', 'Subscriptions', 'History', 'Music', 'Search']);
    expect(primary.selectedIndex, 3);
    final row = tester.widget<NavigationBar>(_musicNavigation);
    expect(
        row.destinations
            .cast<NavigationDestination>()
            .map((destination) => destination.label),
        ['Home', 'Search', 'Library']);
    expect(row.destinations.map((destination) => destination.key), [
      for (final section in MusicDestination.values)
        ValueKey('music-section-${section.name}'),
    ]);
    expect(tester.getRect(_musicNavigation).bottom,
        closeTo(tester.getRect(navigation).top, 0.01));
    for (final section in MusicDestination.values) {
      final target = _musicSection(section);
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    }

    await _selectMusicSection(tester, MusicDestination.search);
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
    _expectMusicSection(tester, MusicDestination.search);
    final field = find.byKey(const ValueKey('music-search'));
    await tester.enterText(field, 'retained song');
    await _selectMusicSection(tester, MusicDestination.library);
    _expectMusicSection(tester, MusicDestination.library);
    expect(find.byKey(const ValueKey('music-library-shortcut-songs')),
        findsOneWidget);

    await _selectPhoneTab(tester, PhoneNavigationItem.search);
    _expectMusicSection(tester, MusicDestination.search);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'retained song');
    tester.testTextInput.hide();
    await _selectPhoneTab(tester, PhoneNavigationItem.search);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
    _expectMusicSection(tester, MusicDestination.library);

    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    expect(
        tester.widget<NavigationBar>(navigation).selectedIndex, historyIndex);
    expect(find.text('History'), findsWidgets);
    expect(_musicNavigation.hitTestable(), findsNothing);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    _expectMusicSection(tester, MusicDestination.library);
    await _selectMusicSection(tester, MusicDestination.home);
    expect(find.text('Saved songs'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reselecting a Music destination scrolls only its active list',
      (tester) async {
    final catalog = musicCatalogService as _TestMusicCatalog;
    catalog.searchSongCount = 35;
    final library =
        MusicLibraryService.forProfile(globals.db, globals.db.profileId);
    await tester.runAsync(() async {
      for (var index = 0; index < 30; index++) {
        await library.save(MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'reselect${index.toString().padLeft(3, '0')}',
          title: 'Recorded song $index',
          subtitle: 'Fixture artist',
        ));
      }
    });
    app_main.darkColorScheme = const ColorScheme.dark();
    const position = Duration(seconds: 18);
    final initial = SettingsState.init();
    final layout = const MusicLayout.defaults().copyWith(destinations: const [
      MusicDestination.library,
      MusicDestination.home,
      MusicDestination.search,
    ]);
    await _pumpHomepage(tester, const Size(360, 640),
        settingsState: initial.copyWith(settings: {
          ...initial.settings,
          musicLayoutSettingName:
              SettingsValue(musicLayoutSettingName, layout.encode()),
        }),
        playerState: PlayerState.init([_navigationSong]).copyWith(
          currentlyPlaying: _navigationSong,
          isAudio: true,
          isHidden: false,
          position: position,
        ));
    final player = tester.element(find.byType(Player)).read<PlayerCubit>();
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    _expectMusicSection(tester, MusicDestination.home);
    final home = find.byKey(const PageStorageKey('music-home'));
    final searchResults = find.descendant(
        of: find.byType(MusicScreen), matching: find.byType(ListView));
    final libraryResults =
        find.byKey(const ValueKey('music-saved-songs-results'));
    ScrollPosition scrollOf(Finder view) => tester
        .state<ScrollableState>(find.descendant(
            of: view,
            matching: find.byWidgetPredicate((widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down)))
        .position;
    Future<double> scrollDown(Finder view) async {
      await tester.drag(view, const Offset(0, -280));
      await tester.pumpAndSettle();
      final offset = scrollOf(view).pixels;
      expect(offset, greaterThan(0));
      return offset;
    }

    final homeOffset = await scrollDown(home);
    await _selectMusicSection(tester, MusicDestination.search);
    const query = 'retained destination';
    final searchField = find.byKey(const ValueKey('music-search'));
    final songsFilter = find.descendant(
        of: find.byKey(const ValueKey('music-search-filters')),
        matching: find.widgetWithText(ChoiceChip, 'Songs'));
    await tester.tap(songsFilter);
    await tester.enterText(searchField, query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final searchOffset = await scrollDown(searchResults);
    final searches = catalog.searchSongCalls;

    await _selectMusicSection(tester, MusicDestination.library);
    _expectMusicSection(tester, MusicDestination.library);
    final savedSongs = find.byKey(const ValueKey('music-library-tab-songs'));
    await tester.ensureVisible(savedSongs);
    await tester.tap(savedSongs);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-saved-songs-search')));
    await tester.pumpAndSettle();
    final libraryFind = find.byKey(const ValueKey('music-saved-songs-query'));
    await tester.enterText(libraryFind, 'recorded');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester
        .longPress(find.textContaining('Recorded song').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    final libraryOffset = await scrollDown(libraryResults);

    await tester.tap(_musicSection(MusicDestination.library));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final libraryScroll = scrollOf(libraryResults);
    expect(
        libraryScroll.pixels, allOf(greaterThan(0), lessThan(libraryOffset)));
    await tester.pumpAndSettle();
    expect(libraryScroll.pixels, libraryScroll.minScrollExtent);
    expect(find.text('1 selected'), findsOneWidget);
    _expectMusicSection(tester, MusicDestination.library);

    await _selectMusicSection(tester, MusicDestination.home);
    expect(scrollOf(home).pixels, closeTo(homeOffset, 0.01));
    await _selectMusicSection(tester, MusicDestination.home);
    expect(scrollOf(home).pixels, scrollOf(home).minScrollExtent);
    _expectMusicSection(tester, MusicDestination.home);

    await _selectMusicSection(tester, MusicDestination.search);
    expect(scrollOf(searchResults).pixels, closeTo(searchOffset, 0.01));
    expect(tester.widget<TextField>(searchField).controller!.text, query);
    expect(tester.widget<ChoiceChip>(songsFilter).selected, isTrue);
    tester.widget<TextField>(searchField).focusNode!.unfocus();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    final searchTab = _musicSection(MusicDestination.search);
    final searchIcon = find.descendant(
        of: searchTab, matching: find.byIcon(MusicDestination.search.icon));
    Focus.of(tester.element(searchIcon)).requestFocus();
    await tester.pump();
    expect(Focus.of(tester.element(searchIcon)).hasPrimaryFocus, isTrue);
    expect(MediaQuery.disableAnimationsOf(tester.element(searchIcon)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final searchScroll = scrollOf(searchResults);
    expect(searchScroll.pixels, searchScroll.minScrollExtent);
    expect(tester.widget<TextField>(searchField).controller!.text, query);
    expect(tester.widget<ChoiceChip>(songsFilter).selected, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(catalog.searchSongCalls, searches);
    _expectMusicSection(tester, MusicDestination.search);

    await _selectMusicSection(tester, MusicDestination.library);
    expect(find.text('1 selected'), findsOneWidget);
    expect(scrollOf(libraryResults).pixels, libraryScroll.minScrollExtent);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(libraryFind).controller!.text, 'recorded');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(savedSongs).selected, isTrue);
    _expectMusicSection(tester, MusicDestination.library);
    final appBar = tester.widget<NavigationBar>(_phoneNavigation);
    expect(appBar.destinations[appBar.selectedIndex].key,
        const ValueKey('main-navigation-music'));
    expect(player.state.currentlyPlaying, _navigationSong);
    expect(player.state.position, position);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone Music Search fits above the keyboard at 320 dp',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetViewInsets);
    final catalog = musicCatalogService as _TestMusicCatalog;
    final library =
        MusicLibraryService.forProfile(globals.db, globals.db.profileId);
    await tester.runAsync(() => library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'cafelibrary',
          title: 'Café by the river',
          subtitle: 'Fixture artist',
        )));
    await _pumpHomepage(tester, const Size(320, 640));
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await _selectMusicSection(tester, MusicDestination.search);
    expect(tester.testTextInput.isVisible, isTrue);
    const keyboardHeight = 300.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('music-search'));
    await tester.enterText(field, 'small screen query');
    expect(field.hitTestable(), findsOneWidget);
    expect(tester.getRect(field).bottom, lessThan(640 - keyboardHeight));
    expect(_musicNavigation.hitTestable(), findsNothing);
    expect(_phoneNavigation.hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);

    final librarySource =
        find.byKey(const ValueKey('music-search-source-library'));
    final onlineSource =
        find.byKey(const ValueKey('music-search-source-online'));
    await tester.ensureVisible(librarySource);
    await tester.tap(librarySource);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'cafe river');
    await tester.pumpAndSettle();
    expect(tester.getRect(field).bottom, lessThan(640 - keyboardHeight));
    final librarySongs = find.widgetWithText(FilterChip, 'Songs');
    expect(librarySongs.hitTestable(), findsOneWidget);
    await tester.tap(librarySongs);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(librarySongs).selected, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'cafe river');
    expect(catalog.searchSongCalls, 0);

    tester.testTextInput.hide();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.text('Café by the river'), findsOneWidget);
    await tester.ensureVisible(onlineSource);
    await tester.tap(onlineSource);
    await tester.pumpAndSettle();
    expect(catalog.searchSongCalls, 0);
    expect(_musicSection(MusicDestination.home).hitTestable(), findsOneWidget);
    expect(
        _phoneTab(PhoneNavigationItem.history).hitTestable(), findsOneWidget);
    _expectMusicSection(tester, MusicDestination.search);
    expect(
        tester.widget<TextField>(field).controller!.text, 'small screen query');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Music fits playback, navigation and keyboard on a short phone',
      (tester) async {
    app_main.darkColorScheme = const ColorScheme.dark();
    addTearDown(tester.view.resetViewInsets);
    await _pumpHomepage(tester, const Size(320, 453),
        playerState: PlayerState.init([_navigationSong]).copyWith(
          currentlyPlaying: _navigationSong,
          isAudio: true,
          isHidden: false,
        ));
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    final mini = find.byKey(const ValueKey('music-mini-player'));
    void expectDocked() {
      expect(find.byKey(const ValueKey('music-mini-expand')).hitTestable(),
          findsOneWidget);
      expect(tester.getRect(mini).bottom,
          lessThanOrEqualTo(tester.getRect(_musicNavigation).top + 0.01));
      expect(tester.getRect(_musicNavigation).bottom,
          closeTo(tester.getRect(_phoneNavigation).top, 0.01));
    }

    expectDocked();
    for (final section in MusicDestination.values) {
      final target = _musicSection(section);
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.getSize(target).shortestSide, greaterThanOrEqualTo(48));
    }
    await _selectMusicSection(tester, MusicDestination.search);
    expect(tester.testTextInput.isVisible, isTrue);
    const keyboardHeight = 210.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('music-search'));
    await tester.enterText(field, 'short phone query');
    expect(field.hitTestable(), findsOneWidget);
    expect(tester.getRect(field).bottom, lessThan(453 - keyboardHeight));
    expect(tester.takeException(), isNull);

    const tallKeyboardHeight = 260.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: tallKeyboardHeight);
    await tester.pumpAndSettle();
    expect(field.hitTestable(), findsOneWidget);
    expect(tester.getRect(field).bottom, lessThan(453 - tallKeyboardHeight));
    expect(mini.hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    tester.testTextInput.hide();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expectDocked();
    expect(
        tester.widget<TextField>(field).controller!.text, 'short phone query');

    await _selectMusicSection(tester, MusicDestination.library);
    _expectMusicSection(tester, MusicDestination.library);
    expect(find.byKey(const ValueKey('music-library-shortcut-songs')),
        findsOneWidget);
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    expect(_musicNavigation.hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Music Back from Now Playing and Settings restores the dock and Search',
      (tester) async {
    (musicCatalogService as _TestMusicCatalog).searchSongCount = 25;
    app_main.darkColorScheme = const ColorScheme.dark();
    await _pumpHomepage(tester, const Size(390, 844),
        playerState: PlayerState.init([_navigationSong]).copyWith(
          currentlyPlaying: _navigationSong,
          isAudio: true,
          isHidden: false,
        ));
    final player = tester.element(find.byType(Player)).read<PlayerCubit>();
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.removeByName('miniPlayer'));

    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await _selectMusicSection(tester, MusicDestination.search);
    final field = find.byKey(const ValueKey('music-search'));
    await tester.enterText(field, 'scrolling query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final results = find.descendant(
        of: find.byType(MusicScreen), matching: find.byType(ListView));
    final scrollable =
        find.descendant(of: results, matching: find.byType(Scrollable));

    final mini = find.byKey(const ValueKey('music-mini-player'));
    final expand = find.byKey(const ValueKey('music-mini-expand'));
    void expectPlaybackStack() {
      expect(tester.getRect(mini).bottom,
          lessThanOrEqualTo(tester.getRect(_musicNavigation).top + 0.01));
      expect(tester.getRect(_musicNavigation).bottom,
          closeTo(tester.getRect(_phoneNavigation).top, 0.01));
      expect(tester.getRect(results).bottom,
          lessThanOrEqualTo(tester.getRect(mini).top + 0.01));
      expect(expand.hitTestable(), findsOneWidget);
      expect(_musicSection(MusicDestination.library).hitTestable(),
          findsOneWidget);
      expect(
          _phoneTab(PhoneNavigationItem.history).hitTestable(), findsOneWidget);
    }

    expectPlaybackStack();
    final settings =
        tester.element(find.byType(MusicModeScreen)).read<SettingsCubit>();
    final originalLayout = settings.state.musicLayout;
    final globalHeight = tester.getSize(_phoneNavigation).height;
    expect(tester.getSize(_musicNavigation).height, greaterThan(48));
    await tester.runAsync(() =>
        settings.setMusicLayout(originalLayout.copyWith(slimNavigation: true)));
    await tester.pumpAndSettle();
    expect(tester.getSize(_musicNavigation).height, 48);
    expect(tester.getSize(_phoneNavigation).height, globalHeight);
    _expectMusicSection(tester, MusicDestination.search);
    expect(tester.widget<TextField>(field).controller!.text, 'scrolling query');
    expectPlaybackStack();
    await tester.drag(results, const Offset(0, -385));
    await tester.pumpAndSettle();
    final offset = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset, greaterThan(200));

    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(find.byKey(const ValueKey('music-player-title')).hitTestable(),
        findsOneWidget);
    expect(_musicSection(MusicDestination.search).hitTestable(), findsNothing);
    expect(_phoneTab(PhoneNavigationItem.history).hitTestable(), findsNothing);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();

    expect(player.state.isMini, isTrue);
    expectPlaybackStack();
    _expectMusicSection(tester, MusicDestination.search);
    expect(tester.widget<TextField>(field).controller!.text, 'scrolling query');
    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(offset, 0.01));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Browsing'), findsOneWidget);
    expect(_musicSection(MusicDestination.search).hitTestable(), findsNothing);
    expect(expand.hitTestable(), findsOneWidget);
    expect(tester.getRect(mini).bottom, closeTo(844, 12));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Browsing'), findsNothing);
    expectPlaybackStack();
    _expectMusicSection(tester, MusicDestination.search);
    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(offset, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'reordering Music retains the current page, query and shortcut Back destination',
      (tester) async {
    (musicCatalogService as _TestMusicCatalog).discoverySongs = const [
      MusicTrack(
          videoId: 'discovers01',
          title: 'Discovered recording',
          artists: ['Artist']),
    ];
    await _pumpHomepage(tester, const Size(390, 844));
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await _selectMusicSection(tester, MusicDestination.search);
    final field = find.byKey(const ValueKey('music-search'));
    await tester.enterText(field, 'kept during reorder');
    await _selectMusicSection(tester, MusicDestination.library);
    final settings = tester
        .element(_musicSection(MusicDestination.library))
        .read<SettingsCubit>();
    final layout = MusicLayout(
      destinations: const [
        MusicDestination.home,
        MusicDestination.library,
        MusicDestination.search
      ],
      shortcuts: const [MusicShortcut.discover, MusicShortcut.library],
    );
    await tester.runAsync(() => settings.setMusicLayout(layout));
    await tester.pumpAndSettle();
    final library = _musicSection(MusicDestination.library);
    final search = _musicSection(MusicDestination.search);
    _expectMusicSection(tester, MusicDestination.library);
    expect(tester.getCenter(library).dx, lessThan(tester.getCenter(search).dx));
    expect(find.byKey(const ValueKey('music-library-shortcut-songs')),
        findsOneWidget);

    await _selectPhoneTab(tester, PhoneNavigationItem.search);
    _expectMusicSection(tester, MusicDestination.search);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(tester.widget<TextField>(field).controller!.text,
        'kept during reorder');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectMusicSection(tester, MusicDestination.library);

    await _selectMusicSection(tester, MusicDestination.home);
    final discover = find.byKey(const ValueKey('music-home-discover'));
    final libraryShortcut = find.byKey(const ValueKey('music-home-library'));
    expect(tester.getCenter(discover).dx,
        lessThan(tester.getCenter(libraryShortcut).dx));
    expect(find.byKey(const ValueKey('music-home-charts')), findsNothing);
    await tester.tap(libraryShortcut);
    await tester.pumpAndSettle();
    _expectMusicSection(tester, MusicDestination.library);
    expect(tester.takeException(), isNull);
  });

  testWidgets('launcher Search focuses Music and Back returns to the video tab',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    final historyIndex =
        tester.widget<NavigationBar>(_phoneNavigation).selectedIndex;

    unawaited(appRouter
        .push(MusicShortcutRoute(destination: MusicDestination.search)));
    await tester.pumpAndSettle();
    final field =
        tester.widget<TextField>(find.byKey(const ValueKey('music-search')));
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MusicShortcutScreen), findsNothing);
    expect(tester.widget<NavigationBar>(_phoneNavigation).selectedIndex,
        historyIndex);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('launcher shuffle plays from Library and reports a revoked grant',
      (tester) async {
    const tree = 'content://provider/tree/music';
    const folder = {'uri': tree, 'name': 'Fixture'};
    final library = LocalMusicLibrary.instance;
    final messenger = tester.binding.defaultBinaryMessenger;
    final nativeCalls = <String>[];
    var granted = true;
    messenger.setMockMethodCallHandler(localMusicChannel, (call) async {
      nativeCalls.add(call.method);
      return switch (call.method) {
        'getFolder' => null,
        'pickFolder' => folder,
        'checkFolderAccess' => granted,
        'listTracks' => [
            {'uri': '$tree/document/song', 'title': 'Fixture song'},
          ],
        'listMovedFileRepairs' => const <String, Object?>{},
        'pendingRenames' => const <Object?>[],
        'forgetFolder' => null,
        _ => throw MissingPluginException(call.method),
      };
    });
    addTearDown(() async {
      if (library.enabled) await library.disable();
      messenger.setMockMethodCallHandler(localMusicChannel, null);
    });
    final chosen = await tester.runAsync(
        () => library.chooseFolder().timeout(const Duration(seconds: 3)));
    expect(chosen, isTrue);
    expect(library.visibleTracks.single.title, 'Fixture song');
    late _LauncherShufflePlayer player;
    await _pumpHomepage(tester, const Size(390, 844),
        createPlayer: (settings) =>
            player = _LauncherShufflePlayer(PlayerState.init(null), settings));

    void launch() {
      unawaited(appRouter.push(MusicShortcutRoute(
          key: UniqueKey(),
          destination: MusicDestination.library,
          canStartShuffle: () => true)));
    }

    Future<void> waitForShortcut(bool Function() completed) async {
      for (var attempt = 0; attempt < 20 && !completed(); attempt++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    launch();
    await tester.pumpAndSettle();
    expect(find.byType(MusicLibraryPage), findsOneWidget);
    await waitForShortcut(() => player.requests.isNotEmpty);
    expect(
        player.requests,
        [
          ['Fixture song'],
        ],
        reason: 'Local music calls before shuffle: $nativeCalls');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    granted = false;
    launch();
    await tester.pumpAndSettle();
    final revoked = find.textContaining('Access to this folder was lost');
    await waitForShortcut(() => revoked.evaluate().isNotEmpty);
    expect(player.requests, hasLength(1));
    expect(revoked, findsOneWidget,
        reason: 'Local music calls after revocation: $nativeCalls');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('choosing Music Home overrides a Search shortcut in progress',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await tester.tap(_phoneTab(PhoneNavigationItem.search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(_musicSection(MusicDestination.home));
    await tester.pumpAndSettle();
    _expectMusicSection(tester, MusicDestination.home);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('leaving Music cancels a pending Search keyboard request',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await tester.tap(_phoneTab(PhoneNavigationItem.search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    expect(tester.testTextInput.isVisible, isFalse);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('opening Settings during Music Search cancels keyboard focus',
      (tester) async {
    await _pumpHomepage(tester, const Size(320, 720));
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await tester.tap(_phoneTab(PhoneNavigationItem.search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Browsing'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Browsing'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await _selectPhoneTab(tester, PhoneNavigationItem.search);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('Music may start first and move out of the primary bar',
      (tester) async {
    final layout =
        PhoneNavigation.defaults().startAt(PhoneNavigationItem.music);
    final initial = SettingsState.init();
    await _pumpHomepage(tester, const Size(390, 844),
        settingsState: initial.copyWith(settings: {
          ...initial.settings,
          phoneNavigationSettingName:
              SettingsValue(phoneNavigationSettingName, layout.encode()),
        }));
    final navigation = _phoneNavigation;
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
    expect(find.text('Saved songs'), findsOneWidget);
    final settings =
        tester.element(find.byType(MusicModeScreen)).read<SettingsCubit>();
    final topSearch =
        layout.move(PhoneNavigationItem.search, NavigationArea.top)!;
    await tester.runAsync(() => settings.setPhoneNavigation(topSearch));
    await tester.pumpAndSettle();
    final appBarSearch = find.descendant(
        of: find.byType(AppBar), matching: find.byTooltip('Search'));
    await tester.tap(appBarSearch);
    await tester.pumpAndSettle();
    _expectMusicSection(tester, MusicDestination.search);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectMusicSection(tester, MusicDestination.home);
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);

    final top = layout.move(PhoneNavigationItem.music, NavigationArea.top)!;
    await tester.runAsync(() => settings.setPhoneNavigation(top));
    await tester.pumpAndSettle();
    expect(_phoneTab(PhoneNavigationItem.music), findsNothing);
    final bar = tester.widget<NavigationBar>(navigation);
    expect((bar.destinations[bar.selectedIndex] as NavigationDestination).label,
        'History');
    await tester.tap(find.byTooltip('More shortcuts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Music'));
    await tester.pumpAndSettle();
    expect(find.text('Saved songs'), findsOneWidget);
    await tester.tap(appBarSearch);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('music-search')))
            .focusNode!
            .hasFocus,
        isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Saved songs'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('History'), findsWidgets);

    final hidden = top.move(PhoneNavigationItem.music, NavigationArea.hidden)!;
    await tester.runAsync(() => settings.setPhoneNavigation(hidden));
    await tester.pumpAndSettle();
    expect(SettingsState.init().phoneNavigation.hidden,
        contains(PhoneNavigationItem.music));
    expect(_phoneTab(PhoneNavigationItem.music), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final musicIndex in [0, 1, 2]) {
    testWidgets('phone swipes follow reordered Music at page $musicIndex',
        (tester) async {
      final pages = [PhoneNavigationItem.home, PhoneNavigationItem.history]
        ..insert(musicIndex, PhoneNavigationItem.music);
      // Search is an action, not a page. Its position must not shift the
      // relationship between the pager and the primary navigation selection.
      final bottom = [...pages]..insert(1, PhoneNavigationItem.search);
      final layout = PhoneNavigation(bottom, const []);
      final initial = SettingsState.init();
      await _pumpHomepage(tester, const Size(390, 844),
          settingsState: initial.copyWith(settings: {
            ...initial.settings,
            phoneNavigationSettingName:
                SettingsValue(phoneNavigationSettingName, layout.encode()),
          }));

      void expectPage(PhoneNavigationItem item) {
        expect(tester.widget<NavigationBar>(_phoneNavigation).selectedIndex,
            bottom.indexOf(item));
      }

      expectPage(pages.first);
      if (pages.first == PhoneNavigationItem.music) {
        await _selectMusicSection(tester, MusicDestination.library);
      }
      for (var i = 1; i < pages.length; i++) {
        await tester.dragFrom(const Offset(350, 500), const Offset(-320, 0));
        await tester.pumpAndSettle();
        expectPage(pages[i]);
        if (pages[i] == PhoneNavigationItem.music) {
          await _selectMusicSection(tester, MusicDestination.library);
        }
      }
      for (var i = pages.length - 2; i >= 0; i--) {
        await tester.dragFrom(const Offset(40, 500), const Offset(320, 0));
        await tester.pumpAndSettle();
        expectPage(pages[i]);
        if (pages[i] == PhoneNavigationItem.music) {
          _expectMusicSection(tester, MusicDestination.library);
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final homeBrightness in [Brightness.light, Brightness.dark]) {
    testWidgets('Music status icons follow $homeBrightness Home after closing',
        (tester) async {
      app_main.darkColorScheme = const ColorScheme.dark();
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      const song = Video(
        videoId: 'musicstatus',
        title: 'Status song',
        lengthSeconds: 60,
        musicMetadata: MusicMetadata(title: 'Status song', artist: 'Artist'),
      );
      await _pumpHomepage(
        tester,
        const Size(390, 844),
        theme: ThemeData(brightness: homeBrightness),
        playerState: PlayerState.init([song]).copyWith(
          currentlyPlaying: song,
          isAudio: true,
          isHidden: false,
          isMini: false,
          top: 0,
        ),
      );
      final player = tester.element(find.byType(Player)).read<PlayerCubit>();

      // Sample the composited region at the same physical point RenderView
      // uses to choose Android's status bar style.
      Brightness? statusIcons() => tester.binding.renderViews.single.debugLayer
          ?.find<SystemUiOverlayStyle>(const Offset(195, 12))
          ?.statusBarIconBrightness;

      expect(statusIcons(), Brightness.light);

      final homeIcons = homeBrightness == Brightness.light
          ? Brightness.dark
          : Brightness.light;
      final header = find.descendant(
          of: find.byType(Player), matching: find.byType(AppBar));
      await tester.dragFrom(tester.getCenter(header), const Offset(0, 245));
      await tester.pumpAndSettle();
      expect(player.state.isMini, isTrue);
      expect(statusIcons(), homeIcons);

      player.hide();
      await tester.pumpAndSettle();
      expect(player.state.isHidden, isTrue);
      expect(statusIcons(), homeIcons);
    });
  }

  testWidgets('Back closes Music channel detail but ignores inactive Search',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    final navigation = _phoneNavigation;
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    final videoTab = tester.widget<NavigationBar>(navigation).selectedIndex;
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await _selectMusicSection(tester, MusicDestination.search);
    await tester.enterText(
        find.byKey(const ValueKey('music-search')), 'kept query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Music channel'));
    await tester.pumpAndSettle();
    expect(find.text('Channel uploads'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectMusicSection(tester, MusicDestination.search);
    expect(find.text('Channel uploads'), findsNothing);
    expect(find.text('Search result kept query'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Music channel'));
    await tester.pumpAndSettle();
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, videoTab);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    _expectMusicSection(tester, MusicDestination.search);
    expect(find.text('Channel uploads'), findsOneWidget,
        reason:
            'The hidden Music detail must not consume the video Back action');
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('music-search')))
            .controller!
            .text,
        'kept query');
    await _selectPhoneTab(tester, PhoneNavigationItem.search);
    final field =
        tester.widget<TextField>(find.byKey(const ValueKey('music-search')));
    expect(field.controller!.text, 'kept query');
    expect(field.focusNode!.hasFocus, isTrue);
    expect(find.text('Channel uploads'), findsNothing);
    expect(find.text('Search result kept query'), findsOneWidget);
    final pending = Completer<void>();
    (musicCatalogService as _TestMusicCatalog).pendingArtist = pending;
    await tester.tap(find.widgetWithText(TextButton, 'Music channel'));
    await tester.pump();
    await tester.tap(_phoneTab(PhoneNavigationItem.search));
    await tester.pump();
    await tester.pump();
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Channel uploads'), findsNothing);
    expect(find.text('Search result kept query'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(320, 640), const Size(1024, 768)]) {
    for (final retiredExperience in ['videosOnly', 'musicOnly']) {
      testWidgets(
          'legacy $retiredExperience keeps video and Music navigation at $size',
          (tester) async {
        final initial = SettingsState.init();
        await _pumpHomepage(tester, size,
            settingsState: initial.copyWith(settings: {
              ...initial.settings,
              homeExperienceSettingName:
                  SettingsValue(homeExperienceSettingName, retiredExperience),
              homeContentModeSettingName: SettingsValue(
                  homeContentModeSettingName, HomeContentMode.music.name),
            }));
        expect(find.byType(SegmentedButton<HomeContentMode>), findsNothing);
        if (size.width < 600) {
          expect(_phoneTab(PhoneNavigationItem.home), findsOneWidget);
          expect(_phoneTab(PhoneNavigationItem.music), findsOneWidget);
          await _selectPhoneTab(tester, PhoneNavigationItem.music);
          expect(find.byType(MusicModeScreen), findsOneWidget);
          await _selectPhoneTab(tester, PhoneNavigationItem.home);
          expect(
              tester.widget<NavigationBar>(_phoneNavigation).selectedIndex, 0);
        } else {
          final rail = find.byType(NavigationRail);
          expect(find.descendant(of: rail, matching: find.text('Home')),
              findsOneWidget);
          await tester
              .tap(find.descendant(of: rail, matching: find.text('Music')));
          await tester.pumpAndSettle();
          expect(find.byType(MusicModeScreen), findsOneWidget);
          await tester
              .tap(find.descendant(of: rail, matching: find.text('Home')));
          await tester.pumpAndSettle();
          expect(tester.widget<NavigationRail>(rail).selectedIndex, 0);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('tablet Music retains content while selecting its primary rail',
      (tester) async {
    await _pumpHomepage(tester, const Size(1024, 768));
    final rail = find.byType(NavigationRail);
    Future<void> select(String label) async {
      await tester.tap(find.descendant(of: rail, matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    await select('Music');
    expect(rail, findsOneWidget);
    expect(_musicNavigation, findsNothing);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 4);
    await _selectMusicSection(tester, MusicDestination.search);
    expect(
        tester
            .widget<ChoiceChip>(_musicSection(MusicDestination.search))
            .selected,
        isTrue);
    await tester.dragFrom(const Offset(950, 420), const Offset(-740, 0));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(_musicSection(MusicDestination.library))
            .selected,
        isTrue);
    await select('Home');
    expect(find.descendant(of: rail, matching: find.text('Subscriptions')),
        findsOneWidget);
    expect(
        find.descendant(of: rail, matching: find.text('Search')), findsNothing);
    await select('Music');
    expect(
        tester
            .widget<ChoiceChip>(_musicSection(MusicDestination.library))
            .selected,
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an empty tablet video layout offers a Music shortcut',
      (tester) async {
    final initial = SettingsState.init();
    await _pumpHomepage(tester, const Size(1024, 768),
        settingsState: initial.copyWith(settings: {
          ...initial.settings,
          appLayoutSettingName: SettingsValue(appLayoutSettingName, ''),
        }));
    expect(find.byType(NavigationRail), findsNothing);
    await tester.tap(find.byTooltip('Music'));
    await tester.pumpAndSettle();
    expect(find.text('Saved songs'), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Music'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a new session resets both retained browsing selections',
      (tester) async {
    final app = _SessionApp();
    await _pumpHomepage(tester, const Size(390, 844), initialApp: app);
    final navigation = _phoneNavigation;
    await _selectPhoneTab(tester, PhoneNavigationItem.history);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    await _selectMusicSection(tester, MusicDestination.library);
    _expectMusicSection(tester, MusicDestination.library);
    app.restartSession();
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);
    expect(find.byType(MusicModeScreen), findsNothing);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    _expectMusicSection(tester, MusicDestination.home);
    expect(find.text('Saved songs'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('five primary tabs fit a narrow phone with large text',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpHomepage(tester, const Size(320, 640));
    expect(tester.takeException(), isNull);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    expect(find.byType(MusicModeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _selectPhoneTab(tester, PhoneNavigationItem.home);
    expect(find.byType(SegmentedButton<HomeContentMode>), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final offline in [false, true]) {
    testWidgets(
        'mode and Music page changes preserve shared playback (offline=$offline)',
        (tester) async {
      final videos = (globals.service as _TestService).videos.take(2).toList();
      final downloads = videos
          .map((video) => DownloadedVideo(
              videoId: video.videoId,
              title: video.title!,
              lengthSeconds: 60,
              quality: 'audio',
              audioOnly: true))
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
      await _selectPhoneTab(tester, PhoneNavigationItem.music);
      await _selectMusicSection(tester, MusicDestination.search);
      expect(tester.element(find.byType(Player)).read<PlayerCubit>(),
          same(player));
      expect(player.state, same(before));
      await _selectPhoneTab(tester, PhoneNavigationItem.home);
      expect(player.state, same(before));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('download folders can be selected and reset independently',
      (tester) async {
    const channel = MethodChannel('videre/download_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const videoFolder = {
      'uri': 'content://documents/tree/primary%3AVideos',
      'name': 'Family videos'
    };
    const audioFolder = {
      'uri': 'content://documents/tree/primary%3ASongs',
      'name': 'Saved songs'
    };
    Map<String, String>? result = videoFolder;
    var unavailable = false;
    final initialUris = <String?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'pickFolder') return null;
      initialUris.add(call.arguments['initialUri'] as String?);
      if (unavailable) throw PlatformException(code: 'PICKER_UNAVAILABLE');
      return result;
    });
    await _pumpHomepage(tester, const Size(390, 844));
    await tester.tap(find.byIcon(Icons.download));
    await tester.pumpAndSettle();
    final entryPoint = find.byTooltip('Download folders');
    await tester.tap(entryPoint);
    await tester.pumpAndSettle();
    expect(find.text('Video downloads'), findsOneWidget);
    expect(find.text('Audio downloads'), findsOneWidget);
    Finder option(String id) => find.byKey(ValueKey('download-folder-$id'));
    Future<void> select(String id) async {
      final tile = option(id);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }

    Future<void> expectSelected(String id, bool expected) async {
      final tile = option(id);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      final node = tester.getSemantics(tile);
      final flags = node.flagsCollection;
      expect(
          node.label,
          contains(
              id.startsWith('video-') ? 'Video downloads' : 'Audio downloads'));
      expect(flags.isInMutuallyExclusiveGroup, isTrue, reason: id);
      expect(flags.isChecked, expected, reason: id);
    }

    expect(option('video-standard'), findsNothing);
    await expectSelected('video-private', true);
    await expectSelected('audio-standard', true);
    await select('video-custom');
    expect(find.text('Family videos'), findsOneWidget);
    await expectSelected('video-custom', true);
    await expectSelected('audio-standard', true);
    result = audioFolder;
    await select('audio-custom');
    expect(find.text('Saved songs'), findsOneWidget);
    await expectSelected('audio-custom', true);
    await expectSelected('video-custom', true);
    result = null;
    await select('video-custom');
    await select('audio-custom');
    expect(find.text('Family videos'), findsOneWidget);
    expect(find.text('Saved songs'), findsOneWidget);
    expect(initialUris, [null, null, videoFolder['uri'], audioFolder['uri']]);
    unavailable = true;
    await select('audio-custom');
    expect(
        find.textContaining('No folder picker is available.'), findsOneWidget);
    await expectSelected('audio-custom', true);

    // Both handset and TV use this dialog. Move up from Video's custom
    // folder and choose its private destination using only the remote.
    final current = option('video-custom');
    await tester.ensureVisible(current);
    await tester.pumpAndSettle();
    Focus.of(tester.element(
            find.descendant(of: current, matching: find.text('Family videos'))))
        .requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await expectSelected('video-private', true);
    await expectSelected('video-custom', false);
    expect(find.text('Family videos'), findsNothing);
    expect(find.text('Saved songs'), findsOneWidget);

    unavailable = false;
    result = videoFolder;
    await select('video-custom');
    await select('audio-private');
    await expectSelected('audio-private', true);
    await expectSelected('video-custom', true);
    expect(find.text('Saved songs'), findsNothing);
    await select('audio-standard');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(entryPoint);
    await tester.pumpAndSettle();
    await expectSelected('audio-standard', true);
    await expectSelected('audio-private', false);
    await expectSelected('video-custom', true);
    expect(find.text('Family videos'), findsOneWidget);
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
    await tester.pumpAndSettle();
    expect(toggle.hitTestable(), findsOneWidget);
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
        if (surface == 'TV grid') {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }
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
    await _openPhoneQueue(tester);
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
      await _openPhoneQueue(tester);
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
      await _openPhoneQueue(tester);
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
        equals(_instanceRequestHeaders),
      );
      expect(
        server.headersForUrl('https://EXAMPLE.com:443/video'),
        equals(_instanceRequestHeaders),
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

    expect(find.byKey(const ValueKey('watch-open-settings')), findsNothing);
    expect(openButton.hitTestable(), findsOneWidget);
    final transcriptButton = tester.widget<IconButton>(openButton);
    expect(transcriptButton.tooltip, 'Transcript');
    expect(transcriptButton.onPressed, isNotNull);
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

  testWidgets(
      'expanded player disables transcript when captions are unavailable',
      (tester) async {
    await _pumpExpandedPlayer(
      tester,
      const Size(390, 844),
      videoIndex: 1,
    );
    final openButton = find.byKey(const ValueKey('video-transcript-open'));
    expect(openButton.hitTestable(), findsOneWidget);
    final transcriptButton = tester.widget<IconButton>(openButton);
    expect(transcriptButton.tooltip, 'Transcript');
    expect(transcriptButton.onPressed, isNull);
    await tester.tap(openButton);
    await tester.pumpAndSettle();
    expect((globals.service as _TestService).transcriptRequests, isEmpty);
    expect(find.byKey(const ValueKey('video-transcript-list')), findsNothing);
  });

  testWidgets('phone homepage tabs swipe fluidly and bounce at both edges',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('video-home-your-feeds')));
    await tester.pumpAndSettle();
    final tabPosition = _tabPosition(tester);

    void expectSelectedTab(int index) {
      expect(
        tester.widget<NavigationBar>(_phoneNavigation).selectedIndex,
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
    expect(find.text('Saved songs'), findsOneWidget);

    // Drag a heading, not a shelf whose horizontal scroll owns the gesture.
    final musicHeading = find.text('Saved songs');
    await tester.ensureVisible(musicHeading);
    final trailingEdgeDrag =
        await tester.startGesture(tester.getCenter(musicHeading));
    await trailingEdgeDrag.moveBy(const Offset(-24, 0));
    await tester.pump();
    await trailingEdgeDrag.moveBy(const Offset(-96, 0));
    await tester.pump();
    expect(tabPosition.pixels, greaterThan(tabPosition.maxScrollExtent));
    await trailingEdgeDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(3);
    expect(find.byType(TextField), findsNothing);

    await tester.dragFrom(tester.getCenter(musicHeading), const Offset(320, 0));
    await tester.pumpAndSettle();
    expectSelectedTab(2);
    await swipeRight();
    expectSelectedTab(1);
    await swipeRight();
    expectSelectedTab(0);
  });

  testWidgets('phone homepage preserves horizontal carousel gestures',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('video-home-your-feeds')));
    await tester.pumpAndSettle();

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

  testWidgets('phone Music shelves own swipes on their cards', (tester) async {
    final library =
        MusicLibraryService.forProfile(globals.db, globals.db.profileId);
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'shelfsong0$i',
            title: 'Shelf song $i'));
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('videre/recommendations'),
            (_) async => {
                  'ranked': [
                    {'id': 'shelfsong00', 'score': 1.0, 'reason': 'Saved song'},
                  ],
                });
    await _pumpHomepage(tester, const Size(390, 1000));
    final pager = _tabPosition(tester);
    await _selectPhoneTab(tester, PhoneNavigationItem.music);
    final quickPicks = find.byKey(const ValueKey('music-quick-picks'));
    final speedDial = find.byKey(const ValueKey('music-speed-dial'));
    final speedDialPosition = tester
        .state<ScrollableState>(
            find.descendant(of: speedDial, matching: find.byType(Scrollable)))
        .position;
    final musicPage = pager.pixels;

    // Even one column of picks owns swipes in both directions.
    for (final dx in [280.0, -280.0]) {
      final row = tester.getRect(quickPicks);
      final start = dx > 0 ? row.left + 25 : row.right - 25;
      await tester.dragFrom(Offset(start, row.center.dy), Offset(dx, 0));
      await tester.pumpAndSettle();
      expect(pager.pixels, musicPage);
    }

    await tester.drag(speedDial, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(speedDialPosition.pixels, greaterThan(0));
    expect(pager.pixels, musicPage);

    // Let a swipe from the heading start moving the app pager, then grab
    // Speed Dial while Music is still painted and the pager is settling.
    final heading = tester.getCenter(find.text('Quick picks'));
    final gesture = await tester.startGesture(heading);
    await gesture.moveBy(const Offset(25, 0));
    await gesture.moveBy(const Offset(55, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(pager.pixels, lessThan(musicPage));
    expect(pager.isScrollingNotifier.value, isTrue);
    final offset = speedDialPosition.pixels;
    await tester.drag(speedDial, const Offset(140, 0));
    await tester.pumpAndSettle();
    expect(speedDialPosition.pixels, lessThan(offset));
    expect(pager.pixels, musicPage);

    // A swipe on the heading still changes the app tab.
    await tester.drag(find.text('Quick picks'), const Offset(280, 0));
    await tester.pumpAndSettle();
    expect(pager.pixels, lessThan(musicPage));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'landscape configured feeds preserve their layout without extra resume sections',
      (tester) async {
    await tester.runAsync(() async {
      await globals.db.upsertHistoryVideo(HistoryVideoCache('video-0',
          'Resume this video', 'Channel', 'https://example.com/resume.png'));
      await globals.db.saveProgress(Progress(0.5, 'video-0'));
    });

    await _pumpHomepage(tester, const Size(640, 360));
    await tester.tap(find.byKey(const ValueKey('video-home-your-feeds')));
    await tester.pumpAndSettle();
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

  testWidgets('phone video preview keeps details and comments on one page',
      (tester) async {
    final service = globals.service as _TestService;
    service.videos[0] =
        service.videos[0].copyWith(description: 'A selectable description.');
    service.comments = [
      Comment('Viewer', [], 'viewer', '', false, 'A real instance comment.',
          'Today', 0, 'preview', false, null, null),
    ];
    await _pumpVideo(tester, const Size(390, 844));
    final screen = find.byType(VideoScreen);
    expect(find.byKey(const ValueKey('flow-watch-details')), findsOneWidget);
    expect(find.descendant(of: screen, matching: find.byType(NavigationBar)),
        findsNothing);
    expect(find.byType(VideoThumbnailView), findsOneWidget);
    expect(find.text('A real instance comment.'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('watch-open-comments')),
            matching: find.byType(ImageFiltered)),
        findsNothing);
    expect(service.commentSorts, ['top']);

    await tester.tap(find.byKey(const ValueKey('watch-open-description')));
    await tester.pumpAndSettle();
    expect(find.byType(TextLinkified), findsOneWidget);
    await tester.tapAt(const Offset(18, 40));
    await tester.pumpAndSettle();
    expect(find.byType(TextLinkified), findsNothing);

    await tester.tap(find.byKey(const ValueKey('watch-open-comments')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Top'), findsOneWidget);
    expect(service.commentSorts, ['top']);
    await tester.tap(find.widgetWithText(ChoiceChip, 'New'));
    await tester.pumpAndSettle();
    expect(service.commentSorts, ['top', 'new']);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Top'));
    await tester.pumpAndSettle();
    expect(service.commentSorts, ['top', 'new']);
    expect(tester.element(screen).read<PlayerCubit>().state.hasVideo, isFalse);
  });

  for (final playing in [false, true]) {
    testWidgets(
        '${playing ? 'Playback' : 'Video preview'} blurs the comment until tapped',
        (tester) async {
      const spoiler = 'A comment with a spoiler.';
      final service = globals.service as _TestService;
      service.comments = [
        Comment('Viewer', [], 'viewer', '', false, spoiler, 'Today', 0,
            'spoiler', false, null, null),
      ];
      final settings = SettingsState.init().copyWith(settings: {
        hideCommentsByDefaultSettingName:
            SettingsValue(hideCommentsByDefaultSettingName, 'true'),
      });
      const size = Size(390, 844);
      if (playing) {
        await _pumpExpandedPlayer(tester, size, settingsState: settings);
      } else {
        await _pumpVideo(tester, size, settingsState: settings);
      }

      final comments = find.byKey(const ValueKey('watch-open-comments'));
      final comment = find.text(spoiler, findRichText: true);
      final blur =
          find.descendant(of: comments, matching: find.byType(ImageFiltered));
      final spoilerSemantics =
          find.bySemanticsLabel(RegExp(RegExp.escape(spoiler)));
      await tester.ensureVisible(blur);
      await tester.pumpAndSettle();
      expect(find.descendant(of: blur, matching: comment), findsOneWidget);
      expect(spoilerSemantics, findsNothing);
      expect(service.commentSorts, ['top']);

      await tester.tap(blur);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Top'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(CommentsContainer), matching: comment),
          findsOneWidget);
      expect(service.commentSorts, ['top']);

      await tester.tapAt(const Offset(18, 40));
      await tester.pumpAndSettle();
      expect(blur, findsOneWidget);
      expect(spoilerSemantics, findsNothing);
      expect(service.commentSorts, ['top']);
    });
  }

  testWidgets('tablet video tabs ignore horizontal swipes', (tester) async {
    await _pumpVideo(tester, const Size(1024, 768));

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller!.index, 0);

    await tester.dragFrom(const Offset(900, 400), const Offset(-800, 0));
    await tester.pumpAndSettle();

    expect(tabBar.controller!.index, 0);
  });

  testWidgets('tablet video loads hidden comments only on the Comments tab',
      (tester) async {
    final service = globals.service as _TestService;
    final settings = SettingsState.init().copyWith(settings: {
      hideCommentsByDefaultSettingName:
          SettingsValue(hideCommentsByDefaultSettingName, 'true'),
    });
    await _pumpVideo(tester, const Size(1024, 768), settingsState: settings);
    expect(service.commentSorts, isEmpty);

    await tester.tap(find.widgetWithText(Tab, 'Recommended'));
    await tester.pumpAndSettle();
    expect(service.commentSorts, isEmpty);

    await tester.tap(find.widgetWithText(Tab, 'Comments'));
    await tester.pumpAndSettle();
    expect(service.commentSorts, ['top']);
  });

  testWidgets('spoiler protection requires a tap in landscape phone tabs',
      (tester) async {
    final service = globals.service as _TestService;
    final settings = SettingsState.init().copyWith(settings: {
      hideCommentsByDefaultSettingName:
          SettingsValue(hideCommentsByDefaultSettingName, 'true'),
    });
    await _pumpVideo(tester, const Size(640, 360), settingsState: settings);

    final video = find.byType(VideoScreen);
    final horizontalPager = find.descendant(
      of: video,
      matching: find.byWidgetPredicate((widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.right),
    );
    final pager = tester.getRect(horizontalPager.first);
    final navigation =
        find.descendant(of: video, matching: find.byType(NavigationBar));
    await tester.dragFrom(
        pager.centerRight - const Offset(24, 0), Offset(-pager.width * 0.8, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);
    expect(service.commentSorts, isEmpty);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Comments'));
    await tester.pumpAndSettle();
    expect(service.commentSorts, ['top']);
  });

  testWidgets('phone watch queue opens and closes while retaining the decoder',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844));
    final expanded = find.byType(ExpandedPlayer);
    final player = tester.element(expanded).read<PlayerCubit>();
    final decoder = find.byKey(const ValueKey('player'));
    final decoderState = tester.state(decoder);
    expect(find.descendant(of: expanded, matching: find.byType(NavigationBar)),
        findsNothing);
    expect(
        find.byKey(const ValueKey('watch-open-description')), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-open-comments')), findsOneWidget);

    final queue = find.byKey(const ValueKey('watch-open-queue'));
    final next = (globals.service as _TestService).videos[1];
    player.queueVideos([next]);
    await tester.pumpAndSettle();
    expect(find.descendant(of: queue, matching: find.text(next.title!)),
        findsOneWidget);
    await tester.tap(queue);
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(player.state.isMini, isFalse);
    await tester.tapAt(const Offset(10, 40));
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsNothing);
    expect(player.state.isMini, isFalse);
    expect(tester.state(decoder), same(decoderState));
  });

  testWidgets(
      'watch related overflow contains Why and Back keeps playback open',
      (tester) async {
    const related = Video(videoId: 'related0001', title: 'Related recording');
    const reason = 'Matches your local video interests.';
    final service = globals.service as _TestService;
    service.videos[0] =
        service.videos[0].copyWith(recommendedVideos: [related]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (call) async {
      final args = call.arguments as Map;
      return {
        'state': <String, Object?>{},
        'ranked': [
          for (final candidate in args['candidates'] as List)
            {'id': (candidate as Map)['id'], 'score': 1.0, 'reason': reason}
        ],
      };
    });
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final expanded = find.byType(ExpandedPlayer);
    final player = tester.element(expanded).read<PlayerCubit>();
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.removeByName('miniPlayer'));

    Future<void> back() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(const MethodCall('popRoute')),
        null,
      );
      await tester.pumpAndSettle();
    }

    final why = find.text('Why this?');
    expect(why, findsNothing);
    final overflow = find.descendant(
      of: find.byKey(const ValueKey('related0001')),
      matching: find.byIcon(Icons.more_vert_rounded),
    );
    await tester.ensureVisible(overflow);
    await tester.tap(overflow);
    await tester.pumpAndSettle();
    expect(why, findsOneWidget);
    await tester.tap(why);
    await tester.pumpAndSettle();
    expect(find.text(reason), findsOneWidget);
    await back();
    expect(find.text(reason), findsNothing);
    expect(why, findsOneWidget);
    expect(player.state.isMini, isFalse);
    await back();
    expect(why, findsNothing);
    expect(player.state.isMini, isFalse);
    await back();
    expect(player.state.isMini, isTrue);
  });

  testWidgets('Flow watch adapts between the related grid and supporting pane',
      (tester) async {
    final service = globals.service as _TestService;
    const related = ['watchrel001', 'watchrel002'];
    service.videos[0] = service.videos[0].copyWith(
        description: 'Details stay beside the video.',
        recommendedVideos: [
          service.videos[1].copyWith(videoId: related[0]),
          service.videos[2].copyWith(videoId: related[1]),
        ]);
    await _pumpExpandedPlayer(tester, const Size(768, 1024), selectedIndex: 0);
    final decoder = find.byKey(const ValueKey('player'));
    final state = tester.state(decoder);
    final player = tester.element(decoder).read<PlayerCubit>();
    final pane = find.byKey(const ValueKey('flow-watch-side-pane'));
    final first = find.byKey(const ValueKey('watchrel001'));
    final second = find.byKey(const ValueKey('watchrel002'));
    expect(pane, findsNothing);
    expect(tester.getSize(decoder).width, 768);
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(tester.getTopLeft(first).dx, lessThan(tester.getTopLeft(second).dx));

    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();
    expect(pane, findsOneWidget);
    expect(tester.getSize(decoder).width, 1024 - 384);
    expect(tester.state(decoder), same(state));
    expect(find.descendant(of: pane, matching: first), findsOneWidget);

    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.removeByName('miniPlayer'));
    await tester.tap(find.byKey(const ValueKey('watch-open-description')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: pane, matching: find.byType(TextLinkified)),
        findsOneWidget);
    expect(tester.state(decoder), same(state));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();
    expect(find.descendant(of: pane, matching: first), findsOneWidget);
    expect(player.state.isMini, isFalse);

    // Safe insets can leave a nominally wide window room for only one pane.
    tester.view.padding = const FakeViewPadding(left: 55, right: 55);
    addTearDown(tester.view.resetPadding);
    tester.view.physicalSize = const Size(840, 500);
    await tester.pumpAndSettle();
    expect(pane, findsNothing);
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(tester.state(decoder), same(state));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Flow Watch Back closes Share and both Save routes first',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player = tester.element(find.byType(Player)).read<PlayerCubit>();
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.removeByName('miniPlayer'));

    Future<void> back() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(const MethodCall('popRoute')),
        null,
      );
      await tester.pumpAndSettle();
      expect(player.state.isMini, isFalse);
    }

    final share = find.text('Share');
    await tester.ensureVisible(share);
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(find.text('Share Invidious link'), findsOneWidget);
    await back();
    expect(find.text('Share Invidious link'), findsNothing);

    final save = find.text('Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final picker = find.text('Select playlist');
    expect(picker, findsOneWidget);
    await tester.tap(find.text('Create new playlist'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await back();
    expect(find.byType(Dialog), findsNothing);
    expect(picker, findsOneWidget);
    await back();
    expect(picker, findsNothing);
  });

  testWidgets('Flow related cards play immediately only in the active watch',
      (tester) async {
    final service = globals.service as _TestService;
    final related = service.videos[1].copyWith(videoId: 'watchrel001');
    service.videos.add(related);
    final original = service.videos[0].copyWith(recommendedVideos: [related]);
    service.videos[0] = original;
    late _WatchSelectionPlayer player;
    await _pumpHomepage(
      tester,
      const Size(390, 844),
      createPlayer: (settings) => player = _WatchSelectionPlayer(
        PlayerState.init([original]).copyWith(
          currentlyPlaying: original,
          isMini: false,
          isHidden: false,
          top: 0,
        ),
        settings,
      ),
    );
    final decoder = find.byKey(const ValueKey('player'));
    final state = tester.state(decoder);
    final card = find.byKey(ValueKey(related.videoId));
    await tester.ensureVisible(card);
    await tester.tapAt(tester.getTopLeft(card) + const Offset(24, 24));
    await tester.pumpAndSettle();
    expect(player.selection, [(related.videoId, false)]);
    expect(find.byType(VideoScreen), findsNothing);
    expect(player.state.isMini, isFalse);
    expect(tester.state(decoder), same(state));

    player.showMiniPlayer();
    unawaited(appRouter.push(VideoRoute(videoId: original.videoId)));
    await tester.pumpAndSettle();
    final preview =
        find.descendant(of: find.byType(VideoScreen), matching: card);
    await tester.ensureVisible(preview);
    await tester.tapAt(tester.getTopLeft(preview) + const Offset(24, 24));
    await tester.pumpAndSettle();
    expect(tester.widget<VideoScreen>(find.byType(VideoScreen)).videoId,
        related.videoId);
    expect(player.selection, [(related.videoId, false)]);
    expect(player.state.isMini, isTrue);
  });

  testWidgets('Flow queue dock stays visible at the end and predicts repeat',
      (tester) async {
    _mockVideoWakelock();
    final videos = (globals.service as _TestService).videos.take(2).toList();
    final settings = SettingsState.init();
    await _pumpHomepage(
      tester,
      const Size(390, 844),
      settingsState: settings.copyWith(settings: {
        ...settings.settings,
        playerRepeat:
            SettingsValue(playerRepeat, '${PlayerRepeat.repeatAll.index}'),
      }),
      playerState: PlayerState.init(videos).copyWith(
          currentlyPlaying: videos.last,
          isMini: false,
          isHidden: false,
          top: 0),
    );
    final dock = find.byKey(const ValueKey('watch-open-queue'));
    expect(find.descendant(of: dock, matching: find.text(videos.first.title!)),
        findsOneWidget);
    final settingsCubit = tester.element(dock).read<SettingsCubit>();
    await tester
        .runAsync(() => settingsCubit.setRepeatMode(PlayerRepeat.repeatOne));
    await tester.pumpAndSettle();
    expect(find.descendant(of: dock, matching: find.text(videos.last.title!)),
        findsOneWidget);
    await tester
        .runAsync(() => settingsCubit.setRepeatMode(PlayerRepeat.noRepeat));
    await tester.pumpAndSettle();
    expect(find.descendant(of: dock, matching: find.text('Video queue')),
        findsOneWidget);
  });

  testWidgets('Flow Watch queue follows and reorders actual occurrences',
      (tester) async {
    final all = (globals.service as _TestService).videos;
    final played = all[0];
    final current = all[1];
    final repeated = current.copyWith(
        queueEntryId: 'queued-copy', title: 'A second occurrence');
    final next = all[2];
    final initial = PlayerState.init([played, current, repeated, next]);
    final settings = SettingsState.init();
    await _pumpHomepage(tester, const Size(390, 844),
        settingsState: settings.copyWith(settings: {
          ...settings.settings,
          playerShuffle: SettingsValue(playerShuffle, 'true'),
        }),
        playerState: initial.copyWith(
            currentlyPlaying: current,
            playedVideos: [played.videoId],
            playQueue: ListQueue.of([next.videoId, repeated.queueEntryId!]),
            isMini: false,
            isHidden: false,
            top: 0));
    final decoder = find.byKey(const ValueKey('player'));
    final decoderState = tester.state(decoder);
    final player = tester.element(decoder).read<PlayerCubit>();
    final dock = find.byKey(const ValueKey('watch-open-queue'));
    expect(find.descendant(of: dock, matching: find.text(next.title!)),
        findsOneWidget);
    await tester.tap(dock);
    await tester.pumpAndSettle();

    final list = find.byType(ReorderableListView);
    Finder occurrence(String id) =>
        find.descendant(of: list, matching: find.byKey(ValueKey(id)));
    final active = occurrence(current.videoId);
    final upcoming = occurrence(next.videoId);
    final duplicate = occurrence(repeated.queueEntryId!);
    expect(
        tester.getTopLeft(active).dy, lessThan(tester.getTopLeft(upcoming).dy));
    expect(tester.getTopLeft(upcoming).dy,
        lessThan(tester.getTopLeft(duplicate).dy));
    expect(
        find.descendant(
            of: active, matching: find.byType(ReorderableDragStartListener)),
        findsNothing);
    final listWidget = tester.widget<ReorderableListView>(list);
    listWidget.onReorderStart!(3);
    listWidget.onReorder(3, 2);
    await tester.pumpAndSettle();
    expect(player.state.playQueue, [repeated.queueEntryId, next.videoId]);
    expect(player.state.playedVideos, [played.videoId]);
    expect(player.state.currentQueueId, current.videoId);
    expect(tester.getTopLeft(duplicate).dy,
        lessThan(tester.getTopLeft(upcoming).dy));
    expect(tester.state(decoder), same(decoderState));
    expect(tester.takeException(), isNull);
  });

  testWidgets('distraction-free watch omits comments and keeps queue access',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844),
        distractionFree: true, selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    expect(
        find.byKey(const ValueKey('watch-open-description')), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-open-comments')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('watch-open-queue')));
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(player.state.isMini, isFalse);
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

  testWidgets(
      'video pull follows the hand and settles without replacing decoder',
      (tester) async {
    _mockVideoWakelock();
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    final video = find.byKey(const ValueKey('player'));
    final videoState = tester.state(video);
    final builder = find.descendant(
      of: video,
      matching: find.byType(BlocBuilder<VideoPlayerCubit, VideoPlayerState>),
    );
    final decoder = tester.element(builder).read<VideoPlayerCubit>();
    final positioned = find.descendant(
      of: find.byType(Player),
      matching: find.byType(AnimatedPositioned),
    );
    final surface = find.ancestor(
      of: video,
      matching: find.byType(AspectRatio),
    );
    final expanded = tester.getRect(positioned);

    void expectSameDecoder() {
      expect(tester.state(video), same(videoState));
      expect(tester.element(builder).read<VideoPlayerCubit>(), same(decoder));
      expect(decoder.isClosed, isFalse);
      expect(tester.takeException(), isNull);
    }

    for (final cancel in [false, true]) {
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      final first = tester.getRect(positioned);
      await gesture.moveBy(Offset(0, cancel ? 220 : 75));
      await tester.pump();
      expect(first.top, greaterThan(expanded.top));
      expect(tester.getRect(positioned).top, greaterThan(first.top));
      expect(player.state.isMini, isFalse);
      expectSameDecoder();

      if (cancel) {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      await tester.pumpAndSettle();
      expect(player.state.isMini, isFalse);
      expect(tester.getRect(positioned).top, closeTo(expanded.top, 0.01));
      expectSameDecoder();
    }

    final gesture = await tester.startGesture(tester.getCenter(surface));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();
    final held = tester.getRect(positioned);
    expect(held.top, greaterThan(expanded.top));
    await gesture.up();
    await tester.pump();
    expect(player.state.isMini, isTrue);
    expect(tester.getRect(positioned).top, closeTo(held.top, 1));
    expectSameDecoder();
    await tester.pump(const Duration(milliseconds: 80));
    final settling = tester.getRect(positioned);
    expect(settling.top, greaterThan(held.top));
    await tester.pumpAndSettle();
    final compact = tester.getRect(positioned);
    expect(compact.top, greaterThan(settling.top));
    expect(compact.bottom, lessThanOrEqualTo(844));
    expect(find.byKey(const ValueKey('flow-mini-surface')), findsOneWidget);
    expectSameDecoder();

    await tester.tap(find.byKey(const ValueKey('flow-mini-close')));
    await tester.pump(globals.animationDuration * 1.5);
    await tester.pumpAndSettle();
    expect(player.state.isHidden, isTrue);
  });

  testWidgets('floating video controls retain their individual tap targets',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    player.showMiniPlayer();
    await tester.pumpAndSettle();
    final stage = find.byKey(const ValueKey('flow-mini-surface'));
    final play = find.byKey(const ValueKey('watch-mini-play'));
    final close = find.byKey(const ValueKey('flow-mini-close'));
    expect(tester.getRect(play).overlaps(tester.getRect(close)), isFalse);
    await tester.tap(play);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.state.isMini, isTrue);

    await tester.tapAt(tester.getRect(stage).center + const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);

    player.showMiniPlayer();
    await tester.pumpAndSettle();
    await tester.tap(close);
    expect(player.state.isClosing, isTrue);
    await tester.pump(globals.animationDuration * 1.5);
    await tester.pumpAndSettle();
    expect(player.state.isHidden, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating video pinch and expansion keep one mounted decoder',
      (tester) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPadding);
    _mockVideoWakelock();
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    final decoder = find.byKey(const ValueKey('player'));
    final decoderState = tester.state(decoder);
    final builder = find.descendant(
      of: decoder,
      matching: find.byType(BlocBuilder<VideoPlayerCubit, VideoPlayerState>),
    );
    final backend = tester.element(builder).read<VideoPlayerCubit>();

    Future<void> compact() async {
      player.showMiniPlayer();
      await tester.pumpAndSettle();
      expect(tester.state(decoder), same(decoderState));
      expect(tester.element(builder).read<VideoPlayerCubit>(), same(backend));
      expect(backend.isClosed, isFalse);
    }

    await compact();
    final stage = find.byKey(const ValueKey('flow-mini-surface'));
    final corner = tester.getRect(stage);
    expect(corner.width, closeTo(390 * .45, 1));
    expect(corner.right, closeTo(382, 1));
    expect(corner.bottom, lessThanOrEqualTo(844 - 60));
    final center = corner.center + const Offset(0, 16);
    // A pinch beginning during the single-tap window supersedes that tap.
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    final first = await tester.startGesture(center - const Offset(18, 0));
    final second = await tester.startGesture(center + const Offset(18, 0));
    await first.moveBy(const Offset(-36, 0));
    await tester.pump();
    await second.moveBy(const Offset(36, 0));
    await tester.pump(const Duration(milliseconds: 330));
    expect(player.state.isMini, isTrue);
    expect(tester.getRect(stage).width, greaterThan(corner.width * 1.5));
    await first.up();
    await tester.pump();
    await second.moveBy(const Offset(0, -40));
    await second.up();
    await tester.pumpAndSettle();
    final wide = tester.getRect(stage);
    expect(wide.width, closeTo(390 - 16, 1));
    expect(wide.center.dx, closeTo(195, 1));
    expect(wide.bottom, closeTo(corner.bottom, 1));
    expect(player.state.isMini, isTrue);
    expect(tester.state(decoder), same(decoderState));
    expect(tester.element(builder).read<VideoPlayerCubit>(), same(backend));

    // Flow's double tap toggles the size; a single tap after the timeout opens.
    final tap = wide.center + const Offset(0, 12);
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(tap);
    await tester.pumpAndSettle();
    expect(tester.getRect(stage).width, closeTo(corner.width, 1));
    await tester.tapAt(tester.getRect(stage).center + const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 301));
    expect(player.state.isMini, isFalse);
    expect(tester.getSize(decoder).width, lessThan(390));
    expect(tester.takeException(), isNull);
    for (var elapsed = Duration.zero;
        elapsed < globals.animationDuration;
        elapsed += const Duration(milliseconds: 16)) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.state(decoder), same(decoderState));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(tester.state(decoder), same(decoderState));
    await compact();
    expect(tester.getRect(stage).width, closeTo(corner.width, 1));

    await tester.tap(find.byKey(const ValueKey('flow-mini-close')));
    expect(player.state.isClosing, isTrue);
    await tester.pump(globals.animationDuration * 1.5);
    await tester.pumpAndSettle();
    expect(player.state.isHidden, isTrue);
    expect(decoder, findsNothing);
    expect(decoderState.mounted, isFalse);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(backend.isClosed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanding a downloaded video fits the legacy controls',
      (tester) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPadding);
    _mockVideoWakelock();
    const download = DownloadedVideo(
        videoId: 'video-0',
        title: 'Downloaded video',
        lengthSeconds: 60,
        quality: '720p');
    await _pumpHomepage(tester, const Size(390, 844),
        playerState: PlayerState.init(null).copyWith(
          offlineVideos: [download],
          offlineCurrentlyPlaying: download,
          isMini: true,
          isHidden: false,
        ));
    final player = tester.element(find.byType(Player)).read<PlayerCubit>();
    final video = find.byKey(const ValueKey('player'));
    final decoderState = tester.state(video);
    final builder = find.descendant(
      of: video,
      matching: find.byType(BlocBuilder<VideoPlayerCubit, VideoPlayerState>),
    );
    final decoder = tester.element(builder).read<VideoPlayerCubit>();

    player.showBigPlayer();
    await tester.pump();
    expect(tester.getSize(video).width, lessThan(390));
    expect(tester.takeException(), isNull);
    for (var elapsed = Duration.zero;
        elapsed < globals.animationDuration;
        elapsed += const Duration(milliseconds: 16)) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.state(video), same(decoderState));
      expect(tester.element(builder).read<VideoPlayerCubit>(), same(decoder));
      final error = tester.takeException();
      expect(error, isNull,
          reason: error is FlutterError ? error.toStringDeep() : null);
    }

    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(find.byType(MiniPlayerControls), findsOneWidget);
    expect(decoder.isClosed, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'floating video tucks with an accessible handle and honors insets',
      (tester) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    final video = find.byKey(const ValueKey('player'));
    final state = tester.state(video);
    player.showMiniPlayer();
    await tester.pumpAndSettle();

    final stage = find.byKey(const ValueKey('flow-mini-surface'));
    final handle = find.byKey(const ValueKey('flow-mini-tuck-handle'));
    final original = tester.getRect(stage);
    await tester.dragFrom(
        original.center + const Offset(0, 10), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(handle.hitTestable(), findsOneWidget);
    expect(tester.getRect(stage).left, greaterThanOrEqualTo(390));
    expect(tester.state(video), same(state));
    expect(find.byTooltip('Video player'), findsOneWidget);

    await tester
        .tap(find.descendant(of: handle, matching: find.byType(InkWell)));
    await tester.pumpAndSettle();
    expect(handle, findsNothing);
    expect(tester.getRect(stage).topLeft, original.topLeft);

    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();
    expect(tester.getRect(stage).bottom, lessThanOrEqualTo(844 - 360));
    tester.view.physicalSize = const Size(260, 540);
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    await tester.pumpAndSettle();
    final resized = tester.getRect(stage);
    expect(resized.left, greaterThanOrEqualTo(0));
    expect(resized.right, lessThanOrEqualTo(260));
    expect(resized.top, greaterThanOrEqualTo(24));
    expect(resized.bottom, lessThanOrEqualTo(540 - 160));
    expect(tester.state(video), same(state));
    expect(tester.takeException(), isNull);
  });

  for (final loggedIn in [false, true]) {
    testWidgets(
        'watch body minimizes after a new pull at the top (account=$loggedIn)',
        (tester) async {
      final service = globals.service as _TestService;
      service.loggedIn = loggedIn;
      service.videos[0] = service.videos[0].copyWith(
          recommendedVideos: List.generate(
              12,
              (index) => Video(
                  videoId: 'relation${index.toString().padLeft(3, '0')}',
                  title: 'Related recording $index')));
      await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
      final expanded = find.byType(ExpandedPlayer);
      final player = tester.element(expanded).read<PlayerCubit>();
      final content = find
          .descendant(
              of: expanded, matching: find.byType(SingleChildScrollView))
          .first;
      final position = tester
          .state<ScrollableState>(find
              .descendant(of: content, matching: find.byType(Scrollable))
              .first)
          .position;
      final start = tester.getTopLeft(content) + const Offset(180, 90);

      await tester.dragFrom(
          start + const Offset(0, 140), const Offset(0, -260));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(player.state.isMini, isFalse);

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

  testWidgets('phone Watch closes Timed comments when the video changes',
      (tester) async {
    final videos = (globals.service as _TestService).videos.take(2).toList();
    final playerState = PlayerState.init(videos).copyWith(
      currentlyPlaying: videos.first,
      isMini: false,
      isHidden: false,
      selectedFullScreenIndex: 0,
      top: 0,
    );
    await _pumpHomepage(
      tester,
      const Size(390, 844),
      createPlayer: (settings) => _QueueSelectionPlayer(playerState, settings),
    );
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    await tester.tap(find.byKey(const ValueKey('watch-open-comments')));
    await tester.pumpAndSettle();
    final timed = find.widgetWithText(ChoiceChip, 'Timed');
    await tester.tap(timed);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timed-comments-list')), findsOneWidget);

    await player.skipToVideo(1);
    await tester.pumpAndSettle();
    expect(player.state.currentlyPlaying?.videoId, videos.last.videoId);
    expect(timed, findsNothing);
    expect(player.state.isMini, isFalse);
  });

  testWidgets('Android Back closes comments before minimizing playback',
      (tester) async {
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    await tester.tap(find.byKey(const ValueKey('watch-open-comments')));
    await tester.pumpAndSettle();
    final newest = find.widgetWithText(ChoiceChip, 'New');
    await tester.tap(newest);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(newest).selected, isTrue);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();
    expect(newest, findsNothing);
    expect(player.state.isMini, isFalse);
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
        await tester.tap(find.byKey(const ValueKey('watch-open-description')));
        await tester.pumpAndSettle();
        final content = find
            .ancestor(
              of: find.byType(TextLinkified),
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        final position = tester
            .state<ScrollableState>(find
                .descendant(of: content, matching: find.byType(Scrollable))
                .first)
            .position;
        position.jumpTo(scrollOffset);
        await tester.pump();
        // The title and channel are also selectable; this gesture exercises
        // multiline description selection while its containing page scrolls.
        final text = find.descendant(
            of: find.descendant(
                of: content, matching: find.byType(TextLinkified)),
            matching: find.byType(EditableText));
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

  testWidgets('expanded description keeps its toolbar during playback updates',
      (tester) async {
    final service = globals.service as _TestService;
    service.videos[0] = service.videos[0].copyWith(
      description: 'Select description words\n'
          '1:02 Introduction\nhttps://youtube.com/playlist?list=PLexample\n'
          '${List.filled(60, 'A line from the description.').join('\n')}',
    );
    await _pumpExpandedPlayer(tester, const Size(390, 844), selectedIndex: 0);
    final player =
        tester.element(find.byType(ExpandedPlayer)).read<PlayerCubit>();
    await tester.tap(find.byKey(const ValueKey('watch-open-description')));
    await tester.pumpAndSettle();
    final text = find.descendant(
        of: find.byType(TextLinkified), matching: find.byType(EditableText));
    final start = tester.getTopLeft(text) + const Offset(30, 10);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    final selected = tester.widget<EditableText>(text).controller.selection;
    expect(selected.isCollapsed, isFalse);
    for (var second = 1; second <= 3; second++) {
      player.setEvent(MediaEvent<Duration>(
          type: MediaEventType.progress,
          state: MediaState.playing,
          value: Duration(seconds: second)));
      await tester.pump(const Duration(milliseconds: 250));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(text).controller.selection, selected);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share').hitTestable(), findsOneWidget);
    expect(player.state.isMini, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final sourceAspectRatio in [9 / 16, 21 / 9]) {
    testWidgets(
        'fullscreen fills the viewport for source aspect $sourceAspectRatio and restores inline and floating sizes',
        (tester) async {
      const viewport = Size(390, 844);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.resetPadding);
      await _pumpExpandedPlayer(tester, viewport, selectedIndex: 0);
      final player = tester.element(find.byType(Player)).read<PlayerCubit>();
      final videoWidget = find.byKey(const ValueKey('player'));
      final videoState = tester.state(videoWidget);
      final videoSurface = find.ancestor(
        of: videoWidget,
        matching: find.byType(AspectRatio),
      );
      final inlineSize = tester.getSize(videoSurface);
      expect(inlineSize.aspectRatio, closeTo(16 / 9, 0.001));

      player.setEvent(MediaEvent<double>(
        state: MediaState.ready,
        type: MediaEventType.aspectRatioChanged,
        value: sourceAspectRatio,
      ));
      player.setFullScreen(FullScreenState.fullScreen);
      await tester.pumpAndSettle();

      expect(tester.getRect(videoSurface), Offset.zero & viewport);
      expect(tester.state(videoWidget), same(videoState));

      player.setFullScreen(FullScreenState.notFullScreen);
      await tester.pumpAndSettle();
      expect(tester.getSize(videoSurface), inlineSize);
      expect(tester.state(videoWidget), same(videoState));

      player.showMiniPlayer();
      await tester.pumpAndSettle();
      final miniSize = tester.getSize(videoSurface);
      expect(miniSize.width, lessThan(inlineSize.width));
      final floatingAspectRatio = sourceAspectRatio < 16 / 9 ? 9 / 16 : 16 / 9;
      expect(miniSize.aspectRatio, closeTo(floatingAspectRatio, 0.001));
      expect(tester.state(videoWidget), same(videoState));
      expect(tester.takeException(), isNull);
    });
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

  for (final withMiniPlayer in [false, true]) {
    testWidgets(
        'routed watch preview pulls down without starting playback (mini=$withMiniPlayer)',
        (tester) async {
      final service = globals.service as _TestService;
      service.videos[0] = service.videos[0].copyWith(
          recommendedVideos: List.generate(
              12,
              (index) => Video(
                  videoId: 'relation${index.toString().padLeft(3, '0')}',
                  title: 'Related recording $index')));
      // An existing mini player should survive dismissing a different preview.
      final playing = withMiniPlayer ? service.videos[1] : null;
      await _pumpVideo(tester, const Size(390, 844),
          playerState: playing == null
              ? null
              : PlayerState.init([playing]).copyWith(
                  currentlyPlaying: playing, isMini: true, isHidden: false));
      final screen = find.byType(VideoScreen);
      final player = tester.element(screen).read<PlayerCubit>();
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
            'https://lh3.googleusercontent.com/artist=w540-h225-p-l90-rj',
            'https://yt3.googleusercontent.com/avatar=s176',
            '//yt3.ggpht.com/avatar=s88',
            'https://i.ytimg.com/vi/video-id/default.jpg',
          ],
          onPressed: () {},
        );

        const expectedUrls = [
          'https://example.com/ggpht/artist=w540-h225-p-l90-rj',
          'https://example.com/ggpht/avatar=s176',
          'https://example.com/ggpht/avatar=s88',
          'https://example.com/vi/video-id/default.jpg',
        ];
        for (var index = 0; index < expectedUrls.length; index++) {
          await _pumpUntilRequestCount(tester, cacheManager, index + 1);
          expect(cacheManager.requests[index].url, expectedUrls[index]);
          expect(cacheManager.requests[index].headers, _instanceRequestHeaders);
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
        expect(cacheManager.requests.single.headers,
            equals(_instanceRequestHeaders));
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
        expect(cacheManager.requests.last.headers,
            equals(_instanceRequestHeaders));
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

    testWidgets('omit off-instance artwork without disabling the controls',
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

        for (var attempt = 0;
            attempt < 20 && find.byIcon(Icons.error_outline).evaluate().isEmpty;
            attempt++) {
          await tester.idle();
          await tester.pump(const Duration(milliseconds: 10));
        }

        expect(cacheManager.requests, isEmpty);
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
