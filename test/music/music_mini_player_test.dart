import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/components/music_mini_player.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Player extends TestPlayerCubit {
  _Player(super.initialState, super.settings);

  int nextCalls = 0;
  int expandCalls = 0;
  int closeCalls = 0;
  Duration? sought;

  Future<void> seed(PlayerState next) async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async => emit(next));
  }

  @override
  void playNext() => nextCalls++;

  @override
  void showBigPlayer() => expandCalls++;

  @override
  void hide() => closeCalls++;

  @override
  void seek(Duration position) {
    sought = position;
    super.seek(position);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;
  const song = Video(
      videoId: 'song',
      title: 'Video title',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Song', artist: 'Singer'));
  const next = Video(
      videoId: 'next',
      title: 'Next',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Next', artist: 'Singer'));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(
        PlayerState.init([song, next]).copyWith(
            currentlyPlaying: song,
            isAudio: true,
            isMini: true,
            isHidden: false,
            position: const Duration(seconds: 30),
            mediaEvent: const MediaEvent(state: MediaState.ready)),
        settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester,
      {double width = 390, double scale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: const Scaffold(
            body: Align(
                alignment: Alignment.bottomCenter, child: MusicMiniPlayer())),
      ),
    ));
    await tester.pump();
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  for (final (width, scale) in [
    (240.0, 2.5),
    (320.0, 1.0),
    (320.0, 2.5),
    (320.0, 3.0),
    (1024.0, 2.0)
  ]) {
    testWidgets('compact Music fits width $width and text scale $scale',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pump(tester, width: width, scale: scale);
        expect(tester.getSize(key('music-mini-player')),
            Size(width, targetHeight));
        if (width >= 320) {
          expect(tester.getSize(key('music-mini-artwork')), const Size(48, 48));
        }
        expect(find.text('Song'), findsOneWidget);
        expect(
            find.bySemanticsLabel('Now playing, Song, Singer'), findsOneWidget);
        expect(find.byTooltip('Close'), findsOneWidget);
        expect(tester.getRect(key('music-mini-expand')).right,
            lessThanOrEqualTo(tester.getRect(key('music-mini-play')).left));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('compact controls use the shared player without expanding',
      (tester) async {
    await pump(tester);
    expect(find.text('Singer'), findsOneWidget);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
    await player.seed(player.state.copyWith(isPlaying: true));
    await tester.pump();
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    await tester.tap(key('music-mini-next'));
    expect(player.nextCalls, 1);
    await tester.tap(key('music-mini-close'));
    expect(player.closeCalls, 1);
    expect(player.expandCalls, 0);
    await tester.tap(key('music-mini-expand'));
    expect(player.expandCalls, 1);
  });

  testWidgets('finished songs forward Play to the shared decoder',
      (tester) async {
    await player.seed(player.state.copyWith(
        position: const Duration(seconds: 180),
        isPlaying: false,
        mediaEvent: const MediaEvent(state: MediaState.completed)));
    await pump(tester);
    expect(find.byIcon(Icons.replay_rounded), findsOneWidget);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  testWidgets('a playing final second still pauses instead of restarting',
      (tester) async {
    await player.seed(player.state
        .copyWith(position: const Duration(seconds: 180), isPlaying: true));
    await pump(tester);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
  });

  testWidgets('paused near the end resumes without restarting', (tester) async {
    await player.seed(player.state
        .copyWith(position: const Duration(seconds: 179), isPlaying: false));
    await pump(tester);
    expect(find.byIcon(Icons.replay_rounded), findsNothing);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  for (final (length, position, expected) in [
    (null, 45, 0.0),
    (0, 45, 0.0),
    (-1, 45, 0.0),
    (180, -1, 0.0),
    (180, 90, 0.5),
    (180, 200, 1.0),
  ]) {
    testWidgets('progress is finite with length $length and position $position',
        (tester) async {
      await player.seed(player.state.copyWith(
          currentlyPlaying: song.copyWith(lengthSeconds: length),
          position: Duration(seconds: position)));
      await pump(tester);
      expect(
          tester
              .widget<LinearProgressIndicator>(key('music-mini-progress'))
              .value,
          expected);
      if (length == null || length <= 0) {
        expect(find.byIcon(Icons.replay_rounded), findsNothing);
        await tester.tap(key('music-mini-play'));
        await tester.pump();
        expect(player.sought, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('single-song playback leaves room instead of a dead next button',
      (tester) async {
    await player.seed(player.state.copyWith(videos: [song]));
    await pump(tester);
    expect(key('music-mini-next'), findsNothing);
    expect(key('music-mini-play'), findsOneWidget);
    expect(key('music-mini-close'), findsOneWidget);
  });

  testWidgets('loading survives presentation events and clears when ready',
      (tester) async {
    player.setEvent(const MediaEvent(state: MediaState.loading));
    await pump(tester);
    LinearProgressIndicator indicator() =>
        tester.widget<LinearProgressIndicator>(key('music-mini-progress'));
    expect(indicator().value, isNull);
    player.showMiniPlayer();
    await tester.pump();
    expect(indicator().value, isNull);
    player.setEvent(const MediaEvent(state: MediaState.ready));
    await tester.pump();
    expect(indicator().value, isNotNull);
  });

  testWidgets('decoder failure remains visible across minimizing and mute',
      (tester) async {
    player.setEvent(const MediaEvent(state: MediaState.error));
    player.showMiniPlayer();
    player.setEvent(const MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.volumeChanged,
        value: false));
    await pump(tester, width: 240, scale: 2.5);
    expect(key('music-mini-error'), findsOneWidget);
    expect(tester.takeException(), isNull);
    player.setEvent(const MediaEvent(state: MediaState.loading));
    expect(player.playbackStatus, MediaState.loading);
    await tester.pump();
    await tester.pump();
    expect(key('music-mini-error'), findsNothing);
  });

  for (final phase in BackendRecoveryPhase.values) {
    testWidgets('compact player exposes backend recovery ${phase.name}',
        (tester) async {
      await player.seed(player.state.copyWith(
          backendRecovery: BackendRecovery(
              phase: phase,
              request: BackendPlayback(Server(
                  url: 'https://instance.example',
                  backendSelector: BackendSelector('COMPANION_ID',
                      const [BackendOption('a', 'Backend A')]))),
              videoId: song.videoId,
              manual: false)));
      await pump(tester);
      final value = tester
          .widget<LinearProgressIndicator>(key('music-mini-progress'))
          .value;
      expect(value, phase == BackendRecoveryPhase.trying ? isNull : isNotNull);
      expect(key('music-mini-error'),
          phase == BackendRecoveryPhase.failed ? findsOneWidget : findsNothing);
      expect(find.text('Singer'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('live Music does not become a completed recording',
      (tester) async {
    await player.seed(player.state.copyWith(
        currentlyPlaying: song.copyWith(liveNow: true),
        position: const Duration(seconds: 200)));
    await pump(tester);
    expect(find.byIcon(Icons.replay_rounded), findsNothing);
    expect(
        tester
            .widget<LinearProgressIndicator>(key('music-mini-progress'))
            .value,
        0);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });
}
