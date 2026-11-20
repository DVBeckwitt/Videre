import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/states/player.dart' as video_player;
import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/podcasts/services/podcast_player.dart';
import 'package:clipious/podcasts/services/podcast_progress_store.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Service extends Service {
  int requests = 0;

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
      String videoId, List<SponsorSegmentType> categories) async {
    requests++;
    return [];
  }
}

class _Platform extends JustAudioPlatform {
  final players = <_NativePlayer>[];
  Completer<void>? holdLoad;
  Duration nextDuration = const Duration(seconds: 60);
  bool completeNextLoad = false;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player =
        _NativePlayer(request.id, holdLoad, nextDuration, completeNextLoad);
    holdLoad = null;
    nextDuration = const Duration(seconds: 60);
    completeNextLoad = false;
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    final player = players.firstWhere((item) => item.id == request.id);
    player.disposed = true;
    await player.events.close();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

class _NativePlayer extends AudioPlayerPlatform {
  final Completer<void>? holdLoad;
  final Duration duration;
  final bool completedLoad;
  final events = StreamController<PlaybackEventMessage>.broadcast();
  final loaded = Completer<void>();
  final loads = <LoadRequest>[];
  final seeks = <Duration?>[];
  final speeds = <double>[];
  int plays = 0;
  int pauses = 0;
  bool disposed = false;
  Completer<void>? delayNextSeek;
  Completer<void>? delayNextSpeed;

