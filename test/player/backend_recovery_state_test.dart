import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late BackendPlayback initial;
  late Server preferred;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
      'COMPANION_ID',
      const [
        BackendOption('a', 'Backend A'),
        BackendOption('b', 'Backend B'),
        BackendOption('c', 'Backend C'),
      ],
      automaticFallback: true,
    );
    preferred = selector.withSelection(
        Server(url: 'https://instance.example', backendSelector: selector),
        'a');
    await db.upsertServer(preferred);
    await db.useServer(preferred);
    app = TestAppCubit(AppState(0, preferred, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    initial = BackendPlayback(preferred);
    player = TestPlayerCubit(
      PlayerState.init(null).copyWith(
        currentlyPlaying: Video(videoId: 'video', backendPlayback: initial),
        requestedBackend: initial,
        isHidden: false,
      ),
      settings,
    );
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  BackendPlayback retry() {
    final request = initial.next()!;
    expect(player.setRequestedBackend('video', request), isTrue);
    return request;
  }

  test('fallback stays trying through metadata, loading, and ready events', () {
    final request = retry();
    for (final event in [
      const MediaEvent(state: MediaState.loading),
      const MediaEvent(state: MediaState.buffering),
      const MediaEvent(state: MediaState.ready),
      const MediaEvent(state: MediaState.playing, type: MediaEventType.play),
      const MediaEvent(
          state: MediaState.playing,
          type: MediaEventType.durationChanged,
          value: Duration(seconds: 60)),
    ]) {
      player.setEvent(event);
      expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);
      expect(player.state.backendRecovery!.request, same(request));
    }
    expect(player.state.backendRecovery!.alternativeIndex, 1);
  });

  test('only advancing current native playback confirms success', () {
    final request = retry();
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 40),
        playing: true);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 40),
        playing: true);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 41),
        playing: true);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.succeeded);
    expect(player.state.requestedBackend, same(request));
  });

  test('paused replacement reports ready, then success after playback advances',
      () {
    final request = retry();
    player.reportBackendPlaybackReady('video', request, playing: false);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.ready);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 10),
        playing: false);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 11),
        playing: false);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.ready);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 11),
        playing: true);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 12),
        playing: true);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.succeeded);
  });

  test('another video or older attempt cannot confirm the active request', () {
    final first = retry();
    final second = first.next()!;
    player.setRequestedBackend('video', second);
    for (final id in ['other', 'video']) {
      player.reportBackendPlaybackProgress(
          id, first, const Duration(seconds: 1),
          playing: true);
      player.reportBackendPlaybackProgress(
          id, first, const Duration(seconds: 2),
          playing: true);
      player.reportBackendPlaybackReady(id, first, playing: false);
    }
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);
    expect(player.state.backendRecovery!.request, same(second));
    expect(player.state.backendRecovery!.alternativeIndex, 2);
  });

  test('terminal failure retains the actual attempt and stops success reports',
      () {
    final request = retry();
    player.setEvent(const MediaEvent(state: MediaState.error));
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.failed);
    expect(player.state.backendRecovery!.alternativeIndex, 1);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 1),
        playing: true);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 2),
        playing: true);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.failed);
  });

  test('same attempt does not restart a completed confirmation', () {
    final request = retry();
    player.reportBackendPlaybackProgress('video', request, Duration.zero,
        playing: true);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 1),
        playing: true);
    player.setRequestedBackend('video', request);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.succeeded);
  });

  test('stopping clears recovery and rejects late progress', () {
    final request = retry();
    player.hide();
    expect(player.state.backendRecovery, isNull);
    player.reportBackendPlaybackProgress('video', request, Duration.zero,
        playing: true);
    player.reportBackendPlaybackProgress(
        'video', request, const Duration(seconds: 1),
        playing: true);
    expect(player.state.backendRecovery, isNull);
    expect(player.setRequestedBackend('video', request), isFalse);
  });

  test('manual routing preserves the saved baseline and bounded alternatives',
      () {
    final manual = BackendPlayback.manual(preferred, 'b');
    expect(manual.manualSelection, isTrue);
    expect(manual.retryIndex, 0);
    expect(manual.matches(preferred), isTrue);
    expect(manual.server.backendSelector!.selectedValue(manual.server), 'b');
    expect(
        manual.preferredServer.backendSelector!
            .selectedValue(manual.preferredServer),
        'a');
    final first = manual.next()!;
    final second = first.next()!;
    expect(first.retryIndex, 1);
    expect(second.retryIndex, 2);
    expect(second.next(), isNull);
    expect({manual.label, first.label, second.label}, hasLength(3));
  });
}
