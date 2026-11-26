import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/models/flow_mini_geometry.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/flow_floating_mini.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  const videos = [
    Video(
        videoId: 'a',
        title: 'First video',
        formatStreams: [],
        adaptiveFormats: []),
    Video(
        videoId: 'b',
        title: 'Second video',
        formatStreams: [],
        adaptiveFormats: []),
    Video(
        videoId: 'c',
        title: 'Third video',
        formatStreams: [],
        adaptiveFormats: []),
  ];
  const second = Duration(seconds: 1);
  const countdownLength =
      Duration(seconds: PlayerCubit.videoAutoplayCountdownSeconds);
  const started =
      MediaEvent(state: MediaState.playing, type: MediaEventType.play);
  const finished = MediaEvent(state: MediaState.completed);

  setUp(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    db = await createPlayerTestDatabase();
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    await db.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    await player.playVideo(videos, playing: true);
    player.showMiniPlayer();
    player.setEvent(started);
  });

  tearDown(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  void expectSecondVideo() {
    expect(player.state.currentQueueId, 'b');
    expect(player.state.playedVideos, ['a']);
    expect(player.state.playQueue, ['c']);
    expect(player.videoAutoplayCountdown.value, isNull);
  }

  Future<void> advanceTo(
      WidgetTester tester, String id, VoidCallback advance) async {
    await tester.runAsync(() async {
      final selected =
          player.stream.firstWhere((state) => state.currentQueueId == id);
      advance();
      await selected.timeout(const Duration(seconds: 2));
    });
  }

  for (final expand in [false, true]) {
    test(
        expand
            ? 'expanding keeps the original automatic transition'
            : 'countdown ticks and automatically advances once in the mini player',
        () async {
      final pending = player.videoAutoplayCountdown;
      final next =
          player.stream.firstWhere((state) => state.currentQueueId == 'b');
      player.setEvent(finished);
      final countdown = pending.value!;
      expect(countdown.next.videoId, 'b');
      expect(countdown.secondsRemaining, countdownLength.inSeconds);

      final firstTick = Completer<void>();
      void observeTick() {
        if (pending.value != null &&
            pending.value!.secondsRemaining < countdownLength.inSeconds &&
            !firstTick.isCompleted) {
          firstTick.complete();
        }
      }

      pending.addListener(observeTick);
      try {
        await firstTick.future.timeout(countdownLength);
      } finally {
        pending.removeListener(observeTick);
      }
      expect(player.state.currentQueueId, 'a');
      if (expand) player.showBigPlayer();
      player.setEvent(finished);
      expect(pending.value?.token, same(countdown.token));

      await next.timeout(countdownLength + const Duration(seconds: 3));
      expectSecondVideo();
      expect(player.state.isMini, !expand);
    });
  }

  testWidgets('Cancel ignores duplicate completion and preserves manual Next',
      (tester) async {
    player.setEvent(finished);
    final token = player.videoAutoplayCountdown.value!.token;
    player.cancelVideoAutoplay(token);
    player.cancelVideoAutoplay(token);
    player.playVideoAutoplayNow(token);
    player.setEvent(finished);
    await tester.pump(countdownLength + second);

    expect(player.videoAutoplayCountdown.value, isNull);
    expect(player.state.currentQueueId, 'a');
    expect(player.state.playedVideos, isEmpty);
    expect(player.state.playQueue, ['b', 'c']);
    expect(player.state.isPlaying, isFalse);

    await advanceTo(tester, 'b', player.playNext);
    expectSecondVideo();
  });

  testWidgets(
      'Play now advances once and an old action cannot affect the next countdown',
      (tester) async {
    player.setEvent(finished);
    final token = player.videoAutoplayCountdown.value!.token;
    await advanceTo(tester, 'b', () {
      player.playVideoAutoplayNow(token);
      player.playVideoAutoplayNow(token);
      player.playNext();
    });
    await tester.pump(countdownLength + second);
    expectSecondVideo();

    player.setEvent(started);
    player.setEvent(finished);
    final secondCountdown = player.videoAutoplayCountdown.value!;
    expect(secondCountdown.next.videoId, 'c');
    player.cancelVideoAutoplay(token);
    player.playVideoAutoplayNow(token);
    expect(player.videoAutoplayCountdown.value?.token,
        same(secondCountdown.token));
    expect(player.state.currentQueueId, 'b');
    player.cancelVideoAutoplay(secondCountdown.token);
  });

  testWidgets('manual Next takes over a pending automatic transition',
      (tester) async {
    player.setEvent(finished);
    final token = player.videoAutoplayCountdown.value!.token;
    await advanceTo(tester, 'b', player.playNext);
    player.playVideoAutoplayNow(token);
    await tester.pump(countdownLength + second);
    expectSecondVideo();
  });

  testWidgets('selecting a different video retires the old countdown',
      (tester) async {
    player.setEvent(finished);
    final token = player.videoAutoplayCountdown.value!.token;
    await tester.runAsync(() => player.selectQueueOccurrence('c'));
    player.playVideoAutoplayNow(token);
    player.cancelVideoAutoplay(token);
    await tester.pump(countdownLength + second);

    expect(player.state.currentQueueId, 'c');
    expect(player.videoAutoplayCountdown.value, isNull);
  });

  testWidgets('the autoplay preference prevents and cancels a countdown',
      (tester) async {
    await tester.runAsync(() => settings.setAutoplayQueue(false));
    player.setEvent(finished);
    await tester.pump();
    expect(player.videoAutoplayCountdown.value, isNull);
    expect(player.state.currentQueueId, 'a');

    await tester.runAsync(() => settings.setAutoplayQueue(true));
    player.play();
    player.setEvent(started);
    player.setEvent(finished);
    expect(player.videoAutoplayCountdown.value?.next.videoId, 'b');
    await tester.runAsync(() => settings.setAutoplayQueue(false));
    await tester.pump(countdownLength + second);
    expect(player.videoAutoplayCountdown.value, isNull);
    expect(player.state.currentQueueId, 'a');
    expect(player.state.playQueue, ['b', 'c']);
  });

  testWidgets(
      'the countdown controls give way to the full player on a surface tap',
      (tester) async {
    const normalPlay = ValueKey('watch-mini-play');
    const playNow = ValueKey('flow-mini-autoplay-play-now');
    const cancel = ValueKey('flow-mini-autoplay-cancel');
    const viewport = Size(400, 800);
    final geometry = FlowMiniGeometry(
      viewport: viewport,
      usable: Offset.zero & viewport,
      aspectRatio: 16 / 9,
      largeWindow: false,
    );
    final motion = FlowFloatingMiniMotion();
    final bounds = motion.bounds(geometry, viewport);
    await tester.pumpWidget(BlocProvider<PlayerCubit>.value(
      value: player,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: BlocBuilder<PlayerCubit, PlayerState>(
            buildWhen: (before, after) => before.isMini != after.isMini,
            builder: (context, state) => state.isMini
                ? Center(
                    child: SizedBox.fromSize(
                      size: bounds.size,
                      child: FlowFloatingMiniSurface(
                        geometry: geometry,
                        viewport: viewport,
                        bounds: bounds,
                        motion: motion,
                        onChanged: () {},
                        onExpand: player.showBigPlayer,
                        onDismiss: player.hide,
                        child: const FlowFloatingMiniOverlay(
                            largeWindow: false, scale: 1),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ));
    expect(find.byKey(normalPlay), findsOneWidget);
    expect(find.byKey(cancel), findsNothing);

    player.setEvent(finished);
    await tester.pump();
    expect(find.byKey(normalPlay), findsNothing);
    expect(find.byKey(playNow), findsOneWidget);
    expect(find.text('Next in ${countdownLength.inSeconds}s'), findsOneWidget);
    expect(find.text('Second video'), findsOneWidget);

    await tester.tap(find.byKey(cancel));
    await tester.pump(kDoubleTapTimeout);
    expect(player.state.isMini, isTrue);
    expect(find.byKey(normalPlay), findsOneWidget);
    expect(find.byKey(cancel), findsNothing);

    player.play();
    player.setEvent(started);
    player.setEvent(finished);
    await tester.pump();
    await tester.pump(second);
    final token = player.videoAutoplayCountdown.value!.token;
    final corner = tester.getTopLeft(find.byType(FlowFloatingMiniSurface));
    await tester.tapAt(corner + const Offset(12, 10));
    await tester.pump(kDoubleTapTimeout);
    await tester.pump();

    expect(player.state.isMini, isFalse);
    expect(find.byKey(playNow), findsNothing);
    expect(player.videoAutoplayCountdown.value?.token, same(token));
    expect(player.videoAutoplayCountdown.value?.secondsRemaining,
        countdownLength.inSeconds - 1);

    player.showMiniPlayer();
    await tester.pump();
    await tester.pump();
    expect(player.state.isMini, isTrue);
    expect(player.videoAutoplayCountdown.value?.token, same(token));
    expect(find.byKey(playNow), findsOneWidget);
    await tester.tap(find.byKey(playNow));
    await tester.pump(kDoubleTapTimeout);
    await tester.pump(second);
    expect(player.state.isMini, isTrue);
    expect(player.videoAutoplayCountdown.value, isNull);
    expect(player.state.playedVideos, ['a']);
    expect(find.byKey(normalPlay), findsOneWidget);
  });
}