  _NativePlayer(super.id, this.holdLoad, this.duration, this.completedLoad);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  void report(ProcessingStateMessage state, Duration position,
      {bool error = false}) {
    if (disposed) return;
    events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: position,
      bufferedPosition: const Duration(seconds: 60),
      duration: duration,
      errorCode: error ? 500 : null,
      errorMessage: error ? 'Decoder failed' : null,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loads.add(request);
    loaded.complete();
    await holdLoad?.future;
    report(
        completedLoad
            ? ProcessingStateMessage.completed
            : ProcessingStateMessage.ready,
        request.initialPosition ?? Duration.zero);
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    plays++;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    pauses++;
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seeks.add(request.position);
    final delay = delayNextSeek;
    delayNextSeek = null;
    await delay?.future;
    report(ProcessingStateMessage.ready, request.position ?? Duration.zero);
    return SeekResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    speeds.add(request.speed);
    final delay = delayNextSpeed;
    delayNextSpeed = null;
    await delay?.future;
    return SetSpeedResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
}

const _episode = PodcastEpisode(
    id: 'episode-one',
    title: 'An episode',
    mediaUrl: 'https://publisher.example/audio.mp3?private=local-only',
    mimeType: 'audio/mpeg',
    durationSeconds: 60);

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Iterable<Map<dynamic, dynamic>> _uriSources(Object? value) sync* {
  if (value is Map) {
    if (value['uri'] is String) yield value;
    for (final child in value.values) {
      yield* _uriSources(child);
    }
  } else if (value is Iterable) {
    for (final child in value) {
      yield* _uriSources(child);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late JustAudioPlatform originalPlatform;
  TargetPlatform? originalTarget;
  late _Platform platform;
  late PodcastPlayer player;
  late BaseAudioHandler handler;
  late String profile;
  late int takeovers;
  late SembastSqfDb progressDatabase;
  late DateTime now;

  PodcastPlayer newPlayer(
          {Future<void> Function()? beforeStart, bool Function()? canPlay}) =>
      PodcastPlayer(
        beforeStart: beforeStart ?? (() async => takeovers++),
        profileId: () => profile,
        canPlay: canPlay ?? (() => true),
        mediaHandler: () => handler,
        progressForProfile: (id) =>
            PodcastProgressStore.forProfile(progressDatabase, id),
        clock: () => now,
        createAudioPlayer: () => AudioPlayer(
            useProxyForRequestHeaders: false,
            handleAudioSessionActivation: false,
            handleInterruptions: false),
      );

  setUp(() async {
    originalPlatform = JustAudioPlatform.instance;
    originalTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    platform = _Platform();
    JustAudioPlatform.instance = platform;
    handler = BaseAudioHandler();
    progressDatabase = await SembastSqfDb.createInMemory();
    profile = progressDatabase.profileId;
    now = DateTime.utc(2026, 11, 15);
    takeovers = 0;
    player = newPlayer();
  });

  tearDown(() async {
    await player.close();
    await progressDatabase.close();
    JustAudioPlatform.instance = originalPlatform;
    debugDefaultTargetPlatformOverride = originalTarget;
  });

  Future<void> start({String? localPath, PodcastEpisode episode = _episode}) =>
      player.playEpisode(
          episode: episode,
          feedTitle: 'Local subscription',
          profileId: profile,
          localPath: localPath);

  test('publisher source is explicit, credential-free, and owns media controls',
      () async {
    await start();
    await _flush();
    final native = platform.players.single;
    final source =
        _uriSources(native.loads.single.audioSourceMessage.toMap()).single;
    expect(source['podcast'], isTrue);
    expect(source['uri'], _episode.mediaUrl);
    expect(source['headers'], isNull);
    expect(takeovers, 1);
    expect(native.plays, 1);
    expect(player.playing, isTrue);
    expect(handler.mediaItem.value!.title, _episode.title);
    expect(handler.mediaItem.value!.artUri, isNull);
    expect(handler.playbackState.value.controls, contains(MediaControl.pause));
    await player.seek(const Duration(seconds: 22));
    await player.setSpeed(1.5);
    await player.pause();
    expect(native.seeks.last, const Duration(seconds: 22));
    expect(native.speeds.last, 1.5);
    expect(handler.playbackState.value.playing, isFalse);
    expect(player.position.inSeconds, 22);
    await player.resume();
    await _flush();
    expect(native.plays, 2);
    await player.stop();
    expect(native.disposed, isTrue);
    expect(handler.mediaItem.value, isNull);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
  });

  test('normal audio sources do not opt into podcast redirect policy',
      () async {
    final ordinary = AudioPlayer(
        useProxyForRequestHeaders: false, handleAudioSessionActivation: false);
    try {
      await ordinary.setAudioSource(AudioSource.uri(
          Uri.parse('https://instance.example/videoplayback'),
          headers: {'X-Videre-Podcast-Source': '1'}));
      final source = _uriSources(
              platform.players.single.loads.single.audioSourceMessage.toMap())
          .single;
      expect(source['podcast'], isNot(true));
    } finally {
      await ordinary.dispose();
    }
  });

  test('Google and FeedBurner sources are rejected before native loading',
      () async {
    for (final host in [
      'youtube.com',
      'google.com',
      'feedproxy.google.com',
      'feeds.feedburner.com'
    ]) {
      await start(
          episode: PodcastEpisode(
              id: 'blocked',
              title: 'Blocked',
              mediaUrl: 'https://$host/audio.mp3',
              mimeType: 'audio/mpeg'));
      expect(player.error, isNotNull);
      expect(platform.players, isEmpty);
    }
  });

  test('downloaded files use file sources without a publisher request',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('videre-podcast-player-');
    final file = File('${directory.path}/episode.audio');
    await file.writeAsBytes([1, 2, 3]);
    try {
      await start(localPath: file.path);
      final source = _uriSources(
              platform.players.single.loads.single.audioSourceMessage.toMap())
          .single;
      expect(Uri.parse(source['uri'] as String).scheme, 'file');
      expect(source['podcast'], isNot(true));
      expect(player.offline, isTrue);
      await player.stop();
      await file.delete();
      await start(localPath: file.path);
      expect(player.error, contains('downloaded'));
      expect(platform.players, hasLength(1));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('pause and latest seek while loading survive source setup', () async {
    final hold = platform.holdLoad = Completer<void>();
    final pending = start();
    while (platform.players.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final native = platform.players.single;
    await native.loaded.future;
    await player.pause();
    await player.seek(const Duration(seconds: 10));
    await player.seek(const Duration(seconds: 25));
    hold.complete();
    await pending;
    await _flush();
    expect(native.plays, 0);
    expect(native.seeks.last, const Duration(seconds: 25));
    expect(player.position, const Duration(seconds: 25));
    expect(player.playing, isFalse);
  });

  test('a speed change during native setup reaches the loaded decoder',
      () async {
    final loadHold = platform.holdLoad = Completer<void>();
    final starting = start();
    while (platform.players.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final native = platform.players.single;
    await native.loaded.future;
    final speedHold = native.delayNextSpeed = Completer<void>();
    final previousSpeedCalls = native.speeds.length;
    loadHold.complete();
    while (native.speeds.length == previousSpeedCalls) {
      await Future<void>.delayed(Duration.zero);
    }
    await player.setSpeed(1.5);
    speedHold.complete();
    await starting;
    expect(player.speed, 1.5);
    expect(native.speeds.last, 1.5);
  });

  test('stop invalidates pending takeover before a decoder can start',
      () async {
    await player.close();
    final hold = Completer<void>();
    player = PodcastPlayer(
        beforeStart: () => hold.future,
        profileId: () => profile,
        canPlay: () => true,
        mediaHandler: () => handler);
    final pending = start();
    await _flush();
    await player.stop();
    hold.complete();
    await pending;
    expect(platform.players, isEmpty);
    expect(player.active, isFalse);
    expect(handler.mediaItem.value, isNull);
  });

  test(
      'pause followed by duck gain releases a deferred source without autoplay during interruption',
      () async {
    final hold = platform.holdLoad = Completer<void>();
    final pending = start();
    while (platform.players.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final native = platform.players.single;
    await native.loaded.future;
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    hold.complete();
    await pending;
    expect(native.plays, 0);
    player.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck));
    player.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck));
    await _flush();
    expect(native.plays, 1);
  });

  test('an inactive profile cannot start or resume another profile episode',
      () async {
    await player.playEpisode(
        episode: _episode, feedTitle: 'Other', profileId: 'other');
    expect(platform.players, isEmpty);
    await start();
    await _flush();
    await player.pause();
    profile = 'another-profile';
    await player.resume();
    expect(platform.players.single.plays, 1);
  });

  test('completed episode replays from zero and seeking clamps to duration',
      () async {
    await start();
    await _flush();
    final native = platform.players.single;
    native.report(
        ProcessingStateMessage.completed, const Duration(seconds: 60));
    await _flush();
    expect(player.playing, isFalse);
    await player.resume();
    await _flush();
    expect(native.seeks, contains(Duration.zero));
    await player.seek(const Duration(seconds: -15));
    expect(native.seeks.last, Duration.zero);
    await player.seek(const Duration(hours: 1));
    expect(native.seeks.last, const Duration(seconds: 60));
  });

  test('pause while replay seek is pending prevents deferred playback',
      () async {
    await start();
    await _flush();
    final native = platform.players.single;
    native.report(
        ProcessingStateMessage.completed, const Duration(seconds: 60));
    await _flush();
    final hold = native.delayNextSeek = Completer<void>();
    final replaying = player.resume();
    while (native.seeks.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await player.pause();
    hold.complete();
    await replaying;
    await _flush();
    expect(native.plays, 1);
    expect(player.playing, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('an old replay seek cannot restart a paused replacement episode',
      () async {
    await start();
    await _flush();
    final native = platform.players.single;
    native.report(
        ProcessingStateMessage.completed, const Duration(seconds: 60));
    await _flush();
    final hold = native.delayNextSeek = Completer<void>();
    final replaying = player.resume();
    while (native.seeks.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await start(
        episode: const PodcastEpisode(
            id: 'replacement',
            title: 'Replacement episode',
            mediaUrl: 'https://publisher.example/replacement.mp3',
            mimeType: 'audio/mpeg'));
    await _flush();
    final replacement = platform.players.last;
    await player.pause();
    hold.complete();
    await replaying;
    await _flush();
    expect(replacement.plays, 1);
    expect(player.episode?.id, 'replacement');
    expect(player.playing, isFalse);
  });

  test(
      'media commands, route-scoped videos, and profile changes share one owner',
      () async {
    await player.close();
    final previousService = service;
    final fakeService = _Service();
    service = fakeService;
    db = await SembastSqfDb.createInMemory();
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final owner =
        TestPlayerCubit(video_player.PlayerState.init(null), settings);
    final routePlayer =
        TestPlayerCubit(video_player.PlayerState.init(null), settings);
    routePlayer.audioSession = await AudioSession.instance;
    final session = app_main.mediaHandler = MediaHandler(owner);
    var decoderStops = 0;
    routePlayer.addBeforeProfileSwitch(() async => decoderStops++);
    player = owner.podcasts;
    profile = db.profileId;
    try {
      await start();
      await _flush();
      expect(player.error, isNull);
      expect(fakeService.requests, 0);
      expect(decoderStops, 1);
      await session.pause();
      await session.seek(const Duration(seconds: 18));
      expect(player.position.inSeconds, 18);
      expect(player.playing, isFalse);
      await session.play();
      await _flush();
      expect(platform.players.single.plays, 2);
      await routePlayer.playVideo([
        const Video(
            videoId: 'normalvideo',
            title: 'Video',
            formatStreams: [],
            adaptiveFormats: [])
      ], audio: true);
      expect(player.active, isFalse);
      expect(platform.players.single.disposed, isTrue);
      await start();
      await _flush();
      expect(player.active, isTrue);
      await session.seek(const Duration(seconds: 27));
      await session.onTaskRemoved();
      expect(player.active, isFalse);
      expect(platform.players.last.disposed, isTrue);
      expect(session.playbackState.value.processingState,
          AudioProcessingState.idle);
      expect(session.mediaItem.value, isNull);
      expect(session.queue.value, isEmpty);
      await start();
      await _flush();
      expect(platform.players.last.loads.single.initialPosition?.inSeconds, 27);
      await owner.prepareForProfileSwitch();
      expect(player.active, isFalse);
      expect(platform.players.last.disposed, isTrue);
      expect(session.mediaItem.value, isNull);
    } finally {
      await owner.close();
      await routePlayer.close();
      await settings.close();
      await app.close();
      await db.close();
      service = previousService;
    }
  });

  test('pause and a fresh controller resume the saved episode position',
      () async {
    await start();
    await player.seek(const Duration(seconds: 42));
    await player.pause();
    await player.close();
    player = newPlayer();
    await start();
    expect(platform.players.last.loads.single.initialPosition!.inSeconds, 42);
    expect(player.position.inSeconds, 42);
  });

  test('streaming and downloaded playback share the same checkpoint', () async {
    await start();
    await player.seek(const Duration(seconds: 37));
    await player.stop();
    final directory =
        await Directory.systemTemp.createTemp('videre-podcast-resume-');
    final file = File('${directory.path}/episode.audio');
    await file.writeAsBytes([1, 2, 3]);
    try {
      await player.close();
      player = newPlayer();
      await start(localPath: file.path);
      expect(player.offline, isTrue);
      expect(platform.players.last.loads.single.initialPosition!.inSeconds, 37);
      expect(
          _uriSources(
                  platform.players.last.loads.single.audioSourceMessage.toMap())
              .single['uri'],
          file.uri.toString());
      await player.stop();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('profile switch flushes the old owner after playback admission closes',
      () async {
    await player.close();
    var admitted = true;
    player = newPlayer(canPlay: () => admitted);
    final originalProfile = profile;
    await start();
    platform.players.last
        .report(ProcessingStateMessage.ready, const Duration(seconds: 41));
    await _flush();
    admitted = false;
    await player.stop();
    final oldStore =
        PodcastProgressStore.forProfile(progressDatabase, originalProfile);
    expect((await oldStore.read(_episode.id))!.position.inSeconds, 41);
    final other = await progressDatabase.createProfile('Other listener');
    profile = other.id;
    await player.close();
    player = newPlayer();
    await start();
    expect(platform.players.last.loads.single.initialPosition, Duration.zero);
    expect((await oldStore.read(_episode.id))!.position.inSeconds, 41);
  });

  test('background checkpoints are throttled to five-second intervals',
      () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await start();
    await _flush();
    now = now.add(const Duration(seconds: 4));
    platform.players.last
        .report(ProcessingStateMessage.ready, const Duration(seconds: 12));
    await _flush();
    expect((await store.read(_episode.id))!.position.inSeconds, 0);
    now = now.add(const Duration(seconds: 1));
    platform.players.last
        .report(ProcessingStateMessage.ready, const Duration(seconds: 13));
    await _flush();
    expect((await store.read(_episode.id))!.position.inSeconds, 13);
  });

  test(
      'near-end positions remain resumable, completion resets, and rewind clears completion',
      () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await start();
    await player.seek(const Duration(seconds: 58));
    await player.stop();
    await start();
    expect(platform.players.last.loads.single.initialPosition!.inSeconds, 58);
    platform.players.last
        .report(ProcessingStateMessage.completed, const Duration(seconds: 60));
    await _flush();
    expect((await store.read(_episode.id))!.completed, isTrue);
    await player.stop();
    await start();
    expect(platform.players.last.loads.single.initialPosition, Duration.zero);
    platform.players.last
        .report(ProcessingStateMessage.completed, const Duration(seconds: 60));
    await _flush();
    await player.seek(const Duration(seconds: 45));
    await player.stop();
    await start();
    expect(platform.players.last.loads.single.initialPosition!.inSeconds, 45);
    expect((await store.read(_episode.id))!.completed, isFalse);
  });

  test('native duration resets a stale EOF checkpoint without losing autoplay',
      () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await store.save(
        _episode.id,
        const PodcastProgress(
            position: Duration(seconds: 90),
            duration: Duration(seconds: 100),
            completed: false));
    platform.completeNextLoad = true;
    await start();
    await _flush();
    expect(platform.players.single.loads.single.initialPosition,
        const Duration(seconds: 90));
    expect(platform.players.single.seeks, contains(Duration.zero));
    expect(platform.players.single.plays, 1);
    expect(player.position.inSeconds, 0);
  });

  test('RSS duration does not truncate a valid native resume position',
      () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await store.save(
        _episode.id,
        const PodcastProgress(
            position: Duration(seconds: 90),
            duration: Duration(seconds: 150),
            completed: false));
    platform.nextDuration = const Duration(seconds: 150);
    await start(); // RSS metadata says 60 seconds, actual file is 150 seconds.
    expect(platform.players.single.loads.single.initialPosition,
        const Duration(seconds: 90));
    expect(player.position.inSeconds, 90);
  });

  test(
      'decoder failure and a missing offline file cannot erase the last position',
      () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await start();
    await player.seek(const Duration(seconds: 42));
    platform.players.last
        .report(ProcessingStateMessage.ready, Duration.zero, error: true);
    await _flush();
    expect(player.error, isNotNull);
    await player.stop();
    expect((await store.read(_episode.id))!.position.inSeconds, 42);
    final directory =
        await Directory.systemTemp.createTemp('videre-missing-podcast-');
    try {
      await start(localPath: '${directory.path}/missing.audio');
      expect(player.error, isNotNull);
      await player.stop();
      expect((await store.read(_episode.id))!.position.inSeconds, 42);
      await start();
      expect(platform.players.last.loads.single.initialPosition!.inSeconds, 42);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
      'stop during initial load preserves resume unless an explicit rewind was requested',
      () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    for (final rewind in [false, true]) {
      await store.save(
          _episode.id,
          const PodcastProgress(
              position: Duration(seconds: 35),
              duration: Duration(seconds: 60),
              completed: false));
      final hold = platform.holdLoad = Completer<void>();
      final starting = start();
      final count = platform.players.length;
      while (platform.players.length == count) {
        await Future<void>.delayed(Duration.zero);
      }
      await platform.players.last.loaded.future;
      if (rewind) await player.seek(Duration.zero);
      final stopping = player.stop();
      hold.complete();
      await Future.wait([starting, stopping]);
      expect(
          (await store.read(_episode.id))!.position.inSeconds, rewind ? 0 : 35);
    }
  });

  test('an explicit rewind before takeover finishes survives Stop', () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await store.save(
        _episode.id,
        const PodcastProgress(
            position: Duration(seconds: 35),
            duration: Duration(seconds: 60),
            completed: false));
    await player.close();
    final hold = Completer<void>();
    player = newPlayer(beforeStart: () => hold.future);
    final starting = start();
    await _flush();
    await player.seek(Duration.zero);
    await player.stop();
    hold.complete();
    await starting;
    expect((await store.read(_episode.id))!.position, Duration.zero);
  });

  test(
      'new controller reads the same episode after previous takeover stop commits',
      () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await start();
    await player.seek(const Duration(seconds: 42));
    platform.players.last
        .report(ProcessingStateMessage.ready, const Duration(seconds: 47));
    await _flush();
    expect((await store.read(_episode.id))!.position.inSeconds, 42);
    final previous = player;
    player = newPlayer(beforeStart: previous.stop);
    try {
      await start();
      expect(platform.players.last.loads.single.initialPosition!.inSeconds, 47);
    } finally {
      await previous.close();
    }
  });

  test('an older failed seek cannot cancel a newer saved seek', () async {
    final store = PodcastProgressStore.forProfile(progressDatabase, profile);
    await start();
    final native = platform.players.single;
    final hold = native.delayNextSeek = Completer<void>();
    final first = player.seek(const Duration(seconds: 10));
    while (native.seeks.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await player.seek(const Duration(seconds: 20));
    hold.completeError(StateError('Old seek failed'));
    await first;
    expect(player.error, isNull);
    expect((await store.read(_episode.id))!.position.inSeconds, 20);
  });
}
