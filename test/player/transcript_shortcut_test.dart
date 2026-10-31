import 'dart:async';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/mini_player_controls.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _TranscriptService extends Service {
  @override
  Future<VideoTranscript> getTranscript(String videoId, Caption caption) async {
    return const VideoTranscript(label: 'English', languageCode: 'en', lines: [
      VideoTranscriptLine(
        type: VideoTranscriptLineType.regular,
        startMs: 0,
        endMs: 1000,
        text: 'Test transcript',
      ),
    ]);
  }
}

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late Service originalService;
  final shortcut = find.byKey(const ValueKey('video-transcript-open'));
  final transcript = find.byKey(const ValueKey('video-transcript-list'));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    originalService = service;
    service = _TranscriptService();
  });

  tearDown(() async {
    service = originalService;
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pumpPlayer(WidgetTester tester,
      {bool isAudio = false, bool withQueueAndBackend = false}) async {
    final video = Video(
      videoId: 'test-video',
      captions: [Caption('English', 'en', '/api/v1/captions/test-video')],
      backendPlayback: withQueueAndBackend
          ? BackendPlayback(Server(
              url: 'https://example.test',
              backendSelector: BackendSelector('COMPANION_ID',
                  const [BackendOption('1', 'One'), BackendOption('2', 'Two')]),
            ))
          : null,
    );
    player = TestPlayerCubit(
        PlayerState.init(null).copyWith(
          isMini: false,
          isAudio: isAudio,
          currentlyPlaying: video,
          videos: withQueueAndBackend
              ? [video, const Video(videoId: 'second-video')]
              : [],
        ),
        settings);
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
            MiniPlayerControls(videoId: 'test-video'),
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
    for (final dismissal in ['Back', 'scrim', 'Navigator']) {
      testWidgets(
          '${isAudio ? 'audio' : 'video'} transcript $dismissal dismissal preserves player and restores Back',
          (tester) async {
        await pumpPlayer(tester, isAudio: isAudio);
        final interceptorsBefore = BackButtonInterceptor.describe();
        await tester.tap(shortcut);
        await tester.pumpAndSettle();
        expect(transcript, findsOneWidget);
        expect(find.text('Test transcript'), findsOneWidget);

        if (dismissal == 'Back') {
          await pressAndroidBack(tester);
        } else if (dismissal == 'scrim') {
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();
        } else {
          Navigator.of(tester.element(transcript)).pop();
          await tester.pumpAndSettle();
        }

        expect(transcript, findsNothing);
        expect(player.state.isMini, isFalse);
        expect(shortcut, findsOneWidget);
        expect(BackButtonInterceptor.describe(), interceptorsBefore);
        await pressAndroidBack(tester);
        expect(player.state.isMini, isTrue);
        expect(shortcut, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('all controls fit a narrow player with transcript beside speed',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpPlayer(tester, withQueueAndBackend: true);

    final speed = find.byKey(const ValueKey('playback-speed-open'));
    expect(
        find.byKey(const ValueKey('player-backend-shortcut')), findsOneWidget);
    expect(find.byIcon(Icons.shuffle), findsOneWidget);
    expect(shortcut, findsOneWidget);
    expect(tester.getRect(shortcut).left,
        greaterThanOrEqualTo(tester.getRect(speed).right));
    expect(tester.getCenter(shortcut).dy, tester.getCenter(speed).dy);
    expect(tester.takeException(), isNull);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expect(transcript, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
