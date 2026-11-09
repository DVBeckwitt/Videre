import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/tv_player_settings.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/player/views/components/subtitle_failure_notice.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _VideoWithoutNative extends VideoPlayerCubit {
  _VideoWithoutNative(super.initialState, super.player, super.settings);

  @override
  void onInit() {}

  @override
  void disposeControllers() => videoController = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late _VideoWithoutNative video;
  late BetterPlayerController controller;
  final english = BetterPlayerSubtitlesSource(
    type: BetterPlayerSubtitlesSourceType.memory,
    name: 'English',
    content: 'WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nWorking caption\n\n',
  );
  final japanese = BetterPlayerSubtitlesSource(
    type: BetterPlayerSubtitlesSourceType.memory,
    name: 'Japanese',
    content: '',
  );

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    video = _VideoWithoutNative(
      VideoPlayerState(
        colors: ColorScheme.fromSeed(seedColor: Colors.blue),
        overFlowTextColor: Colors.white,
        key: GlobalKey(),
        video: const Video(videoId: 'caption-test'),
      ),
      player,
      settings,
    );
    controller = BetterPlayerController(const BetterPlayerConfiguration());
    controller.betterPlayerSubtitlesSourceList.addAll([english, japanese]);
    controller.addEventsListener(video.onVideoListener);
    video.videoController = controller;
    player.setEvent(const MediaEvent(state: MediaState.pause));
  });

  tearDown(() async {
    controller.removeEventsListener(video.onVideoListener);
    await video.close();
    controller.dispose(forceDispose: true);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  test('failed captions preserve the last valid language and paused playback',
      () async {
    await controller.setupSubtitleSource(english);
    await Future<void>.delayed(Duration.zero);
    expect(settings.state.lastSubtitles, 'English');
    expect(video.selectedSubtitle(), 0);
    final pausedEvent = player.state.mediaEvent;

    await controller.setupSubtitleSource(japanese);
    expect(video.state.subtitleFailed, isTrue);
    expect(video.selectedSubtitle(), 0);
    expect(settings.state.lastSubtitles, 'English');
    expect(player.state.mediaEvent, same(pausedEvent));
    expect(controller.subtitlesLines.single.texts, ['Working caption']);

    await video.retrySubtitles();
    expect(video.state.subtitleFailed, isTrue);
    expect(video.selectedSubtitle(), 0);
    await controller.setupSubtitleSource(english);
    expect(video.state.subtitleFailed, isFalse);
    expect(player.state.mediaEvent, same(pausedEvent));
  });

  test('TV selection remembers only successfully loaded captions', () async {
    await controller.setupSubtitleSource(english);
    await Future<void>.delayed(Duration.zero);
    final tv =
        TvPlayerSettingsCubit(const TvPlayerSettingsState(), video, settings);
    tv.changeSubtitles('Japanese');
    await Future<void>.delayed(Duration.zero);
    expect(video.state.subtitleFailed, isTrue);
    expect(settings.state.lastSubtitles, 'English');
    expect(video.selectedSubtitle(), 0);
    tv.changeSubtitles('English');
    await Future<void>.delayed(Duration.zero);
    expect(video.state.subtitleFailed, isFalse);
    await tv.close();
  });

  test('changing the data source clears an obsolete caption retry', () async {
    await controller.setupSubtitleSource(japanese);
    expect(video.state.subtitleFailed, isTrue);
    video.onVideoListener(
        BetterPlayerEvent(BetterPlayerEventType.setupDataSource));
    expect(video.state.subtitleFailed, isFalse);
    await video.retrySubtitles();
    expect(video.state.subtitleFailed, isFalse);
  });

  Widget host(
          {double width = 400,
          double height = 220,
          bool autofocus = false,
          Widget? child}) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: SubtitleFailureOverlay(
                player: video,
                autofocus: autofocus,
                child: child ?? const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      );

  testWidgets(
      'caption failure exposes retry and dismiss without stopping video',
      (tester) async {
    await controller.setupSubtitleSource(japanese);
    await tester.pumpWidget(host());
    expect(find.textContaining('Subtitles unavailable'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('subtitle-retry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Subtitles unavailable'), findsOneWidget);
    expect(player.state.mediaEvent.state, MediaState.pause);
    await tester.tap(find.byKey(const ValueKey('subtitle-dismiss')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Subtitles unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'mini player retains the failure without overflowing its controls',
      (tester) async {
    await controller.setupSubtitleSource(japanese);
    await tester.pumpWidget(host(width: 117, height: 66));
    expect(find.byKey(const ValueKey('subtitle-retry')), findsNothing);
    expect(video.state.subtitleFailed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(host());
    expect(find.byKey(const ValueKey('subtitle-retry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen caption retry leaves the seek bar reachable',
      (tester) async {
    const viewport = Size(1000, 400);
    const padding = FakeViewPadding(left: 32, right: 48, bottom: 30);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    app_main.darkColorScheme = const ColorScheme.dark();
    player.showBigPlayer();
    player.setFullScreen(FullScreenState.fullScreen);
    await controller.setupSubtitleSource(japanese);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: host(
        width: viewport.width,
        height: viewport.height,
        child: PlayerControls(mediaPlayerCubit: video),
      ),
    ));
    await tester.pumpAndSettle();

    final retry = find.byKey(const ValueKey('subtitle-retry'));
    final dismiss = find.byKey(const ValueKey('subtitle-dismiss'));
    final seekBar = find.byType(Slider);
    expect(
        tester.getRect(dismiss).bottom, lessThan(tester.getRect(seekBar).top));
    expect(seekBar.hitTestable(), findsOneWidget);
    expect(retry.hitTestable(), findsOneWidget);
    expect(dismiss.hitTestable(), findsOneWidget);
    await tester.tap(dismiss);
    await tester.pumpAndSettle();
    expect(retry, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV failure takes remote focus and restores it after dismissal',
      (tester) async {
    final playbackFocus = FocusNode();
    addTearDown(playbackFocus.dispose);
    var failures = 0;
    controller.addEventsListener((event) {
      if (event.betterPlayerEventType ==
          BetterPlayerEventType.subtitleLoadFailed) {
        failures++;
      }
    });
    await tester.pumpWidget(host(
      autofocus: true,
      child: TextButton(
        focusNode: playbackFocus,
        autofocus: true,
        onPressed: () {},
        child: const Text('Playback controls'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(playbackFocus.hasFocus, isTrue);
    await controller.setupSubtitleSource(japanese);
    await tester.pumpAndSettle();
    expect(playbackFocus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(failures, 2);
    await tester.tap(find.byKey(const ValueKey('subtitle-dismiss')));
    await tester.pumpAndSettle();
    expect(playbackFocus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}
