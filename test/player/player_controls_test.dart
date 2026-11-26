import 'dart:async';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/video_display_mode.dart';
import 'package:clipious/player/models/watch_audio_track.dart';
import 'package:clipious/player/services/watch_local_subtitles.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/player_controls.dart';
import 'package:clipious/player/states/tv_player_controls.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/player/views/components/minimize_on_swipe_down.dart';
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/player/views/components/seek_preview.dart';
import 'package:clipious/player/views/components/video_display_mode_picker.dart';
import 'package:clipious/player/views/tv/components/player_settings.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_chapter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _ControlsTestPlayer extends TestPlayerCubit {
  _ControlsTestPlayer(super.initialState, super.settings);

  void replaceOccurrence() => emit(state.copyWith(
      currentlyPlaying: const Video(videoId: 'next-track', lengthSeconds: 60)));

  void replaceWithChapteredVideo() => emit(state.copyWith(
        currentlyPlaying: const Video(
          videoId: 'description-chapters',
          lengthSeconds: 60,
          description: '0:00 Intro\n0:30 Setup',
        ),
      ));
}

class _SpeedBoostVideo extends VideoPlayerCubit {
  _SpeedBoostVideo(super.initialState, super.player, super.settings);

  final speedChanges = <double>[];
  bool onionPlayback = false;
  List<String> qualityTracks = [];
  List<String> audioTracks = [];
  List<String> subtitleTracks = [];
  final selectedAudioTracks = <int>[];
  final selectedSubtitleTracks = <int>[];
  Completer<bool>? qualityPreparation;
  bool qualityPreparationResult = true;
  int qualityPreparationCalls = 0;
  @override
  bool canManageLocalSubtitles = false;
  @override
  String? localSubtitleName;
  Completer<WatchLocalSubtitleResult>? subtitlePicker;
  int subtitlePickerCalls = 0;

  @override
  bool get isOnionPlayback => onionPlayback;

  @override
  List<String> getVideoTracks() => qualityTracks;

  @override
  List<String> getAudioTracks() => audioTracks;

  @override
  List<String> getSubtitles() => subtitleTracks;

  @override
  void selectAudioTrack(int index) => selectedAudioTracks.add(index);

  @override
  void selectSubtitle(int index) => selectedSubtitleTracks.add(index);

  @override
  Future<WatchLocalSubtitleResult> pickLocalSubtitle() async {
    subtitlePickerCalls++;
    final result =
        await subtitlePicker?.future ?? WatchLocalSubtitleResult.done;
    if (result == WatchLocalSubtitleResult.done) {
      localSubtitleName = 'festival.srt';
    }
    return result;
  }

  @override
  Future<WatchLocalSubtitleResult> removeLocalSubtitle() async {
    localSubtitleName = null;
    return WatchLocalSubtitleResult.done;
  }

  @override
  Future<bool> prepareVideoTracks() async {
    qualityPreparationCalls++;
    final pending = qualityPreparation;
    return pending == null ? qualityPreparationResult : await pending.future;
  }

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

class _WatchTrackAudio extends AudioPlayerCubit {
  _WatchTrackAudio(super.initialState, super.player, super.settings);

  final selections = <String>[];
  bool switchSucceeds = true;

  @override
  List<WatchAudioTrack> watchAudioTracks = const [
    (id: 'en.original', label: 'English (original)'),
    (id: 'es.dub', label: 'Spanish'),
  ];

  @override
  String? selectedWatchAudioTrackId = 'en.original';

  @override
  void onInit() {}

