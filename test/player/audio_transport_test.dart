import 'dart:async';

import 'package:audio_service/audio_service.dart' show PlaybackState;
import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/audio_playback_sources.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/watch_audio_track.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/audio_player.dart' as view;
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../support/media_companion_transport.dart';
import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _AudioWithoutAutostart extends AudioPlayerCubit {
  _AudioWithoutAutostart(super.initialState, super.player, super.settings);

  @override
  void onInit() {}
}

class _SessionPlayer extends PlayerCubit {
  _SessionPlayer(super.initialState, super.settings);

  @override
  Future<void> onReady() async {}
}

class _TransportPlatform extends JustAudioPlatform {
  final players = <String, _TransportPlayer>{};
  _TransportPlayer? get player => players.values.lastOrNull;

  Iterable<_TransportPlayer> loaded(String trackId) =>
      players.values.where((native) => native.loads.any((load) =>
          _uriSources(load.audioSourceMessage.toMap()).any((source) =>
              Uri.parse(source['uri'] as String).queryParameters['id'] ==
              trackId)));

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      players[request.id] = _TransportPlayer(request.id);

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await players[request.id]?.events.close();
    return DisposePlayerResponse();
  }
}

class _TransportPlayer extends AudioPlayerPlatform {
  final events = StreamController<PlaybackEventMessage>.broadcast();
  final loads = <LoadRequest>[];
  final seeks = <Duration?>[];
  int plays = 0;
  int pauses = 0;
  Completer<void> nextPlay = Completer<void>();
  final firstPause = Completer<void>();

