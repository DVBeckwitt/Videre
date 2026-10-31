import 'dart:async';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/mini_player_controls.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  final shortcut = find.byKey(const ValueKey('playback-speed-open'));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pumpPlayer(WidgetTester tester,
      {bool isAudio = false, bool isMini = false}) async {
    player = TestPlayerCubit(
        PlayerState.init(null).copyWith(
          isMini: isMini,
          isAudio: isAudio,
          currentlyPlaying: const Video(videoId: 'test-video'),
        ),
        settings);
    // Match the Android player's global handler, which runs before Navigator.
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Column(children: [
            Text('Player screen'),
            MiniPlayerControls(),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pressAndroidBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();
  }

  for (final isAudio in [false, true]) {
    for (final useBack in [true, false]) {
      testWidgets(
          '${isAudio ? 'audio' : 'video'} speed sheet ${useBack ? 'Back' : 'scrim'} dismissal preserves player and restores Back',
          (tester) async {
        await pumpPlayer(tester, isAudio: isAudio);
        final interceptorsBefore = BackButtonInterceptor.describe();
        await tester.tap(shortcut);
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackSpeedControls), findsOneWidget);

        if (useBack) {
          await pressAndroidBack(tester);
        } else {
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();
        }

        expect(find.byType(PlaybackSpeedControls), findsNothing);
        expect(player.state.isMini, isFalse);
        expect(shortcut, findsOneWidget);
        expect(BackButtonInterceptor.describe(), interceptorsBefore);

        await pressAndroidBack(tester);
        expect(player.state.isMini, isTrue);
        expect(shortcut, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
        '${isAudio ? 'audio' : 'video'} shortcut opens full controls with current speed',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpPlayer(tester, isAudio: isAudio);
      player.setEvent(const MediaEvent<double>(
        state: MediaState.pause,
        type: MediaEventType.speedChanged,
        value: 1.37,
      ));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Playback speed'), findsOneWidget);
      await tester.tap(shortcut);
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackSpeedControls), findsOneWidget);
      expect(find.text('1.37×'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final increase = find.byKey(const ValueKey('playback-speed-increase'));
      await tester.tap(increase);
      await tester.pumpAndSettle();
      expect(player.state.mediaCommand?.type, MediaCommandType.speed);
      expect(player.state.mediaCommand?.value, 1.42);

      // Decoder acknowledgement may arrive after the shortcut sent its command.
      player.setEvent(const MediaEvent<double>(
        state: MediaState.pause,
        type: MediaEventType.speedChanged,
        value: 1.42,
      ));
      Navigator.of(tester.element(find.byType(PlaybackSpeedControls))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Player screen'), findsOneWidget);
      expect(shortcut, findsOneWidget);
      await tester.tap(shortcut);
      await tester.pumpAndSettle();
      expect(find.text('1.42×'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('collapsed mini player keeps its compact playback controls',
      (tester) async {
    await pumpPlayer(tester, isMini: true);
    expect(shortcut, findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
