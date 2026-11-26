import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/services/android_music_output.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

class _RecoveryPlayer extends PlayerCubit {
  _RecoveryPlayer(
      super.initialState, super.settings, Future<void> Function(Duration) wait,
      {Future<bool> Function()? activateFocus})
      : super(playbackRecoveryDelay: wait, videoFocusActivation: activateFocus);

  void seed(PlayerState value) => emit(value);

  @override
  Future<void> onReady() async {}

  @override
  void mapMediaEventToMediaHandler(MediaEvent event) {}
}

const _id = '9bZkp7q19f0';
const _server = Server(
    url: 'https://instance.example',
    id: 'account',
    customHeaders: {'X-Fixture': 'private-route'});

http.Response _response(http.Request request, int status,
        {Map<String, String> headers = const {},
        String error = 'Temporary upstream failure'}) =>
    http.Response(
        jsonEncode(status == 200
            ? {
                'videoId': _id,
                'title': 'Upload title',
                'lengthSeconds': 120,
                'formatStreams': [],
                'adaptiveFormats': [],
              }
            : {'error': error}),
        status,
        request: request,
        headers: {'content-type': 'application/json', ...headers});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service previousService;
  late Service api;
  late SembastSqfDb database;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _RecoveryPlayer player;
  late Video original;
  late Future<void> Function(Duration) wait;
  late Future<bool> Function() activateFocus;
  late Future<http.Response> Function(http.Request) respond;
  final delays = <Duration>[];
  final requests = <http.Request>[];

  setUp(() async {
    previousService = service;
    db = database = await SembastSqfDb.createInMemory();
    await database.upsertServer(_server);
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    wait = (_) async {};
    activateFocus = () async => true;
    respond = (request) async => _response(request, 200);
    service = api = Service(
        httpClient: MockClient((request) async {
          requests.add(request);
          return respond(request);
        }),
        wait: (_) => throw StateError('Metadata must not stack another retry'));
    original = (await api.getVideo(_id)).copyWith(queueEntryId: 'occurrence-1');
    requests.clear();
    delays.clear();
    app = TestAppCubit(AppState(0, _server, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _RecoveryPlayer(
        PlayerState.init([original]).copyWith(
            currentlyPlaying: original,
            position: const Duration(seconds: 42),
            isPlaying: true,
            isHidden: false),
        settings, (delay) {
      delays.add(delay);
      return wait(delay);
    }, activateFocus: () => activateFocus());
    player.audioSession = await AudioSession.instance;
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    api.httpClient.close();
    service = previousService;
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await database.close();
  });

  Future<Video?> refresh(Video video, {bool Function()? current}) =>
      player.refreshCurrentPlayback(video, isCurrent: current ?? () => true);

  void mountMusic() {
    final song = original.copyWith(
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
    player.seed(player.state
        .copyWith(videos: [song], currentlyPlaying: song, isAudio: true));
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
  }

  for (final removalFirst in [false, true]) {
    test(
        'wired insertion resumes a Music unplug pause once '
        '(removal first: $removalFirst)', () async {
      await settings.setMusicWiredHeadsetAutoplay(true);
      mountMusic();
      player.onWiredHeadsetInserted();
      expect(player.state.mediaCommand, isNull);

      if (removalFirst) player.onWiredHeadsetRemoved();
      player.pauseForAudioOutputDisconnect();
      if (!removalFirst) player.onWiredHeadsetRemoved();
      expect(player.state.mediaCommand!.type, MediaCommandType.pause);
      expect(player.requestedPlaying, isFalse);

      player.onWiredHeadsetInserted();
      final play = player.state.mediaCommand;
      expect(play!.type, MediaCommandType.play);
      expect(player.requestedPlaying, isTrue);

      player.onWiredHeadsetInserted();
      expect(player.state.mediaCommand, same(play));
    });
  }

  test('a noisy pause without wired removal cannot arm a wired insertion',
      () async {
    await settings.setMusicWiredHeadsetAutoplay(true);
    mountMusic();
    // For example, disconnecting Bluetooth also sends becoming-noisy.
    player.pauseForAudioOutputDisconnect();
    player.onWiredHeadsetInserted();
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    expect(player.requestedPlaying, isFalse);
  });

  for (final reason in [
    'disabled',
    'disabled during the disconnect pause',
    'non-Music audio',
    'already paused',
    'explicit Pause',
    'Stop',
    'focus loss',
    'permanent focus loss',
    'profile switch',
    'new occurrence',
  ]) {
    test('wired insertion respects $reason', () async {
      if (reason != 'disabled') {
        await settings.setMusicWiredHeadsetAutoplay(true);
      }
      if (reason != 'non-Music audio') {
        mountMusic();
      } else {
        player.seed(player.state.copyWith(
            currentlyPlaying: original.copyWith(queueEntryId: 'watch-audio'),
            isAudio: true));
      }
      if (reason == 'already paused') player.pause();
      player.pauseForAudioOutputDisconnect();
      player.onWiredHeadsetRemoved();
      expect(player.state.mediaCommand!.type, MediaCommandType.pause);
      switch (reason) {
        case 'disabled during the disconnect pause':
          await settings.setMusicWiredHeadsetAutoplay(false);
        case 'explicit Pause':
          player.pause();
        case 'Stop':
          player.hide();
        case 'focus loss':
          player.handleAudioInterruption(
              AudioInterruptionEvent(true, AudioInterruptionType.pause));
          player.handleAudioInterruption(
              AudioInterruptionEvent(false, AudioInterruptionType.pause));
        case 'permanent focus loss':
          player.handleAudioInterruption(
              AudioInterruptionEvent(true, AudioInterruptionType.unknown));
        case 'profile switch':
          await player.prepareForProfileSwitch();
        case 'new occurrence':
          final song = player.state.currentlyPlaying!;
          player.seed(player.state.copyWith(
              currentlyPlaying: song.copyWith(queueEntryId: 'next-song')));
      }
      final command = player.state.mediaCommand;
      player.onWiredHeadsetInserted();
      expect(player.state.mediaCommand, same(command));
      expect(player.requestedPlaying, isFalse);
    });
  }

  test('standard Invidious receives a private, nonserialized source snapshot',
      () {
    expect(original.backendPlayback, isNull);
    expect(original.playbackConnection, isNotNull);
    expect(original.playbackSourceId, isNotNull);
    final json = jsonEncode(original.toJson());
    expect(json, isNot(contains('playbackConnection')));
    expect(json, isNot(contains('playbackSourceId')));
    expect(json, isNot(contains('private-route')));
  });

  test(
      'two refreshes survive success and audio/video remounts without new budget',
      () async {
    final first = (await refresh(original))!;
    expect(player.state.recoveringPlayback, isTrue);
    expect(player.state.position, const Duration(seconds: 42));
    expect(player.state.currentQueueId, 'occurrence-1');
    expect(first.playbackConnection, same(original.playbackConnection));
    expect(first.playbackSourceId, isNot(same(original.playbackSourceId)));
    player.reportPlaybackRecoveryReady(first, playing: true);
    expect(player.state.recoveringPlayback, isTrue);
    player.reportPlaybackRecoveryProgress(original, const Duration(seconds: 43),
        playing: true);
    player.reportPlaybackRecoveryProgress(original, const Duration(seconds: 44),
        playing: true);
    expect(player.state.recoveringPlayback, isTrue);
    player.reportPlaybackRecoveryProgress(first, const Duration(seconds: 42),
        playing: true);
    player.reportPlaybackRecoveryProgress(first, const Duration(seconds: 43),
        playing: true);
    expect(player.state.recoveringPlayback, isFalse);
    player.switchAudio(true);
    final second = (await refresh(first))!;
    player.reportPlaybackRecoveryReady(second, playing: false);
    expect(player.state.recoveringPlayback, isFalse);
    player.switchAudio(false);
    expect(await refresh(second), isNull);
    expect(requests, hasLength(2));
    expect(delays, [const Duration(seconds: 1), const Duration(seconds: 3)]);
    expect(requests.first.url, requests.last.url);
    expect(requests.first.headers, requests.last.headers);
    expect(requests.first.url.queryParameters['local'], 'true');
  });

  test('transient metadata consumes the second reservation without inner retry',
      () async {
    respond = (request) async => _response(request, 503);
    await expectLater(refresh(original), throwsA(isA<InvidiousServiceError>()));
    expect(requests, hasLength(2));
    expect(delays, [const Duration(seconds: 1), const Duration(seconds: 3)]);
    expect(player.state.recoveringPlayback, isFalse);
    expect(await refresh(original), isNull);
  });

  for (final audioOnly in [false, true]) {
    test(
        'explicit outage during Video playback skips a second refresh, audioOnly=$audioOnly',
        () async {
      final selector = BackendSelector('ROUTE', const [
        BackendOption('a', 'First'),
        BackendOption('b', 'Second'),
      ]);
      final selected = selector.withSelection(_server, 'a');
      await database.upsertServer(selected);
      await database.useServer(selected);
      final video =
          (await api.getVideo(_id)).copyWith(queueEntryId: 'occurrence-1');
      player.seed(player.state.copyWith(
          currentlyPlaying: video, videos: [video], isAudio: audioOnly));
      requests.clear();
      respond = (request) async => _response(request, 500,
          error: 'This backend is blocked by Youtube. Please wait '
              'until it has refreshed itself or switch to another backend.');

      await expectLater(refresh(video), throwsA(isA<InvidiousServiceError>()));
      expect(requests, hasLength(1));
      expect(delays, [const Duration(seconds: 1)]);
      respond = (request) async => _response(request, 200);
      final replacement =
          await api.retryVideoBackend(video, isCurrent: () => true);
      expect(replacement!.backendPlayback!.label, 'Second');
      expect(requests, hasLength(2));
      expect(player.state.position, const Duration(seconds: 42));
    });
  }

  for (final headers in [
    {'retry-after': '60'},
    {'retry-after': 'invalid'},
  ]) {
    test('metadata cooldown $headers never spends another automatic attempt',
        () async {
      respond = (request) async => _response(request, 503, headers: headers);
      await expectLater(
          refresh(original), throwsA(isA<InvidiousServiceError>()));
      expect(requests, hasLength(1));
      expect(delays, [const Duration(seconds: 1)]);
      expect(player.state.recoveringPlayback, isFalse);
    });
  }

  for (final failure in [
    const HandshakeException('TLS refused'),
    const SocketException('Privacy policy refused'),
  ]) {
    test('${failure.runtimeType} never permits another refresh', () async {
      respond = (_) async => throw failure;
      await expectLater(refresh(original), throwsA(same(failure)));
      expect(requests, hasLength(1));
      expect(delays, hasLength(1));
    });
  }

  test(
      'same source observers share work and one stale observer cannot cancel it',
      () async {
    final waiting = Completer<void>();
    final release = Completer<void>();
    var firstCurrent = true;
    wait = (_) {
      waiting.complete();
      return release.future;
    };
    final first = refresh(original, current: () => firstCurrent);
    final firstResult = expectLater(first, throwsStateError);
    await waiting.future;
    final second = refresh(original);
    firstCurrent = false;
    release.complete();
    await firstResult;
    expect(await second, isNotNull);
    expect(requests, hasLength(1));
    expect(delays, hasLength(1));
  });

  test('account changes during backoff prevent dispatch and clear feedback',
      () async {
    wait =
        (_) async => database.upsertServer(_server.copyWith(authToken: 'new'));
    await expectLater(refresh(original), throwsStateError);
    expect(requests, isEmpty);
    expect(player.state.recoveringPlayback, isFalse);
  });

  test('missing admission and stale sources fail closed instead of fallback',
      () async {
    final unadmitted = original.copyWith(playbackConnection: null);
    player.seed(player.state.copyWith(currentlyPlaying: unadmitted));
    await expectLater(refresh(unadmitted), throwsStateError);
    expect(delays, isEmpty);
    player.seed(player.state.copyWith(currentlyPlaying: original));
    await refresh(original);
    await expectLater(refresh(original), throwsStateError);
    expect(requests, hasLength(1));
  });

  test('refresh preserves Music labels and queue occurrence', () async {
    final music = original.copyWith(
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
        title: 'Song',
        author: 'Artist');
    player
        .seed(player.state.copyWith(currentlyPlaying: music, videos: [music]));
    final refreshed = (await refresh(music))!;
    expect(refreshed.title, 'Song');
    expect(refreshed.author, 'Artist');
    expect(refreshed.musicMetadata, music.musicMetadata);
    expect(refreshed.queueEntryId, music.queueEntryId);
  });

  test('new selections reset the budget and cancel old pending recovery',
      () async {
    final first = (await refresh(original))!;
    final second = (await refresh(first))!;
    expect(await refresh(second), isNull);
    final next = original.copyWith(queueEntryId: 'occurrence-2');
    await player.switchToVideo(next);
    expect(await refresh(player.state.currentlyPlaying!), isNotNull);
    expect(delays.last, const Duration(seconds: 1));
  });

  test('focus loss gates playback and user Pause prevents focus-end resume',
      () {
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    expect(player.playbackInterrupted, isTrue);
    expect(player.shouldStartPlayback, isFalse);
    player.pause();
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    expect(player.shouldStartPlayback, isFalse);
  });

  group('Bluetooth reconnect', () {
    const selected = MusicBluetoothOutputEvent.selected('headset');
    const disconnected = MusicBluetoothOutputEvent.disconnected('headset');
    const otherSelected = MusicBluetoothOutputEvent.selected('other');
    const position = Duration(seconds: 42);

    Video song() => original.copyWith(
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));

    Future<void> start({bool enable = true, bool music = true}) async {
      if (enable) await settings.setMusicResumeOnBluetoothReconnect(true);
      await player.playVideo([music ? song() : original],
          audio: true, fromMusic: music, startAt: position);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(player.state.isPlaying, isTrue);
      expect(player.isMusicAudio, music);
    }

    test('leaves the existing noisy pause in place by default', () async {
      await start(enable: false);
      player.handleBluetoothOutput(selected);
      player.handleBecomingNoisy();
      final paused = player.state.mediaCommand;
      player.handleBluetoothOutput(disconnected);
      player.handleBluetoothOutput(selected);

      expect(paused?.type, MediaCommandType.pause);
      expect(player.state.mediaCommand, same(paused));
      expect(player.shouldStartPlayback, isFalse);
    });

    for (final noisyFirst in [false, true]) {
      test(
          'resumes only once after a matching reconnect, noisy first=$noisyFirst',
          () async {
        await start();
        final occurrence = player.state.currentQueueId;
        player.handleBluetoothOutput(selected);
        if (noisyFirst) {
          // The decoder also listens for noisy events and can report first.
          player.setEvent(const MediaEvent(
              state: MediaState.playing, type: MediaEventType.pause));
          player.handleBecomingNoisy();
        }
        player.handleBluetoothOutput(disconnected);
        final paused = player.state.mediaCommand;
        expect(paused?.type, MediaCommandType.pause);
        expect(player.shouldStartPlayback, isFalse);

        player.handleBecomingNoisy();
        player.handleBluetoothOutput(disconnected);
        player.handleBluetoothOutput(otherSelected);
        expect(player.state.mediaCommand, same(paused));

        player.handleBluetoothOutput(selected);
        final resumed = player.state.mediaCommand;
        expect(resumed?.type, MediaCommandType.play);
        expect(player.shouldStartPlayback, isTrue);
        expect(player.state.position, position);
        expect(player.state.currentQueueId, occurrence);
        player.handleBluetoothOutput(selected);
        expect(player.state.mediaCommand, same(resumed));
      });
    }

    test('requires a disconnection of the selected Bluetooth output', () async {
      await start();
      player.handleBluetoothOutput(selected);
      final playing = player.state.mediaCommand;
      player.handleBluetoothOutput(
          const MusicBluetoothOutputEvent.disconnected('other'));
      expect(player.state.mediaCommand, same(playing));

      player.handleBecomingNoisy();
      final paused = player.state.mediaCommand;
      player.handleBluetoothOutput(
          const MusicBluetoothOutputEvent.selected(null));
      player.handleBluetoothOutput(selected);

      expect(paused?.type, MediaCommandType.pause);
      expect(player.state.mediaCommand, same(paused));
    });

    test('ignores removal of a different port on the same headset', () async {
      await start();
      player.handleBluetoothOutput(
          const MusicBluetoothOutputEvent.selected('headset', portId: 1));
      final playing = player.state.mediaCommand;
      player.handleBluetoothOutput(
          const MusicBluetoothOutputEvent.disconnected('headset', portId: 2));
      expect(player.state.mediaCommand, same(playing));

      player.handleBluetoothOutput(
          const MusicBluetoothOutputEvent.disconnected('headset', portId: 1));
      expect(player.state.mediaCommand?.type, MediaCommandType.pause);
      player.handleBluetoothOutput(
          const MusicBluetoothOutputEvent.selected('headset', portId: 3));
      expect(player.state.mediaCommand?.type, MediaCommandType.play);
    });

    test('waits for temporary audio focus loss to end', () async {
      await start();
      player.handleBluetoothOutput(selected);
      player.handleBluetoothOutput(disconnected);
      final paused = player.state.mediaCommand;
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause));
      player.handleBluetoothOutput(selected);
      expect(player.state.mediaCommand, same(paused));

      player.handleAudioInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.pause));
      expect(player.state.mediaCommand?.type, MediaCommandType.play);
    });

    test('keeps a manually paused song paused on connection and reconnection',
        () async {
      await start();
      player.pause();
      final paused = player.state.mediaCommand;
      player.handleBluetoothOutput(selected);
      player.handleBluetoothOutput(disconnected);
      player.handleBluetoothOutput(selected);

      expect(player.state.mediaCommand, same(paused));
      expect(player.shouldStartPlayback, isFalse);
    });

    for (final stop in [false, true]) {
      test('intervening explicit ${stop ? 'Stop' : 'Pause'} cancels resume',
          () async {
        await start();
        player.handleBluetoothOutput(selected);
        player.handleBluetoothOutput(disconnected);
        if (stop) {
          player.hide();
        } else {
          player.pause();
        }
        final userCommand = player.state.mediaCommand;
        player.handleBluetoothOutput(selected);

        expect(userCommand?.type, MediaCommandType.pause);
        expect(player.state.mediaCommand, same(userCommand));
        expect(player.shouldStartPlayback, isFalse);
      });
    }

    test('a replacement session cannot inherit resume for the same occurrence',
        () async {
      await start();
      final occurrence = player.state.currentQueueId;
      player.handleBluetoothOutput(selected);
      player.handleBluetoothOutput(disconnected);
      await player
          .playVideo([song()], audio: true, fromMusic: true, playing: false);
      expect(player.state.currentQueueId, occurrence);
      final replacement = player.state.mediaCommand;
      player.handleBluetoothOutput(selected);

      expect(player.state.mediaCommand, same(replacement));
      expect(player.shouldStartPlayback, isFalse);
    });

    test('retiring playback for a new profile discards the old resume',
        () async {
      await start();
      final other = await database.createProfile('Other listener');
      player.handleBluetoothOutput(selected);
      player.handleBluetoothOutput(disconnected);
      await player.prepareForProfileSwitch();
      await database.useProfile(other.id);
      await player.reloadForProfile();
      final replacement = player.state.mediaCommand;
      player.handleBluetoothOutput(selected);

      expect(player.state.mediaCommand, same(replacement));
      expect(player.state.hasVideo, isFalse);
    });

    test('does not resume audio from a video', () async {
      await start(music: false);
      player.handleBluetoothOutput(selected);
      player.handleBecomingNoisy();
      final paused = player.state.mediaCommand;
      player.handleBluetoothOutput(disconnected);
      player.handleBluetoothOutput(selected);

      expect(paused?.type, MediaCommandType.pause);
      expect(player.state.mediaCommand, same(paused));
    });
  });

  test('Music can require explicit Play after a temporary focus loss',
      () async {
    await settings.setMusicResumeAfterAudioFocusLoss(false);
    final music = original.copyWith(
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
    player.seed(player.state
        .copyWith(currentlyPlaying: music, videos: [music], isAudio: true));
    final loss = AudioInterruptionEvent(true, AudioInterruptionType.pause);
    final gain = AudioInterruptionEvent(false, AudioInterruptionType.pause);

    player.handleAudioInterruption(loss);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    player.handleAudioInterruption(gain);
    expect(player.shouldStartPlayback, isFalse);

    player.play();
    expect(player.shouldStartPlayback, isTrue);
    player.handleAudioInterruption(loss);
    player.play();
    expect(player.shouldStartPlayback, isFalse);
    player.handleAudioInterruption(gain);
    expect(player.shouldStartPlayback, isTrue);
  });

  test('zero media volume cancels Music resume intent during focus loss',
      () async {
    await settings.setMusicPauseAtZeroVolume(true);
    final music = original.copyWith(
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
    player.seed(player.state
        .copyWith(currentlyPlaying: music, videos: [music], isAudio: true));
    final loss = AudioInterruptionEvent(true, AudioInterruptionType.pause);
    final gain = AudioInterruptionEvent(false, AudioInterruptionType.pause);

    player.handleMediaVolumeChange(0);
    expect(player.shouldStartPlayback, isTrue);
    player.handleMediaVolumeChange(0.5);
    player.handleAudioInterruption(loss);
    player.handleMediaVolumeChange(0);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    player.handleAudioInterruption(gain);
    player.handleMediaVolumeChange(0.5);
    expect(player.shouldStartPlayback, isFalse);
    player.play();
    expect(player.shouldStartPlayback, isTrue);
  });

  test('Music interruption settings leave background video audio unchanged',
      () async {
    await settings.setMusicResumeAfterAudioFocusLoss(false);
    await settings.setMusicPauseAtZeroVolume(true);
    await settings.setMusicResumeOnVolumeRise(true);
    player.switchAudio(true);
    player.handleMediaVolumeChange(0.5);
    player.handleMediaVolumeChange(0);
    player.handleMediaVolumeChange(0.5);
    expect(player.state.mediaCommand?.type, isNot(MediaCommandType.play));
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.shouldStartPlayback, isTrue);
  });

  group('Music volume-rise resume', () {
    late Video music;

    setUp(() async {
      await settings.setMusicPauseAtZeroVolume(true);
      await settings.setMusicResumeOnVolumeRise(true);
      music = original.copyWith(
          musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
      player.seed(player.state
          .copyWith(currentlyPlaying: music, videos: [music], isAudio: true));
    });

    void lowerVolumeToZero() {
      player.handleMediaVolumeChange(0.5);
      player.handleMediaVolumeChange(0);
    }

    test('resumes the same occurrence and playhead once after a volume pause',
        () {
      player.handleMediaVolumeChange(0);
      expect(player.intendsPlayback, isTrue);

      lowerVolumeToZero();
      expect(player.state.mediaCommand!.type, MediaCommandType.pause);
      expect(player.intendsPlayback, isFalse);
      // Native setup can issue a late Play before acknowledging Pause.
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(player.state.mediaCommand!.type, MediaCommandType.pause);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      player.handleMediaVolumeChange(0);
      expect(player.intendsPlayback, isFalse);

      player.handleMediaVolumeChange(0.5);
      final resume = player.state.mediaCommand;
      expect(resume!.type, MediaCommandType.play);
      expect(player.shouldStartPlayback, isTrue);
      expect(player.state.currentQueueId, 'occurrence-1');
      expect(player.state.position, const Duration(seconds: 42));
      player.handleMediaVolumeChange(0.75);
      expect(player.state.mediaCommand, same(resume));
    });

    for (final command in ['already paused', 'pause again', 'stop']) {
      test('media controls take precedence when the user chooses $command',
          () async {
        final handler = MediaHandler(player);
        if (command == 'already paused') await handler.pause();
        lowerVolumeToZero();
        if (command == 'pause again') await handler.pause();
        if (command == 'stop') await handler.stop();

        final pause = player.state.mediaCommand;
        expect(pause!.type, MediaCommandType.pause);
        player.handleMediaVolumeChange(0.5);
        expect(player.state.mediaCommand, same(pause));
        expect(player.intendsPlayback, isFalse);
      });
    }

    test('enabling the preference does not adopt an earlier pause', () async {
      await settings.setMusicResumeOnVolumeRise(false);
      lowerVolumeToZero();
      await settings.setMusicResumeOnVolumeRise(true);
      player.handleMediaVolumeChange(0.5);
      expect(player.intendsPlayback, isFalse);
    });

    test('disabling pause-at-zero cancels automatic resume', () async {
      lowerVolumeToZero();
      await settings.setMusicPauseAtZeroVolume(false);
      player.handleMediaVolumeChange(0.5);
      expect(player.intendsPlayback, isFalse);
    });

    test('does not resume a replacement occurrence of the same song', () async {
      lowerVolumeToZero();
      await player.playVideo([music.copyWith(queueEntryId: 'occurrence-2')],
          fromMusic: true, playing: false);
      expect(player.state.currentQueueId, 'occurrence-2');
      expect(player.intendsPlayback, isFalse);

      player.handleMediaVolumeChange(0.5);
      expect(player.intendsPlayback, isFalse);
    });

    test('does not resume a fresh stream for the same occurrence', () async {
      lowerVolumeToZero();
      final replacement = (await refresh(music))!;
      expect(player.state.currentQueueId, 'occurrence-1');
      expect(replacement.playbackSourceId, isNot(same(music.playbackSourceId)));

      player.handleMediaVolumeChange(0.5);
      expect(player.intendsPlayback, isFalse);
    });

    test('does not resume after an audio mode round trip', () {
      lowerVolumeToZero();
      player.switchAudio(false);
      player.switchAudio(true);
      player.handleMediaVolumeChange(0.5);
      expect(player.intendsPlayback, isFalse);
    });

    test('does not resume after a profile switch', () async {
      final other = await database.createProfile('Other listener');
      lowerVolumeToZero();
      await player.prepareForProfileSwitch();
      await database.useProfile(other.id);
      await player.reloadForProfile();
      await settings.setMusicPauseAtZeroVolume(true);
      await settings.setMusicResumeOnVolumeRise(true);
      player.seed(player.state.copyWith(
          currentlyPlaying: music,
          videos: [music],
          isAudio: true,
          isHidden: false));

      player.handleMediaVolumeChange(0.5);
      expect(player.state.mediaCommand?.type, isNot(MediaCommandType.play));
    });

    test('does not resume after a terminal decoder error', () {
      lowerVolumeToZero();
      player.setEvent(const MediaEvent(state: MediaState.error));
      player.handleMediaVolumeChange(0.5);
      expect(player.intendsPlayback, isFalse);
    });

    test('raising volume during a focus loss leaves Music paused', () {
      const pause = AudioInterruptionType.pause;
      lowerVolumeToZero();
      player.handleAudioInterruption(AudioInterruptionEvent(true, pause));
      player.handleMediaVolumeChange(0.5);
      player.handleAudioInterruption(AudioInterruptionEvent(false, pause));
      expect(player.intendsPlayback, isFalse);
    });
  });

  test('explicit Play while interrupted defers playback until focus returns',
      () {
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    player.pause();
    player.play();
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    expect(player.shouldStartPlayback, isFalse);
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
    expect(player.shouldStartPlayback, isTrue);
  });

  for (final fromAudio in [false, true]) {
    for (final userPause in [false, true]) {
      test(
          'focus return restores a replacement decoder fromAudio=$fromAudio, pause=$userPause',
          () {
        player.switchAudio(fromAudio);
        player.handleAudioInterruption(
            AudioInterruptionEvent(true, AudioInterruptionType.pause));
        // Native interruption pause is not a new user Pause intent.
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.pause));
        player.switchAudio(!fromAudio);
        if (userPause) player.pause();
        final waiting = player.state.mediaCommand;
        expect(player.shouldStartPlayback, isFalse);

        player.handleAudioInterruption(
            AudioInterruptionEvent(false, AudioInterruptionType.pause));
        if (userPause) {
          expect(player.state.mediaCommand, same(waiting));
          expect(player.shouldStartPlayback, isFalse);
        } else {
          expect(player.state.mediaCommand, isNot(same(waiting)));
          expect(player.state.mediaCommand!.type, MediaCommandType.play);
          expect(player.shouldStartPlayback, isTrue);
        }
      });
    }
    test(
        'latest Play survives a decoder switch during focus, fromAudio=$fromAudio',
        () {
      player.switchAudio(fromAudio);
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause));
      player.pause();
      player.play();
      player.switchAudio(!fromAudio);
      player.handleAudioInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.pause));
      expect(player.state.mediaCommand!.type, MediaCommandType.play);
      expect(player.shouldStartPlayback, isTrue);
    });
  }

  for (final userPause in [false, true]) {
    test('duck escalating to pause keeps original intent, userPause=$userPause',
        () {
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.duck));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      if (userPause) player.pause();
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause));
      final waiting = player.state.mediaCommand;
      player.handleAudioInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.pause));
      if (userPause) {
        expect(player.state.mediaCommand, same(waiting));
        expect(player.shouldStartPlayback, isFalse);
      } else {
        expect(player.state.mediaCommand, isNot(same(waiting)));
        expect(player.state.mediaCommand!.type, MediaCommandType.play);
      }
    });

    test(
        'replacement audio remembers blocking pause before duck, Pause=$userPause',
        () {
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      player.switchAudio(true);
      expect(player.shouldStartPlayback, isFalse);
      if (userPause) player.pause();
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.duck));
      final waiting = player.state.mediaCommand;
      player.handleAudioInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.duck));
      if (userPause) {
        expect(player.state.mediaCommand, same(waiting));
        expect(player.shouldStartPlayback, isFalse);
      } else {
        expect(player.state.mediaCommand, isNot(same(waiting)));
        expect(player.state.mediaCommand!.type, MediaCommandType.play);
      }
    });
  }

  test('permanent loss clears a replacement audio focus resume', () {
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    player.setEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.pause));
    player.switchAudio(true);
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    final stopped = player.state.mediaCommand;
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.state.mediaCommand, same(stopped));
    expect(player.shouldStartPlayback, isFalse);
  });

  test('a newer occurrence cannot inherit a nested interruption resume',
      () async {
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck));
    player.setEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.pause));
    await player.switchToVideo(original.copyWith(queueEntryId: 'occurrence-2'));
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    final waiting = player.state.mediaCommand;
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.state.mediaCommand, same(waiting));
  });

  test('focus return does not start a paused or newly selected video',
      () async {
    player.seed(player.state.copyWith(isPlaying: false));
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    final command = player.state.mediaCommand;
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.state.mediaCommand, same(command));
    player.play();
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await player.switchToVideo(original.copyWith(queueEntryId: 'occurrence-2'));
    final changed = player.state.mediaCommand;
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.state.mediaCommand, same(changed));
  });

  test('focus end during a profile switch cannot leave the gate stuck',
      () async {
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await player.prepareForProfileSwitch();
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.playbackInterrupted, isFalse);
    expect(player.state.mediaCommand?.type, isNot(MediaCommandType.play));
  });

  test('audio ducking does not pause an audio source or invent a resume', () {
    player.switchAudio(true);
    final command = player.state.mediaCommand;
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck));
    expect(player.playbackInterrupted, isFalse);
    expect(player.shouldStartPlayback, isTrue);
    expect(player.state.mediaCommand, same(command));
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck));
    expect(player.playbackInterrupted, isFalse);
    expect(player.state.mediaCommand, same(command));
  });

  for (final fromAudio in [false, true]) {
    for (final userPause in [false, true]) {
      test('duck mode switch fromAudio=$fromAudio preserves Pause=$userPause',
          () {
        player.switchAudio(fromAudio);
        player.handleAudioInterruption(
            AudioInterruptionEvent(true, AudioInterruptionType.duck));
        player.switchAudio(!fromAudio);
        // Video remains gated during duck; replacement audio can start as usual.
        expect(player.shouldStartPlayback, !fromAudio);
        if (userPause) player.pause();
        final waiting = player.state.mediaCommand;
        player.handleAudioInterruption(
            AudioInterruptionEvent(false, AudioInterruptionType.duck));
        if (fromAudio && !userPause) {
          expect(player.state.mediaCommand, isNot(same(waiting)));
          expect(player.state.mediaCommand!.type, MediaCommandType.play);
        } else {
          expect(player.state.mediaCommand, same(waiting));
        }
        expect(player.shouldStartPlayback, !userPause);
      });
    }
  }

  test('audio ducking can escalate to a blocking focus interruption', () {
    player.switchAudio(true);
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck));
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    expect(player.playbackInterrupted, isTrue);
    expect(player.shouldStartPlayback, isFalse);
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.playbackInterrupted, isFalse);
  });

  for (final endType in [
    AudioInterruptionType.unknown,
    AudioInterruptionType.pause,
  ]) {
    test('permanent focus loss never restores intent on $endType end', () {
      player.play();
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      player.handleAudioInterruption(AudioInterruptionEvent(false, endType));
      expect(player.shouldStartPlayback, isFalse);
      expect(player.requestedPlaying, isFalse);
      expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    });
  }

  for (final audio in [false, true]) {
    test('explicit Play after permanent loss needs no end event, audio=$audio',
        () async {
      player.switchAudio(audio);
      player.play();
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      expect(player.shouldStartPlayback, isFalse);
      player.play();
      await Future<void>.delayed(Duration.zero);
      expect(player.shouldStartPlayback, isTrue);
      expect(player.state.mediaCommand!.type, MediaCommandType.play);
    });
  }

  test('Pause while permanent-loss focus activation waits cancels playback',
      () async {
    final focus = Completer<bool>();
    activateFocus = () => focus.future;
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    player.play();
    expect(player.shouldStartPlayback, isFalse);
    player.pause();
    focus.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(player.shouldStartPlayback, isFalse);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
  });

  test('denied focus does not play and a later explicit attempt can succeed',
      () async {
    var activations = 0;
    activateFocus = () async => ++activations > 1;
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    player.play();
    await Future<void>.delayed(Duration.zero);
    expect(player.shouldStartPlayback, isFalse);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    player.play();
    await Future<void>.delayed(Duration.zero);
    expect(activations, 2);
    expect(player.shouldStartPlayback, isTrue);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  test('a late focus grant cannot start a replacement occurrence', () async {
    final focus = Completer<bool>();
    var activations = 0;
    activateFocus =
        () => ++activations == 1 ? focus.future : Future.value(true);
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    player.play();
    await player.switchToVideo(original.copyWith(queueEntryId: 'replacement'));
    final replacementCommand = player.state.mediaCommand;
    focus.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(player.state.currentQueueId, 'replacement');
    expect(player.state.mediaCommand, same(replacementCommand));
  });

  test('a new selection after permanent loss stays paused if focus is denied',
      () async {
    var activations = 0;
    activateFocus = () async => ++activations > 1;
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    await player.switchToVideo(original.copyWith(queueEntryId: 'replacement'));
    expect(player.state.currentQueueId, 'replacement');
    expect(player.shouldStartPlayback, isFalse);
    player.play();
    await Future<void>.delayed(Duration.zero);
    expect(activations, 2);
    expect(player.shouldStartPlayback, isTrue);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  test('permanent-loss mode switch reacquires focus without resetting recovery',
      () async {
    final recovered = (await refresh(original))!;
    player.reportPlaybackRecoveryReady(recovered, playing: false);
    player.switchAudio(true);
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    player.play();
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    var activations = 0;
    activateFocus = () async {
      activations++;
      return true;
    };
    player.switchAudio(false);
    await Future<void>.delayed(Duration.zero);
    expect(activations, 1);
    expect(player.shouldStartPlayback, isTrue);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
    expect(await refresh(recovered), isNotNull);
    expect(delays.last, const Duration(seconds: 3));
  });

  test('permanent-loss paused mode switch does not request or resume focus',
      () async {
    player.switchAudio(true);
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    player.pause();
    player.setEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.pause));
    var activations = 0;
    activateFocus = () async {
      activations++;
      return true;
    };
    player.switchAudio(false);
    await Future<void>.delayed(Duration.zero);
    expect(activations, 0);
    expect(player.shouldStartPlayback, isFalse);
  });

  test(
      'permanent-loss focus activation waits for a later temporary interruption',
      () async {
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    var activations = 0;
    activateFocus = () async {
      activations++;
      return true;
    };
    player.play();
    expect(activations, 0);
    expect(player.shouldStartPlayback, isFalse);
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await Future<void>.delayed(Duration.zero);
    expect(activations, 1);
    expect(player.shouldStartPlayback, isTrue);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  test('a stale selection focus grant cannot clear a newer permanent loss',
      () async {
    final focus = Completer<bool>();
    final started = Completer<void>();
    var activations = 0;
    activateFocus = () {
      activations++;
      if (activations == 1) {
        started.complete();
        return focus.future;
      }
      return Future.value(true);
    };
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    final selecting =
        player.switchToVideo(original.copyWith(queueEntryId: 'replacement'));
    await started.future;
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    focus.complete(true);
    await selecting;
    expect(player.shouldStartPlayback, isFalse);
    player.play();
    await Future<void>.delayed(Duration.zero);
    expect(activations, 2);
    expect(player.shouldStartPlayback, isTrue);
  });
}