  _TransportPlayer(super.id);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  void report(ProcessingStateMessage state, Duration position) {
    events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: position,
      bufferedPosition: const Duration(seconds: 30),
      duration: const Duration(seconds: 30),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    plays++;
    if (!nextPlay.isCompleted) nextPlay.complete();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    pauses++;
    if (!firstPause.isCompleted) firstPause.complete();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seeks.add(request.position);
    report(ProcessingStateMessage.ready, request.position ?? Duration.zero);
    return SeekResponse();
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loads.add(request);
    events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(seconds: 30),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    return LoadResponse(duration: const Duration(seconds: 30));
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
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

Video _playableVideo(String id, Server server, {bool music = false}) => Video(
      videoId: id,
      title: id,
      author: 'Artist',
      musicMetadata: music ? MusicMetadata(title: id, artist: 'Artist') : null,
      lengthSeconds: 30,
      playbackConnection: BackendPlayback(server),
      playbackSourceId: Object(),
      formatStreams: const [],
      adaptiveFormats: [
        AdaptiveFormat.fromJson({
          'url': '${server.url}/videoplayback?id=$id',
          'itag': '140',
          'type': 'audio/mp4',
          'clen': '300000',
          'lmt': '1',
          'projectionType': 'RECTANGULAR',
        }),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'audio companion approval applies only to the current account and preload',
      () async {
    mockMediaCompanionTransport();
    final originalTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = originalTarget);
    db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    const server = Server(
        url: 'https://instance.example',
        id: 'listener',
        customHeaders: {'X-Private-Test': 'account-only'});
    await db.upsertServer(server);
    await db.useServer(server);
    final base = _playableVideo('scoped', server);
    final local = base.adaptiveFormats!.first;
    const direct = 'https://media.example/videoplayback?q=%2B&itag=140';
    final video = base.copyWith(
      playbackConnection: null,
      adaptiveFormats: [
        AdaptiveFormat.fromJson({...local.toJson(), 'url': direct}),
        local,
        AdaptiveFormat.fromJson(
            {...local.toJson(), 'url': 'https://unselected.example/audio'}),
      ],
    );
    Future<AudioPlaybackSources> resolve([Video? item]) async =>
        (await resolveAudioPlaybackSources(
            video: item ?? video,
            offlineVideo: null,
            sessionId: 'fixture',
            isCurrent: () => true,
            skipDownload: true))!;
    final before = await resolve();
    expect((before.sources.single as UriAudioSource).uri.toString(), local.url);
    await db.setMediaCompanionOrigin(server, 'https://media.example',
        enabled: true);
    final allowed = await resolve();
    final sources = allowed.sources.cast<UriAudioSource>();
    expect(sources.map((s) => s.uri.toString()),
        unorderedEquals([local.url, direct]));
    final foreign = sources.singleWhere((s) => s.uri.host == 'media.example');
    expect(foreign.headers, isNull);
    expect(foreign.mediaCompanions?['origin'], server.url);
    expect(foreign.mediaCompanions?['origins'], ['https://media.example']);
    expect(foreign.mediaCompanions?['gatewayContext'], isA<String>());
    expect((foreign as ProgressiveAudioSource).playbackCache?['origin'],
        server.url);
    final sameHost = sources.singleWhere((s) => s.uri.toString() == local.url);
    expect(sameHost.headers?['X-Private-Test'], 'account-only');

    final prepared = await resolve(video.copyWith(adaptiveFormats: [local]));
    expect(samePreparedAudioSource(prepared, before), isFalse);
    expect(samePreparedAudioSource(allowed, await resolve()), isTrue);
    await db.setMediaCompanionOrigin(server, 'https://media.example',
        enabled: false);
    final revoked = await resolve();
    expect((revoked.sources.single as UriAudioSource).mediaCompanions, isNull);
    expect(samePreparedAudioSource(prepared, revoked), isFalse);
  });

  group('ordinary Watch audio renditions', () {
    const server = Server(url: 'https://instance.example');
    const english = AudioTrack(
        id: 'en.original', displayName: 'English', audioIsDefault: true);
    const french = AudioTrack(id: 'fr.dub', displayName: 'French');

    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      addTearDown(db.close);
      await db.upsertServer(server);
      await db.useServer(server);
    });

    AdaptiveFormat audio(String path, String bitrate, [AudioTrack? track]) =>
        AdaptiveFormat(null, bitrate, null, '${server.url}/$path', '140',
            'audio/mp4', '10000', '1', 'RECTANGULAR', 'mp4', 'aac', null, null,
            audioTrack: track);

    FormatStream muxed(String path, [AudioTrack? track]) => FormatStream(
        '${server.url}/$path',
        '18',
        'video/mp4',
        'medium',
        null,
        null,
        null,
        null,
        null,
        audioTrack: track);

    Future<AudioPlaybackSources> resolve(List<AdaptiveFormat> audio,
            {List<FormatStream> video = const [],
            String? trackId,
            String? progressiveUrl}) async =>
        (await resolveAudioPlaybackSources(
            video: _playableVideo('language001', server)
                .copyWith(adaptiveFormats: audio, formatStreams: video),
            offlineVideo: null,
            sessionId: 'watch-audio-test',
            isCurrent: () => true,
            watchAudio: (trackId: trackId, progressiveUrl: progressiveUrl),
            skipDownload: true))!;

    Iterable<String> paths(AudioPlaybackSources plan) =>
        plan.sources.cast<UriAudioSource>().map((source) => source.uri.path);

    test('default and explicit track decisions precede bitrate ranking',
        () async {
      final formats = [
        audio('french-high', '256000', french),
        audio('english-low', '64000', english),
        audio('english-high', '128000', english),
        audio('french-low', '96000', french),
        audio('untagged', '480000'),
        audio('blocked', '768000',
            const AudioTrack(id: 'blocked', displayName: 'Blocked'))
          ..url = 'https://unrelated.example/blocked',
      ];
      final primary =
          await resolve(formats, video: [muxed('english-video', english)]);
      expect(
          paths(primary), ['/english-high', '/english-low', '/english-video']);
      expect(primary.watchTrackIds.values, everyElement(english.id));
      expect(primary.watchTracks, [
        (id: english.id, label: 'English'),
        (id: french.id, label: 'French'),
      ]);

      final explicit = await resolve(formats,
          video: [muxed('english-video', english)], trackId: french.id);
      expect(paths(explicit), ['/french-high', '/french-low']);
      expect(explicit.watchTrackIds.values, everyElement(french.id));
      expect(explicit.watchTracks, primary.watchTracks);
    });

    test('keeps the exact active muxed audio when no track is proven',
        () async {
      final active = muxed('active-video');
      final formats = [audio('default-audio', '64000', english)];
      final plan = await resolve(formats,
          video: [active, muxed('other-video')],
          progressiveUrl: active.url,
          trackId: 'unavailable-id');
      expect(paths(plan), ['/active-video']);
      expect(plan.watchTrackIds, isEmpty);

      // A stale URL is not admitted just because a previous decoder used it.
      final stale = await resolve(formats,
          video: [active], progressiveUrl: '${active.url}?old-signature');
      expect(paths(stale), ['/default-audio']);
      expect(stale.watchTrackIds.values, [english.id]);
    });

    test('untagged muxed fallback wins over ambiguous dubbed groups', () async {
      const other = AudioTrack(id: 'de.dub', displayName: 'German');
      final formats = [
        audio('french', '256000', french),
        audio('german', '64000', other),
      ];
      final safe = await resolve(formats, video: [muxed('unlabeled')]);
      expect(paths(safe), ['/unlabeled']);
      expect(safe.watchTrackIds, isEmpty);

      for (final audio in [formats, formats.reversed.toList()]) {
        final bounded = await resolve(audio);
        expect(paths(bounded), ['/german']);
        expect(bounded.watchTrackIds.values, [other.id]);
      }
    });

    test('conflicting exact URL identities stay unlabeled', () async {
      final active = FormatStream.fromJson(muxed('same', english).toJson());
      expect(active.audioTrack?.id, english.id);
      final video = Video(videoId: 'language001', formatStreams: [active]);
      expect(watchAudioTrackIdForProgressiveUrl(video, server, active.url),
          english.id);

      final conflict = [active, muxed('same', french)];
      expect(
          watchAudioTrackIdForProgressiveUrl(
              video.copyWith(formatStreams: conflict), server, active.url),
          isNull);
      final plan =
          await resolve([], video: conflict, progressiveUrl: active.url);
      expect(paths(plan), ['/same']);
      expect(plan.watchTracks, isEmpty);
      expect(plan.watchTrackIds, isEmpty);
    });
  });

  for (final completed in [true, false]) {
    test(
        completed
            ? 'native completion followed by automatic pause replays from zero'
            : 'a paused final second resumes without rewinding', () async {
      final originalTarget = debugDefaultTargetPlatformOverride;
      final originalPlatform = JustAudioPlatform.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = _TransportPlatform();
      JustAudioPlatform.instance = platform;
      db = await SembastSqfDb.createInMemory();
      const server = Server(url: 'https://instance.example');
      await db.upsertServer(server);
      await db.useServer(server);
      final app = TestAppCubit(AppState(0, null, HomeLayout()));
      await app.initState();
      app.intentDataStreamSubscription =
          const Stream<void>.empty().listen((_) {});
      final settings = TestSettingsCubit(SettingsState.init(), app);
      await settings.setAutoplayQueue(false);
      final video = _playableVideo('replaymusic1', server);
      final player = TestPlayerCubit(
          PlayerState.init(null).copyWith(
              isAudio: true,
              isHidden: false,
              currentlyPlaying: video,
              videos: [video]),
          settings);
      final audio = _AudioWithoutAutostart(
          AudioPlayerState(video: video), player, settings);
      MediaCommand? lastCommand;
      final commands = player.stream.listen((state) {
        final command = state.mediaCommand;
        if (command != null && command != lastCommand) {
          lastCommand = command;
          audio.handleCommand(command);
        }
      });
      Future<void> flush() async {
        for (var i = 0; i < 16; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      try {
        await audio.playVideo(false, startAt: Duration.zero);
        await platform.player!.nextPlay.future
            .timeout(const Duration(seconds: 5));
        await flush();
        expect(platform.player!.plays, 1);
        platform.player!.report(
            completed
                ? ProcessingStateMessage.completed
                : ProcessingStateMessage.ready,
            Duration(milliseconds: completed ? 30000 : 29900));
        await flush();
        if (!completed) {
          player.pause();
        }
        await platform.player!.firstPause.future
            .timeout(const Duration(seconds: 5));
        await flush();
        expect(audio.audioPlayer!.playing, isFalse);
        expect(platform.player!.pauses, 1);
        expect(player.state.isPlaying, isFalse);
        platform.player!.seeks.clear();
        final previousPlays = platform.player!.plays;
        platform.player!.nextPlay = Completer<void>();
        player.play();
        await platform.player!.nextPlay.future
            .timeout(const Duration(seconds: 5));
        await flush();
        expect(platform.player!.seeks, completed ? [Duration.zero] : isEmpty);
        expect(platform.player!.plays, previousPlays + 1);
        expect(audio.audioPlayer!.processingState, ProcessingState.ready);
      } finally {
        await commands.cancel();
        await audio.close();
        await player.close();
        await settings.close();
        await app.close();
        await db.close();
        JustAudioPlatform.instance = originalPlatform;
        debugDefaultTargetPlatformOverride = originalTarget;
      }
    });
  }

  for (final repeat in [PlayerRepeat.repeatOne, PlayerRepeat.repeatAll]) {
    test('Music $repeat restarts the decoder once on focus gain after EOF',
        () async {
      final originalTarget = debugDefaultTargetPlatformOverride;
      final originalPlatform = JustAudioPlatform.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = _TransportPlatform();
      JustAudioPlatform.instance = platform;
      db = await SembastSqfDb.createInMemory();
      const server = Server(url: 'https://instance.example');
      await db.upsertServer(server);
      await db.useServer(server);
      await db.saveSetting(
          SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
      final app = TestAppCubit(AppState(0, server, HomeLayout()));
      await app.initState();
      app.intentDataStreamSubscription =
          const Stream<void>.empty().listen((_) {});
      final settings = TestSettingsCubit(SettingsState.init(), app);
      await settings.setRepeatMode(repeat);
      final player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      final track = _playableVideo('repeatSong1', server, music: true);
      await player.playVideo([track], audio: true, fromMusic: true);
      final occurrence = player.state.currentQueueId;
      final audio = AudioPlayerCubit(
          AudioPlayerState(video: player.state.currentlyPlaying),
          player,
          settings);
      var previous = player.state.mediaCommand;
      final commands = player.stream.listen((state) {
        final command = state.mediaCommand;
        if (command == null || identical(command, previous)) return;
        previous = command;
        audio.handleCommand(command);
      });
      Iterable<_TransportPlayer> loaded() => platform.loaded(track.videoId);
      int playCount() => loaded().fold(0, (total, p) => total + p.plays);
      Future<void> until(bool Function() ready, String reason) async {
        final deadline = Stopwatch()..start();
        while (!ready() && deadline.elapsed < const Duration(seconds: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(ready(), isTrue, reason: reason);
      }

      void focus(bool begin) {
        final event =
            AudioInterruptionEvent(begin, AudioInterruptionType.pause);
        player.handleAudioInterruption(event);
        audio.handleAudioInterruption(event);
      }

      try {
        await until(() => playCount() == 1 && player.state.isPlaying,
            'The source must be playing before foreground focus changes.');
        final decoder = loaded().single;
        focus(true);
        // just_audio pauses its decoder on focus loss, before the queued EOF.
        await audio.audioPlayer!.pause();
        await until(() => !player.state.isPlaying,
            'The controller must observe the native pause before EOF.');
        decoder.report(
            ProcessingStateMessage.completed, const Duration(seconds: 30));
        await until(() => player.state.mediaEvent.state == MediaState.completed,
            'The focused-out decoder must still report its EOF.');
        expect(playCount(), 1);
        expect(decoder.seeks, isEmpty);
        expect(loaded().expand((p) => p.loads), hasLength(1));

        focus(false);
        focus(false);
        await until(() => playCount() == 2 && player.state.isPlaying,
            'Focus gain must start the repeat from its beginning.');
        await Future<void>.delayed(Duration.zero);
        expect(player.state.currentQueueId, occurrence);
        expect(player.state.playQueue, isEmpty);
        expect(playCount(), 2);
        if (repeat == PlayerRepeat.repeatOne) {
          expect(loaded().expand((p) => p.loads), hasLength(1));
          expect(decoder.seeks, [Duration.zero]);
        } else {
          final loads = loaded().expand((p) => p.loads).toList();
          expect(loads, hasLength(2));
          expect(loads.last.initialPosition ?? Duration.zero, Duration.zero);
        }
      } finally {
        await commands.cancel();
        await audio.close();
        await player.close();
        await settings.close();
        await app.close();
        await db.close();
        JustAudioPlatform.instance = originalPlatform;
        debugDefaultTargetPlatformOverride = originalTarget;
      }
    });
  }

  test(
      'Music prepares both neighbors and promotes the buffered decoder on skip and EOF',
      () async {
    final originalTarget = debugDefaultTargetPlatformOverride;
    final originalPlatform = JustAudioPlatform.instance;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final platform = _TransportPlatform();
    JustAudioPlatform.instance = platform;
    db = await SembastSqfDb.createInMemory();
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    await db.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    final app = TestAppCubit(AppState(0, server, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final player = TestPlayerCubit(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    final tracks = [
      for (final id in ['beforeSong1', 'middleSong2', 'afterSong03'])
        _playableVideo(id, server, music: true),
    ];
    // Mount the same shared audio transport that receives the player's queue
    // commands on the device. Only the native decoder/clock are simulated.
    AudioPlayerCubit? audio;
    MediaCommand? lastCommand;
    final commands = player.stream.listen((state) {
      final command = state.mediaCommand;
      if (command != null && command != lastCommand) {
        lastCommand = command;
        audio?.handleCommand(command);
      }
    });
    final loaded = platform.loaded;
    Future<void> until(bool Function() ready, String reason) async {
      final deadline = Stopwatch()..start();
      while (!ready() && deadline.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(ready(), isTrue, reason: reason);
    }

    try {
      await player.playVideo(tracks, audio: true, startIndex: 1);
      audio = AudioPlayerCubit(
          AudioPlayerState(video: player.state.currentlyPlaying),
          player,
          settings);
      await until(() => loaded(tracks[1].videoId).any((p) => p.plays > 0),
          'The middle song should start normally.');
      await until(
          () =>
              loaded(tracks.first.videoId).isNotEmpty &&
              loaded(tracks.last.videoId).isNotEmpty,
          'Both neighbors should be buffered before any skip.');
      final previous = loaded(tracks.first.videoId).single;
      final next = loaded(tracks.last.videoId).single;
      expect([previous.plays, next.plays], [0, 0]);

      player.playPrevious();
      await until(() => previous.plays > 0,
          'Swiping back should use the prepared player.');
      expect(player.state.currentlyPlaying?.videoId, tracks.first.videoId);
      expect(previous.loads, hasLength(1));

      await until(
          () =>
              loaded(tracks[1].videoId)
                  .any((p) => !p.events.isClosed && p.plays == 0) ||
              loaded(tracks[1].videoId)
                  .any((p) => !p.events.isClosed && p.pauses > 0),
          'The next song should be ready before completion.');
      final bufferedMiddle =
          loaded(tracks[1].videoId).where((p) => !p.events.isClosed).last;
      final playsBeforeEnd = bufferedMiddle.plays;
      final loadsBeforeEnd = bufferedMiddle.loads.length;
      previous.report(
          ProcessingStateMessage.completed, const Duration(seconds: 30));
      await until(() => bufferedMiddle.plays > playsBeforeEnd,
          'The real native completion event should reuse the prepared next player.');
      expect(player.state.currentlyPlaying?.videoId, tracks[1].videoId);
      expect(bufferedMiddle.loads, hasLength(loadsBeforeEnd));
    } finally {
      await commands.cancel();
      await audio?.close();
      await player.close();
      await settings.close();
      await app.close();
      await db.close();
      JustAudioPlatform.instance = originalPlatform;
      debugDefaultTargetPlatformOverride = originalTarget;
    }
  });

  testWidgets('mounted Music transports several songs with the screen off',
      (tester) async {
    await tester.runAsync(() async {
      final originalPlatform = JustAudioPlatform.instance;
      final originalTarget = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = _TransportPlatform();
      JustAudioPlatform.instance = platform;
      db = await SembastSqfDb.createInMemory();
      const server = Server(url: 'https://instance.example');
      await db.upsertServer(server);
      await db.useServer(server);
      await db.saveSetting(
          SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
      final app = TestAppCubit(AppState(0, server, HomeLayout()));
      await app.initState();
      app.intentDataStreamSubscription =
          const Stream<void>.empty().listen((_) {});
      final settings = TestSettingsCubit(SettingsState.init(), app);
      final player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      final handler = app_main.mediaHandler = MediaHandler(player);
      final tracks = [
        for (var i = 1; i <= 5; i++)
          _playableVideo('locked-song-$i', server, music: true)
      ];

      _TransportPlayer? playing(Video track) => platform
          .loaded(track.videoId)
          .where((p) => !p.events.isClosed && p.plays > 0)
          .lastOrNull;

      Future<_TransportPlayer> waitFor(Video track) async {
        final clock = Stopwatch()..start();
        while (clock.elapsed < const Duration(seconds: 3)) {
          final decoder = playing(track);
          if (decoder != null &&
              player.state.currentQueueId == track.videoId &&
              handler.mediaItem.value?.id == track.videoId) {
            return decoder;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError(
            'Music session or native decoder did not reach ${track.videoId}: '
            'queue=${player.state.currentQueueId}, notification=${handler.mediaItem.value?.id}, '
            'playing=${playing(track) != null}.');
      }

      WidgetsBinding.instance.addObserver(player);
      AudioPlayerCubit? mountedTransport;
      StreamSubscription<PlaybackState>? mediaStates;
      try {
        app_main.darkColorScheme = ThemeData.dark().colorScheme;
        await player.playVideo(tracks, audio: true);
        await tester.pumpWidget(MultiBlocProvider(
            providers: [
              BlocProvider<AppCubit>.value(value: app),
              BlocProvider<SettingsCubit>.value(value: settings),
              BlocProvider<PlayerCubit>.value(value: player),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                  body: view.AudioPlayer(
                      video: player.state.currentlyPlaying, miniPlayer: false)),
            )));
        mountedTransport = tester
            .element(find.byType(PlayerControls))
            .read<AudioPlayerCubit>();
        var decoder = await waitFor(tracks.first);
        final reported = <PlaybackState>[];
        mediaStates = handler.playbackState.listen(reported.add);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        var rendered = false;
        tester.binding.addPostFrameCallback((_) => rendered = true);
        expect(tester.binding.framesEnabled, isFalse);
        for (var i = 1; i < tracks.length; i++) {
          if (i == 3) {
            await handler.skipToNext();
          } else {
            decoder.report(
                ProcessingStateMessage.completed, const Duration(seconds: 30));
          }
          decoder = await waitFor(tracks[i]);
          expect(handler.playbackState.value.playing, isTrue);
          expect(rendered, isFalse);
        }
        expect(reported, isNotEmpty);
        expect(reported.map((state) => state.playing), everyElement(isTrue));
      } finally {
        await mediaStates?.cancel();
        WidgetsBinding.instance.removeObserver(player);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        final closed = mountedTransport?.stream.drain<void>();
        await tester.pumpWidget(const SizedBox.shrink());
        await closed;
        await player.close();
        await settings.close();
        await app.close();
        await db.close();
        JustAudioPlatform.instance = originalPlatform;
        debugDefaultTargetPlatformOverride = originalTarget;
      }
    });
  });

  test('Android audio retains instance URI and headers at the native boundary',
      () async {
    final originalTarget = debugDefaultTargetPlatformOverride;
    final originalPlatform = JustAudioPlatform.instance;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final platform = _TransportPlatform();
    JustAudioPlatform.instance = platform;
    db = await SembastSqfDb.createInMemory();
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final player = TestPlayerCubit(PlayerState.init(null), settings);
    final audio =
        _AudioWithoutAutostart(const AudioPlayerState(), player, settings);
    try {
      audio.initPlayer();
      const source = 'https://instance.example/videoplayback?itag=140';
      const headers = {
        'X-Instance-Key': 'test-only',
        'Authorization': 'Bearer test-only',
      };
      await audio.audioPlayer!
          .setAudioSource(AudioSource.uri(Uri.parse(source), headers: headers));

      final sent =
          _uriSources(platform.player!.loads.single.audioSourceMessage.toMap())
              .single;
      expect(sent['uri'], source);
      expect(sent['headers'], headers);
    } finally {
      await audio.close();
      await player.close();
      await settings.close();
      await app.close();
      await db.close();
      JustAudioPlatform.instance = originalPlatform;
      debugDefaultTargetPlatformOverride = originalTarget;
    }
  });
}
