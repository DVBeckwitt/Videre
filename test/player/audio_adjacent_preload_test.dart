import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/replay_gain.dart';
import 'package:clipious/music/models/song_transition.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/manual_music_preparation.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/music_audio_quality.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart'
    show PlayerException, ProcessingState;
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _server = Server(url: 'https://instance.example');

Video _song(String id) => Video(
        videoId: id,
        title: id,
        lengthSeconds: 120,
        queueEntryId: 'queue-$id',
        playbackConnection: BackendPlayback(_server),
        playbackSourceId: Object(),
        musicMetadata: MusicMetadata(title: id, artist: 'Artist'),
        adaptiveFormats: [
          AdaptiveFormat(
              null,
              '128000',
              null,
              '${_server.url}/$id',
              '140',
              'audio/mp4',
              '100',
              '1',
              'RECTANGULAR',
              'mp4',
              'mp4a',
              null,
              null),
        ]);

class _Queue extends TestPlayerCubit {
  final listeners = <ValueChanged<List<IdedVideo>>>{};
  final events = <MediaEvent>[];
  @override
  IdedVideo? automaticMusicSuccessor;
  @override
  bool isCommittingMusicSelection = false;
  MediaCommand? committedCommand;
  @override
  bool isManualMusicSelectionCommand(MediaCommand command) =>
      isCommittingMusicSelection && identical(command, committedCommand);
  String? automaticTarget;
  _Queue(super.initialState, super.settings);

  @override
  bool isAutomaticMusicHandoffTo(String queueId) => queueId == automaticTarget;

  @override
  void addAdjacentMusicListener(ValueChanged<List<IdedVideo>> listener) =>
      listeners.add(listener);

  @override
  void removeAdjacentMusicListener(ValueChanged<List<IdedVideo>> listener) =>
      listeners.remove(listener);

  void publish(List<IdedVideo> adjacent) {
    for (final listener in listeners.toList()) {
      listener(adjacent);
    }
  }

  void select(Video video) => emit(state.copyWith(currentlyPlaying: video));

  void selectLocal(DownloadedVideo song, List<DownloadedVideo> queue) =>
      emit(state.copyWith(
          videos: [],
          currentlyPlaying: null,
          offlineVideos: queue,
          offlineCurrentlyPlaying: song));

  @override
  void setEvent(MediaEvent event) {
    final successor = automaticMusicSuccessor;
    if (event.state == MediaState.completed && successor != null) {
      automaticTarget = playbackQueueId(successor);
    }
    events.add(event);
    emit(state.copyWith(mediaEvent: event));
  }
}

class _Decoder {
  final String id;
  final Map<Object?, Object?>? androidLoadControl;
  final loads = <String>[];
  final playedTracks = <String>[];
  final playVolumes = <double>[];
  final playMusicGains = <double>[];
  final playPositions = <Duration>[];
  Duration position = Duration.zero;
  final volumes = <double>[];
  final seeks = <Duration>[];
  final loadPositions = <Duration>[];
  double get volume => volumes.lastOrNull ?? 1;
  double speed = 1;
  double pitch = 1;
  double musicGain = 1;
  bool playing = false;
  int pauses = 0;
  bool disposed = false;
  _Decoder(this.id, this.androidLoadControl);

  MethodChannel get channel =>
      MethodChannel('com.ryanheise.just_audio.methods.$id');
  MethodChannel get events =>
      MethodChannel('com.ryanheise.just_audio.events.$id');
  MethodChannel get data => MethodChannel('com.ryanheise.just_audio.data.$id');

  Future<void> report(ProcessingStateMessage state, Duration position) async {
    const duration = Duration(minutes: 2);
    this.position = position;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            events.name,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'processingState': state.index,
              'updateTime': DateTime.now().millisecondsSinceEpoch,
              'updatePosition': position.inMicroseconds,
              'bufferedPosition': duration.inMicroseconds,
              'duration': duration.inMicroseconds,
              'currentIndex': 0,
            }),
            (_) {});
  }
}

