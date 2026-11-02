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

class _SpriteCache extends cache.BaseCacheManager {
  final requests = <({String url, Map<String, String>? headers})>[];
  bool fail = false;
  final file = MemoryFileSystem.test().file('sprite.png')
    ..writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAIAAAC1qksFAAAAKklEQVR4nGP4z8BAEiJNNRlo1IJRC4ajBaTq+P+fgSQ0asGoBaMW/GcAAMouzU/PxmgLAAAAAElFTkSuQmCC'));

  @override
  Stream<cache.FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    requests.add((url: url, headers: headers));
    if (fail) throw StateError('unavailable storyboard');
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

  for (final shortSheet in [false, true]) {
    testWidgets(
        'crops and reuses ${shortSheet ? 'a partial final' : 'a full'} sprite sheet',
        (tester) async {
      if (shortSheet) {
        cacheManager.file.writeAsBytesSync(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAACAAAAAJCAIAAADcu7ldAAAAGUlEQVR4nGP4z8BAEiJNNRlo1IJRC4ahBQDUcB7w0UWv5gAAAABJRU5ErkJggg=='));
      }
      final previewVideo = shortSheet
          ? video.copyWith(storyboards: [
              Storyboard.fromJson({...board.toJson(), 'count': 2})
            ])
          : video;
      const boundaryKey = ValueKey('preview-image');
      Future<void> preview(int seconds) async {
        await tester.pumpWidget(host(RepaintBoundary(
            key: boundaryKey,
            child: SeekPreview(
                video: previewVideo,
                position: Duration(seconds: seconds),
                duration: const Duration(seconds: 40)))));
        await settleImage(tester);
      }

      Future<List<int>?> pixel() => tester.runAsync(() async {
            final boundary = tester
                .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes =
                (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
            final offset = (49 * image.width + 84) * 4;
            final color =
                List<int>.generate(3, (i) => bytes.getUint8(offset + i));
            image.dispose();
            return color;
          });
      await preview(0);
      expect(await pixel(), [255, 0, 0]);
      await preview(10);
      expect(await pixel(), [0, 255, 0]);
      if (!shortSheet) {
        await preview(20);
        expect(await pixel(), [0, 0, 255]);
      }
      expect(cacheManager.requests, hasLength(1));
      expect(cacheManager.requests.single.url,
          'https://instance.example/sb/i/id/L2/M0.png');
      expect(cacheManager.requests.single.headers, server.customHeaders);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('missing and failed storyboards retain the time without crashing',
      (tester) async {
    await tester.pumpWidget(host(const SeekPreview(
        video: null,
        position: Duration(seconds: 10),
        duration: Duration(seconds: 40))));
    expect(find.text('00:10'), findsOneWidget);
    expect(cacheManager.requests, isEmpty);
    cacheManager.fail = true;
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
      'storyboard requests never send instance headers to another origin',
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
    expect(
        cacheManager.requests.single.url, 'https://images.example/sheet-0.png');
    expect(cacheManager.requests.single.headers, isNull);
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