  @override
  Future<bool> selectWatchAudioTrack(String trackId) async {
    selections.add(trackId);
    if (switchSucceeds) selectedWatchAudioTrackId = trackId;
    return switchSucceeds;
  }
}

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _ControlsTestPlayer player;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _ControlsTestPlayer(
        PlayerState.init(null).copyWith(isMini: false), settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await db.close();
  });

  Widget hostControls(Widget child, {Locale? locale}) {
    app_main.darkColorScheme = ColorScheme.fromSeed(
        seedColor: Colors.blue, brightness: Brightness.dark);
    return MultiBlocProvider(
      providers: [
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Future<_SpeedBoostVideo> createPlayingVideo(WidgetTester tester,
      {double aspectRatio = 16 / 9,
      int lengthSeconds = 60,
      Video? source,
      bool playing = true}) async {
    final video =
        source ?? Video(videoId: 'boost-test', lengthSeconds: lengthSeconds);
    await tester.runAsync(player.close);
    player = _ControlsTestPlayer(
      PlayerState.init(null).copyWith(
        isMini: false,
        isHidden: false,
        isPlaying: playing,
        currentlyPlaying: video,
        forwardStep: settings.state.skipStep,
        rewindStep: settings.state.skipStep,
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

  Future<_WatchTrackAudio> createPlayingAudio(WidgetTester tester,
      {MusicMetadata? music}) async {
    final video =
        Video(videoId: 'watch-audio', lengthSeconds: 60, musicMetadata: music);
    await tester.runAsync(player.close);
    player = _ControlsTestPlayer(
      PlayerState.init(null).copyWith(
        isMini: false,
        isHidden: false,
        isPlaying: true,
        isAudio: true,
        currentlyPlaying: video,
      ),
      settings,
    );
    final audio =
        _WatchTrackAudio(AudioPlayerState(video: video), player, settings);
    addTearDown(audio.close);
    return audio;
  }

  testWidgets('Flow watch time pill toggles and the idle timeline seeks',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: video),
    )));
    player.setEvent(const MediaEvent<Duration>(
      state: MediaState.ready,
      type: MediaEventType.durationChanged,
      value: Duration(seconds: 60),
    ));
    await tester.pump();
    final pill = find.byKey(const ValueKey('flow-watch-time-pill'));
    expect(pill, findsOneWidget);
    await tester.tap(pill);
    await tester.pump();
    expect(find.descendant(of: pill, matching: find.textContaining('-')),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(pill, findsNothing);

    final timeline = find.byKey(const ValueKey('flow-watch-seekbar'));
    final bounds = tester.getRect(timeline);
    await tester.tapAt(bounds.center + const Offset(0, 10));
    await tester.pumpAndSettle();
    expect(player.state.position.inSeconds, closeTo(30, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('portrait watch keeps fullscreen and mute at the video edge',
      (tester) async {
    tester.view.physicalSize = const Size(540, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 512,
      height: 288,
      child: PlayerControls(mediaPlayerCubit: video),
    )));
    player.setEvent(const MediaEvent<Duration>(
      state: MediaState.ready,
      type: MediaEventType.durationChanged,
      value: Duration(minutes: 33, seconds: 8),
    ));
    await tester.pump();
    final frame = tester.getRect(find.byType(PlayerControls));
    final pill = find.byKey(const ValueKey('flow-watch-time-pill'));
    final fullscreen =
        find.widgetWithIcon(IconButton, Icons.fullscreen_rounded);
    final mute = find.widgetWithIcon(IconButton, Icons.volume_up_rounded);
    for (final remaining in [false, true]) {
      if (remaining) {
        await tester.tap(pill);
        await tester.pump();
      }
      expect(tester.getRect(pill).left - frame.left, 8);
      expect(frame.right - tester.getRect(fullscreen).right, 8);
      expect(tester.getRect(mute).right, tester.getRect(fullscreen).left);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

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

  testWidgets(
      'hidden video controls leave expanded pulls to the minimize scope',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    final updates = <double>[];
    final endings = <bool>[];
    var fallbackMinimizes = 0;
    await tester.pumpWidget(hostControls(MinimizeDragScope(
      identity: videoPlayer,
      onUpdate: updates.add,
      onEnd: (commit) {
        endings.add(commit);
        if (commit) player.showMiniPlayer();
      },
      child: MinimizeOnSwipeDown(
        enabled: true,
        onSwipeDown: () {
          fallbackMinimizes++;
          player.showMiniPlayer();
        },
        child: SizedBox(
          width: 390,
          height: 220,
          child: PlayerControls(mediaPlayerCubit: videoPlayer),
        ),
      ),
    )));
    player.setEvent(const MediaEvent<Duration>(
      state: MediaState.ready,
      type: MediaEventType.durationChanged,
      value: Duration(seconds: 60),
    ));
    await tester.pump(const Duration(seconds: 4));
    final controls = tester
        .element(find.byType(LayoutBuilder).last)
        .read<PlayerControlsCubit>();
    expect(controls.state.displayControls, isFalse);
    expect(controls.state.duration, const Duration(seconds: 60));
    final initialPosition = player.state.position;

    for (final finish in ['short', 'cancel', 'commit']) {
      updates.clear();
      endings.clear();
      final gesture = await tester
          .startGesture(tester.getCenter(find.byType(PlayerControls)));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(updates, isNotEmpty);
      expect(updates.last, 40);
      expect(player.state.isMini, isFalse);
      expect(player.state.isDragging, isFalse);
      expect(endings, isEmpty);
      expect(find.byType(SeekPreview), findsNothing);
      expect(player.state.position, initialPosition);

      await gesture.moveBy(Offset(0, finish == 'short' ? 75 : 220));
      await tester.pump();
      expect(updates.last, finish == 'short' ? 115 : 260);
      expect(player.state.isMini, isFalse);
      expect(player.state.isDragging, isFalse);
      expect(endings, isEmpty);
      expect(videoPlayer.isClosed, isFalse);
      expect(find.byType(SeekPreview), findsNothing);
      expect(player.state.position, initialPosition);

      if (finish == 'cancel') {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      await tester.pump();
      expect(endings, [finish == 'commit']);
      expect(player.state.isMini, finish == 'commit');
      expect(player.state.isDragging, isFalse);
      expect(fallbackMinimizes, 0);
      expect(videoPlayer.isClosed, isFalse);
      expect(find.byType(SeekPreview), findsNothing);
      expect(player.state.position, initialPosition);
      expect(tester.takeException(), isNull);
    }
    // Committing mounts the compact controls' deferred animation starters.
    // Let those controls settle before disposing their owning subtree.
    await tester.pumpAndSettle();
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
    final transportButton = find.byIcon(Icons.pause);
    final seekbar = find.byKey(const ValueKey('flow-watch-seekbar'));

    expect(transportButton, findsOneWidget);
    expect(seekbar, findsOneWidget);
    final left = await tester.startGesture(pointAt(.15));
    await tester.pump(const Duration(milliseconds: 199));
    expect(videoPlayer.speedChanges, isEmpty);
    expect(indicator, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(videoPlayer.speedChanges, [2]);
    expect(indicator, findsOneWidget);

    // The controls can auto-hide while the same finger is still held down.
    await tester.pump(const Duration(seconds: 4));
    expect(transportButton, findsNothing);
    expect(seekbar, findsOneWidget);
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
    await tester.pump(Duration.zero); // Flush animation startup callbacks.
  });

  testWidgets('Flow double tap toggles at the center and seeks on either side',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    player.seek(const Duration(seconds: 30));
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pump();
    final bounds = tester.getRect(find.byType(PlayerControls));
    Offset point(double x) => bounds.topLeft + Offset(x, bounds.height * .30);
    Future<void> doubleTap(double x) async {
      await tester.tapAt(point(x));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(point(x));
      await tester.pump();
    }

    // At 42% of the stage an even split would rewind, while Flow's middle
    // third pauses. This point is outside the center button's hit target.
    await doubleTap(bounds.width * .42);
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    expect(player.state.position, const Duration(seconds: 30));

    final forward = player.state.forwardStep;
    await doubleTap(bounds.width * .85);
    expect(player.state.position, Duration(seconds: 30 + forward));
    final nextForward = player.state.forwardStep;
    await tester.tapAt(point(bounds.width * .85));
    await tester.pump();
    expect(
        player.state.position, Duration(seconds: 30 + forward + nextForward));

    final beforeBack = player.state.position;
    final back = player.state.rewindStep;
    await doubleTap(bounds.width * .15);
    expect(player.state.position, beforeBack - Duration(seconds: back));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (label, height, insets) in [
    ('wide', 220.0, const FakeViewPadding()),
    ('tall', 680.0, const FakeViewPadding(left: 20, right: 24)),
  ]) {
    testWidgets('Flow $label stage seeks on edge taps and ignores edge swipes',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.systemGestureInsets = insets;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetSystemGestureInsets);
      await tester.runAsync(() => settings.setSkipStep(15));
      final videoPlayer = await createPlayingVideo(tester,
          aspectRatio: 390 / height, lengthSeconds: 180);
      const startingPosition = Duration(seconds: 60);
      player.seek(startingPosition);
      await tester.pumpWidget(hostControls(SizedBox(
        width: 390,
        height: height,
        child: PlayerControls(mediaPlayerCubit: videoPlayer),
      )));
      await tester.pump();
      final bounds = tester.getRect(find.byType(PlayerControls));
      final left = bounds.topLeft + Offset(5, bounds.height * .3);
      final right = bounds.topRight + Offset(-5, bounds.height * .3);

      Future<void> doubleTap(Offset point) async {
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(point);
        await tester.pump();
      }

      await doubleTap(left);
      expect(player.state.position, const Duration(seconds: 45));
      await doubleTap(right);
      expect(player.state.position, startingPosition);

      await tester.pump(const Duration(seconds: 1));
      for (final (point, inward) in [(left, 1.0), (right, -1.0)]) {
        final swipe = await tester.startGesture(point);
        await swipe.moveBy(Offset(30 * inward, 0));
        await swipe.moveBy(Offset(130 * inward, 0));
        await tester.pump();
        expect(find.byType(SeekPreview), findsNothing);
        await swipe.up();
        await tester.pump();
        expect(player.state.position, startingPosition);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'Flow horizontal drag previews 90s across the stage and commits on release',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester, lengthSeconds: 180);
    player.seek(const Duration(seconds: 60));
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pump(const Duration(seconds: 4));
    final bounds = tester.getRect(find.byType(PlayerControls));
    final start =
        bounds.topLeft + Offset(bounds.width * .30, bounds.height * .35);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(30, 0)); // Claim the horizontal axis.
    await gesture.moveBy(Offset(bounds.width / 3, 0));
    await tester.pump();
    expect(find.byType(SeekPreview), findsOneWidget);
    expect(player.state.position, const Duration(seconds: 60));
    await gesture.up();
    await tester.pump();
    expect(find.byType(SeekPreview), findsNothing);
    expect(player.state.mediaCommand?.type, MediaCommandType.seek);
    expect(player.state.position, const Duration(seconds: 90));

    final canceled = await tester.startGesture(start);
    await canceled.moveBy(const Offset(-30, 0));
    await canceled.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(find.byType(SeekPreview), findsOneWidget);
    await canceled.cancel();
    await tester.pump();
    expect(find.byType(SeekPreview), findsNothing);
    expect(player.state.position, const Duration(seconds: 90));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a quick Flow center-button tap pauses without a tap delay',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));

    await tester.pump(Duration.zero); // Start the transport animations.
    await tester.tap(find.byIcon(Icons.pause));
    expect(player.state.mediaCommand?.type, MediaCommandType.pause,
        reason: 'A button tap must complete as soon as the finger lifts');
    expect(videoPlayer.speedChanges, isEmpty);
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

  testWidgets('fullscreen chapter controls and gestures seek while paused',
      (tester) async {
    final videoPlayer = await createPlayingVideo(
      tester,
      source: const Video(videoId: 'chapters', lengthSeconds: 90, chapters: [
        VideoChapter(title: 'Intro', start: Duration(seconds: 10)),
        VideoChapter(title: 'Setup', start: Duration(seconds: 30)),
        VideoChapter(title: 'Results', start: Duration(seconds: 60)),
      ]),
      playing: false,
    );
    player.setFullScreen(FullScreenState.fullScreen);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 540,
      height: 320,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pumpAndSettle();

    final bounds = tester.getRect(find.byType(PlayerControls));
    Future<void> doubleTapWithTwoFingers(double x) async {
      for (var tap = 0; tap < 2; tap++) {
        final first = await tester
            .startGesture(bounds.topLeft + Offset(x, bounds.height / 3));
        final second = await tester.startGesture(
            bounds.topLeft + Offset(x + 30, bounds.height / 3 + 16));
        await first.up();
        await second.up();
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(kDoubleTapTimeout);
    }

    Finder chapterButton(String label) => find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == label);
    final previous = chapterButton('Previous chapter');
    final next = chapterButton('Next chapter');
    expect(tester.widget<IconButton>(previous).onPressed, isNull);
    await doubleTapWithTwoFingers(70);
    expect(player.state.position, Duration.zero);
    expect(player.state.mediaCommand?.type, MediaCommandType.enterFullScreen);
    await tester.tap(next);
    await tester.pump();
    expect(player.state.position, const Duration(seconds: 10));
    expect(player.state.mediaCommand?.type, MediaCommandType.seek);

    await doubleTapWithTwoFingers(410);
    expect(player.state.position, const Duration(seconds: 30));
    await doubleTapWithTwoFingers(70);
    expect(player.state.position, const Duration(seconds: 10));

    player.seek(const Duration(seconds: 34));
    await tester.pump();
    await tester.tap(previous);
    await tester.pump();
    expect(player.state.position, const Duration(seconds: 30));

    await tester.tap(next);
    await tester.pump();
    final lastSeek = player.state.mediaCommand;
    expect(player.state.position, const Duration(seconds: 60));
    expect(tester.widget<IconButton>(next).onPressed, isNull);
    await doubleTapWithTwoFingers(410);
    expect(player.state.mediaCommand, same(lastSeek));
    expect(player.state.isPlaying, isFalse);
    expect(videoPlayer.speedChanges, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('chapter actions require fullscreen and loaded chapters',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    player.setFullScreen(FullScreenState.fullScreen);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 540,
      height: 320,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    final chapterAction = find.byTooltip('Next chapter');
    expect(chapterAction, findsNothing);
    expect(player.skipFullscreenChapter(forward: true), isFalse);

    player.setFullScreen(FullScreenState.notFullScreen);
    player.replaceWithChapteredVideo();
    await tester.pump();
    expect(chapterAction, findsNothing);
    expect(player.skipFullscreenChapter(forward: true), isFalse);

    player.setFullScreen(FullScreenState.fullScreen);
    await tester.pumpAndSettle();
    expect(player.fullscreenChapterTargets.next?.start,
        const Duration(seconds: 30));
    expect(chapterAction, findsOneWidget);
    await tester.tap(chapterAction);
    expect(player.state.position, const Duration(seconds: 30));
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

  testWidgets('fullscreen touch lock shields playback and has a focused Unlock',
      (tester) async {
    final video = await createPlayingVideo(tester, lengthSeconds: 180);
    const position = Duration(seconds: 60);
    player.seek(position);
    player.setFullScreen(FullScreenState.fullScreen);
    var underlyingTaps = 0;
    await tester.pumpWidget(hostControls(Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => underlyingTaps++,
        ),
        PlayerControls(mediaPlayerCubit: video),
      ],
    )));
    await tester.pump();

    final lock = find.byTooltip('Lock touch controls');
    final unlock = find.bySemanticsLabel('Unlock touch controls');
    final bounds = tester.getRect(find.byType(PlayerControls));
    final edge = Offset(bounds.width * .85, bounds.height * .35);
    final seekStart = Offset(bounds.width * .3, bounds.height * .35);
    final timeline = tester.getCenter(find.byType(Slider));
    final baseline = player.state.mediaCommand;
    await tester.tap(lock);
    await tester.pumpAndSettle();

    expect(lock, findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(
      tester.getSemantics(unlock),
      containsSemantics(isButton: true, isFocused: true, isLiveRegion: true),
    );

    await tester.tapAt(bounds.center);
    await tester.tapAt(edge);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(edge);
    await tester.tapAt(timeline);
    final swipe = await tester.startGesture(seekStart);
    await swipe.moveBy(const Offset(30, 0));
    await swipe.moveBy(const Offset(140, 0));
    await tester.pump();
    expect(find.byType(SeekPreview), findsNothing);
    await swipe.up();
    await tester.longPressAt(edge);
    await tester.pump(const Duration(seconds: 4));

    expect(player.state.position, position);
    expect(player.state.isPlaying, isTrue);
    expect(player.state.mediaCommand, baseline);
    expect(video.speedChanges, isEmpty);
    expect(underlyingTaps, 0);
    expect(unlock, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(unlock, findsNothing);
    expect(lock, findsOneWidget);

    final forward = Duration(seconds: player.state.forwardStep);
    await tester.tapAt(edge);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(edge);
    await tester.pump();
    expect(player.state.position, position + forward);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch lock clears when leaving fullscreen and re-entering',
      (tester) async {
    final video = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(
      PlayerControls(mediaPlayerCubit: video),
    ));
    final lock = find.byTooltip('Lock touch controls');
    final unlock = find.text('Unlock touch controls');
    expect(lock, findsNothing);

    player.setFullScreen(FullScreenState.fullScreen);
    await tester.pumpAndSettle();
    await tester.tap(lock);
    await tester.pumpAndSettle();
    expect(unlock, findsOneWidget);

    player.setFullScreen(FullScreenState.notFullScreen);
    await tester.pumpAndSettle();
    expect(unlock, findsNothing);
    expect(lock, findsNothing);

    player.setFullScreen(FullScreenState.fullScreen);
    await tester.pumpAndSettle();
    await tester.tap(lock);
    await tester.pumpAndSettle();
    expect(unlock, findsOneWidget);

    // An exit and re-entry can arrive before the controls build again.
    player.setFullScreen(FullScreenState.notFullScreen);
    player.setFullScreen(FullScreenState.fullScreen);
    await tester.pumpAndSettle();
    expect(unlock, findsNothing);
    expect(lock, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('video options apply a new display mode during playback',
      (tester) async {
    final videoPlayer = await createPlayingVideo(tester);
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-video-display-open')));
    await tester.pumpAndSettle();

    expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'Fit')).selected,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('video-display-mode-stretch')));
    await tester.pumpAndSettle();

    expect(settings.state.videoDisplayMode, VideoDisplayMode.stretch);
    expect(player.state.isPlaying, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<AppLocalizations> openPhoneQuality(
      WidgetTester tester, _SpeedBoostVideo videoPlayer) async {
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pumpAndSettle();
    final locals =
        AppLocalizations.of(tester.element(find.byType(PlayerControls)))!;
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(locals.quality));
    await tester.tap(find.text(locals.quality));
    await tester.pump();
    return locals;
  }

  Future<void> pressAndroidBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();
    // Minimizing mounts controls whose Animate initialization starts on a
    // zero-delay future after the last frame. Let that start before settling
    // again and disposing the tree; keep the real Back/state assertions below.
    await tester.pump();
    await tester.pumpAndSettle();
  }

  for (final subtitles in [false, true]) {
    final kind = subtitles ? 'subtitle' : 'audio';
    for (final transition in ['replacement', 'track order', 'none']) {
      testWidgets('phone $kind picker handles $transition while open',
          (tester) async {
        final videoPlayer = (await createPlayingVideo(tester))
          ..audioTracks = ['English audio', 'Spanish audio']
          ..subtitleTracks = ['English captions', 'Spanish captions'];
        await tester.pumpWidget(hostControls(SizedBox(
          width: 390,
          height: 220,
          child: PlayerControls(mediaPlayerCubit: videoPlayer),
        )));
        await tester.pumpAndSettle();
        final locals =
            AppLocalizations.of(tester.element(find.byType(PlayerControls)))!;
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        final option = find.text(subtitles ? locals.subtitles : locals.audio);
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
        final selectedLabel = subtitles ? 'Spanish captions' : 'Spanish audio';
        expect(find.text(selectedLabel), findsOneWidget);

        if (transition == 'replacement') {
          player.replaceOccurrence();
        } else if (transition == 'track order') {
          videoPlayer.audioTracks = ['Spanish audio', 'English audio'];
          videoPlayer.subtitleTracks = ['Spanish captions', 'English captions'];
        }
        await tester.pump();
        await tester.tap(find.text(selectedLabel));
        await tester.pumpAndSettle();

        expect(
            subtitles
                ? videoPlayer.selectedSubtitleTracks
                : videoPlayer.selectedAudioTracks,
            transition == 'none' ? [1] : isEmpty);
        expect(find.byType(BottomSheet), findsNothing);
        expect(player.state.isPlaying, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('phone $kind options retire when the occurrence changes',
        (tester) async {
      final videoPlayer = (await createPlayingVideo(tester))
        ..audioTracks = ['English audio', 'Spanish audio']
        ..subtitleTracks = ['English captions', 'Spanish captions'];
      await tester.pumpWidget(hostControls(SizedBox(
        width: 390,
        height: 220,
        child: PlayerControls(mediaPlayerCubit: videoPlayer),
      )));
      await tester.pumpAndSettle();
      final locals =
          AppLocalizations.of(tester.element(find.byType(PlayerControls)))!;
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      player.replaceOccurrence();
      await tester.pump();
      final option = find.text(subtitles ? locals.subtitles : locals.audio);
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(videoPlayer.selectedAudioTracks, isEmpty);
      expect(videoPlayer.selectedSubtitleTracks, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  final watchAudioTrackMenu =
      find.byKey(const ValueKey('player-audio-track-open'));

  testWidgets('phone caption menu attaches and removes a file without tracks',
      (tester) async {
    final videoPlayer = (await createPlayingVideo(tester))
      ..canManageLocalSubtitles = true
      ..subtitlePicker = Completer<WatchLocalSubtitleResult>();
    await tester.pumpWidget(hostControls(SizedBox(
      width: 390,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: videoPlayer),
    )));
    await tester.pumpAndSettle();
    final locals =
        AppLocalizations.of(tester.element(find.byType(PlayerControls)))!;
    final captions = find.byKey(const ValueKey('player-subtitles-open'));
    final pick = find.byKey(const ValueKey('player-local-subtitle-pick'));
    final remove = find.byKey(const ValueKey('player-local-subtitle-remove'));

    Future<void> openCaptions() async {
      final options = find.byIcon(Icons.more_vert);
      if (options.evaluate().isEmpty) {
        tester
            .element(find.byType(LayoutBuilder).last)
            .read<PlayerControlsCubit>()
            .showControls();
        await tester.pumpAndSettle();
      }
      await tester.tap(options);
      await tester.pumpAndSettle();
      await tester.ensureVisible(captions);
      await tester.tap(captions);
      await tester.pumpAndSettle();
    }

    await openCaptions();
    expect(find.text(locals.localSubtitleAttach), findsOneWidget);
    await tester.tap(pick);
    await tester.pump();
    expect(tester.widget<ListTile>(pick).enabled, isFalse);
    videoPlayer.subtitlePicker!.complete(WatchLocalSubtitleResult.invalidFile);
    await tester.pumpAndSettle();
    expect(find.text(locals.localSubtitleInvalidFile), findsOneWidget);

    videoPlayer.subtitlePicker = null;
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    await openCaptions();
    expect(find.text(locals.localSubtitleRelink), findsOneWidget);
    expect(find.text('festival.srt'), findsOneWidget);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await openCaptions();
    expect(find.text(locals.localSubtitleAttach), findsOneWidget);
    expect(remove, findsNothing);
    player.replaceOccurrence();
    await tester.pump();
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(videoPlayer.subtitlePickerCalls, 2);
    expect(player.state.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV remote activates local subtitle actions in the caption tab',
      (tester) async {
    final videoPlayer = (await createPlayingVideo(tester))
      ..canManageLocalSubtitles = true;
    await tester.pumpWidget(hostControls(BlocProvider<VideoPlayerCubit>.value(
      value: videoPlayer,
      child: const TvPlayerSettings(),
    )));
    await tester.pumpAndSettle();
    final locals =
        AppLocalizations.of(tester.element(find.byType(TvPlayerSettings)))!;
    Focus.of(tester.element(find.text(locals.subtitles))).requestFocus();
    await tester.pumpAndSettle();

    Future<void> activate(String label) async {
      Focus.of(tester.element(find.text(label))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
    }

    await activate(locals.localSubtitleAttach);
    expect(find.text(locals.localSubtitleRelink), findsOneWidget);
    expect(find.text('festival.srt'), findsOneWidget);
    await activate(locals.localSubtitleRemove);
    expect(find.text(locals.localSubtitleAttach), findsOneWidget);
    expect(find.text('festival.srt'), findsNothing);
    expect(player.state.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> openAudioOptions(
      WidgetTester tester, _WatchTrackAudio audio) async {
    await tester.pumpWidget(hostControls(SizedBox(
      width: 320,
      height: 220,
      child: PlayerControls(mediaPlayerCubit: audio),
    )));
    await tester.pumpAndSettle();
    if (audio.state.video?.musicMetadata == null) {
      final tooltip =
          MaterialLocalizations.of(tester.element(find.byType(PlayerControls)))
              .showMenuTooltip;
      expect(find.byTooltip(tooltip), findsOneWidget);
    }
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  Future<void> openWatchTrackPicker(WidgetTester tester) async {
    await tester.ensureVisible(watchAudioTrackMenu);
    await tester.tap(watchAudioTrackMenu);
    await tester.pumpAndSettle();
  }

  testWidgets('ordinary audio options announce and switch the exact track',
      (tester) async {
    final audio = await createPlayingAudio(tester);
    await openAudioOptions(tester, audio);
    await openWatchTrackPicker(tester);

    final english = find.text('English (original)');
    final spanish = find.text('Spanish');
    expect(tester.getSemantics(english).flagsCollection.isSelected, true);
    expect(
        tester.getSemantics(spanish).flagsCollection.isSelected, isNot(true));
    await tester.tap(spanish);
    await tester.pumpAndSettle();

    expect(audio.selections, ['es.dub']);
    expect(audio.selectedWatchAudioTrackId, 'es.dub');
    expect(player.state.isPlaying, isTrue);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final music in [false, true]) {
    testWidgets(
        music
            ? 'Music controls omit the ordinary audio track chooser'
            : 'ordinary audio with a single track omits the chooser',
        (tester) async {
      final audio = await createPlayingAudio(tester,
          music: music
              ? const MusicMetadata(title: 'Music', artist: 'Artist')
              : null);
      if (!music) audio.watchAudioTracks = [audio.watchAudioTracks.first];
      await openAudioOptions(tester, audio);
      expect(watchAudioTrackMenu, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final replaceOccurrence in [false, true]) {
    testWidgets(
        replaceOccurrence
            ? 'ordinary audio chooser ignores a replaced queue occurrence'
            : 'ordinary audio chooser ignores a replaced ID with the same label',
        (tester) async {
      final audio = await createPlayingAudio(tester);
      await openAudioOptions(tester, audio);
      await openWatchTrackPicker(tester);
      if (replaceOccurrence) {
        player.replaceOccurrence();
      } else {
        audio.watchAudioTracks = [
          audio.watchAudioTracks.first,
          (id: 'es.another', label: 'Spanish'),
        ];
      }

      await tester.tap(find.text('Spanish'));
      await tester.pumpAndSettle();
      expect(audio.selections, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'ordinary audio announces a rejected switch with no selected track',
      (tester) async {
    final audio = (await createPlayingAudio(tester))
      ..selectedWatchAudioTrackId = null
      ..switchSucceeds = false;
    await openAudioOptions(tester, audio);
    await openWatchTrackPicker(tester);
    final spanish = find.text('Spanish');
    expect(
        tester.getSemantics(spanish).flagsCollection.isSelected, isNot(true));

    await tester.tap(spanish);
    await tester.pumpAndSettle();
    expect(audio.selections, ['es.dub']);
    expect(audio.selectedWatchAudioTrackId, isNull);
    expect(find.text('Could not switch audio tracks.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'ordinary audio distinguishes tracks with the same provider label',
      (tester) async {
    final audio = (await createPlayingAudio(tester))
      ..watchAudioTracks = const [
        (id: 'en.original', label: 'English'),
        (id: 'en.alternate', label: 'English'),
      ];
    await openAudioOptions(tester, audio);
    await openWatchTrackPicker(tester);
    expect(find.text('English (en.original)'), findsOneWidget);
    await tester.tap(find.text('English (en.alternate)'));
    await tester.pumpAndSettle();
    expect(audio.selections, ['en.alternate']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final quality in [false, true]) {
    for (final fullscreen in [false, true]) {
      testWidgets(
          'Android Back dismisses ${quality ? 'quality' : 'options'} before ${fullscreen ? 'leaving fullscreen' : 'minimizing playback'}',
          (tester) async {
        final videoPlayer = (await createPlayingVideo(tester))
          ..qualityTracks = ['720p', '1080p'];
        if (fullscreen) player.setFullScreen(FullScreenState.fullScreen);
        BackButtonInterceptor.add(player.handleBackButton,
            name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
        final interceptorsBefore = BackButtonInterceptor.describe();
        await tester.pumpWidget(hostControls(SizedBox(
          width: 390,
          height: 220,
          child: PlayerControls(mediaPlayerCubit: videoPlayer),
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        if (quality) {
          final locals =
              AppLocalizations.of(tester.element(find.byType(PlayerControls)))!;
          await tester.ensureVisible(find.text(locals.quality));
          await tester.tap(find.text(locals.quality));
          await tester.pumpAndSettle();
          expect(find.text('1080p'), findsOneWidget);
        }
        expect(find.byType(BottomSheet), findsOneWidget);
        final initialFullscreen = player.state.fullScreenState;

        await pressAndroidBack(tester);
        expect(find.byType(BottomSheet), findsNothing);
        expect(player.state.isMini, isFalse);
        expect(player.state.isPlaying, isTrue);
        expect(player.state.fullScreenState, initialFullscreen);
        expect(BackButtonInterceptor.describe(), interceptorsBefore);

        await pressAndroidBack(tester);
        expect(player.state.isMini, !fullscreen);
        expect(player.state.fullScreenState, FullScreenState.notFullScreen);
        expect(player.state.isPlaying, isTrue);
        if (fullscreen) {
          await pressAndroidBack(tester);
          expect(player.state.isMini, isTrue);
          expect(player.state.isPlaying, isTrue);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('phone quality waits for preparation and reads the fresh tracks',
      (tester) async {
    final videoPlayer = (await createPlayingVideo(tester))
      ..qualityTracks = ['720p']
      ..qualityPreparation = Completer<bool>();
    final locals = await openPhoneQuality(tester, videoPlayer);
    expect(videoPlayer.qualityPreparationCalls, 1);
    expect(find.text(locals.quality), findsOneWidget);
    expect(find.text('1080p'), findsNothing);
    expect(find.text('720p'), findsNothing);
    expect(player.state.isPlaying, isTrue);

    videoPlayer.qualityTracks = ['720p', '1080p'];
    videoPlayer.qualityPreparation!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(videoPlayer.qualityPreparationCalls, 1);
    expect(player.state.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'dismissed phone options cannot reopen after preparation completes',
      (tester) async {
    final videoPlayer = (await createPlayingVideo(tester))
      ..qualityTracks = ['720p']
      ..qualityPreparation = Completer<bool>();
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    await openPhoneQuality(tester, videoPlayer);
    expect(videoPlayer.qualityPreparationCalls, 1);
    await pressAndroidBack(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(player.state.isMini, isFalse);

    videoPlayer.qualityTracks = ['720p', '1080p'];
    videoPlayer.qualityPreparation!.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('1080p'), findsNothing);
    expect(player.state.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone quality failure keeps the local choice with feedback',
      (tester) async {
    final videoPlayer = (await createPlayingVideo(tester))
      ..qualityTracks = ['720p']
      ..qualityPreparationResult = false;
    final locals = await openPhoneQuality(tester, videoPlayer);
    await tester.pumpAndSettle();
    expect(videoPlayer.qualityPreparationCalls, 1);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text(locals.couldntLoadVideo), findsOneWidget);
    expect(player.state.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV quality retains local choices while preparing fresh tracks',
      (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final videoPlayer = (await createPlayingVideo(tester))
      ..qualityTracks = ['720p']
      ..qualityPreparation = Completer<bool>();
    await tester.pumpWidget(hostControls(BlocProvider<VideoPlayerCubit>.value(
      value: videoPlayer,
      child: const TvPlayerSettings(),
    )));
    await tester.pump();
    expect(videoPlayer.qualityPreparationCalls, 1);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsNothing);
    expect(player.state.isPlaying, isTrue);

    videoPlayer.qualityTracks = ['720p', '1080p'];
    videoPlayer.qualityPreparation!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(videoPlayer.qualityPreparationCalls, 1);
    expect(player.state.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV quality failure keeps local choices with inline feedback',
      (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final videoPlayer = (await createPlayingVideo(tester))
      ..qualityTracks = ['720p']
      ..qualityPreparationResult = false;
    await tester.pumpWidget(hostControls(BlocProvider<VideoPlayerCubit>.value(
      value: videoPlayer,
      child: const TvPlayerSettings(),
    )));
    await tester.pumpAndSettle();
    final locals =
        AppLocalizations.of(tester.element(find.byType(TvPlayerSettings)))!;
    expect(videoPlayer.qualityPreparationCalls, 1);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text(locals.couldntLoadVideo), findsOneWidget);
    expect(player.state.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final television in [false, true]) {
    for (final onion in [false, true]) {
      testWidgets(
          '${television ? 'TV' : 'phone'} quality guidance for onion=$onion playback',
          (tester) async {
        tester.view.physicalSize =
            television ? const Size(720, 360) : const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final videoPlayer = (await createPlayingVideo(tester))
          ..onionPlayback = onion
          ..qualityTracks = ['360p', '720p', '1080p'];
        final originalQuality = settings.state.lastVideoQuality;
        await tester.pumpWidget(hostControls(
          BlocProvider<VideoPlayerCubit>.value(
            value: videoPlayer,
            child: television
                ? const TvPlayerSettings()
                : PlayerControls(mediaPlayerCubit: videoPlayer),
          ),
          // The English template supplies new strings until translations arrive.
          locale: const Locale('de'),
        ));
        await tester.pumpAndSettle();
        if (!television) {
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();
          final locals =
              AppLocalizations.of(tester.element(find.byType(PlayerControls)))!;
          await tester.ensureVisible(find.text(locals.quality));
          await tester.tap(find.text(locals.quality));
          await tester.pumpAndSettle();
        }
        final hint = find.byKey(const ValueKey('onion-quality-help'));
        expect(hint, onion ? findsOneWidget : findsNothing);
        if (onion) {
          expect(tester.widget<Text>(hint).data, contains('Higher bitrates'));
          expect(
              tester.widget<Text>(hint).data, contains('maximum you select'));
        }
        expect(find.text('1080p'), findsOneWidget);
        expect(settings.state.lastVideoQuality, originalQuality);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('a stale display picker cannot change another profile',
      (tester) async {
    final originalOwner = db.forProfile(db.profileId);
    final other = await tester.runAsync(() => db.createProfile('Other'));
    final otherOwner = db.forProfile(other!.id);
    await tester.runAsync(() => otherOwner.saveSetting(SettingsValue(
        videoDisplayModeSettingName, VideoDisplayMode.crop.name)));
    await tester.pumpWidget(hostControls(Builder(
      builder: (context) => TextButton(
        onPressed: () => showVideoDisplayModePicker(context),
        child: const Text('Display options'),
      ),
    )));
    await tester.tap(find.text('Display options'));
    await tester.pumpAndSettle();

    // A dialog result can outlive the profile that opened it. Do not apply
    // that result to whichever profile owns the database when it completes.
    await tester.runAsync(() => db.useProfile(other.id));
    await tester.tap(find.byKey(const ValueKey('video-display-mode-stretch')));
    await tester.pumpAndSettle();

    expect(otherOwner.getSettings(videoDisplayModeSettingName)?.value,
        VideoDisplayMode.crop.name);
    expect(originalOwner.getSettings(videoDisplayModeSettingName), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV remote selects a ratio and returns to the settings button',
      (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final videoPlayer = await createPlayingVideo(tester);
    await tester.runAsync(
        () => settings.setVideoDisplayMode(VideoDisplayMode.ratio4x3));
    await tester.pumpWidget(hostControls(
      BlocProvider<VideoPlayerCubit>.value(
        value: videoPlayer,
        child: const Shortcuts(
          shortcuts: {
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          },
          child: TvPlayerSettings(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final opener = find.byKey(const ValueKey('player-video-display-open'));
    final openerLabel =
        find.descendant(of: opener, matching: find.text('Video display'));
    Focus.of(tester.element(openerLabel)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(Focus.of(tester.element(find.text('4:3'))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('3:2'))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(settings.state.videoDisplayMode, VideoDisplayMode.ratio3x2);
    expect(Focus.of(tester.element(openerLabel)).hasPrimaryFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
