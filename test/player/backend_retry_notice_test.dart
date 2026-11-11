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
import 'package:clipious/player/states/player_controls.dart';
import 'package:clipious/player/states/tv_player_controls.dart';
import 'package:clipious/player/views/components/backend_retry_notice.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/player/views/components/backend_request_indicator.dart';
import 'package:clipious/player/views/components/video_retry_notice.dart';
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/player/views/components/system_setting_slider.dart';
import 'package:clipious/player/views/tv/components/player_controls.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/motion_binding.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _MotionTestBinding extends AutomatedTestWidgetsFlutterBinding
    with InterfaceMotionBinding {}

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

  void setReconnecting(bool active, MediaEvent event) =>
      emit(state.copyWith(recoveringPlayback: active, mediaEvent: event));

  void setColdMetadataEvent(MediaEvent event) =>
      emit(state.copyWith(currentlyPlaying: null, mediaEvent: event));

  void setTimer(bool active) => emit(state.copyWith(hasTimer: active));

  void setCompact({bool mini = false, bool pip = false}) =>
      emit(state.copyWith(isMini: mini, isPip: pip));
}

Future<void> pumpRecoveryFrame(WidgetTester tester) async {
  // Bloc's stream notification and context.select's dependent rebuild need
  // separate frames; an active recovery spinner cannot use pumpAndSettle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  final binding = _MotionTestBinding();
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
    binding.reduceInterfaceMotion = false;
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Widget host(Widget child,
          {MotionPreference motion = MotionPreference.system}) =>
      MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: settings),
        ],
        child: MaterialApp(
          builder: (context, child) =>
              MotionScope(preference: motion, child: child!),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  double opacity(WidgetTester tester, Finder child) => tester
      .widgetList<FadeTransition>(
          find.ancestor(of: child, matching: find.byType(FadeTransition)))
      .fold(1.0, (value, fade) => value * fade.opacity.value);

  double paintedOpacity(WidgetTester tester, Finder child) {
    var opacity = 1.0;
    RenderObject? node = tester.renderObject(child);
    while (node != null) {
      if (node is RenderOpacity) opacity *= node.opacity;
      if (node is RenderAnimatedOpacity) opacity *= node.opacity.value;
      node = node.parent;
    }
    return opacity;
  }

  testWidgets(
      'metadata retry on cold start is nonblocking and yields to recovery',
      (tester) async {
    await tester.runAsync(() async {
      player.setColdMetadataEvent(const MediaEvent(
          state: MediaState.loading, type: MediaEventType.metadataRetry));
    });
    var taps = 0;
    const buttonKey = ValueKey('underlying-control');
    await tester.pumpWidget(host(
        Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: TextButton(
                key: buttonKey,
                onPressed: () => taps++,
                child: const Text('Control'),
              ),
            ),
            const Positioned.fill(child: PlayerRetryIndicator()),
          ],
        ),
        motion: MotionPreference.off));
    try {
      final notice = find.text('Retrying video details…');
      expect(notice, findsOneWidget);
      await tester.tap(find.byKey(buttonKey));
      expect(taps, 1);

      await tester.runAsync(() async {
        player.showRecovery(
            BackendPlayback(backendServer), BackendRecoveryPhase.trying,
            manual: true);
      });
      await pumpRecoveryFrame(tester);
      expect(notice, findsNothing);

      await tester.runAsync(() async {
        player.clearRecovery();
        player.setColdMetadataEvent(const MediaEvent(
            state: MediaState.error, type: MediaEventType.metadataRetry));
      });
      await pumpRecoveryFrame(tester);
      expect(notice, findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
      'playback recovery stays visible through incidental decoder events',
      (tester) async {
    final focus = FocusNode();
    var taps = 0;
    await tester.pumpWidget(host(
        Stack(
          fit: StackFit.expand,
          children: [
            Center(
                child: TextButton(
              focusNode: focus,
              onPressed: () => taps++,
              child: const Text('Pause'),
            )),
            const Positioned.fill(child: PlayerRetryIndicator()),
          ],
        ),
        motion: MotionPreference.off));
    focus.requestFocus();
    await tester.pump();
    for (final state in [
      MediaState.loading,
      MediaState.buffering,
      MediaState.ready
    ]) {
      player.setReconnecting(true, MediaEvent(state: state));
      await pumpRecoveryFrame(tester);
      expect(find.text('Reconnecting playback…'), findsOneWidget);
      expect(find.text('Retrying video details…'), findsNothing);
      expect(focus.hasFocus, isTrue);
    }
    await tester.tap(find.text('Pause'));
    expect(taps, 1);
    player.setCompact(pip: true);
    await pumpRecoveryFrame(tester);
    expect(find.text('Reconnecting playback…'), findsNothing);
    player.setCompact();
    player.setReconnecting(false, const MediaEvent(state: MediaState.error));
    await pumpRecoveryFrame(tester);
    expect(find.text('Reconnecting playback…'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  });

  for (final motion in MotionPreference.values) {
    testWidgets('${motion.name}: sponsor notice remains readable before expiry',
        (tester) async {
      await tester.pumpWidget(host(const PlayerControls(), motion: motion));
      final context = tester.element(find
          .descendant(
              of: find.byType(PlayerControls),
              matching: find.byType(LayoutBuilder))
          .first);
      context.read<PlayerControlsCubit>().onStreamEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.sponsorSkipped));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 600));
      final notice = find.text(AppLocalizations.of(context)!.sponsorSkipped);
      expect(notice, findsOneWidget);
      expect(opacity(tester, notice), 1);
      await tester.pump(const Duration(seconds: 1));
      expect(notice, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        '${motion.name}: sleep timer feedback keeps its three-second dwell',
        (tester) async {
      await tester.pumpWidget(host(const PlayerControls(), motion: motion));
      expect(opacity(tester, find.byIcon(Icons.bedtime_off_outlined)), 0);
      final sliders = find.byType(SystemSettingsSlider);
      for (var i = 0; i < sliders.evaluate().length; i++) {
        expect(opacity(tester, sliders.at(i)), 0);
      }
      player.setTimer(true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(seconds: 1));
      final notice = find.byIcon(Icons.bedtime_outlined);
      expect(notice, findsOneWidget);
      expect(opacity(tester, notice), 1);
      await tester.pump(const Duration(milliseconds: 2400));
      expect(opacity(tester, notice), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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

    for (final motion in MotionPreference.values) {
      testWidgets(
          '$mode ${motion.name}: backend label follows controls after recovery',
          (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          if (mode == 'audio') player.setAudio(true);
          final initial =
              BackendPlayback(selector.withSelection(backendServer, 'west'));
          player.requestBackend(initial);
          await tester.pumpWidget(host(
              mode == 'TV' ? const TvPlayerControls() : const PlayerControls(),
              motion: motion));
          Future<void> revealControls() async {
            if (mode == 'TV') {
              // A remote key reveals the timeline even before full controls open.
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            } else {
              await tester.tapAt(const Offset(400, 200));
              // The player distinguishes a single tap from double-tap seek.
              await tester.pump(const Duration(milliseconds: 300));
            }
            await pumpRecoveryFrame(tester);
            await tester.pump(const Duration(milliseconds: 300));
          }

          if (mode == 'TV') await revealControls();
          await tester.pump(const Duration(milliseconds: 300));
          var label = find.text('Requested backend: West · 1');
          expect(paintedOpacity(tester, label), 1);
          expect(find.semantics.byLabel(RegExp('Requested backend: West · 1')),
              findsOneWidget);
          await tester.pump(const Duration(seconds: 5));
          await tester.pump(const Duration(milliseconds: 300));
          expect(paintedOpacity(tester, label), 0);
          expect(find.semantics.byLabel(RegExp('Requested backend: West · 1')),
              findsNothing);

          await revealControls();
          expect(paintedOpacity(tester, label), 1);
          expect(find.semantics.byLabel(RegExp('Requested backend: West · 1')),
              findsOneWidget);
          if (mode == 'TV') {
            final context =
                tester.element(find.byType(BackendRequestIndicator));
            expect(context.read<TvPlayerControlsCubit>().state.displayControls,
                isFalse);
          }

          final retry = initial.next()!;
          player.showRecovery(retry, BackendRecoveryPhase.trying);
          await pumpRecoveryFrame(tester);
          expect(find.text('Trying East · 2…'), findsOneWidget);
          await tester.pump(const Duration(seconds: 5));
          await tester.pump(const Duration(milliseconds: 300));
          label = find.text('Requested backend: East · 2');
          expect(paintedOpacity(tester, label), 0);
          expect(paintedOpacity(tester, find.text('Trying East · 2…')), 1);
          player.showRecovery(retry, BackendRecoveryPhase.succeeded);
          await pumpRecoveryFrame(tester);
          expect(paintedOpacity(tester, find.text('Playback resumed')), 1);
          player.clearRecovery();
          await tester.pump(const Duration(seconds: 5));
          expect(find.byType(BackendRecoveryNotice), findsNothing);
          expect(paintedOpacity(tester, label), 0);
          await revealControls();
          expect(paintedOpacity(tester, label), 1);
          expect(find.text('Requested backend: West · 1'), findsNothing);

          player.requestBackend(null);
          await pumpRecoveryFrame(tester);
          expect(find.byType(BackendRequestIndicator), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 5));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  for (final compact in ['mini', 'PiP']) {
    testWidgets('$compact video has no backend label over its picture',
        (tester) async {
      player.requestBackend(
          BackendPlayback(selector.withSelection(backendServer, 'west')));
      await tester.pumpWidget(host(const PlayerControls()));
      player.setCompact(mini: compact == 'mini', pip: compact == 'PiP');
      await pumpRecoveryFrame(tester);
      await tester.pump(const Duration(milliseconds: 300));
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

  testWidgets('backend overlay leaves underlying player controls clickable',
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
    // The inline player supplies the 16:9 bounds to its controls.
    await tester.pumpWidget(host(const SizedBox(
      width: 360,
      height: 202.5,
      child: PlayerControls(),
    )));
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
