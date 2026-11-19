import 'dart:async';
import 'dart:collection';

import 'package:clipious/globals.dart';
import 'package:clipious/music/services/music_video_source.dart';
import 'package:clipious/music/views/components/music_video_surface.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = Server(url: 'https://instance.example');
const _song = Video(videoId: 'song', lengthSeconds: 90);
const _nextSong = Video(videoId: 'next');

class _Database extends Fake implements IDbClient {
  Server selected = _server;

  @override
  String get profileId => selected.profileId;

  @override
  Future<Server> getCurrentlySelectedServer() async => selected;

  @override
  Future<void> upsertServer(Server server) =>
      throw UnsupportedError('Read-only database');

  @override
  Future<void> insertLogs(AppLog log) =>
      throw UnsupportedError('Read-only database');
}

// The surface may observe the song. Calling a queue or audio command on this
// fake is an error, including while the video is starting or disappearing.
class _SongPlayer extends Fake implements PlayerCubit {
  final _states = StreamController<PlayerState>.broadcast();

  @override
  PlayerState state = PlayerState.init([_song, _nextSong]).copyWith(
      currentlyPlaying: _song,
      playQueue: ListQueue.of([_nextSong.videoId]),
      isAudio: true,
      isPlaying: true,
      isMini: false,
      isHidden: false,
      position: const Duration(seconds: 12),
      mediaEvent: const MediaEvent(state: MediaState.playing));

  @override
  Stream<PlayerState> get stream => _states.stream;

  @override
  bool get isClosed => _states.isClosed;

  @override
  MediaState get playbackStatus => state.mediaEvent.state;

  void update(PlayerState next) {
    state = next;
    _states.add(next);
  }

  @override
  Future<void> close() => _states.close();
}

FormatStream _format(
        {String itag = '18', String type = 'video/mp4', String? url}) =>
    FormatStream(url ?? '${_server.url}/visual.mp4', itag, type, 'medium',
        'mp4', 'h264', '360p', '360p', '640x360');

