import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show darkColorScheme;
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_retry_notice.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/player/views/components/backend_request_indicator.dart';
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/player/views/tv/components/player_controls.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _BackendPlayerCubit extends TestPlayerCubit {
  _BackendPlayerCubit(super.initialState, super.settings);

  void requestBackend(BackendPlayback? playback) =>
      emit(state.copyWith(requestedBackend: playback));

  void showRecovery(BackendPlayback request, BackendRecoveryPhase phase,
          {bool manual = false}) =>
      emit(state.copyWith(
        requestedBackend: request,
        backendRecovery: BackendRecovery(
            phase: phase, request: request, videoId: 'test', manual: manual),
      ));

  void clearRecovery() => emit(state.copyWith(backendRecovery: null));
}

Future<void> pumpRecoveryFrame(WidgetTester tester) async {
  // Bloc's stream notification and context.select's dependent rebuild need
  // separate frames; an active recovery spinner cannot use pumpAndSettle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _BackendPlayerCubit player;
  final selector = BackendSelector(
      'COMPANION_ID',
      const [
        BackendOption('west', 'West · 1'),
        BackendOption('east', 'East · 2'),
        BackendOption('north', 'North · 3'),
      ],
      automaticFallback: true);
  final backendServer = Server(
    url: 'https://private-instance.example',
    authToken: 'private-token',
    backendSelector: selector,
  );

  setUp(() async {
    darkColorScheme = ColorScheme.fromSeed(
        seedColor: Colors.blue, brightness: Brightness.dark);
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    await db.upsertServer(const Server(url: 'https://test.example'));
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _BackendPlayerCubit(
        PlayerState.init(null).copyWith(
          isMini: false,
          currentlyPlaying: const Video(
              videoId: 'test', title: 'Test video', lengthSeconds: 120),
        ),
        settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Widget host(Widget child) => MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  for (final mode in ['video', 'audio', 'TV']) {
    testWidgets('$mode recovery survives decoder events and reports outcomes',
        (tester) async {
      if (mode == 'audio') player.setAudio(true);
      await tester.pumpWidget(host(
          mode == 'TV' ? const TvPlayerControls() : const PlayerControls()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BackendRecoveryNotice), findsNothing);

      final initial =
          BackendPlayback(selector.withSelection(backendServer, 'west'));
      final first = initial.next()!;
      player.showRecovery(first, BackendRecoveryPhase.trying);
      await pumpRecoveryFrame(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Trying East · 2…'), findsOneWidget);
      expect(find.text('Alternative 1 of 2'), findsOneWidget);
      expect(
          find.ancestor(
              of: find.byType(BackendRecoveryNotice),
              matching: find.byType(AnimatedOpacity)),
          findsNothing);
      expect(tester.takeException(), isNull);

      // Metadata, duration and decoder-ready events do not establish playback.
      for (final event in const [
        MediaEvent(state: MediaState.loading),
        MediaEvent(state: MediaState.buffering),
        MediaEvent(state: MediaState.ready),
        MediaEvent(
            state: MediaState.ready,
            type: MediaEventType.durationChanged,
            value: Duration(seconds: 120)),
      ]) {
        player.setEvent(event);
        await pumpRecoveryFrame(tester);
        expect(find.text('Trying East · 2…'), findsOneWidget);
        expect(find.text('Playback resumed'), findsNothing);
      }

      final second = first.next()!;
      player.showRecovery(second, BackendRecoveryPhase.trying);
      await pumpRecoveryFrame(tester);
      expect(find.text('Trying North · 3…'), findsOneWidget);
      expect(find.text('Alternative 2 of 2'), findsOneWidget);
      expect(find.text('Trying East · 2…'), findsNothing);
      expect(find.text('Alternative 1 of 2'), findsNothing);

      // The runtime tests own native advancement detection. These snapshots
      // verify the same confirmed outcome is presented on every player surface.
      player.showRecovery(second, BackendRecoveryPhase.ready);
      await pumpRecoveryFrame(tester);
      expect(find.text('Backend ready · Paused'), findsOneWidget);
      expect(find.byType(BackendRetryNotice), findsNothing);
      expect(find.text('Playback resumed'), findsNothing);

      player.showRecovery(second, BackendRecoveryPhase.succeeded);
      await pumpRecoveryFrame(tester);
      expect(find.text('Playback resumed'), findsOneWidget);
      expect(find.text('Backend ready · Paused'), findsNothing);
      player.setEvent(const MediaEvent(
          state: MediaState.playing,
          type: MediaEventType.bufferChanged,
          value: Duration(seconds: 10)));
      await pumpRecoveryFrame(tester);
      expect(find.text('Playback resumed'), findsOneWidget);
      expect(find.textContaining('Switched successfully'), findsNothing);
      expect(find.text('Requested backend: North · 3'), findsOneWidget);

      player.clearRecovery();
      await pumpRecoveryFrame(tester);
      expect(find.byType(BackendRecoveryNotice), findsNothing);
      expect(find.text('Requested backend: North · 3'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '$mode recovery failure reports actual attempts and offers picker',
        (tester) async {
      if (mode == 'audio') player.setAudio(true);
      final initial =
          BackendPlayback(selector.withSelection(backendServer, 'west'));
      final first = initial.next()!;
      player.showRecovery(first, BackendRecoveryPhase.failed);
      await tester.pumpWidget(host(
          mode == 'TV' ? const TvPlayerControls() : const PlayerControls()));
      await tester.pump(const Duration(milliseconds: 300));
      final failureMessage =
          find.text('Couldn’t resume playback after trying 1 alternative.');
      expect(failureMessage, findsOneWidget);
      // The player paints a dark overlay even when the app uses a light theme.
      expect(Theme.of(tester.element(find.byType(Scaffold))).brightness,
          Brightness.light);
      expect(tester.widget<Text>(failureMessage).style?.color, Colors.white);
      expect(find.byType(BackendRetryNotice), findsNothing);
      expect(find.text('Playback resumed'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Connection help'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-backend-error-open')),
          findsOneWidget);

      final second = first.next()!;
      player.showRecovery(second, BackendRecoveryPhase.failed);
      await pumpRecoveryFrame(tester);
      expect(find.text('Couldn’t resume playback after trying 2 alternatives.'),
          findsOneWidget);
      expect(find.text('Couldn’t resume playback after trying 1 alternative.'),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('player-backend-error-open')));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerBackendPicker), findsOneWidget);
      expect(find.text('Save as preferred backend'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerBackendPicker), findsNothing);
      expect(find.text('Couldn’t resume playback after trying 2 alternatives.'),
          findsOneWidget);

      // A manual retry can become ready while paused. Old decoder-error flags
      // must not obscure the explicit recovery state or retain error actions.
      player.setEvent(const MediaEvent(state: MediaState.error));
      await pumpRecoveryFrame(tester);
      player.showRecovery(second, BackendRecoveryPhase.ready);
      await pumpRecoveryFrame(tester);
      expect(find.text('Backend ready · Paused'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Connection help'), findsNothing);
      expect(find.byKey(const ValueKey('player-backend-error-open')),
          findsNothing);
      expect(find.text('Playback resumed'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '$mode requested backend persists after recovery and controls fade',
        (tester) async {
      if (mode == 'audio') player.setAudio(true);
      final initial =
          BackendPlayback(selector.withSelection(backendServer, 'west'));
      player.requestBackend(initial);
      await tester.pumpWidget(host(
          mode == 'TV' ? const TvPlayerControls() : const PlayerControls()));
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Requested backend: West · 1'), findsOneWidget);
      expect(
          find.ancestor(
              of: find.byType(BackendRequestIndicator),
              matching: find.byType(AnimatedOpacity)),
          findsNothing);

      final retry = initial.next()!;
      player.showRecovery(retry, BackendRecoveryPhase.trying);
      await pumpRecoveryFrame(tester);
      expect(find.text('Trying East · 2…'), findsOneWidget);
      expect(find.text('Requested backend: East · 2'), findsOneWidget);
      player.showRecovery(retry, BackendRecoveryPhase.succeeded);
      await pumpRecoveryFrame(tester);
      player.clearRecovery();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(BackendRecoveryNotice), findsNothing);
      expect(find.text('Requested backend: East · 2'), findsOneWidget);
      expect(find.text('Requested backend: West · 1'), findsNothing);

      player.requestBackend(null);
      await pumpRecoveryFrame(tester);
      expect(find.byType(BackendRequestIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('long backend labels fit 320px video with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const name =
        'A long backend name with a region and additional instance details';
    await tester.pumpWidget(host(const AspectRatio(
      aspectRatio: 16 / 9,
      child: BackendRetryNotice(backendName: name),
    )));
    final message = find.text('Trying $name…');
    expect(message, findsOneWidget);
    final bounds = tester.getRect(message);
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(320));
    expect(bounds.bottom, lessThanOrEqualTo(180));
    expect(tester.takeException(), isNull);
    final longSelector =
        BackendSelector('COMPANION_ID', const [BackendOption('one', name)]);
    await tester.pumpWidget(host(AspectRatio(
      aspectRatio: 16 / 9,
      child: BackendRequestIndicator(
        overlay: true,
        playback: BackendPlayback(longSelector.withSelection(
            backendServer.copyWith(backendSelector: longSelector), 'one')),
      ),
    )));
    final requestBounds = tester.getRect(find.text('Requested backend: $name'));
    expect(requestBounds.left, greaterThanOrEqualTo(0));
    expect(requestBounds.right, lessThanOrEqualTo(320));
    expect(requestBounds.bottom, lessThanOrEqualTo(180));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'default and custom requests expose labels without routing secrets',
      (tester) async {
    await tester.pumpWidget(host(
        BackendRequestIndicator(playback: BackendPlayback(backendServer))));
    expect(find.text('Requested backend: Server default'), findsOneWidget);

    await tester.pumpWidget(host(BackendRequestIndicator(
        playback: BackendPlayback(backendServer.copyWith(customHeaders: {
      'Cookie': 'COMPANION_ID=private-cookie-value; SID=private-session',
    })))));
    expect(find.text('Requested backend: Custom selection'), findsOneWidget);
    expect(find.textContaining('private-'), findsNothing);
    expect(find.textContaining('COMPANION_ID'), findsNothing);
    await tester
        .pumpWidget(host(const BackendRequestIndicator(playback: null)));
    expect(find.textContaining('Requested backend:'), findsNothing);
    await tester.pumpWidget(host(BackendRequestIndicator(
        playback: BackendPlayback(
            const Server(url: 'https://private-instance.example')))));
    expect(find.textContaining('Requested backend:'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistent overlay leaves underlying player controls clickable',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(Stack(children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SizedBox(
            height: 64,
            child: TextButton(
              onPressed: () => taps++,
              child: const Text('Player control'),
            )),
      ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: BackendRequestIndicator(
          playback:
              BackendPlayback(selector.withSelection(backendServer, 'west')),
          overlay: true,
        ),
      ),
    ])));
    await tester
        .tapAt(tester.getCenter(find.text('Requested backend: West · 1')));
    expect(taps, 1);
  });

  testWidgets(
      'long backend names remain separated in 360px large-text controls',
      (tester) async {
    // The existing timeline row requires 360px at 2x text. The new standalone
    // overlays are also checked at 320px above.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const name =
        'A long backend name with a region and additional instance details';
    final longSelector =
        BackendSelector('COMPANION_ID', const [BackendOption('one', name)]);
    final request = BackendPlayback(longSelector.withSelection(
        backendServer.copyWith(backendSelector: longSelector), 'one'));
    player.showRecovery(request, BackendRecoveryPhase.trying, manual: true);
    await tester.pumpWidget(host(const PlayerControls()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    final requested = tester.getRect(find.text('Requested backend: $name'));
    final trying = tester.getRect(find.text('Trying $name…'));
    expect(requested.left, greaterThanOrEqualTo(0));
    expect(requested.right, lessThanOrEqualTo(360));
    expect(trying.right, lessThanOrEqualTo(360));
    expect(requested.bottom, lessThanOrEqualTo(trying.top));
    expect(trying.bottom, lessThanOrEqualTo(202.5));
    expect(tester.takeException(), isNull);
    player.clearRecovery();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
