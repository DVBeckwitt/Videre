import 'dart:convert';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/player/views/components/seek_preview.dart';
import 'package:clipious/player/views/tv/components/player_controls.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/storyboard.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _firstSheetUrl = 'https://instance.example/sb/i/id/L2/M0.png';
const _secondSheetUrl = 'https://instance.example/sb/i/id/L2/M1.png';

class _SpriteCache extends cache.BaseCacheManager {
  final requests =
      <({String url, String? key, Map<String, String>? headers})>[];
  final shortSheets = <String>{};
  final failedSheets = <String>{};
  final _fileSystem = MemoryFileSystem.test();
  late final _fullSprite = _fileSystem.file('sprite.png')
    ..writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAIAAAC1qksFAAAAKklEQVR4nGP4z8BAEiJNNRlo1IJRC4ajBaTq+P+fgSQ0asGoBaMW/GcAAMouzU/PxmgLAAAAAElFTkSuQmCC'));
  late final _shortSprite = _fileSystem.file('partial-sprite.png')
    ..writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAJCAIAAADcu7ldAAAAGUlEQVR4nGP4z8BAEiJNNRlo1IJRC4ahBQDUcB7w0UWv5gAAAABJRU5ErkJggg=='));

  @override
  Stream<cache.FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    requests.add((url: url, key: key, headers: headers));
    if (failedSheets.contains(url)) throw StateError('unavailable storyboard');
    final file = shortSheets.contains(url) ? _shortSprite : _fullSprite;
    yield cache.FileInfo(file, cache.FileSource.Cache, DateTime.utc(2100), url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PreviewPlayer extends TestPlayerCubit {
  _PreviewPlayer(super.initialState, super.settings);

  void changeVideo(Video video) => emit(state.copyWith(
      currentlyPlaying: video,
      position: Duration.zero,
      mediaEvent: const MediaEvent(state: MediaState.loading)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const board = Storyboard(
      templateUrl: r'https://i.ytimg.com/sb/id/L2/M$M.png',
      width: 16,
      height: 9,
      count: 4,
      interval: 10000,
      columns: 2,
      rows: 2,
      sheets: 1);
  const video = Video(
      videoId: 'id', title: 'Video', lengthSeconds: 40, storyboards: [board]);
  const server = Server(
      url: 'https://instance.example', customHeaders: {'X-Test': 'instance'});
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _PreviewPlayer player;
  late _SpriteCache cacheManager;
  final originalCache = _SpriteCache();
  CachedNetworkImageProvider.defaultCacheManager = originalCache;

  setUp(() async {
    app_main.isTv = false;
    app_main.darkColorScheme = ColorScheme.fromSeed(
        seedColor: Colors.blue, brightness: Brightness.dark);
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(server);
    await db.useServer(server);
    app = TestAppCubit(AppState(0, server, HomeLayout()));
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _PreviewPlayer(
        PlayerState.init([video])
            .copyWith(currentlyPlaying: video, isMini: false, isHidden: false),
        settings);
    cacheManager = _SpriteCache();
    CachedNetworkImageProvider.defaultCacheManager = cacheManager;
  });

  tearDown(() async {
    CachedNetworkImageProvider.defaultCacheManager = originalCache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (!player.isClosed) await player.close();
    await settings.close();
    await db.close();
  });

  Widget host(Widget child) => MultiBlocProvider(
          providers: [
            BlocProvider<AppCubit>.value(value: app),
            BlocProvider<SettingsCubit>.value(value: settings),
            BlocProvider<PlayerCubit>.value(value: player),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: Center(child: child)),
          ));

  Future<void> settleImage(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }

  const previewBoundaryKey = ValueKey('preview-image');

  Future<void> showPreview(WidgetTester tester, Video previewVideo, int seconds,
      {int duration = 40}) async {
    await tester.pumpWidget(host(RepaintBoundary(
        key: previewBoundaryKey,
        child: SeekPreview(
            video: previewVideo,
            position: Duration(seconds: seconds),
            duration: Duration(seconds: duration)))));
    await settleImage(tester);
  }

  Future<void> expectTiles(
      WidgetTester tester, List<List<int>?> expectedColors) async {
    final tiles = find.byWidgetPredicate(
        (widget) => widget is RawImage && widget.image != null);
    final expectedCount = expectedColors.nonNulls.length;
    // A neighboring sheet starts loading after the current tile is decoded.
    for (var i = 0; i < 10 && tiles.evaluate().length < expectedCount; i++) {
      await settleImage(tester);
    }
    expect(tiles, findsNWidgets(expectedCount));

    final colors = await tester.runAsync(() async {
      final boundary = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(previewBoundaryKey));
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final y = image.height ~/ 3;
      final colors = [
        for (var slot = 0; slot < 3; slot++)
          [
            for (var channel = 0; channel < 3; channel++)
              bytes.getUint8(
                  (y * image.width + (2 * slot + 1) * image.width ~/ 6) * 4 +
                      channel),
          ],
      ];
      image.dispose();
      return colors;
    });
    for (var slot = 0; slot < 3; slot++) {
      final expected = expectedColors[slot];
      expect(colors![slot], expected ?? everyElement(lessThan(64)),
          reason: 'filmstrip tile ${slot + 1}');
    }
  }

  const red = [255, 0, 0];
  const green = [0, 255, 0];
  const blue = [0, 0, 255];
  const yellow = [255, 255, 0];

  testWidgets('centers the current tile and reuses its sheet for nearby tiles',
      (tester) async {
    await showPreview(tester, video, 0);
    await expectTiles(tester, [null, red, green]);
    await showPreview(tester, video, 10);
    await expectTiles(tester, [red, green, blue]);
    await showPreview(tester, video, 20);
    await expectTiles(tester, [green, blue, yellow]);
    await showPreview(tester, video, 40);
    await expectTiles(tester, [blue, yellow, null]);

    expect(cacheManager.requests, hasLength(1));
    expect(cacheManager.requests.single.url, _firstSheetUrl);
    expect(cacheManager.requests.single.headers, {
      ...server.customHeaders,
      gatewayContextHeader: GatewayRequestContext.forAccount(
              server.profileId, server.accountId, server.url)!
          .encoded,
    });
    expect(cacheManager.requests.single.key,
        invidiousImageCacheKey(_firstSheetUrl, server));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  final twoSheetVideo = video.copyWith(lengthSeconds: 60, storyboards: [
    Storyboard.fromJson({...board.toJson(), 'count': 6, 'storyboardCount': 2}),
  ]);

  testWidgets('cropped tiles cross into a partial final sheet', (tester) async {
    cacheManager.shortSheets.add(_secondSheetUrl);
    await showPreview(tester, twoSheetVideo, 30, duration: 60);
    await expectTiles(tester, [blue, yellow, red]);
    await showPreview(tester, twoSheetVideo, 40, duration: 60);
    await expectTiles(tester, [yellow, red, green]);
    await showPreview(tester, twoSheetVideo, 60, duration: 60);
    await expectTiles(tester, [red, green, null]);

    expect(cacheManager.requests.map((request) => request.url),
        unorderedEquals([_firstSheetUrl, _secondSheetUrl]));
    expect(
        cacheManager.requests.map((request) => request.key),
        unorderedEquals([
          invidiousImageCacheKey(_firstSheetUrl, server),
          invidiousImageCacheKey(_secondSheetUrl, server),
        ]));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a missing neighbor sheet keeps the usable current preview',
      (tester) async {
    cacheManager.failedSheets.add(_secondSheetUrl);
    await showPreview(tester, twoSheetVideo, 30, duration: 60);
    await expectTiles(tester, [blue, yellow, null]);
    expect(find.text('00:30'), findsOneWidget);

    await showPreview(tester, twoSheetVideo, 40, duration: 60);
    expect(find.text('00:40'), findsOneWidget);
    expect(tester.getSize(find.byType(SeekPreview)).height, lessThan(50));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing and failed storyboards retain the time without crashing',
      (tester) async {
    await tester.pumpWidget(host(const SeekPreview(
        video: null,
        position: Duration(seconds: 10),
        duration: Duration(seconds: 40))));
    expect(find.text('00:10'), findsOneWidget);
    expect(cacheManager.requests, isEmpty);
    cacheManager.failedSheets.add(_firstSheetUrl);
    await tester.pumpWidget(host(const SeekPreview(
        video: video,
        position: Duration(seconds: 10),
        duration: Duration(seconds: 40))));
    await settleImage(tester);
    expect(find.text('00:10'), findsOneWidget);
    expect(find.byType(ClipRRect), findsNothing);
    expect(tester.getSize(find.byType(SeekPreview)).height, lessThan(50));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'off-instance storyboards keep the seek time without an image request',
      (tester) async {
    final external = Storyboard.fromJson({
      ...board.toJson(),
      'templateUrl': r'https://images.example/sheet-$M.png',
    });
    await tester.pumpWidget(host(SeekPreview(
        video: video.copyWith(storyboards: [external]),
        position: Duration.zero,
        duration: const Duration(seconds: 40))));
    await settleImage(tester);
    expect(cacheManager.requests, isEmpty);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.byType(ClipRRect), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unsupported preferred storyboard keeps a usable private preview',
      (tester) async {
    final unsupported = Storyboard.fromJson({
      ...board.toJson(),
      'width': 32,
      'height': 18,
      'templateUrl': r'https://i.ytimg.com/unsupported/sheet-$M.png',
    });
    await tester.pumpWidget(host(SeekPreview(
        video: video.copyWith(storyboards: [board, unsupported]),
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 40))));
    await settleImage(tester);
    expect(cacheManager.requests, hasLength(1));
    expect(cacheManager.requests.single.url, _firstSheetUrl);
    expect(find.byType(ClipRRect), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unsupported-only storyboard retains time without a request',
      (tester) async {
    final unsupported = Storyboard.fromJson({
      ...board.toJson(),
      'templateUrl': r'https://i.ytimg.com/unsupported/sheet-$M.png',
    });
    await tester.pumpWidget(host(SeekPreview(
        video: video.copyWith(storyboards: [unsupported]),
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 40))));
    await settleImage(tester);
    expect(cacheManager.requests, isEmpty);
    expect(find.text('00:10'), findsOneWidget);
    expect(find.byType(ClipRRect), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'phone shows a preview while dragging and commits the seek only on release',
      (tester) async {
    await tester.pumpWidget(
        host(const SizedBox(width: 390, height: 220, child: PlayerControls())));
    await tester.pumpAndSettle();
    expect(find.byType(SeekPreview), findsNothing);
    expect(cacheManager.requests, isEmpty);
    final slider = tester.getRect(find.byType(Slider));
    final drag = await tester.startGesture(slider.centerLeft + Offset(30, 0));
    await drag.moveTo(slider.center);
    await tester.pump();
    expect(find.byType(SeekPreview), findsOneWidget);
    expect(player.state.position, Duration.zero);
    final target =
        tester.widget<SeekPreview>(find.byType(SeekPreview)).position;
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.byType(SeekPreview), findsNothing);
    expect(player.state.position, target);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'changing videos during a phone drag cancels the old seek and preview',
      (tester) async {
    addTearDown(() => tester.runAsync(player.close));
    await tester.pumpWidget(
        host(const SizedBox(width: 390, height: 220, child: PlayerControls())));
    await tester.pumpAndSettle();
    final slider = tester.getRect(find.byType(Slider));
    final drag = await tester.startGesture(slider.centerLeft + Offset(30, 0));
    await drag.moveTo(slider.center);
    await tester.pump();
    expect(find.byType(SeekPreview), findsOneWidget);

    // Session writes use real async work, outside the widget test's fake clock.
    await tester.runAsync(() async {
      player.changeVideo(video.copyWith(videoId: 'next', lengthSeconds: 5));
    });
    await settleImage(tester);
    expect(find.byType(SeekPreview), findsNothing);
    await drag.moveTo(slider.centerRight - Offset(30, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(player.state.position, Duration.zero);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'TV preview does not carry across videos and can close with a pending timer',
      (tester) async {
    addTearDown(() => tester.runAsync(player.close));
    await tester.pumpWidget(host(const TvPlayerControls()));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.byType(SeekPreview), findsOneWidget);
    await tester.runAsync(() async {
      player.changeVideo(video.copyWith(videoId: 'next'));
    });
    await settleImage(tester);
    expect(find.byType(SeekPreview), findsNothing);
    await tester
        .runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.arrowRight));
    await settleImage(tester);
    expect(tester.widget<SeekPreview>(find.byType(SeekPreview)).video?.videoId,
        'next');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'TV remote seeks show the target preview and dismiss it after the last step',
      (tester) async {
    await tester.pumpWidget(host(const TvPlayerControls()));
    await tester.pumpAndSettle();
    expect(find.byType(SeekPreview), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.widget<SeekPreview>(find.byType(SeekPreview)).position,
        const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<SeekPreview>(find.byType(SeekPreview)).position,
        Duration.zero);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(SeekPreview), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}
