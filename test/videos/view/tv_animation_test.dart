import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/channels/models/channel_playlists.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/channels/states/tv_channel.dart';
import 'package:clipious/channels/views/tv/screens/channel.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_item_list.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/tv_video.dart';
import 'package:clipious/videos/views/tv/screens/video.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';

class _Service extends Service {
  final List<ImageObject>? banners;

  _Service({this.banners});

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<bool> isSubscribedToChannel(String channelId) async => false;

  @override
  Future<Channel> getChannel(String channelId,
          {bool saveLastSeen = true, Server? serverOverride}) async =>
      Channel(
          'A channel',
          channelId,
          '/channel/$channelId',
          banners ?? [ImageObject(null, '/banner', 1060, 175)],
          [],
          100,
          1000,
          0,
          false,
          true,
          List.filled(40, 'Channel description.').join(' '),
          [],
          []);

  @override
  Future<VideosWithContinuation> getChannelVideos(
          String channelId, String? continuation,
          {bool saveLastSeen = true,
          Server? serverOverride,
          ChannelSortBy sortBy = ChannelSortBy.newest}) async =>
      VideosWithContinuation([], null);

  @override
  Future<VideosWithContinuation> getChannelShorts(
          String channelId, String? continuation) async =>
      VideosWithContinuation([], null);

  @override
  Future<VideosWithContinuation> getChannelStreams(
          String channelId, String? continuation) async =>
      VideosWithContinuation([], null);

  @override
  Future<ChannelPlaylists> getChannelPlaylists(String channelId,
          {String? continuation}) async =>
      ChannelPlaylists([], null);

  @override
  Future<Video> getVideo(String videoId,
          {Server? serverOverride,
          VideoLoadObserver? loadObserver,
          void Function(BackendPlayback request)? onBackendRequest}) async =>
      Video(
          videoId: videoId,
          title: 'A video',
          author: 'A channel',
          authorId: 'channel',
          lengthSeconds: 30,
          description: 'A video description.');
}

class _CacheManager implements cache.BaseCacheManager {
  final requests = <String>[];

  @override
  Stream<cache.FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    requests.add(url);
    yield cache.FileInfo(const LocalFileSystem().file('assets/icon.png'),
        cache.FileSource.Cache, DateTime.utc(2100), url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads() : super(const DownloadManagerState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Fake implements SettingsCubit {
  @override
  Stream<SettingsState> get stream => const Stream.empty();

  @override
  SettingsState get state => SettingsState.init().copyWith(settings: {
        useReturnYoutubeDislikeSettingName:
            SettingsValue(useReturnYoutubeDislikeSettingName, 'false')
      });
}

class _Player extends Fake implements PlayerCubit {
  @override
  PlayerState get state => PlayerState.init(null);

  @override
  Stream<PlayerState> get stream => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Set the test cache before reading this lazily initialized static; the real
  // default creates platform directories unavailable in a widget test.
  CachedNetworkImageProvider.defaultCacheManager = _CacheManager();
  late Service originalService;
  late cache.BaseCacheManager originalCache;
  late _CacheManager imageCache;
  late _Downloads downloads;

  setUp(() async {
    originalService = service;
    service = _Service();
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(const Server(url: 'https://instance.example'));
    originalCache = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager =
        imageCache = _CacheManager();
    downloads = _Downloads();
  });

  tearDown(() async {
    debugOnRebuildDirtyWidget = null;
    CachedNetworkImageProvider.defaultCacheManager = originalCache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await downloads.close();
    await db.close();
    service = originalService;
  });

  Future<void> mount(WidgetTester tester, Widget screen, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<DownloadManagerCubit>.value(value: downloads),
        BlocProvider<SettingsCubit>.value(value: _Settings()),
        BlocProvider<PlayerCubit>.value(value: _Player()),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: screen,
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Future<void> expectStableContentDuringBlur(WidgetTester tester) async {
    // Let the new Cubit state rebuild the content once. Only animation ticks
    // after this point should be limited to the backdrop filter itself.
    await tester.pump();
    // Bloc notification delivery can schedule the content rebuild for the next
    // frame; flush it before measuring the independent animation ticks.
    await tester.pump();
    var listBuilds = 0;
    var animationBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is TvHorizontalVideoList) listBuilds++;
      if (element.widget is TweenAnimationBuilder<double>) animationBuilds++;
    };
    for (var i = 0; i < 4; i++) {
      await tester.pump(animationDuration ~/ 5);
    }
    debugOnRebuildDirtyWidget = null;
    expect(animationBuilds, greaterThan(1));
    expect(listBuilds, 0,
        reason: 'Changing blur must not rebuild independent video lists');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('TV channel blur preserves its content between animation ticks',
      (tester) async {
    await mount(tester, const TvChannelScreen(channelId: 'channel'),
        const Size(1280, 280));
    final context = tester.element(find.byType(TvHorizontalVideoList).first);
    final tv = context.read<TvChannelCubit>();
    expect(tv.scrollController.position.maxScrollExtent, greaterThan(0));
    tv.scrollController.jumpTo(tv.scrollController.position.maxScrollExtent);
    expect(tv.state.showBackground, isTrue);
    await expectStableContentDuringBlur(tester);
    expect(find.text('A channel'), findsOneWidget);
    tv.scrollController.jumpTo(0);
    await tester.pumpAndSettle();
    expect(tv.state.showBackground, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'TV banner skips unsupported artwork and retains instance headers',
      (tester) async {
    service = _Service(banners: [
      ImageObject(null, 'https://yt4.ggpht.com/unsupported', 2000, 400),
      ImageObject(null, 'https://yt3.ggpht.com/banner=s1000', 1000, 200),
    ]);
    await tester.runAsync(() => db.upsertServer(const Server(
        url: 'https://instance.example',
        customHeaders: {'X-Image-Access': 'fixture-access'})));
    await mount(tester, const TvChannelScreen(channelId: 'channel'),
        const Size(1280, 900));

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    final image =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(image.imageUrl, 'https://instance.example/ggpht/banner=s1000');
    expect(image.httpHeaders?['X-Image-Access'], 'fixture-access');
    expect(
        imageCache.requests, ['https://instance.example/ggpht/banner=s1000']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final banners in <List<ImageObject>>[
    [],
    [ImageObject(null, '', 1000, 200)],
    [ImageObject(null, 'https://yt4.ggpht.com/unsupported', 1000, 200)],
  ]) {
    testWidgets(
        'TV omits missing or unsupported banner (${banners.firstOrNull?.url})',
        (tester) async {
      service = _Service(banners: banners);
      await mount(tester, const TvChannelScreen(channelId: 'channel'),
          const Size(1280, 900));

      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(imageCache.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('TV video blur preserves its content between animation ticks',
      (tester) async {
    await mount(
        tester, const TvVideoScreen(videoId: 'video'), const Size(1280, 900));
    final context = tester.element(find.byType(TvHorizontalVideoList));
    final tv = context.read<TvVideoCubit>();
    tv.scrollDown();
    expect(tv.state.showImage, isFalse);
    await expectStableContentDuringBlur(tester);
    expect(find.text('A video'), findsOneWidget);
    tv.scrollUp();
    await tester.pumpAndSettle();
    expect(tv.state.showImage, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
