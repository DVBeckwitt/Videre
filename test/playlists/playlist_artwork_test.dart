import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/playlists/views/screens/playlist.dart';
import 'package:clipious/playlists/views/tv/screens/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';

import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _App extends AppCubit {
  _App(Server selected) : super(AppState(0, selected, HomeLayout()));

  @override
  void initState() {}

  @override
  void onReady() {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }
}

class _ArtworkCache extends Fake implements cache.BaseCacheManager {
  final requests = <({String url, Map<String, String>? headers})>[];

  @override
  Stream<cache.FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    requests.add((url: url, headers: headers));
    yield cache.FileInfo(const LocalFileSystem().file('assets/icon.png'),
        cache.FileSource.Cache, DateTime.utc(2100), url);
  }
}

class _Playlists extends Service {
  final response = Completer<Playlist>();
  final accounts = <Server?>[];

  @override
  Future<Playlist> getUserPlaylist(String playlistId,
      {int? page, Server? serverOverride}) {
    accounts.add(serverOverride);
    return response.future;
  }

  @override
  Future<Playlist> getPublicPlaylists(String playlistId,
          {int? page, bool saveLastSeen = true, Server? serverOverride}) =>
      getUserPlaylist(playlistId, page: page, serverOverride: serverOverride);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Avoid constructing the plugin-backed default cache in this test isolate.
  CachedNetworkImageProvider.defaultCacheManager = _ArtworkCache();
  const owner = Server(
      url: 'https://owner.example',
      id: 'owner',
      customHeaders: {'X-Test': 'owner'});
  const selected = Server(
      url: 'https://selected.example',
      id: 'selected',
      customHeaders: {'X-Test': 'selected'});
  const reference = PlaylistReference(
      kind: PlaylistSourceKind.account,
      playlistId: 'IVPprivate',
      profileId: 'default',
      accountId: 'owner',
      origin: 'https://owner.example');
  final preview = Video(
      videoId: 'private-video',
      title: 'Private item',
      lengthSeconds: 120,
      videoThumbnails: [
        ImageObject(null, '/vi/private-video/mqdefault.jpg', 320, 180)
      ]);
  final playlist = Playlist(
      playlistId: reference.playlistId,
      type: invidiousPlaylist,
      title: 'Private playlist',
      author: '',
      videoCount: 1,
      videos: [preview]);
  late SembastSqfDb database;
  late _App app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late Service previousService;
  late _Playlists playlists;
  late _ArtworkCache images;
  late cache.BaseCacheManager previousCache;

  setUp(() async {
    app_main.darkColorScheme = const ColorScheme.dark();
    database = await SembastSqfDb.createInMemory();
    db = database;
    await database.upsertServer(owner);
    await database.upsertServer(selected);
    await database.useServer(selected);
    app = _App(selected);
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    previousService = service;
    service = playlists = _Playlists();
    previousCache = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager = images = _ArtworkCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() async {
    service = previousService;
    CachedNetworkImageProvider.defaultCacheManager = previousCache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await player.close();
    await settings.close();
    await app.close();
    await database.close();
  });

  Future<void> show(WidgetTester tester,
      {bool tv = false,
      Size size = const Size(390, 750),
      Playlist? data,
      PlaylistReference source = reference}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: tv
            ? TvPlaylistScreen(
                playlist: data ?? playlist,
                canDeleteVideos: false,
                reference: source)
            : PlaylistViewScreen(
                playlist: data ?? playlist,
                canDeleteVideos: false,
                reference: source),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  }

  for (final layout in [
    (name: 'phone', tv: false, size: const Size(390, 750)),
    (name: 'tablet', tv: false, size: const Size(1100, 750)),
    (name: 'TV', tv: true, size: const Size(1280, 900)),
  ]) {
    testWidgets('${layout.name} private detail artwork retains its owner',
        (tester) async {
      await show(tester, tv: layout.tv, size: layout.size);
      // Cached previews already render while the fresh metadata is pending.
      expect(playlists.response.isCompleted, isFalse);
      expect(images.requests, isNotEmpty);
      expect(images.requests.map((request) => Uri.parse(request.url).origin),
          everyElement(owner.url));
      expect(images.requests.map((request) => request.headers?['X-Test']),
          everyElement('owner'));
      expect(playlists.accounts.single?.accountId, owner.accountId);

      // The service completer was created by setUp outside the fake-async zone.
      await tester.runAsync(() async {
        playlists.response.complete(playlist.copyWith(videos: [
          preview.copyWith(videoId: 'fresh-video', videoThumbnails: [
            ImageObject(null,
                'https://i.ytimg.com/vi/fresh-video/mqdefault.jpg', 320, 180)
          ])
        ]));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final detail = tester
          .element(find.byKey(const ValueKey('playlist-bookmark')))
          .read<PlaylistCubit>();
      expect(detail.loader.videos.single.videoId, 'fresh-video');
      expect(
          tester
              .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
              .any((image) => image.imageUrl.contains('fresh-video')),
          isTrue);
      expect(
          images.requests.any((request) => request.url.contains('fresh-video')),
          isTrue);
      expect(images.requests.map((request) => Uri.parse(request.url).origin),
          everyElement(owner.url));
      expect(images.requests.map((request) => request.headers?['X-Test']),
          everyElement('owner'));
      expect(app.state.server?.accountId, selected.accountId);
      expect(tester.takeException(), isNull);
    });
  }

  for (final unavailable in ['removed', 'origin replaced', 'other profile']) {
    testWidgets(
        'private cached artwork fails closed when owner is $unavailable',
        (tester) async {
      await tester.runAsync(() async {
        if (unavailable == 'removed') {
          await database.deleteServerById(owner);
        } else if (unavailable == 'origin replaced') {
          await database
              .upsertServer(owner.copyWith(url: 'https://moved.example'));
        } else {
          final profile = await database.createProfile('Another person');
          await database.useProfile(profile.id);
          final other = selected.copyWith(profileId: profile.id);
          await database.upsertServer(other);
          await database.useServer(other);
          app.setServer(other);
        }
      });
      await show(tester);
      expect(images.requests, isEmpty);
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in [PlaylistSourceKind.public, PlaylistSourceKind.local]) {
    testWidgets('$kind detail artwork keeps the selected backend',
        (tester) async {
      final id =
          kind == PlaylistSourceKind.local ? 'local:artwork' : 'PLpublic';
      await show(tester,
          data: playlist.copyWith(playlistId: id, type: youtubePlaylist),
          source: PlaylistReference(
              kind: kind, playlistId: id, profileId: 'default'));
      expect(images.requests, isNotEmpty);
      expect(images.requests.map((request) => Uri.parse(request.url).origin),
          everyElement(selected.url));
      expect(images.requests.map((request) => request.headers?['X-Test']),
          everyElement('selected'));
      expect(tester.takeException(), isNull);
    });
  }
}