Future<void> _until(bool Function() predicate, String description) async {
  final elapsed = Stopwatch()..start();
  while (!predicate() && elapsed.elapsed < const Duration(seconds: 4)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue, reason: description);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mainChannel = MethodChannel('com.ryanheise.just_audio.methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Queue player;
  late AudioPlayerCubit audio;
  late Video current;
  late Video next;
  late Video previous;
  late List<_Decoder> decoders;
  late TargetPlatform? originalTarget;
  Completer<void>? loadGate;
  String? heldTrack;
  String? failingTrack;
  late Set<String> retryableTracks;
  late Set<String> blockedTracks;

  Iterable<_Decoder> loaded(String id) =>
      decoders.where((d) => d.loads.contains(id));

  setUp(() async {
    originalTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    decoders = [];
    loadGate = null;
    heldTrack = null;
    failingTrack = null;
    retryableTracks = {};
    blockedTracks = {};
    messenger.setMockMethodCallHandler(mainChannel, (call) async {
      if (call.method == 'init') {
        final configuration = call.arguments['audioLoadConfiguration'] as Map?;
        final decoder = _Decoder(call.arguments['id'] as String,
            configuration?['androidLoadControl'] as Map<Object?, Object?>?);
        decoder.musicGain =
            (call.arguments['androidMusicGain'] as num?)?.toDouble() ?? 1;
        decoders.add(decoder);
        messenger.setMockMethodCallHandler(decoder.events, (_) async => null);
        messenger.setMockMethodCallHandler(decoder.data, (_) async => null);
        messenger.setMockMethodCallHandler(decoder.channel, (method) async {
          if (method.method == 'load') {
            final playlist = method.arguments['audioSource'] as Map;
            final child = (playlist['children'] as List).single as Map;
            final id = Uri.parse(child['uri'] as String).pathSegments.last;
            decoder.loads.add(id);
            final start = Duration(
                microseconds: method.arguments['initialPosition'] as int? ?? 0);
            decoder.loadPositions.add(start);
            if (id == heldTrack) await loadGate?.future;
            if (retryableTracks.contains(id) || blockedTracks.contains(id)) {
              throw PlatformException(
                  code: '2002',
                  message: 'Stream unavailable: $id',
                  details: {
                    'backendRetryable': retryableTracks.contains(id),
                    'mediaOriginBlocked': blockedTracks.contains(id),
                    'index': 0
                  });
            }
            if (id == failingTrack) {
              throw PlatformException(code: '400', message: 'Warm load failed');
            }
            const duration = Duration(minutes: 2);
            if (!decoder.disposed) {
              await decoder.report(ProcessingStateMessage.ready, start);
            }
            return {'duration': duration.inMicroseconds};
          }
          if (method.method == 'play') {
            decoder.playing = true;
            decoder.playVolumes.add(decoder.volume);
            decoder.playMusicGains.add(decoder.musicGain);
            decoder.playPositions.add(decoder.position);
            decoder.playedTracks.add(decoder.loads.last);
          }
          if (method.method == 'pause') {
            decoder.playing = false;
            decoder.pauses++;
          }
          if (method.method == 'setVolume') {
            decoder.volumes.add((method.arguments['volume'] as num).toDouble());
          }
          if (method.method == 'setAndroidMusicGain') {
            decoder.musicGain = (method.arguments['gain'] as num).toDouble();
          }
          if (method.method == 'setSpeed') {
            decoder.speed = method.arguments['speed'] as double;
          }
          if (method.method == 'setPitch') {
            decoder.pitch = method.arguments['pitch'] as double;
          }
          if (method.method == 'seek') {
            final position =
                Duration(microseconds: method.arguments['position'] as int);
            decoder.seeks.add(position);
            await decoder.report(ProcessingStateMessage.ready, position);
          }
          return <String, Object?>{};
        });
      }
      if (call.method == 'disposePlayer') {
        decoders.firstWhere((d) => d.id == call.arguments['id']).disposed =
            true;
      }
      return <String, Object?>{};
    });
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(_server);
    await db.useServer(_server);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    current = _song('current');
    previous = _song('previous');
    next = _song('next');
    player = _Queue(
        PlayerState.init([previous, current, next]).copyWith(
            isPlaying: true,
            isAudio: true,
            isHidden: false,
            currentlyPlaying: current),
        settings);
    audio =
        AudioPlayerCubit(AudioPlayerState(video: current), player, settings);
    await _until(
        () => loaded('current').any((d) => d.playedTracks.contains('current')),
        'Current song starts playing');
  });

  tearDown(() async {
    if (loadGate != null && !loadGate!.isCompleted) loadGate!.complete();
    await audio.close();
    expect(player.listeners, isEmpty);
    expect(decoders.every((decoder) => decoder.disposed), isTrue);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    messenger.setMockMethodCallHandler(mainChannel, null);
    for (final decoder in decoders) {
      messenger.setMockMethodCallHandler(decoder.channel, null);
      messenger.setMockMethodCallHandler(decoder.events, null);
      messenger.setMockMethodCallHandler(decoder.data, null);
    }
    debugDefaultTargetPlatformOverride = originalTarget;
  });

  Future<(_Decoder, _Decoder)> prepareTransition(SongTransitionMode mode,
      {int seconds = 1}) async {
    await settings.setSongTransitionSeconds(seconds);
    await settings.setSongTransitionMode(mode);
    player.automaticMusicSuccessor = next;
    player.publish([next]);
    await _until(() => loaded('next').isNotEmpty, 'Next song was preloaded');
    return (loaded('current').single, loaded('next').single);
  }

  void expectOriginalPlaying(_Decoder original) {
    expect(original.playing, isTrue);
    expect(original.disposed, isFalse);
    expect(original.loads, [current.videoId]);
    expect(original.playedTracks, [current.videoId]);
    expect(original.pauses, 0);
    expect(original.seeks, isEmpty);
    expect(audio.state.video?.queueEntryId, current.queueEntryId);
    expect(player.state.currentQueueId, current.queueEntryId);
  }

  MediaCommand switchCommand(Video song, Duration startAt) =>
      MediaCommand(MediaCommandType.switchVideo,
          value: SwitchVideoValue(video: song, startAt: startAt));

  void commitManual(Video song, {Duration startAt = Duration.zero}) {
    final command = switchCommand(song, startAt);
    player.committedCommand = command;
    player.isCommittingMusicSelection = true;
    try {
      player.select(song);
      audio.handleCommand(command);
    } finally {
      player.isCommittingMusicSelection = false;
      player.committedCommand = null;
    }
  }

  test(
      'a queued stale switch to the same song and offset cannot consume the committed decoder',
      () async {
    final old = loaded('current').single;
    const at = Duration(seconds: 15);
    final stale = switchCommand(next, at);
    expect(await audio.prepareMusicSelection(next, at, () => true), isTrue);
    final reserved = loaded('next').single;
    final beforePauses = reserved.pauses;
    final beforeSeeks = List.of(reserved.seeks);

    final committed = switchCommand(next, at);
    player.select(next);
    player.isCommittingMusicSelection = true;
    player.committedCommand = committed;
    try {
      audio.handleCommand(stale);
      await Future<void>.delayed(Duration.zero);
      expect(audio.state.video?.queueEntryId, current.queueEntryId);
      expect(old.disposed, isFalse);
      expect(old.playing, isTrue);
      expect(old.loads, [current.videoId]);
      expect(old.playedTracks, [current.videoId]);
      expect(old.pauses, 0);
      expect(old.seeks, isEmpty);
      expect(reserved.loads, [next.videoId]);
      expect(reserved.playedTracks, isEmpty);
      expect(reserved.pauses, beforePauses);
      expect(reserved.seeks, beforeSeeks);
      expect(decoders, hasLength(2));
      audio.handleCommand(committed);
    } finally {
      player.isCommittingMusicSelection = false;
      player.committedCommand = null;
    }
    await _until(() => reserved.playedTracks.isNotEmpty,
        'The exact switch command promotes the reserved decoder');
    expect(old.disposed, isTrue);
    expect(reserved.loads, [next.videoId]);
    expect(reserved.playedTracks, [next.videoId]);
    expect(audio.audioPlayer!.position, greaterThanOrEqualTo(at));
  });

  test(
      'manual selection keeps the current decoder audible until a prepared alternate source is committed',
      () async {
    final original = loaded('current').single;
    const at = Duration(seconds: 23);
    final selected = next.copyWith(adaptiveFormats: [
      ...next.adaptiveFormats!,
      AdaptiveFormat(null, '64000', null, '${_server.url}/alternate', '139',
          'audio/mp4', '100', '1', 'RECTANGULAR', 'mp4', 'mp4a', null, null),
    ]);
    retryableTracks.add(next.videoId);
    heldTrack = 'alternate';
    loadGate = Completer<void>();
    final prepared = audio.prepareMusicSelection(selected, at, () => true);
    await _until(() => loaded('alternate').isNotEmpty,
        'Manual preparation reaches the second format after the first fails');
    final staged = loaded('alternate').single;
    expect(staged, isNot(same(original)));
    expectOriginalPlaying(original);
    expect(staged.playedTracks, isEmpty);
    await original.report(
        ProcessingStateMessage.ready, const Duration(seconds: 32));
    await _until(
        () => audio.audioPlayer!.position >= const Duration(seconds: 32),
        'The original song advances during the alternate source load');
    loadGate!.complete();
    expect(await prepared, isTrue);
    expectOriginalPlaying(original);
    expect(staged.playedTracks, isEmpty);
    expect([...staged.loadPositions, ...staged.seeks], contains(at));
    final previousLoads =
        decoders.fold<int>(0, (total, d) => total + d.loads.length);
    commitManual(selected, startAt: at);
    await _until(() => staged.playedTracks.contains('alternate'),
        'Commit plays the prepared alternate rendition');
    expect(decoders.fold<int>(0, (total, d) => total + d.loads.length),
        previousLoads);
    expect(staged.playedTracks, ['alternate']);
    expect(original.disposed, isTrue);
    expect(audio.audioPlayer!.position, greaterThanOrEqualTo(at));
    expect(audio.state.error, isNull);
  });

  for (final cancel in [false, true]) {
    test(
        'a ${cancel ? 'cancelled' : 'failed'} manual load leaves the audible song untouched',
        () async {
      final original = loaded('current').single;
      heldTrack = next.videoId;
      loadGate = Completer<void>();
      if (!cancel) failingTrack = next.videoId;
      var currentRequest = true;
      final prepared = audio.prepareMusicSelection(
          next, Duration.zero, () => currentRequest);
      await _until(
          () => loaded('next').isNotEmpty, 'A separate source is loading');
      final staged = loaded('next').single;
      expectOriginalPlaying(original);
      if (cancel) {
        currentRequest = false;
        audio.cancelMusicSelection();
        await _until(() => staged.disposed,
            'Cancel releases the still-loading candidate');
      }
      loadGate!.complete();
      expect(await prepared, isFalse);
      await _until(() => staged.disposed, 'Rejected candidate was released');
      expect(staged.playedTracks, isEmpty);
      expectOriginalPlaying(original);
      expect(player.events.where((e) => e.state == MediaState.error), isEmpty);
      expect(audio.state.error, isNull);
    });
  }

  test(
      'a blocked manual selection tries remaining formats without rotating the playing song',
      () async {
    final original = loaded('current').single;
    final selected = next.copyWith(adaptiveFormats: [
      ...next.adaptiveFormats!,
      AdaptiveFormat(null, '64000', null, '${_server.url}/last', '139',
          'audio/mp4', '100', '1', 'RECTANGULAR', 'mp4', 'mp4a', null, null),
    ]);
    blockedTracks.addAll(['next', 'last']);
    expect(
        await audio.prepareMusicSelection(selected, Duration.zero, () => true),
        isFalse);
    expect(loaded('last'), hasLength(1));
    expectOriginalPlaying(original);
    expect(player.events.where((event) => event.state == MediaState.error),
        isEmpty);
  });

  test('a blocked manual source cannot open a fallback with stale credentials',
      () async {
    final original = loaded('current').single;
    final selected = next.copyWith(adaptiveFormats: [
      ...next.adaptiveFormats!,
      AdaptiveFormat(null, '64000', null, '${_server.url}/last', '139',
          'audio/mp4', '100', '1', 'RECTANGULAR', 'mp4', 'mp4a', null, null),
    ]);
    blockedTracks.add('next');
    heldTrack = 'next';
    final held = loadGate = Completer<void>();
    try {
      final pending =
          audio.prepareMusicSelection(selected, Duration.zero, () => true);
      await _until(() => loaded('next').isNotEmpty, 'First source is loading');
      await db.upsertServer((await db.getCurrentlySelectedServer())
          .copyWith(authToken: 'changed-test-token'));
      held.complete();
      expect(await pending, isFalse);
      expect(loaded('last'), isEmpty);
      expectOriginalPlaying(original);
    } finally {
      if (!held.isCompleted) held.complete();
    }
  });

  test(
      'exhausting retryable native sources releases the manual slot and reports the final cause',
      () async {
    final original = loaded('current').single;
    final selected = next.copyWith(adaptiveFormats: [
      ...next.adaptiveFormats!,
      AdaptiveFormat(null, '64000', null, '${_server.url}/last', '139',
          'audio/mp4', '100', '1', 'RECTANGULAR', 'mp4', 'mp4a', null, null),
    ]);
    retryableTracks.addAll(['next', 'last']);
    heldTrack = 'last';
    loadGate = Completer<void>();
    final pending =
        audio.prepareMusicSelection(selected, Duration.zero, () => true);
    final checkedFailure = expectLater(
        pending,
        throwsA(isA<ManualMusicSourceFailure>().having(
            (e) => e.cause,
            'cause',
            isA<PlayerException>()
                .having((e) => e.backendRetryable, 'retryable', isTrue)
                .having((e) => e.message, 'last failed rendition',
                    contains('last')))));
    await _until(
        () => loaded('last').isNotEmpty, 'All admitted formats were attempted');
    expectOriginalPlaying(original);
    final failedDecoder = loaded('last').single;
    loadGate!.complete();
    await checkedFailure;
    expectOriginalPlaying(original);
    expect(failedDecoder.playedTracks, isEmpty);
    expect(player.events.where((e) => e.state == MediaState.error), isEmpty);

    // The same occurrence can be prepared again immediately with fresh media.
    retryableTracks.clear();
    expect(
        await audio.prepareMusicSelection(selected, Duration.zero, () => true),
        isTrue);
    commitManual(selected);
    await _until(
        () => loaded('next')
            .any((d) => d != failedDecoder && d.playedTracks.contains('next')),
        'A fresh decoder owns the retried selection');
    expect(failedDecoder.disposed, isTrue);
  });

  test(
      'a later manual tap wins even if the first decoder finishes loading last',
      () async {
    final original = loaded('current').single;
    heldTrack = next.videoId;
    loadGate = Completer<void>();
    var target = next;
    final first = audio.prepareMusicSelection(
        next, Duration.zero, () => identical(target, next));
    await _until(
        () => loaded('next').isNotEmpty, 'The first selection is in flight');
    final stale = loaded('next').single;
    target = previous;
    const start = Duration(seconds: 8);
    final second = audio.prepareMusicSelection(
        previous, start, () => identical(target, previous));
    expect(await second.timeout(const Duration(seconds: 4)), isTrue);
    final winner = loaded('previous').single;
    expectOriginalPlaying(original);
    commitManual(previous, startAt: start);
    await _until(() => winner.playedTracks.contains('previous'),
        'Latest selection starts without waiting for the earlier load');
    loadGate!.complete();
    expect(await first, isFalse);
    expect(stale.playedTracks, isEmpty);
    expect(stale.disposed, isTrue);
    expect(winner.loads, ['previous']);
    expect(winner.playedTracks, ['previous']);
    expect(audio.state.video?.queueEntryId, previous.queueEntryId);
  });

  test(
      'a manually prepared song survives the previous queue automatically advancing',
      () async {
    final selected = _song('manual');
    final first = loaded('current').single;
    heldTrack = selected.videoId;
    loadGate = Completer<void>();
    final pending =
        audio.prepareMusicSelection(selected, Duration.zero, () => true);
    await _until(() => loaded('manual').isNotEmpty,
        'Manual candidate is preparing independently');
    final staged = loaded('manual').single;
    await first.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await _until(
        () => player.events.any((event) => event.state == MediaState.completed),
        'The old queue can complete normally');
    player.automaticTarget = next.queueEntryId;
    player.select(next);
    audio.switchVideo(next);
    await _until(
        () => loaded('next').any((d) => d.playedTracks.contains('next')),
        'The old queue advances before the manual candidate is ready');
    expect(staged.playedTracks, isEmpty);

    loadGate!.complete();
    expect(await pending, isTrue);
    player.automaticTarget = null;
    commitManual(selected);
    await _until(() => staged.playedTracks.contains('manual'),
        'Only the explicit manual commit promotes the candidate');
    expect(staged.loads, ['manual']);
    expect(staged.playedTracks, ['manual']);
    expect(audio.state.video?.queueEntryId, selected.queueEntryId);
  });

  test(
      'automatic advancement to the same occurrence leaves the ready manual decoder reserved',
      () async {
    final outgoing = loaded('current').single;
    expect(await audio.prepareMusicSelection(next, Duration.zero, () => true),
        isTrue);
    final reserved = loaded('next').single;
    expectOriginalPlaying(outgoing);
    player.automaticMusicSuccessor = next;
    await outgoing.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await _until(() => player.isAutomaticMusicHandoffTo(next.queueEntryId!),
        'The natural queue boundary selected the same occurrence');
    player.select(next);
    audio.switchVideo(next, startAt: Duration.zero);
    await _until(
        () => loaded('next').any((d) => d.playedTracks.contains('next')),
        'Natural handoff reached a playing decoder');
    expect(reserved.playedTracks, isEmpty);
    expect(reserved.disposed, isFalse);
    final automatic = loaded('next').singleWhere((d) => d != reserved);
    expect(automatic.playedTracks.last, 'next');

    commitManual(next);
    await _until(() => reserved.playedTracks.contains('next'),
        'Only the matching manual commit consumed the reservation');
    expect(reserved.loads, ['next']);
    expect(reserved.playedTracks, ['next']);
    expect(automatic.disposed, isTrue);
  });

  Future<(_Decoder, _Decoder)> overlap() async {
    final (outgoing, incoming) =
        await prepareTransition(SongTransitionMode.crossfade);
    await outgoing.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 119450));
    await _until(
        () => incoming.playing && outgoing.volume < 1 && incoming.volume > 0,
        'Both decoders are audible before the outgoing song completes');
    return (outgoing, incoming);
  }

  for (final seconds in [0, 23]) {
    test(
        'cancelling a manual selection at ${seconds}s preserves the automatic successor crossfade',
        () async {
      await settings.setSongTransitionMode(SongTransitionMode.crossfade);
      await settings.setSongTransitionSeconds(1);
      player.automaticMusicSuccessor = next;
      player.publish([next, previous]);
      await _until(
          () => loaded('next').isNotEmpty && loaded('previous').isNotEmpty,
          'Both adjacent songs were prepared');
      final original = loaded('current').single;
      final nextNeighbor = loaded('next').single;
      final previousNeighbor = loaded('previous').single;

      expect(
          await audio.prepareMusicSelection(
              next, Duration(seconds: seconds), () => true),
          isTrue);
      audio.cancelMusicSelection();
      expectOriginalPlaying(original);
      // The queue did not change, so it won't publish its neighbors again.
      await original.report(
          ProcessingStateMessage.ready, const Duration(milliseconds: 119450));
      await _until(
          () =>
              loaded('next')
                  .any((d) => d.playing && !d.disposed && d.volume > 0) &&
              original.volume < 1,
          'The automatic successor still overlaps the original song before EOF');
      final successor =
          loaded('next').singleWhere((d) => d.playing && !d.disposed);
      expect(successor, same(nextNeighbor));
      expect(nextNeighbor.loads, [next.videoId]);
      expect(successor.playPositions.single, Duration.zero);
      expect(player.state.currentQueueId, current.queueEntryId);
      expect(loaded('previous'), [previousNeighbor]);
      expect(previousNeighbor.disposed, isFalse);
      expect(previousNeighbor.playedTracks, isEmpty);
    });
  }

  test(
      'cancelling a zero-position selection returns its still-loading neighbor to the crossfade',
      () async {
    await settings.setSongTransitionMode(SongTransitionMode.crossfade);
    await settings.setSongTransitionSeconds(1);
    heldTrack = next.videoId;
    loadGate = Completer<void>();
    player.automaticMusicSuccessor = next;
    player.publish([next]);
    await _until(() => loaded('next').isNotEmpty,
        'The queue neighbor has begun its native load');
    final original = loaded('current').single;
    final loadingNeighbor = loaded('next').single;
    var currentRequest = true;
    final prepared =
        audio.prepareMusicSelection(next, Duration.zero, () => currentRequest);
    currentRequest = false;
    audio.cancelMusicSelection();
    expect(await prepared.timeout(const Duration(seconds: 4)), isFalse);
    expect(loadingNeighbor.disposed, isFalse);
    expect(loadingNeighbor.playedTracks, isEmpty);
    expectOriginalPlaying(original);

    loadGate!.complete();
    await original.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 119450));
    await _until(
        () =>
            loadingNeighbor.playing &&
            loadingNeighbor.volume > 0 &&
            original.volume < 1,
        'After loading, the original neighbor joins the crossfade');
    expect(loaded('next'), [loadingNeighbor]);
    expect(loadingNeighbor.loads, [next.videoId]);
    expect(loadingNeighbor.playPositions, [Duration.zero]);
    expect(player.state.currentQueueId, current.queueEntryId);
  });

  test(
      'cancelling after the queue changes does not restore an evicted automatic successor',
      () async {
    final (original, _) = await prepareTransition(SongTransitionMode.crossfade);
    expect(await audio.prepareMusicSelection(next, Duration.zero, () => true),
        isTrue);
    player.automaticMusicSuccessor = previous;
    player.publish([previous]);
    await _until(() => loaded('previous').isNotEmpty,
        'New queue successor reached the decoder');
    final loadsBeforeCancellation =
        loaded('next').expand((d) => d.loads).length;
    audio.cancelMusicSelection();
    await original.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 119450));
    await _until(
        () =>
            loaded('previous')
                .any((d) => d.playing && !d.disposed && d.volume > 0) &&
            original.volume < 1,
        'Only the successor from the updated queue crossfades');
    expect(loaded('next').every((d) => d.disposed && d.playedTracks.isEmpty),
        isTrue);
    expect(loaded('next').expand((d) => d.loads),
        hasLength(loadsBeforeCancellation));
  });

  void selectNext({required bool automatic, Duration? startAt}) {
    player.automaticTarget = automatic ? next.queueEntryId : null;
    player.automaticMusicSuccessor = null;
    player.select(next);
    audio.switchVideo(next, startAt: startAt);
  }

  Future<List<LocalMusicTrack>> scanDeviceMusic(
      {bool Function()? canRead, bool tagged = false}) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    const tree = 'content://provider.example/tree/music';
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
        case 'forgetFolder':
          return null;
        case 'pickFolder':
          return {'uri': tree, 'name': 'Music', 'selectionId': 'folder-grant'};
        case 'checkFolderAccess':
          return canRead?.call() ?? true;
        case 'listTracks':
          expect(call.arguments['treeUri'], tree);
          return [
            for (final title in ['Intro', 'Finale'])
              {
                'uri': '$tree/document/$title.mp3',
                'title': title,
                'artist': 'Device artist',
                'durationMs': 120000,
                if (tagged)
                  'replayGain': {
                    'trackGainDb': title == 'Intro' ? -6.0 : 6.0,
                    'trackPeak': 0.75,
                  },
              }
          ];
        default:
          throw UnsupportedError(call.method);
      }
    });
    final library = LocalMusicLibrary.instance;
    addTearDown(() async {
      await library.disable();
      messenger.setMockMethodCallHandler(channel, null);
    });
    expect(await library.chooseFolder(), isTrue);
    expect(library.tracks.map((track) => track.title), ['Intro', 'Finale']);
    return library.tracks;
  }

  test(
      'device crossfade retains the playing document through a reconstructed queue entry',
      () async {
    await settings.setRememberPlayBackSpeed(true);
    await settings.setLastSpeed(2, music: false);
    await settings.setLastPitch(-3, music: false);
    await settings.setLastSpeed(1.25, music: true);
    await settings.setLastPitch(12, music: true);
    await player.musicSound.setReplayGainMode(ReplayGainMode.track);
    final tracks = await scanDeviceMusic(tagged: true);
    final queue = [
      for (final track in tracks) localMusicPlaybackEntry(track, db.profileId)
    ];
    player.selectLocal(queue.first, queue);
    audio.switchToOfflineVideo(queue.first);
    await _until(
        () => loaded('Intro.mp3')
            .any((d) => d.playedTracks.contains('Intro.mp3')),
        'Local track owns playback');
    final outgoing = loaded('Intro.mp3').single;
    await settings.setSongTransitionMode(SongTransitionMode.crossfade);
    await settings.setSongTransitionSeconds(1);
    player.automaticMusicSuccessor = queue.last;
    player.publish([queue.last]);
    await _until(
        () => loaded('Finale.mp3').isNotEmpty, 'Device neighbor preloaded');
    final incoming = loaded('Finale.mp3').single;
    await outgoing.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 119450));
    await _until(
        () => incoming.playing && incoming.volume > 0 && outgoing.volume < 1,
        'Both document decoders overlap');
    expect((outgoing.speed, outgoing.pitch), (1.25, 2.0));
    expect((incoming.speed, incoming.pitch), (1.25, 2.0));
    expect(outgoing.playMusicGains.last, closeTo(0.501187, 0.000001));
    expect(incoming.playMusicGains.single, closeTo(1 / 0.75, 0.000001));
    await incoming.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 500));
    final seekCount = incoming.seeks.length;
    await outgoing.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await _until(() => player.isAutomaticMusicHandoffTo(queue.last.videoId),
        'Queue accepts native EOF');

    final refreshed = localMusicPlaybackEntry(tracks.last, db.profileId);
    expect(
        identical(queue.last.musicMetadata, refreshed.musicMetadata), isFalse);
    player.events.clear();
    player.selectLocal(refreshed, queue);
    player.automaticMusicSuccessor = null;
    audio.switchToOfflineVideo(refreshed);
    await _until(
        () => player.events
            .any((e) => e.type == MediaEventType.aspectRatioChanged),
        'The reconstructed document completed foreground admission');
    expect(loaded('Finale.mp3'), [incoming]);
    expect(incoming.playedTracks, ['Finale.mp3']);
    expect(incoming.seeks.skip(seekCount), isEmpty);
    expect(incoming.volume, 1);
    expect(incoming.musicGain, closeTo(1 / 0.75, 0.000001));
    await player.musicSound.setMusicPreampDb(-6);
    await _until(() => incoming.musicGain == 1,
        'Preamp is applied to the promoted decoder');
    expect((incoming.speed, incoming.pitch), (1.25, 2.0));
    expect(player.state.speed, 1.25);
    expect(player.state.pitchSemitones, 12);
    expect(settings.state.playbackSpeed(music: false), 2);
    expect(settings.state.playbackPitch(music: false), -3);
    expect(outgoing.disposed, isTrue);
    expect(audio.audioPlayer!.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 500)));
  });

  test('a revoked device grant cannot start a preloaded document', () async {
    var canRead = true;
    final tracks = await scanDeviceMusic(canRead: () => canRead);
    final entry = localMusicPlaybackEntry(tracks.last, db.profileId);
    player.publish([entry]);
    await _until(() => loaded('Finale.mp3').isNotEmpty,
        'Document buffered before grant revocation');
    canRead = false;
    await LocalMusicLibrary.instance.revalidate();
    expect(LocalMusicLibrary.instance.trackById(entry.videoId), isNull);

    final rebuilt = localMusicPlaybackEntry(tracks.last, db.profileId);
    player.selectLocal(rebuilt, [rebuilt]);
    audio.switchToOfflineVideo(rebuilt);
    await _until(() => audio.state.error != null,
        'Unavailable grant fails source admission');
    expect(
        loaded('Finale.mp3')
            .every((d) => !d.playedTracks.contains('Finale.mp3')),
        isTrue);
  });

  test(
      'crossfade overlaps before EOF and adopts the playing neighbor without rewinding',
      () async {
    final (outgoing, incoming) = await overlap();
    expect(outgoing.playing, isTrue);
    expect(outgoing.volume, inExclusiveRange(0, 1));
    expect(incoming.volume, inExclusiveRange(0, 1));
    expect(incoming.playVolumes.single, lessThan(1));
    expect(player.state.currentQueueId, current.queueEntryId);
    expect(
        player.events.where((e) => e.state == MediaState.completed), isEmpty);

    await incoming.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 520));
    final seeksBefore = incoming.seeks.length;
    await outgoing.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await _until(
        () => player.events.any((e) => e.state == MediaState.completed),
        'Queue received native EOF');
    selectNext(automatic: true);
    await _until(
        () => outgoing.disposed && !audio.state.loading && incoming.volume == 1,
        'The current song retires and the existing neighbor reaches full volume');
    expect(incoming.playedTracks, ['next']);
    expect(incoming.loads, ['next']);
    expect(incoming.seeks.skip(seeksBefore), isEmpty);
    expect(audio.audioPlayer!.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 520)));
  });

  for (final when in [
    'before crossfade',
    'during crossfade',
    'while reserved'
  ]) {
    test('changing streaming quality $when preserves the handoff', () async {
      final alreadyAudible = when == 'during crossfade';
      next = next.copyWith(adaptiveFormats: [
        ...next.adaptiveFormats!,
        AdaptiveFormat(null, '64000', null, '${_server.url}/next-low', '139',
            'audio/mp4', '100', '1', 'RECTANGULAR', 'mp4', 'mp4a', null, null),
      ]);
      final (outgoing, _) =
          await prepareTransition(SongTransitionMode.crossfade);
      if (when == 'while reserved') {
        expect(
            await audio.prepareMusicSelection(next, Duration.zero, () => true),
            isTrue);
      }
      if (!alreadyAudible) {
        await settings
            .setMusicStreamingQuality(MusicStreamingQuality.dataSaver);
      }
      if (when == 'while reserved') audio.cancelMusicSelection();
      await outgoing.report(
          ProcessingStateMessage.ready, const Duration(milliseconds: 119450));
      final rendition = alreadyAudible ? 'next' : 'next-low';
      await _until(
          () => loaded(rendition).any((d) => d.playing && d.volume > 0),
          'The preferred stream overlaps before EOF');
      final incoming = loaded(rendition).singleWhere((d) => d.playing);
      if (alreadyAudible) {
        await settings
            .setMusicStreamingQuality(MusicStreamingQuality.dataSaver);
      }
      await incoming.report(
          ProcessingStateMessage.ready, const Duration(milliseconds: 470));
      final previousSeeks = incoming.seeks.length;
      await outgoing.report(
          ProcessingStateMessage.completed, const Duration(minutes: 2));
      await _until(() => player.automaticTarget == next.queueEntryId,
          'The queue receives the outgoing EOF');
      selectNext(automatic: true);
      await _until(
          () =>
              outgoing.disposed && !audio.state.loading && incoming.volume == 1,
          'The incoming decoder is promoted');
      expect(incoming.playedTracks, [rendition]);
      expect(incoming.seeks.length, previousSeeks);
      expect(audio.audioPlayer!.position,
          greaterThanOrEqualTo(const Duration(milliseconds: 470)));
      expect(player.musicAudioQuality?.effective?.bitrate,
          alreadyAudible ? 128000 : 64000);
    });
  }

  test(
      'fade lowers the first song before EOF and raises the next song after it',
      () async {
    final (outgoing, incoming) =
        await prepareTransition(SongTransitionMode.fade);
    await outgoing.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 119420));
    await _until(() => outgoing.volume > 0 && outgoing.volume < 1,
        'The outgoing song fades');
    expect(incoming.playedTracks, isEmpty);

    await outgoing.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await _until(
        () => player.events.any((e) => e.state == MediaState.completed),
        'Queue reached the boundary');
    selectNext(automatic: true);
    await _until(
        () => incoming.playing, 'The next song starts after the first ends');
    expect(incoming.playVolumes.single, closeTo(0, .05));
    await incoming.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 500));
    await _until(() => incoming.volume > 0 && incoming.volume < 1,
        'The new decoder fades in');
    await incoming.report(
        ProcessingStateMessage.ready, const Duration(seconds: 2));
    await _until(() => incoming.volume == 1, 'The gain returns to normal');
    expect(incoming.loads, ['next']);
  });

  test(
      'pause mode keeps the neighbor silent and permits an immediate manual skip',
      () async {
    final (outgoing, incoming) =
        await prepareTransition(SongTransitionMode.pause, seconds: 6);
    await outgoing.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 119600));
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(incoming.playedTracks, isEmpty);
    expect(outgoing.volume, 1);
    selectNext(automatic: false);
    await _until(() => incoming.playing && outgoing.disposed,
        'Manual skip bypasses the six-second automatic pause');
    expect(incoming.playVolumes, [1.0]);
  });

  test(
      'seeking away during a crossfade restores the current song and releases the overlap',
      () async {
    final (outgoing, incoming) = await overlap();
    audio.seek(const Duration(seconds: 20));
    await _until(
        () => (incoming.disposed || !incoming.playing) && outgoing.volume == 1,
        'Seeking away from the boundary cancels the overlap');
    expect(outgoing.seeks.last, const Duration(seconds: 20));
    expect(player.state.currentQueueId, current.queueEntryId);
  });

  test('audio focus loss stops the overlapping song', () async {
    final (outgoing, incoming) = await overlap();
    audio.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await _until(
        () => (incoming.disposed || !incoming.playing) && outgoing.volume == 1,
        'Focus interruption cancels crossfade gains and the background decoder');
    expect(player.state.currentQueueId, current.queueEntryId);
  });

  test('preplaying the next song preserves the outgoing song speed and pitch',
      () async {
    await settings.setRememberPlayBackSpeed(false);
    player.setSpeed(1.25);
    audio.setSpeed(1.25);
    player.setPitchSemitones(2);
    audio.setPitchSemitones(2);
    await overlap();
    expect(player.state.currentQueueId, current.queueEntryId);
    expect(player.state.speed, 1.25);
    expect(player.state.pitchSemitones, 2);
  });

  test(
      'a manual choice during overlap starts the selected song at its requested time',
      () async {
    final (outgoing, incoming) = await overlap();
    await incoming.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 400));
    const requested = Duration(seconds: 11);
    selectNext(automatic: false, startAt: requested);
    await _until(
        () =>
            outgoing.disposed &&
            !audio.state.loading &&
            audio.audioPlayer!.playing &&
            audio.audioPlayer!.position >= requested,
        'The manual selection took over from the preplaying pair');
    expect(audio.audioPlayer!.position, greaterThanOrEqualTo(requested));
    expect(audio.audioPlayer!.position,
        lessThan(requested + const Duration(seconds: 1)));
    expect(decoders.where((d) => !d.disposed && d.playing), hasLength(1));
    expect(
        player.events.where((e) => e.state == MediaState.completed), isEmpty);
  });

  test('muting a crossfade silences both decoders and teardown releases them',
      () async {
    final (outgoing, incoming) = await overlap();
    audio.toggleVolume(false);
    await _until(
        () =>
            outgoing.volume == 0 &&
            (incoming.volume == 0 || incoming.disposed || !incoming.playing),
        'Mute immediately silences both sides of the overlap');
    await outgoing.report(
        ProcessingStateMessage.ready, const Duration(milliseconds: 119800));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(outgoing.volume, 0);
    expect(
        incoming.volume == 0 || incoming.disposed || !incoming.playing, isTrue);
    await audio.stopForProxyChange();
    expect(outgoing.disposed, isTrue);
    expect(incoming.disposed, isTrue);
  });

  test('Music volume follows both decoders through automatic promotion',
      () async {
    final (outgoing, incoming) = await overlap();
    await settings.setMusicPlaybackVolume(0.4);
    await _until(
        () =>
            outgoing.volume > 0 &&
            incoming.volume > 0 &&
            (outgoing.volume + incoming.volume - 0.4).abs() < 0.003,
        'The two crossfade gains are scaled to the Music volume');

    await settings.setMusicPlaybackVolume(0);
    await _until(() => outgoing.volume == 0 && incoming.volume == 0,
        'A zero Music volume silences both decoders');
    expect(outgoing.playing, isTrue);
    expect(incoming.playing, isTrue);
    await settings.setMusicPlaybackVolume(0.4);
    await outgoing.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await _until(
        () => player.events.any((e) => e.state == MediaState.completed),
        'Queue received native EOF');
    selectNext(automatic: true);
    await _until(
        () =>
            outgoing.disposed && !audio.state.loading && incoming.volume == 0.4,
        'The promoted decoder keeps the Music volume');
    expect(incoming.playedTracks, ['next']);
  });

  test('a decoder reused for ordinary audio restores its usual level',
      () async {
    final decoder = loaded('current').single;
    await settings.setMusicPlaybackVolume(0.3);
    await _until(() => decoder.volume == 0.3, 'Current Music level changed');

    final ordinary = next.copyWith(musicMetadata: null);
    player.select(ordinary);
    audio.switchVideo(ordinary);
    await _until(() => decoder.playedTracks.contains('next'),
        'The existing decoder starts ordinary audio');
    expect(decoder.playVolumes.last, 1);

    await settings.setMusicPlaybackVolume(0.6);
    expect(decoder.volume, 1);
    player.select(current);
    audio.switchVideo(current);
    await _until(() => decoder.playedTracks.length == 3,
        'The same decoder returns to Music');
    expect(decoder.playVolumes.last, 0.6);
  });

  test('repeated adjacent snapshots keep one silent decoder per neighbor',
      () async {
    player.publish([next, previous]);
    await _until(
        () => loaded('previous').isNotEmpty && loaded('next').isNotEmpty,
        'Both neighbors reach the native decoder');
    player.publish([next, previous]);
    player.publish([previous, next]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final track in [next, previous]) {
      final decoder = loaded(track.videoId).single;
      expect(decoder.loads, [track.videoId]);
      expect(decoder.playedTracks, isEmpty);
    }
    expect(player.state.currentQueueId, current.queueEntryId);
  });

  for (final direction in ['previous', 'next']) {
    test('Android can rewind the promoted $direction decoder in place',
        () async {
      player.publish([previous, next]);
      await _until(
          () => loaded('previous').isNotEmpty && loaded('next').isNotEmpty,
          'Both adjacent songs are prepared');
      for (final decoder in decoders) {
        expect(
            decoder.androidLoadControl,
            containsPair('backBufferDuration',
                const Duration(seconds: 90).inMicroseconds));
        expect(decoder.androidLoadControl,
            containsPair('targetBufferBytes', null));
        expect(decoder.androidLoadControl,
            containsPair('prioritizeTimeOverSizeThresholds', false));
      }

      final selected = direction == 'previous' ? previous : next;
      final promoted = loaded(selected.videoId).single;
      final other =
          loaded(direction == 'previous' ? 'next' : 'previous').single;
      player.select(selected);
      audio.switchVideo(selected);
      await _until(
          () => promoted.playing, 'The selected standby owns playback');
      await promoted.report(
          ProcessingStateMessage.ready, const Duration(seconds: 75));
      await _until(
          () => audio.audioPlayer!.position >= const Duration(seconds: 75),
          'Position advanced before rewind');
      final seeks = promoted.seeks.length;
      const rewind = Duration(seconds: 15);
      audio.seek(rewind);
      await _until(() => promoted.seeks.length > seeks, 'Native seek received');

      expect(promoted.seeks.skip(seeks), [rewind]);
      expect(promoted.loads, [selected.videoId]);
      expect(promoted.playedTracks, [selected.videoId]);
      expect(promoted.playing, isTrue);
      expect(other.playedTracks, isEmpty);
      expect(other.seeks, isEmpty);
    });
  }

  test(
      'route revocation disposes an in-flight standby despite late load success',
      () async {
    heldTrack = next.videoId;
    loadGate = Completer<void>();
    player.publish([next]);
    await _until(() => loaded('next').isNotEmpty, 'Standby started loading');
    final standby = loaded('next').single;
    final revoked = audio.stopForProxyChange();
    await _until(() => standby.disposed,
        'Stop reaches the native decoder while its load is pending');
    loadGate!.complete();
    await revoked;
    expect(standby.disposed, isTrue);
    expect(standby.playedTracks, isEmpty);
    expect(player.state.currentQueueId, current.queueEntryId);
  });

  test(
      'a failed standby load leaves the current song playing and the neighbor can start cold',
      () async {
    failingTrack = next.videoId;
    player.publish([next]);
    await _until(() => loaded('next').any((d) => d.disposed),
        'Failed standby was released');
    final failed = loaded('next').single;
    expect(failed.playedTracks, isEmpty);
    expect(player.events.where((e) => e.state == MediaState.error), isEmpty);
    expect(loaded('current').single.disposed, isFalse);
    expect(audio.state.error, isNull);

    failingTrack = null;
    player.select(next);
    audio.switchVideo(next);
    await _until(
        () => loaded('next')
            .any((d) => !d.disposed && d.playedTracks.contains('next')),
        'Selecting the neighbor retries through normal playback');
    expect(failed.playedTracks, isEmpty);
    expect(audio.state.video?.queueEntryId, next.queueEntryId);
    expect(audio.state.error, isNull);
  });

  test(
      'pausing at the end reports one completion, and replay can complete again',
      () async {
    const end = Duration(minutes: 2);
    final decoder = loaded('current').single;
    final completions =
        player.events.where((e) => e.state == MediaState.completed);
    await decoder.report(ProcessingStateMessage.completed, end);
    await _until(
        () => completions.isNotEmpty, 'First completion reached the queue');

    // just_audio publishes a new player state when playing changes to false
    // even though the native processing state is still completed.
    final beforePause = decoder.pauses;
    audio.pause();
    await _until(() => decoder.pauses > beforePause, 'Paused at EOF');
    expect(completions, hasLength(1));

    audio.seek(Duration.zero);
    await _until(
        () => audio.audioPlayer!.processingState == ProcessingState.ready,
        'Seeking away from EOF reinstated the source');
    final beforePlay = decoder.playedTracks.length;
    audio.play();
    await _until(
        () => decoder.playedTracks.length > beforePlay, 'Replayed the song');
    await decoder.report(ProcessingStateMessage.completed, end);
    await _until(
        () => completions.length >= 2, 'The replay can finish normally');
    expect(completions, hasLength(2));
  });

  test(
      'a completion from a replaced source cannot finish its still-loading successor',
      () async {
    heldTrack = next.videoId;
    loadGate = Completer<void>();
    player.select(next);
    audio.switchVideo(next);
    await _until(() => loaded('next').isNotEmpty,
        'Next load reached the native decoder');
    final decoder = loaded('next').single;
    final completions =
        player.events.where((e) => e.state == MediaState.completed);
    final nativeCompletion = audio.audioPlayer!.processingStateStream
        .firstWhere((state) => state == ProcessingState.completed);
    await decoder.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await nativeCompletion.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);
    expect(completions, isEmpty);

    loadGate!.complete();
    await _until(() => decoder.playedTracks.contains('next'),
        'The selected song is now admitted');
    await decoder.report(
        ProcessingStateMessage.completed, const Duration(minutes: 2));
    await _until(() => completions.isNotEmpty,
        'The selected song finished after admission');
    expect(completions, hasLength(1));
  });
}