Video _video() => Video(
    videoId: 'official-video',
    lengthSeconds: 90,
    playbackConnection: BackendPlayback(_server),
    formatStreams: [_format()]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('better_player_channel');
  const events = MethodChannel('better_player_channel/videoEvents1');
  late List<MethodCall> calls;
  late _SongPlayer player;
  late int failures;
  late int position;
  Completer<int>? pendingPosition;
  String? sourceKey;

  setUp(() {
    db = _Database();
    calls = [];
    player = _SongPlayer();
    failures = 0;
    position = 0;
    pendingPosition = null;
    sourceKey = null;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'create') return {'textureId': 1};
      if (call.method == 'setDataSource') {
        final source = call.arguments['dataSource'] as Map;
        sourceKey = source['key'] as String;
        position = source['initialPositionMs'] as int? ?? 0;
      }
      if (call.method == 'seekTo') position = call.arguments['location'];
      if (call.method == 'position') {
        final pending = pendingPosition;
        pendingPosition = null;
        return pending?.future ?? position;
      }
      return null;
    });
  });

  tearDown(() async {
    await player.close();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<void> mount(WidgetTester tester, {Video? video}) async {
    await tester.pumpWidget(BlocProvider<PlayerCubit>.value(
        value: player,
        child: MaterialApp(
            home: MusicVideoSurface(
                video: video ?? _video(), onUnavailable: () => failures++))));
    await tester.pump();
  }

  Future<void> nativeEvent(
      WidgetTester tester, Map<String, Object?> event) async {
    await messenger.handlePlatformMessage(events.name,
        const StandardMethodCodec().encodeSuccessEnvelope(event), (_) {});
    await tester.pump();
  }

  Future<void> initialize(WidgetTester tester,
          {int width = 640, int height = 360}) =>
      nativeEvent(tester, {
        'event': 'initialized',
        'key': sourceKey,
        'duration': 90000,
        'width': width,
        'height': height,
        'isLiveStream': false,
      });

  Future<void> flushNativeShutdown(WidgetTester tester) async {
    // Allow the EventChannel cancellation to finish outside the fake frame clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  test('availability requires a usable video rendition', () {
    final video = _video();
    expect(hasMusicVideoSource(video), isTrue);
    expect(hasMusicVideoSource(video.copyWith(formatStreams: [])), isFalse);
    expect(
        hasMusicVideoSource(
            video.copyWith(formatStreams: [_format(type: 'audio/mp4')])),
        isFalse);
    expect(
        hasMusicVideoSource(
            video.copyWith(formatStreams: [_format(itag: '22')])),
        isFalse);
    expect(
        hasMusicVideoSource(video.copyWith(playbackConnection: null)), isFalse);
    expect(hasMusicVideoSource(video.copyWith(downloadPlaybackOnly: true)),
        isFalse);
    expect(
        hasMusicVideoSource(video.copyWith(formatStreams: [
          _format(url: 'https://unrelated.example/video.mp4'),
        ])),
        isFalse);
  });

  test('prefers an admitted video-only rendition over a combined stream', () {
    AdaptiveFormat track(int height) => AdaptiveFormat.fromJson({
          'url': '${_server.url}/visual-$height.mp4',
          'type': 'video/mp4',
          'itag': '136',
          'clen': '1024',
          'lmt': '0',
          'projectionType': 'RECTANGULAR',
          'qualityLabel': '${height}p',
        });
    final sources = musicVideoSources(_video().copyWith(
        adaptiveFormats: [track(1080), track(360), track(720)],
        dashUrl: '${_server.url}/manifest.mpd'));
    expect(sources.map((source) => source.uri), [
      '${_server.url}/visual-720.mp4',
      '${_server.url}/manifest.mpd?local=true',
      '${_server.url}/visual.mp4',
    ]);
    expect(sources.every((s) => s.videoOnly && s.showNotification != true),
        isTrue);
  });

  testWidgets('video follows song time and controls without taking audio focus',
      (tester) async {
    await mount(tester);
    final source = calls
        .singleWhere((c) => c.method == 'setDataSource')
        .arguments['dataSource'] as Map;
    expect(source['videoOnly'], isTrue);
    expect(source['showNotification'], isNot(true));
    expect(calls.where((c) => c.method == 'play'), isEmpty);
    await initialize(tester);

    final firstPlay = calls.indexWhere((c) => c.method == 'play');
    expect(firstPlay, greaterThanOrEqualTo(0));
    final beforePlay = calls.take(firstPlay);
    expect(
        beforePlay
            .any((c) => c.method == 'setVolume' && c.arguments['volume'] == 0),
        isTrue);
    expect(
        beforePlay.any((c) =>
            c.method == 'setMixWithOthers' &&
            c.arguments['mixWithOthers'] == true),
        isTrue);
    expect(position, 12000);
    expect(
        calls.where(
            (c) => c.method == 'setVolume' && c.arguments['volume'] != 0),
        isEmpty);

    calls.clear();
    position = 12940;
    player.update(player.state.copyWith(position: const Duration(seconds: 13)));
    await tester.pump();
    expect(calls.map((c) => c.method), isNot(contains('seekTo')));

    calls.clear();
    player.update(player.state.copyWith(
        isPlaying: false,
        mediaEvent: const MediaEvent(state: MediaState.pause)));
    await tester.pump();
    expect(calls.map((c) => c.method), contains('pause'));

    calls.clear();
    const later = Duration(seconds: 36);
    player.update(player.state.copyWith(
        position: later,
        mediaCommand: const MediaCommand(MediaCommandType.seek, value: later)));
    await tester.pump();
    expect(position, later.inMilliseconds);
    expect(calls.map((c) => c.method), isNot(contains('play')));

    player.update(player.state.copyWith(
        speed: 1.5,
        isPlaying: true,
        mediaEvent: const MediaEvent(state: MediaState.playing)));
    await tester.pump();
    expect(
        calls.any((c) => c.method == 'setSpeed' && c.arguments['speed'] == 1.5),
        isTrue);
    expect(calls.map((c) => c.method), contains('play'));

    await tester.pumpWidget(const SizedBox());
    await flushNativeShutdown(tester);
    expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
    expect(player.state.currentQueueId, _song.videoId);
    expect(player.state.playQueue, [_nextSong.videoId]);
    expect(failures, 0);
  });

  testWidgets('removing a pending video releases it and ignores late readiness',
      (tester) async {
    await mount(tester);
    expect(calls.map((c) => c.method), contains('setDataSource'));
    await tester.pumpWidget(const SizedBox());
    await flushNativeShutdown(tester);
    await initialize(tester);
    expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
    expect(calls.map((c) => c.method), isNot(contains('play')));
    expect(player.state.isPlaying, isTrue);
    expect(failures, 0);
  });

  testWidgets('switching the selected instance rejects a stale video',
      (tester) async {
    (db as _Database).selected = const Server(url: 'https://other.example');
    await mount(tester);
    expect(calls.map((c) => c.method), isNot(contains('setDataSource')));
    expect(failures, 1);
    expect(player.state.isPlaying, isTrue);
  });

  testWidgets('an audio-only manifest falls back to the playable rendition',
      (tester) async {
    await mount(tester,
        video: _video().copyWith(dashUrl: '${_server.url}/manifest.mpd'));
    await initialize(tester, width: 0, height: 0);
    await flushNativeShutdown(tester);
    final urls = calls
        .where((c) => c.method == 'setDataSource')
        .map((c) => c.arguments['dataSource']['uri']);
    expect(urls, [
      '${_server.url}/manifest.mpd?local=true',
      '${_server.url}/visual.mp4'
    ]);
    expect(calls.map((c) => c.method), isNot(contains('play')));
    await initialize(tester);
    expect(position, 12000);
    expect(calls.map((c) => c.method), contains('play'));
    expect(failures, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'backgrounding releases the decoder and resumes at the current song time',
      (tester) async {
    await mount(tester);
    await initialize(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Android may stop scheduling frames before the inactive widget can rebuild.
    await tester.idle();
    expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
    expect(player.state.isPlaying, isTrue);

    player.update(player.state.copyWith(position: const Duration(seconds: 42)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await initialize(tester);
    expect(calls.where((c) => c.method == 'create'), hasLength(2));
    expect(position, 42000);
    expect(failures, 0);
    await tester.pumpWidget(const SizedBox());
    await flushNativeShutdown(tester);
  });

  testWidgets('buffering defers drift correction while honoring a song seek',
      (tester) async {
    await mount(tester);
    await initialize(tester);
    await nativeEvent(tester, {'event': 'bufferingStart'});

    calls.clear();
    player.update(player.state.copyWith(position: const Duration(seconds: 17)));
    await tester.pump();
    expect(calls.map((c) => c.method), isNot(contains('seekTo')));

    const sought = Duration(seconds: 40);
    player.update(player.state.copyWith(
        position: sought,
        mediaCommand:
            const MediaCommand(MediaCommandType.seek, value: sought)));
    await tester.pump();
    expect(position, sought.inMilliseconds);
    calls.clear();
    await tester.pump(const Duration(seconds: 10));
    player.update(player.state.copyWith(position: const Duration(seconds: 50)));
    await tester.pump();
    expect(calls.map((c) => c.method), isNot(contains('seekTo')));

    await nativeEvent(tester, {'event': 'bufferingEnd'});
    // A sustained, large error after playback resumes still needs correction.
    // The fake video advances normally again with a ten-second head start
    // for the audio. A hard correction should happen once, then stay aligned.
    for (var second = 51; second <= 64; second++) {
      await tester.pump(const Duration(seconds: 1));
      position += 1000;
      player.update(player.state.copyWith(position: Duration(seconds: second)));
      await tester.pump();
    }
    expect(position, closeTo(64000, 250));
    expect(calls.where((c) => c.method == 'seekTo'), hasLength(1));
    expect(failures, 0);
    await tester.pumpWidget(const SizedBox());
    await flushNativeShutdown(tester);
  });

  testWidgets('a brief rebuffer between song samples never seeks backwards',
      (tester) async {
    await mount(tester);
    await initialize(tester);
    await tester.pump(const Duration(seconds: 1));
    position = 13000;
    player.update(player.state.copyWith(position: const Duration(seconds: 13)));
    await tester.pump();
    calls.clear();

    // The native video played another 800ms since the song's one-second
    // progress update. Both decoders are within 150ms when buffering ends.
    await tester.pump(const Duration(milliseconds: 800));
    position = 13800;
    await nativeEvent(tester, {'event': 'bufferingStart'});
    await tester.pump(const Duration(milliseconds: 150));
    await nativeEvent(tester, {'event': 'bufferingEnd'});
    expect(calls.where((c) => c.method == 'seekTo'), isEmpty);

    await tester.pump(const Duration(milliseconds: 50));
    position += 50;
    player.update(player.state.copyWith(position: const Duration(seconds: 14)));
    await tester.pump();
    expect(calls.where((c) => c.method == 'seekTo'), isEmpty);
    expect(failures, 0);
    await tester.pumpWidget(const SizedBox());
    await flushNativeShutdown(tester);
  });

  testWidgets(
      'slow preparation and seeks allow frames to play before correcting drift',
      (tester) async {
    await mount(tester);
    final data = calls
        .singleWhere((c) => c.method == 'setDataSource')
        .arguments['dataSource'] as Map;
    expect(data['initialPositionMs'], 12000);
    await nativeEvent(tester, {'event': 'bufferingStart'});

    Future<void> songTick(int seconds) async {
      await tester.pump(const Duration(seconds: 1));
      player
          .update(player.state.copyWith(position: Duration(seconds: seconds)));
      await tester.pump();
    }

    await songTick(13);
    await songTick(14);
    // ExoPlayer sends initialized and bufferingEnd in the same ready callback.
    // Let that second event arrive while the first native position read is pending.
    final firstRead = pendingPosition = Completer<int>();
    await initialize(tester);
    await nativeEvent(tester, {'event': 'bufferingEnd'});
    firstRead.complete(position);
    await tester.pump();
    expect(calls.where((c) => c.method == 'play'), isNotEmpty);
    expect(calls.where((c) => c.method == 'seekTo'), isEmpty,
        reason: 'Rebuffering here would move the startup target again.');

    calls.clear();
    const sought = Duration(seconds: 30);
    player.update(player.state.copyWith(
        position: sought,
        mediaCommand:
            const MediaCommand(MediaCommandType.seek, value: sought)));
    await tester.pump();
    expect(position, sought.inMilliseconds);
    await nativeEvent(tester, {'event': 'bufferingStart'});
    await songTick(31);
    await songTick(32);
    await nativeEvent(tester, {'event': 'bufferingEnd'});
    expect(calls.where((c) => c.method == 'seekTo'), hasLength(1),
        reason: 'The user seek has just buffered its first playable frame.');

    expect(player.state.isPlaying, isTrue);
    expect(failures, 0);
    await tester.pumpWidget(const SizedBox());
    await flushNativeShutdown(tester);
  });
}
