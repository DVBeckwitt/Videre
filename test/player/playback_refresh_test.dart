import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
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
