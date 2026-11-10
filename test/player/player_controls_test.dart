import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/player_controls.dart';
import 'package:clipious/player/states/tv_player_controls.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _SpeedBoostVideo extends VideoPlayerCubit {
  _SpeedBoostVideo(super.initialState, super.player, super.settings);

  final speedChanges = <double>[];

  @override
  void onInit() {}

  @override
  void disposeControllers() {}

  @override
  VoidCallback? startSpeedBoost({VoidCallback? onEnded}) {
    speedChanges.add(2);
    return () {
      speedChanges.add(1.37);
      onEnded?.call();
    };
  }
}

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(
        PlayerState.init(null).copyWith(isMini: false), settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await db.close();
  });

  Widget hostControls(Widget child) {
    app_main.darkColorScheme = ColorScheme.fromSeed(
        seedColor: Colors.blue, brightness: Brightness.dark);
    return MultiBlocProvider(
      providers: [
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Future<_SpeedBoostVideo> createPlayingVideo(WidgetTester tester,
      {double aspectRatio = 16 / 9}) async {
    const video = Video(videoId: 'boost-test', lengthSeconds: 60);
    await tester.runAsync(player.close);
    player = TestPlayerCubit(
      PlayerState.init(null).copyWith(
        isMini: false,
        isHidden: false,
        isPlaying: true,
        currentlyPlaying: video,
        speed: 1.37,
        aspectRatio: aspectRatio,
      ),
      settings,
    );
    final videoPlayer = _SpeedBoostVideo(
      VideoPlayerState(
        video: video,
        colors: const ColorScheme.dark(),
        overFlowTextColor: Colors.white,
        key: GlobalKey(),
      ),
      player,
      settings,
    );
    addTearDown(videoPlayer.close);
    return videoPlayer;
  }

  testWidgets('closing controls cancels pending feedback and hide timers',
      (tester) async {
    final controls = PlayerControlsCubit(const PlayerControlsState(), player);
    controls.doubleTapFastForward();
    controls.doubleTapRewind();
    controls.onStreamEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.sponsorSkipped));
    await controls.close();
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled mini-player drag restores its docked position',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    player.showMiniPlayer();
    await tester.pumpWidget(hostControls(SizedBox(
      width: 300,
      height: 120,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pump(const Duration(seconds: 4));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(PlayerControls)));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(player.state.isDragging, isTrue);
    await gesture.cancel();
    await tester.pump();
    expect(player.state.isDragging, isFalse);
    expect(player.state.isMini, isTrue);
    expect(player.state.top, isNull);
    expect(player.state.showMiniPlaceholder, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit minimize clears an interrupted drag', (tester) async {
    await createPlayingVideo(tester);
    player.videoDragStarted(DragStartDetails());
    player.videoDragged(DragUpdateDetails(
        delta: const Offset(0, 250), globalPosition: const Offset(100, 1200)));
    expect(player.state.isDragging, isTrue);
    player.showMiniPlayer();
    expect(player.state.isDragging, isFalse);
    expect(player.state.top, isNull);
    expect(player.state.dragDistance, 0);
  });

  testWidgets('controls appearing mid-drag retain the cancellation handler',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    player.showMiniPlayer();
    await tester.pumpWidget(hostControls(SizedBox(
      width: 300,
      height: 120,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pump(const Duration(seconds: 4));
    final controls = tester
        .element(find.byType(LayoutBuilder).last)
        .read<PlayerControlsCubit>();
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(PlayerControls)));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(player.state.isDragging, isTrue);
    controls.showControls();
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(player.state.isDragging, isFalse);
    expect(player.state.isMini, isTrue);
    expect(player.state.top, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('separate controls keep their own hide deadlines',
      (tester) async {
    final first = PlayerControlsCubit(const PlayerControlsState(), player);
    await tester.pump(const Duration(seconds: 1));
    final second = PlayerControlsCubit(const PlayerControlsState(), player);
    await tester.pump(const Duration(seconds: 2));
    expect(first.state.displayControls, isFalse);
    expect(second.state.displayControls, isTrue);
    await first.close();
    await tester.pump(const Duration(seconds: 1));
    expect(second.state.displayControls, isFalse);
    await second.close();
  });

  testWidgets('paused decoder readiness clears the loading overlay',
      (tester) async {
    final controls = PlayerControlsCubit(const PlayerControlsState(), player);
    controls.onStreamEvent(const MediaEvent(state: MediaState.loading));
    expect(controls.state.buffering, isTrue);
    // Metadata can arrive while the decoder is still loading.
    controls.onStreamEvent(const MediaEvent<double>(
        state: MediaState.ready, type: MediaEventType.speedChanged, value: 1));
    expect(controls.state.buffering, isTrue);
    // A paused decoder may never send a progress event after becoming ready.
    controls.onStreamEvent(const MediaEvent(state: MediaState.ready));
    expect(controls.state.buffering, isFalse);
    expect(player.state.isPlaying, isFalse);
    await controls.close();
  });

  testWidgets('holding either video side boosts speed until release or cancel',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pumpAndSettle();

    final bounds = tester.getRect(find.byType(PlayerControls));
    Offset pointAt(double fraction) =>
        bounds.topLeft + Offset(bounds.width * fraction, bounds.height * .25);
    final indicator = find.text('2×');
    final slider = find.byType(Slider);

    expect(slider, findsOneWidget);
    final left = await tester.startGesture(pointAt(.15));
    await tester.pump(const Duration(milliseconds: 199));
    expect(videoPlayer.speedChanges, isEmpty);
    expect(indicator, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(videoPlayer.speedChanges, [2]);
    expect(indicator, findsOneWidget);

    // The controls can auto-hide while the same finger is still held down.
    await tester.pump(const Duration(seconds: 4));
    expect(slider, findsNothing);
    expect(indicator, findsOneWidget);
    await left.up();
    // Restoring speed must not wait for another frame or a release timer.
    expect(videoPlayer.speedChanges, [2, 1.37]);
    await tester.pump();
    expect(indicator, findsNothing);

    final right = await tester.startGesture(pointAt(.85));
    await tester.pump(const Duration(milliseconds: 200));
    expect(videoPlayer.speedChanges, [2, 1.37, 2]);
    expect(indicator, findsOneWidget);
    await right.cancel();
    expect(videoPlayer.speedChanges, [2, 1.37, 2, 1.37]);
    await tester.pump();
    expect(indicator, findsNothing);

    final center = await tester.startGesture(pointAt(.5));
    await tester.pump(kLongPressTimeout);
    await center.up();
    await tester.pump();
    expect(videoPlayer.speedChanges, [2, 1.37, 2, 1.37]);
    expect(indicator, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('quick taps, double-tap seeking and drags do not boost speed',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pump(const Duration(seconds: 4));
    final controls = tester
        .element(find.byType(LayoutBuilder).last)
        .read<PlayerControlsCubit>();
    final bounds = tester.getRect(find.byType(PlayerControls));
    final point =
        bounds.topLeft + Offset(bounds.width * .85, bounds.height * .25);

    await tester.tapAt(point);
    await tester.pump(kDoubleTapTimeout);
    expect(controls.state.displayControls, isTrue);
    expect(videoPlayer.speedChanges, isEmpty);

    controls.hideControls();
    await tester.pumpAndSettle();
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(point);
    await tester.pump();
    expect(controls.state.justDoubleTappedSkip, isTrue);
    expect(videoPlayer.speedChanges, isEmpty);

    controls.hideControls();
    await tester.pump(const Duration(seconds: 1));
    final drag = await tester.startGesture(point);
    await drag.moveBy(const Offset(0, 50));
    await drag.moveBy(const Offset(0, 25));
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.state.isDragging, isTrue);
    expect(videoPlayer.speedChanges, isEmpty);
    await drag.cancel();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a deliberate center-button press still pauses playback',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    final press =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.pause)));
    await tester.pump(const Duration(milliseconds: 300));
    await press.up();
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    expect(videoPlayer.speedChanges, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('speed hold preserves the device touch movement tolerance',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(MediaQuery(
      data: const MediaQueryData(
          gestureSettings: DeviceGestureSettings(touchSlop: 40)),
      child: SizedBox(
        width: 390,
        height: 220,
        child: PlayerControls(mediaPlayerCubit: videoPlayer),
      ),
    )));
    final bounds = tester.getRect(find.byType(PlayerControls));
    final hold =
        await tester.startGesture(bounds.topLeft + const Offset(40, 60));
    // More than Flutter's default 18, less than this device's tolerance.
    await hold.moveBy(const Offset(24, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(videoPlayer.speedChanges, [2]);
    await hold.up();
    expect(videoPlayer.speedChanges, [2, 1.37]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (layout, viewport, videoAspect) in [
    ('portrait', const Size(390, 844), 21 / 9),
    ('ultrawide', const Size(1000, 400), 9 / 16),
  ]) {
    testWidgets('fullscreen controls fill the $layout viewport with insets',
        (tester) async {
      const padding = FakeViewPadding(left: 24, top: 36, right: 32, bottom: 18);
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = padding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      final videoPlayer =
          await createPlayingVideo(tester, aspectRatio: videoAspect);
      player.setFullScreen(FullScreenState.fullScreen);
      await tester.pumpWidget(hostControls(Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: videoAspect,
            child: const ColoredBox(
              key: ValueKey('test-video-picture'),
              color: Colors.black,
            ),
          ),
          PlayerControls(mediaPlayerCubit: videoPlayer),
        ],
      )));
      await tester.pumpAndSettle();

      final bounds = tester.getRect(find.byType(PlayerControls));
      expect(bounds, Offset.zero & viewport);

      final options = tester.getRect(find.byIcon(Icons.more_vert));
      expect(options.top, greaterThanOrEqualTo(padding.top));
      expect(options.right, closeTo(viewport.width - padding.right, 12));

      final slider = tester.getRect(find.byType(Slider));
      expect(slider.left, closeTo(padding.left, 1));
      expect(slider.bottom, closeTo(viewport.height - padding.bottom, 1));

      final sidePoint = Offset(viewport.width * .15, viewport.height * .25);
      final picture =
          tester.getRect(find.byKey(const ValueKey('test-video-picture')));
      expect(picture.contains(sidePoint), isFalse);
      final hold = await tester.startGesture(sidePoint);
      await tester.pump(kLongPressTimeout);
      expect(videoPlayer.speedChanges, [2]);
      await hold.up();
      await tester.pump();
      expect(videoPlayer.speedChanges, [2, 1.37]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('TV settings stay open until Back, then controls auto-hide',
      (tester) async {
    final controls =
        TvPlayerControlsCubit(const TvPlayerControlsState(), player);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(controls.close);

    controls.showUi();
    controls.displaySettings();
    // A held slider key is consumed by the child, so the parent sees no key
    // events until release. The existing hide deadline must not close settings.
    await tester.pump(controlFadeOut + const Duration(seconds: 1));
    expect(controls.state.showSettings, isTrue);
    expect(controls.state.controlsOpacity, 1);

    expect(
      controls.handleRemoteEvents(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.browserBack,
          logicalKey: LogicalKeyboardKey.goBack,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.handled,
    );
    expect(controls.state.showSettings, isFalse);
    expect(controls.state.displayControls, isTrue);

    await tester.pump(controlFadeOut + const Duration(seconds: 1));
    expect(controls.state.displayControls, isFalse);
    expect(controls.state.controlsOpacity, 0);
  });
}
