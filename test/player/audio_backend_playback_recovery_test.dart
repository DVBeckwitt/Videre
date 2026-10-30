import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _HeldServerDb extends IDbClient {
  final IDbClient delegate;
  final requested = Completer<void>();
  final selected = Completer<Server>();

  _HeldServerDb(this.delegate);

  @override
  Future<Server> getCurrentlySelectedServer() {
    if (!requested.isCompleted) requested.complete();
    return selected.future;
  }

  @override
  double getVideoProgress(String videoId) => delegate.getVideoProgress(videoId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingPlayer extends TestPlayerCubit {
  final events = <MediaEvent>[];

  _RecordingPlayer(super.initialState, super.settings);

  @override
  void setEvent(MediaEvent event) {
    events.add(event);
    emit(state.copyWith(mediaEvent: event));
  }
}

class _NativeAudio implements AudioPlayer {
  final errors = <Object>[];
  final sources = <AudioSource>[];
  final sourcePositions = <Duration?>[];
  double nativeSpeed = 1;
  double nativePitch = 1;
  bool nativePlaying = false;
  Duration nativePosition = Duration.zero;
  int playCalls = 0;
  bool disposed = false;

  @override
  double get speed => nativeSpeed;

  @override
  bool get playing => nativePlaying;

  @override
  Duration get position => nativePosition;

  @override
  Future<Duration?> setAudioSource(AudioSource source,
      {bool preload = true,
      int? initialIndex,
      Duration? initialPosition}) async {
    sources.add(source);
    sourcePositions.add(initialPosition);
    nativePosition = initialPosition ?? Duration.zero;
    if (errors.isNotEmpty) throw errors.removeAt(0);
    return const Duration(minutes: 2);
  }

  @override
  Future<void> setSpeed(double value) async => nativeSpeed = value;

  @override
  Future<void> setPitch(double value) async => nativePitch = value;

  @override
  Future<void> play() async {
    playCalls++;
    nativePlaying = true;
  }

  @override
  Future<void> pause() async => nativePlaying = false;

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Audio extends AudioPlayerCubit {
  final _NativeAudio native;

  _Audio(super.initialState, super.player, super.settings, this.native);

  @override
  void onInit() {}

  @override
  void initPlayer() => audioPlayer ??= native;
}

class _RetryService extends Service {
  final requested = Completer<void>();
  Completer<void>? held;
  int retryCalls = 0;
  int metadataCalls = 0;
  final retryVideos = <Video>[];

  @override
  bool useProxy() => true;

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest}) async {
    metadataCalls++;
    throw StateError('Direct audio admission must not fetch metadata');
  }

  @override
  Future<Video?> retryVideoBackend(Video video,
      {required bool Function() isCurrent,
      void Function(BackendPlayback request)? onRetry}) async {
    retryCalls++;
    retryVideos.add(video);
    if (!requested.isCompleted) requested.complete();
    final next = video.backendPlayback?.next();
    if (next == null) return null;
    onRetry?.call(next);
    if (held != null) await held!.future;
    if (!isCurrent()) return null;
    return video.copyWith(backendPlayback: next);
  }
}

Video _video(String id, Server server) => Video(
      videoId: id,
      lengthSeconds: 120,
      backendPlayback: BackendPlayback(server),
      formatStreams: [
        FormatStream('${server.url}/$id.mp4', '18', 'video/mp4', 'medium',
            'mp4', 'h264', '360p', '360p', '640x360'),
      ],
      adaptiveFormats: [],
    );

PlayerException _retryable() =>
    PlayerException(2002, 'Transport failure', 0, backendRetryable: true);

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _RecordingPlayer player;
  late Service originalService;
  late _RetryService retryService;
  late Server preferred;
  final players = <_Audio>[];

  setUp(() async {
    originalService = service;
    service = retryService = _RetryService();
    documents = await Directory.systemTemp.createTemp('videre-audio-retry-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
        'ROUTE',
        const [
          BackendOption('0', 'First'),
          BackendOption('1', 'Second'),
          BackendOption('2', 'Third'),
        ],
        automaticFallback: true);
    preferred = selector.withSelection(
        const Server(
            url: 'https://instance.example',
            customHeaders: {'Cookie': 'login=kept', 'X-Instance': 'kept'}),
        '0');
    await db.upsertServer(preferred);
    await db.useServer(preferred);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _RecordingPlayer(
        PlayerState.init(null).copyWith(isAudio: true), settings);
  });

  tearDown(() async {
    for (final audio in players) {
      await audio.close();
    }
    players.clear();
    await _flush();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    retryService.httpClient.close();
    service = originalService;
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  _Audio create(_NativeAudio native,
      {Video? video, DownloadedVideo? offlineVideo}) {
    final current = video ?? _video('first', preferred);
    player.emit(player.state.copyWith(
        currentlyPlaying: current, offlineCurrentlyPlaying: offlineVideo));
    final audio = _Audio(
        AudioPlayerState(video: current, offlineVideo: offlineVideo),
        player,
        settings,
        native);
    players.add(audio);
    return audio;
  }

  test('typed load failure retries with effective headers without saving them',
      () async {
    final native = _NativeAudio()..errors.add(_retryable());
    final audio = create(native);
    await audio.playVideo(false, startAt: const Duration(seconds: 12));

    expect(retryService.retryCalls, 1);
    expect(player.state.requestedBackend?.label, 'Second');
    expect(native.sources, hasLength(2));
    final first = native.sources.first as UriAudioSource;
    final second = native.sources.last as UriAudioSource;
    expect(first.headers?['Cookie'], contains('ROUTE=0'));
    expect(second.headers?['Cookie'], contains('ROUTE=1'));
    expect(second.headers?['Cookie'], contains('login=kept'));
    expect(second.headers?['X-Instance'], 'kept');
    expect(native.sourcePositions,
        [const Duration(seconds: 12), const Duration(seconds: 12)]);
    expect(native.nativePlaying, isTrue);
    expect(audio.state.video!.backendPlayback!.server.customHeaders,
        second.headers);
    expect((await db.getCurrentlySelectedServer()).customHeaders,
        preferred.customHeaders);
    expect(player.events.where((event) => event.state == MediaState.error),
        isEmpty);
    expect(
        player.events
            .where((event) => event.type == MediaEventType.backendRetry),
        hasLength(1));
  });

  test('unknown decoder errors do not switch backends', () async {
    final native = _NativeAudio()
      ..errors.add(PlayerException(4001, 'Unsupported codec', 0));
    final audio = create(native);
    await audio.playVideo(false);
    expect(retryService.retryCalls, 0);
    expect(native.sources, hasLength(1));
    expect(player.events.where((event) => event.state == MediaState.error),
        hasLength(1));
  });

  test('offline failures never request online metadata', () async {
    final native = _NativeAudio()..errors.add(_retryable());
    final audio = create(native,
        offlineVideo: const DownloadedVideo(
            videoId: 'offline',
            title: 'Offline',
            lengthSeconds: 120,
            quality: 'audio',
            audioOnly: true));
    await audio.playVideo(true);
    expect(native.sources, hasLength(1));
    expect(retryService.retryCalls, 0);
    expect(player.events.where((event) => event.state == MediaState.error),
        hasLength(1));
  });

  for (final pauseBeforeError in [true, false]) {
    test(
        'midstream recovery retains pause and rate, pauseBefore=$pauseBeforeError',
        () async {
      final native = _NativeAudio();
      final audio = create(native);
      await audio.playVideo(false);
      native.nativePosition = const Duration(seconds: 42);
      audio.setSpeed(1.75);
      audio.setPitchSemitones(12);
      if (pauseBeforeError) audio.pause();
      retryService.held = Completer<void>();
      audio.onPlaybackError(_retryable());
      await retryService.requested.future;
      audio.onPlaybackError(_retryable()); // Same failure must not retry twice.
      audio.onDurationChanged(Duration.zero);
      audio.onPositionChanged(Duration.zero);
      audio.onBufferChanged(Duration.zero);
      expect(audio.state.loading, isTrue);
      expect(player.events.last.type, MediaEventType.backendRetry);
      expect(player.events.last.value, 'Second');
      expect(player.state.requestedBackend?.label, 'Second');
      if (!pauseBeforeError) audio.pause();
      retryService.held!.complete();
      await _flush();

      expect(retryService.retryCalls, 1);
      expect(native.sources, hasLength(2));
      expect(native.sourcePositions.last, const Duration(seconds: 42));
      expect(native.nativeSpeed, 1.75);
      expect(native.nativePitch, 2);
      expect(native.nativePlaying, isFalse);
      expect(native.playCalls, 1);
      expect(player.state.requestedBackend?.label, 'Second');
      expect(player.events.where((event) => event.state == MediaState.error),
          isEmpty);
    });
  }

  for (final stop in [true, false]) {
    test('late metadata cannot revive an old audio source, stop=$stop',
        () async {
      final native = _NativeAudio()..errors.add(_retryable());
      final audio = create(native);
      retryService.held = Completer<void>();
      final loading = audio.playVideo(false);
      await retryService.requested.future;
      if (stop) {
        await audio.stopForProxyChange();
      } else {
        audio.switchVideo(_video('replacement', preferred));
        await _flush();
      }
      final sourcesBeforeResponse = native.sources.length;
      retryService.held!.complete();
      await loading;
      await _flush();

      expect(native.sources, hasLength(sourcesBeforeResponse));
      expect(audio.state.video!.videoId, stop ? 'first' : 'replacement');
      expect(player.events.where((event) => event.state == MediaState.error),
          isEmpty);
      if (stop) {
        expect(native.disposed, isTrue);
        expect(native.playCalls, 0);
      } else {
        expect((native.sources.last as UriAudioSource).uri.path,
            '/replacement.mp4');
      }
    });
  }

  test('repeated transport failures exhaust the shared two-backend budget',
      () async {
    final native = _NativeAudio()
      ..errors.addAll([_retryable(), _retryable(), _retryable()]);
    final audio = create(native);
    await audio.playVideo(false);
    expect(audio.state.video!.backendPlayback!.retries, 2);
    expect(native.sources, hasLength(3));
    expect(native.playCalls, 0);
    expect(player.events.where((event) => event.state == MediaState.error),
        hasLength(1));
  });
  for (final changed in ['headers', 'credentials', 'server', 'proxy']) {
    test('stale backend $changed snapshot is rejected before native setup',
        () async {
      final cached = _video('cached', preferred);
      if (changed == 'proxy') {
        await NetworkProxy.instance.initialize(
            saved: '{"enabled":false,"host":"127.0.0.1","port":9150}',
            configureNative: false);
      } else {
        final current = switch (changed) {
          'headers' =>
            preferred.copyWith(customHeaders: {'Cookie': 'login=current'}),
          'credentials' => preferred.copyWith(authToken: 'changed-test-auth'),
          _ => preferred.copyWith(url: 'https://new-instance.example'),
        };
        await db.upsertServer(current);
        await db.useServer(current);
      }
      final native = _NativeAudio();
      final audio = create(native, video: cached);
      await audio.playVideo(false);

      expect(native.sources, isEmpty);
      expect(native.playCalls, 0);
      expect(retryService.retryCalls, 0);
      expect(retryService.metadataCalls, 0);
      expect(player.events.where((event) => event.state == MediaState.error),
          hasLength(1));
    });
  }

  test('stopping during snapshot admission prevents late source setup',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    final originalDb = db;
    final held = _HeldServerDb(originalDb);
    db = held;
    try {
      final loading = audio.playVideo(false);
      await held.requested.future;
      await audio.stopForProxyChange();
      held.selected.complete(preferred);
      await loading;
      expect(native.sources, isEmpty);
      expect(native.playCalls, 0);
      expect(retryService.retryCalls, 0);
      expect(player.events.where((event) => event.state == MediaState.error),
          isEmpty);
    } finally {
      db = originalDb;
    }
  });
  test('legacy videos without a session use current headers without refetch',
      () async {
    final cached = _video('legacy', preferred).copyWith(backendPlayback: null);
    final current =
        preferred.copyWith(customHeaders: {'Cookie': 'login=current'});
    await db.upsertServer(current);
    await db.useServer(current);
    final native = _NativeAudio();
    final audio = create(native, video: cached);
    await audio.playVideo(false);

    expect((native.sources.single as UriAudioSource).headers,
        current.customHeaders);
    expect(native.playCalls, 1);
    expect(retryService.retryCalls, 0);
    expect(retryService.metadataCalls, 0);
  });
}
