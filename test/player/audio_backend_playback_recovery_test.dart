import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart'
    show AudioProcessingState, MediaControl;
import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/nerdvpn_origin.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:just_audio/just_audio.dart' as native_audio show PlayerState;

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
  int refreshCalls = 0;
  Video? refreshedVideo;
  Object? refreshError;
  Completer<void>? refreshGate;
  bool interrupted = false;
  final recoveryProgress = <Duration>[];
  final backendProgress = <Duration>[];

  _RecordingPlayer(super.initialState, super.settings);

  @override
  bool get playbackInterrupted => interrupted || super.playbackInterrupted;

  @override
  Future<Video?> refreshCurrentPlayback(Video video,
      {required bool Function() isCurrent}) async {
    refreshCalls++;
    await refreshGate?.future;
    if (!isCurrent()) throw StateError('Stale recovery');
    if (refreshError != null) throw refreshError!;
    if (refreshedVideo != null) {
      emit(state.copyWith(currentlyPlaying: refreshedVideo));
    }
    return refreshedVideo;
  }

  @override
  void reportPlaybackRecoveryProgress(Video video, Duration position,
      {required bool playing}) {
    if (playing) recoveryProgress.add(position);
  }

  @override
  void reportBackendPlaybackProgress(
      String videoId, BackendPlayback? request, Duration position,
      {required bool playing}) {
    if (playing) backendProgress.add(position);
  }

  @override
  void setEvent(MediaEvent event) {
    events.add(event);
    emit(state.copyWith(mediaEvent: event));
  }
}

class _MediaSessionPlayer extends PlayerCubit {
  _MediaSessionPlayer(super.initialState, super.settings)
      : super(playbackRecoveryDelay: (_) async {});

  @override
  Future<void> onReady() async {}
}

class _HydratingPlayer extends _MediaSessionPlayer {
  final requests = <({Video video, Duration? startAt})>[];

  _HydratingPlayer(super.initialState, super.settings);

  @override
  Future<void> retryCurrentVideo() async {
    requests.add((video: state.currentlyPlaying!, startAt: state.position));
  }
}

class _NativeAudio implements AudioPlayer {
  final errors = <Object>[];
  final sources = <AudioSource>[];
  final sourcePositions = <Duration?>[];
  final seeks = <Duration>[];
  double nativeSpeed = 1;
  double nativePitch = 1;
  bool nativePlaying = false;
  Duration nativePosition = Duration.zero;
  int playCalls = 0;
  bool disposed = false;
  void Function()? onLoad;
  Completer<void>? loadGate;
  Completer<void>? speedGate;
  Completer<void>? progressGate;
  Object? progressError;
  int progressCalls = 0;
  final progressSamples = <NativePlaybackProgress?>[];

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<NativePlaybackProgress?> getNativePlaybackProgress() async {
    progressCalls++;
    final sample = progressSamples.isEmpty ? null : progressSamples.removeAt(0);
    await progressGate?.future;
    if (progressError != null) throw progressError!;
    return sample;
  }

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
    onLoad?.call();
    nativePosition = initialPosition ?? Duration.zero;
    await loadGate?.future;
    if (errors.isNotEmpty) throw errors.removeAt(0);
    return const Duration(minutes: 2);
  }

  @override
  Future<void> setSpeed(double value) async {
    nativeSpeed = value;
    await speedGate?.future;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    nativePosition = position ?? Duration.zero;
    seeks.add(nativePosition);
  }

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
  int refreshMetadataCalls = 0;
  Video? metadataResult;
  Object? metadataError;
  Completer<void>? metadataGate;
  bool stripMusicMetadata = false;
  final retryVideos = <Video>[];

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    metadataCalls++;
    await metadataGate?.future;
    if (metadataError != null) throw metadataError!;
    final result = metadataResult;
    if (result == null) {
      throw StateError('Direct audio admission must not fetch metadata');
    }
    if (result.backendPlayback != null) {
      onBackendRequest?.call(result.backendPlayback!);
    }
    return result;
  }

  @override
  Future<Video> refreshPlaybackVideo(Video video,
      {required bool Function() isCurrent}) async {
    if (!isCurrent()) throw StateError('Stale recovery');
    refreshMetadataCalls++;
    return video.copyWith(
        playbackConnection: video.playbackConnection ?? video.backendPlayback,
        playbackSourceId: Object());
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];

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
    return video.copyWith(
        backendPlayback: next,
        musicMetadata: stripMusicMetadata ? null : video.musicMetadata,
        title: stripMusicMetadata ? 'Upload' : video.title,
        author: stripMusicMetadata ? 'Channel' : video.author);
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

AdaptiveFormat _adaptive(String url, {String bitrate = '128000'}) =>
    AdaptiveFormat(null, bitrate, null, url, '140', 'audio/mp4', '100', '1',
        'RECTANGULAR', 'mp4', 'mp4a', null, null);

NativePlaybackProgress _progress(int seconds, int position,
        {int revision = 1,
        ProcessingState processing = ProcessingState.ready}) =>
    NativePlaybackProgress(
        position: Duration(seconds: position),
        bufferedPosition: const Duration(seconds: 100),
        duration: const Duration(seconds: 120),
        sampledAtMillis: seconds * 1000,
        sourceRevision: revision,
        playWhenReady: true,
        isPlaying: processing == ProcessingState.ready,
        processingState: processing,
        suppressionReason: 0,
        seekPending: false,
        hasError: false);

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
    expect(first.headers, preferred.headersForUrl(first.uri.toString()));
    expect(first.headers?['Cookie'], contains('ROUTE=0'));
    expect(second.headers?['Cookie'], contains('ROUTE=1'));
    expect(second.headers?['Cookie'], contains('login=kept'));
    expect(second.headers?['X-Instance'], 'kept');
    expect(native.sourcePositions,
        [const Duration(seconds: 12), const Duration(seconds: 12)]);
    expect(native.nativePlaying, isTrue);
    final effectiveServer = audio.state.video!.backendPlayback!.server;
    expect(
        second.headers, effectiveServer.headersForUrl(second.uri.toString()));
    expect(second.headers?[gatewayContextHeader], isNotEmpty);
    expect(effectiveServer.customHeaders,
        {'Cookie': 'login=kept; ROUTE=1', 'X-Instance': 'kept'});
    expect(
        effectiveServer.customHeaders, isNot(contains(gatewayContextHeader)));
    expect((await db.getCurrentlySelectedServer()).customHeaders,
        preferred.customHeaders);
    expect(player.events.where((event) => event.state == MediaState.error),
        isEmpty);
    expect(
        player.events
            .where((event) => event.type == MediaEventType.backendRetry),
        hasLength(1));
  });

  test('recovered audio metadata survives a decoder remount', () async {
    final native = _NativeAudio()..errors.add(_retryable());
    final audio = create(native);
    await audio.playVideo(false);
    final recovered = audio.state.video!;
    expect(player.state.currentlyPlaying, same(recovered));
    await audio.close();
    players.remove(audio);
    player.switchAudio(false);
    player.switchAudio(true);
    final replacementNative = _NativeAudio();
    final replacement =
        create(replacementNative, video: player.state.currentlyPlaying);
    await replacement.playVideo(false);
    expect(
        (replacementNative.sources.single as UriAudioSource).headers?['Cookie'],
        contains('ROUTE=1'));
    expect(retryService.retryCalls, 1);
  });

  test('audio backend recovery retains music catalog labels', () async {
    retryService.stripMusicMetadata = true;
    const music =
        MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
    final native = _NativeAudio()..errors.add(_retryable());
    final audio = create(native,
        video: _video('song', preferred).copyWith(musicMetadata: music));
    await audio.playVideo(false, startAt: Duration.zero);
    expect(audio.state.video!.musicMetadata, music);
    expect(audio.state.video!.title, 'Song');
    expect(audio.state.video!.author, 'Artist');
    expect(player.state.currentlyPlaying!.musicMetadata!.album, 'Album');
  });

  test('midstream standard Invidious audio refreshes the same admitted route',
      () async {
    final source = _video('song', preferred).copyWith(
        backendPlayback: null,
        playbackConnection: BackendPlayback(preferred),
        playbackSourceId: Object(),
        queueEntryId: 'song-occurrence');
    final native = _NativeAudio();
    final audio = create(native, video: source);
    await audio.playVideo(false, startAt: const Duration(seconds: 12));
    native.nativePosition = const Duration(seconds: 80);
    native.progressSamples.add(_progress(2, 37));
    player.refreshedVideo =
        source.copyWith(playbackSourceId: Object(), formatStreams: [
      FormatStream('${preferred.url}/fresh.mp4', '18', 'video/mp4', 'medium',
          'mp4', 'h264', '360p', '360p', '640x360')
    ]);
    audio.onPlaybackError(_retryable());
    audio.onPlaybackError(_retryable());
    await _flush();

    expect(player.refreshCalls, 1);
    expect(retryService.retryCalls, 0);
    expect(native.sources, hasLength(2));
    expect(native.sourcePositions.last, const Duration(seconds: 37));
    expect((native.sources.last as UriAudioSource).uri.path, '/fresh.mp4');
    expect(audio.state.video!.queueEntryId, 'song-occurrence');
    expect(audio.state.video!.backendPlayback, isNull);
    expect(native.nativePlaying, isTrue);
  });

  for (final refusal in <Object>[
    InvidiousServiceError('Refused', statusCode: 401),
    InvidiousServiceError('Refused', statusCode: 403),
    InvidiousServiceError('Limited', statusCode: 429),
    InvidiousServiceError('Wait',
        statusCode: 503, retryAfter: const Duration(seconds: 10)),
    const HandshakeException('Certificate refused'),
    const SocketException('Privacy refused'),
  ]) {
    test('audio refresh ${refusal.runtimeType} refusal never changes backend',
        () async {
      final native = _NativeAudio();
      final audio = create(native);
      await audio.playVideo(false);
      player.refreshError = refusal;
      audio.onPlaybackError(_retryable());
      await _flush();
      expect(player.refreshCalls, 1);
      expect(retryService.retryCalls, 0);
      expect(native.sources, hasLength(1));
      expect(audio.state.error, isNotNull);
      expect(native.nativePlaying, isFalse);
    });
  }

  for (final userPause in [false, true]) {
    test(
        'audio refresh preserves seek, rate and temporary focus, pause=$userPause',
        () async {
      final native = _NativeAudio();
      final audio = create(native);
      await audio.playVideo(false, startAt: const Duration(seconds: 12));
      player.refreshGate = Completer<void>();
      player.refreshedVideo =
          audio.state.video!.copyWith(playbackSourceId: Object());
      audio.onPlaybackError(_retryable());
      await _flush();
      expect(player.refreshCalls, 1);
      audio.seek(const Duration(seconds: 45));
      audio.setSpeed(1.75);
      audio.setPitchSemitones(12);
      player.interrupted = true;
      audio.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause));
      native.nativePlaying = false;
      if (userPause) audio.pause();
      player.refreshGate!.complete();
      await _flush();

      expect(native.sources, hasLength(2));
      expect(native.nativePosition, const Duration(seconds: 45));
      expect(native.nativeSpeed, 1.75);
      expect(native.nativePitch, 2);
      expect(native.nativePlaying, isFalse);
      expect(native.playCalls, 1);
      player.interrupted = false;
      audio.handleAudioInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await _flush();
      expect(native.nativePlaying, !userPause);
      expect(native.playCalls, userPause ? 1 : 2);
    });
  }

  test('audio refresh completed during duck is not left paused at duck end',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    player.refreshGate = Completer<void>();
    player.refreshedVideo =
        audio.state.video!.copyWith(playbackSourceId: Object());
    audio.onPlaybackError(_retryable());
    await _flush();
    final begin = AudioInterruptionEvent(true, AudioInterruptionType.duck);
    player.handleAudioInterruption(begin);
    audio.handleAudioInterruption(begin);
    player.refreshGate!.complete();
    await _flush();
    expect(native.nativePlaying, isTrue);
    expect(native.sources, hasLength(2));
    final plays = native.playCalls;
    final end = AudioInterruptionEvent(false, AudioInterruptionType.duck);
    player.handleAudioInterruption(end);
    audio.handleAudioInterruption(end);
    await _flush();
    expect(native.nativePlaying, isTrue);
    expect(native.playCalls, plays);
  });

  for (final userPause in [false, true]) {
    test('pause then duck releases the local audio gate, userPause=$userPause',
        () async {
      final native = _NativeAudio();
      final audio = create(native);
      await audio.playVideo(false);
      final pause = AudioInterruptionEvent(true, AudioInterruptionType.pause);
      player.handleAudioInterruption(pause);
      audio.handleAudioInterruption(pause);
      await native.pause(); // just_audio handles the original focus loss.
      final duck = AudioInterruptionEvent(true, AudioInterruptionType.duck);
      player.handleAudioInterruption(duck);
      audio.handleAudioInterruption(duck);
      if (userPause) {
        player.pause();
        audio.handleCommand(player.state.mediaCommand!);
      }
      final end = AudioInterruptionEvent(false, AudioInterruptionType.duck);
      player.handleAudioInterruption(end);
      audio.handleAudioInterruption(end);
      await _flush();
      expect(native.nativePlaying, !userPause);
      expect(native.sources, hasLength(1));
      if (userPause) {
        player.play();
        audio.handleCommand(player.state.mediaCommand!);
        expect(native.nativePlaying, isTrue);
      }
    });
  }

  test('permanent focus loss during refresh never resumes automatically',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    player.refreshGate = Completer<void>();
    player.refreshedVideo =
        audio.state.video!.copyWith(playbackSourceId: Object());
    audio.onPlaybackError(_retryable());
    await _flush();
    player.interrupted = true;
    audio.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    native.nativePlaying = false;
    player.refreshGate!.complete();
    await _flush();
    player.interrupted = false;
    audio.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.unknown));
    await _flush();
    expect(native.nativePlaying, isFalse);
    expect(native.playCalls, 1);
  });

  test('Play after permanent focus loss does not require an interruption end',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    player.refreshGate = Completer<void>();
    player.refreshedVideo =
        audio.state.video!.copyWith(playbackSourceId: Object());
    audio.onPlaybackError(_retryable());
    await _flush();
    final loss = AudioInterruptionEvent(true, AudioInterruptionType.unknown);
    player.handleAudioInterruption(loss);
    audio.handleAudioInterruption(loss);
    // just_audio pauses on permanent native focus loss. Android abandons the
    // focus request, so there need not be a later interruption-end event.
    native.nativePlaying = false;
    player.refreshGate!.complete();
    await _flush();
    expect(native.nativePlaying, isFalse);
    expect(native.playCalls, 1);

    player.play();
    audio.play();
    await _flush();
    expect(native.nativePlaying, isTrue);
    expect(native.playCalls, 2);
  });

  test(
      'the latest Play during temporary interruption resumes after focus returns',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    player.interrupted = true;
    audio.handleAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    native.nativePlaying = false;
    audio.pause();
    audio.play();
    expect(native.nativePlaying, isFalse);
    player.interrupted = false;
    audio.handleAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await _flush();
    expect(native.nativePlaying, isTrue);
    expect(native.playCalls, 2);
  });

  test('a late audio refresh cannot replace a newer selection', () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    player.refreshGate = Completer<void>();
    player.refreshedVideo =
        audio.state.video!.copyWith(playbackSourceId: Object());
    audio.onPlaybackError(_retryable());
    await _flush();
    audio.switchVideo(_video('replacement', preferred));
    await _flush();
    player.refreshGate!.complete();
    await _flush();
    expect(native.sources, hasLength(2));
    expect(audio.state.video!.videoId, 'replacement');
    expect(
        (native.sources.last as UriAudioSource).uri.path, '/replacement.mp4');
    expect(audio.state.error, isNull);
  });

  test('parent Pause during refresh wins before its child command arrives',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    player.refreshGate = Completer<void>();
    player.refreshedVideo =
        audio.state.video!.copyWith(playbackSourceId: Object());
    audio.onPlaybackError(_retryable());
    await _flush();
    player.pause();
    player.refreshGate!.complete();
    await _flush();
    expect(native.sources, hasLength(2));
    expect(native.nativePlaying, isFalse);
    expect(native.playCalls, 1);
  });

  test(
      'a proved native audio stall refreshes from actual rather than animated position',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    player.refreshedVideo =
        audio.state.video!.copyWith(playbackSourceId: Object());
    native.nativePosition = const Duration(seconds: 80);
    for (final sample in [
      _progress(0, 10),
      _progress(2, 12),
      for (var time = 4; time <= 24; time += 2) _progress(time, 12),
    ]) {
      native.progressSamples.add(sample);
      await audio.checkForStalledPlayback();
    }
    await _flush();
    expect(player.refreshCalls, 1);
    expect(native.sources, hasLength(2));
    expect(native.sourcePositions.last, const Duration(seconds: 12));
    expect(retryService.retryCalls, 0);
    expect(
        player.recoveryProgress, isNot(contains(const Duration(seconds: 80))));
  });

  test(
      'native progress probes are single flight and a paused late sample is discarded',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    native.progressSamples.add(_progress(0, 10));
    native.progressGate = Completer<void>();
    final probing = audio.checkForStalledPlayback();
    await audio.checkForStalledPlayback();
    expect(native.progressCalls, 1);
    audio.pause();
    native.progressGate!.complete();
    await probing;
    await audio.checkForStalledPlayback();
    expect(native.progressCalls, 1);
    expect(player.refreshCalls, 0);
    expect(player.recoveryProgress, isEmpty);
  });

  test('alternate recovery progress also requires actual native advancement',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    audio.onPositionChanged(const Duration(seconds: 80));
    expect(player.backendProgress, isEmpty);
    native.progressSamples.addAll([_progress(0, 10), _progress(2, 12)]);
    await audio.checkForStalledPlayback();
    await audio.checkForStalledPlayback();
    expect(player.backendProgress,
        [const Duration(seconds: 10), const Duration(seconds: 12)]);
  });

  test('missing or failed native progress does not cause recovery', () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false);
    await audio.checkForStalledPlayback();
    native.progressError = PlatformException(code: 'Unavailable');
    await audio.checkForStalledPlayback();
    expect(player.refreshCalls, 0);
    expect(native.sources, hasLength(1));
    expect(audio.state.error, isNull);
  });

  testWidgets(
      'a missing native observation cannot block typed failure recovery',
      (tester) async {
    final native = _NativeAudio();
    final audio = create(native);
    await tester.runAsync(() => audio.playVideo(false));
    player.refreshedVideo =
        audio.state.video!.copyWith(playbackSourceId: Object());
    native.progressGate = Completer<void>();
    audio.onPlaybackError(_retryable());
    await tester.pump();
    expect(player.refreshCalls, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(player.refreshCalls, 1);
    expect(native.progressCalls, 1);
    native.progressGate!.complete();
    await tester.pump();
    await tester.runAsync(() => audio.close());
    players.remove(audio);
  });

  test(
      'native music interruption updates transport without replacing the source',
      () async {
    const music =
        MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
    final native = _NativeAudio();
    final audio = create(native,
        video: _video('song', preferred).copyWith(musicMetadata: music));
    await audio.playVideo(false, startAt: const Duration(seconds: 37));
    audio.onStateStreamChange(
        native_audio.PlayerState(false, ProcessingState.ready));
    expect(player.events.last.type, MediaEventType.pause);
    audio.onStateStreamChange(
        native_audio.PlayerState(true, ProcessingState.ready));
    expect(player.events.last.type, MediaEventType.play);
    expect(native.sources, hasLength(1));
    expect(native.sourcePositions.single, const Duration(seconds: 37));
    expect(audio.state.video!.musicMetadata, music);
  });

  for (final offline in [false, true]) {
    test(
        'resumed music publishes the admitted position to MediaSession, offline=$offline',
        () async {
      const position = Duration(seconds: 33);
      const music =
          MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
      final video = _video('song', preferred).copyWith(musicMetadata: music);
      const downloaded = DownloadedVideo(
          videoId: 'song',
          title: 'Song',
          lengthSeconds: 120,
          quality: 'audio',
          audioOnly: true,
          musicMetadata: music);
      final controller = _MediaSessionPlayer(
          PlayerState.init(null).copyWith(
              isAudio: true,
              isHidden: false,
              startAt: position,
              position: position,
              videos: offline ? [] : [video],
              currentlyPlaying: offline ? null : video,
              offlineVideos: offline ? [downloaded] : [],
              offlineCurrentlyPlaying: offline ? downloaded : null),
          settings);
      final handler = app_main.mediaHandler = MediaHandler(controller);
      final native = _NativeAudio();
      final audio = _Audio(
          AudioPlayerState(
              video: offline ? null : video,
              offlineVideo: offline ? downloaded : null),
          controller,
          settings,
          native);
      native.onLoad = () {
        audio.onPositionChanged(Duration.zero);
        audio.onStateStreamChange(
            native_audio.PlayerState(false, ProcessingState.ready));
      };
      try {
        await audio.playVideo(offline, startAt: position);
        expect(native.sourcePositions.single, position);
        expect(handler.playbackState.value.playing, isTrue);
        expect(handler.playbackState.value.updatePosition, position);
        expect(controller.state.position, position);
      } finally {
        await audio.close();
        await controller.close();
      }
    });
  }

  test('proxy audio-only responses route adaptive audio through the instance',
      () async {
    final native = _NativeAudio();
    final audio = create(native,
        video: _video('song', preferred)
            .copyWith(formatStreams: [], adaptiveFormats: [
          _adaptive('https://r1.googlevideo.com/videoplayback?id=song&itag=140')
        ]));
    await audio.playVideo(false);
    final source = native.sources.single as UriAudioSource;
    expect(source.uri.toString(),
        'https://instance.example/videoplayback?id=song&itag=140&host=r1.googlevideo.com');
    expect(source.headers?['Cookie'], contains('ROUTE=0'));
    expect(source.headers?['X-Instance'], 'kept');
    expect(audio.state.error, isNull);
  });

  for (final legacyProxy in [false, true]) {
    test('adaptive audio stays proxied with saved use-proxy=$legacyProxy',
        () async {
      await db.saveSetting(SettingsValue('use-proxy', '$legacyProxy'));
      final native = _NativeAudio();
      final audio = create(native,
          video: _video('song', preferred).copyWith(adaptiveFormats: [
            _adaptive('https://r1.googlevideo.com/audio-low', bitrate: '64000'),
            _adaptive('https://r1.googlevideo.com/audio'),
          ]));
      await audio.playVideo(false);
      final source = native.sources.single as UriAudioSource;
      expect(source.uri.path, '/audio');
      expect(source.uri.host, 'instance.example');
      expect(source.uri.queryParameters, {'host': 'r1.googlevideo.com'});
      expect(source.headers?['Cookie'], contains('ROUTE=0'));
      expect(audio.state.error, isNull);
    });

    test(
        'combined fallback stays on the instance with saved use-proxy=$legacyProxy',
        () async {
      await db.saveSetting(SettingsValue('use-proxy', '$legacyProxy'));
      final native = _NativeAudio();
      final audio = create(native,
          video: _video('song', preferred).copyWith(adaptiveFormats: [
            _adaptive('https://unrelated.example/unsafe'),
            _adaptive('not-a-url'),
          ]));
      await audio.playVideo(false);
      expect((native.sources.single as UriAudioSource).uri.toString(),
          'https://instance.example/song.mp4');
      expect(audio.state.error, isNull);
    });
  }

  test('audio-only proxy skips invalid URLs and never selects legacy HD720',
      () async {
    final native = _NativeAudio();
    final audio = create(native,
        video: _video('song', preferred).copyWith(formatStreams: [
          FormatStream('https://instance.example/legacy', '22', 'video/mp4',
              'hd720', 'mp4', 'h264', '720p', '720p', '1280x720'),
        ], adaptiveFormats: [
          _adaptive('https://unrelated.example/unsafe', bitrate: '300000'),
          _adaptive('https://user:password@r1.googlevideo.com/unsafe',
              bitrate: '200000'),
          _adaptive('https://r1.googlevideo.com/audio'),
        ]));
    await audio.playVideo(false);
    expect((native.sources.single as UriAudioSource).uri.toString(),
        'https://instance.example/audio?host=r1.googlevideo.com');
  });

  test('failed adaptive audio tries the combined source before another backend',
      () async {
    final native = _NativeAudio()..errors.add(_retryable());
    final audio = create(native,
        video: _video('song', preferred).copyWith(adaptiveFormats: [
          _adaptive('https://r1.googlevideo.com/audio'),
        ]));
    await audio.playVideo(false, startAt: const Duration(seconds: 37));

    expect(retryService.retryCalls, 0);
    expect(native.sources.map((source) => (source as UriAudioSource).uri.path),
        ['/audio', '/song.mp4']);
    expect(native.sourcePositions,
        [const Duration(seconds: 37), const Duration(seconds: 37)]);
    expect((native.sources.last as UriAudioSource).headers?['Cookie'],
        contains('ROUTE=0'));
    expect(native.playCalls, 1);
    expect(audio.state.error, isNull);
  });

  for (final (advertised, selected) in [
    ('https://invidious.nerdvpn.de', 'http://$nerdVpnOnionHost'),
    ('http://$nerdVpnOnionHost', 'https://invidious.nerdvpn.de'),
  ]) {
    test('NerdVPN audio fallback stays on selected $selected', () async {
      final account = preferred.copyWith(url: selected);
      await db.upsertServer(account);
      await db.useServer(account);
      const signed = 'sig=a%2Fb%2Bc&x=one&x=two&host=rr1.googlevideo.com';
      final native = _NativeAudio()..errors.add(_retryable());
      final audio = create(native,
          video: _video('song', account).copyWith(
            adaptiveFormats: [
              _adaptive('$advertised/videoplayback?$signed&itag=140'),
            ],
            formatStreams: [
              FormatStream(
                  '$advertised/videoplayback?$signed&itag=18',
                  '18',
                  'video/mp4',
                  'medium',
                  'mp4',
                  'h264',
                  '360p',
                  '360p',
                  '640x360'),
            ],
          ));
      await audio.playVideo(false, startAt: const Duration(seconds: 37));

      final sources = native.sources.cast<UriAudioSource>();
      expect(sources.map((source) => source.uri.toString()), [
        '$selected/videoplayback?$signed&itag=140',
        '$selected/videoplayback?$signed&itag=18',
      ]);
      for (final source in sources) {
        expect(source.headers?['Cookie'], contains('ROUTE=0'));
        expect(source.headers?['Cookie'], contains('login=kept'));
        expect(source.headers?['X-Instance'], 'kept');
      }
      expect(retryService.retryCalls, 0);
      expect(native.sourcePositions,
          [const Duration(seconds: 37), const Duration(seconds: 37)]);
      expect(native.playCalls, 1);
      expect(audio.state.error, isNull);
    });
  }

  test(
      'saved direct preference cannot send adaptive audio or credentials to Google',
      () async {
    await db.saveSetting(SettingsValue('use-proxy', 'false'));
    final native = _NativeAudio();
    final audio = create(native,
        video: _video('song', preferred).copyWith(adaptiveFormats: [
          _adaptive('https://r1.googlevideo.com/audio'),
        ]));
    await audio.playVideo(false);
    final source = native.sources.single as UriAudioSource;
    expect(source.uri.toString(),
        'https://instance.example/audio?host=r1.googlevideo.com');
    expect(source.headers?['Cookie'], contains('ROUTE=0'));
    expect(source.headers?['X-Instance'], 'kept');
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

  test('audio buffering and native pause stay coherent in the media session',
      () async {
    final video = _video('ordinary-video', preferred);
    final controller = _MediaSessionPlayer(
        PlayerState.init(null).copyWith(
            isAudio: true,
            isHidden: false,
            videos: [video],
            currentlyPlaying: video),
        settings);
    final handler = app_main.mediaHandler = MediaHandler(controller);
    final native = _NativeAudio();
    final audio =
        _Audio(AudioPlayerState(video: video), controller, settings, native);
    final observed = <(AudioProcessingState, bool, bool, bool)>[];
    void recordSession() {
      final state = handler.playbackState.value;
      observed.add((
        state.processingState,
        state.playing,
        state.controls.contains(MediaControl.play),
        state.controls.contains(MediaControl.pause),
      ));
    }

    try {
      await audio.playVideo(false, startAt: const Duration(seconds: 37));
      audio.onStateStreamChange(
          native_audio.PlayerState(true, ProcessingState.buffering));
      await _flush();
      recordSession();

      // Buffered-position updates must not claim that the decoder is ready.
      audio.onBufferChanged(const Duration(seconds: 45));
      await _flush();
      recordSession();

      // Audio focus can pause the native player while it is still buffering.
      native.nativePlaying = false;
      audio.onStateStreamChange(
          native_audio.PlayerState(false, ProcessingState.buffering));
      await _flush();
      recordSession();

      native.nativePlaying = true;
      audio.onStateStreamChange(
          native_audio.PlayerState(true, ProcessingState.buffering));
      await _flush();
      recordSession();

      audio.onStateStreamChange(
          native_audio.PlayerState(true, ProcessingState.ready));
      await _flush();
      recordSession();

      expect(observed, [
        (AudioProcessingState.buffering, true, false, true),
        (AudioProcessingState.buffering, true, false, true),
        // On Android, ready/false maps to PAUSED and exposes the Play button.
        (AudioProcessingState.ready, false, true, false),
        (AudioProcessingState.buffering, true, false, true),
        (AudioProcessingState.ready, true, false, true),
      ]);
      expect(controller.state.isPlaying, isTrue);
      expect(native.sources, hasLength(1));
      expect(native.playCalls, 1);
      expect(retryService.retryCalls, 0);
      expect(audio.state.error, isNull);
    } finally {
      await audio.close();
      await controller.close();
    }
  });

  test(
      'terminal audio failure remains actionable until Play reloads the source',
      () async {
    final video = _video('song', preferred);
    final controller = _MediaSessionPlayer(
        PlayerState.init(null).copyWith(
            isAudio: true,
            isHidden: false,
            videos: [video],
            currentlyPlaying: video),
        settings);
    controller.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(controller);
    final native = _NativeAudio();
    final audio =
        _Audio(AudioPlayerState(video: video), controller, settings, native);
    try {
      await audio.playVideo(false, startAt: const Duration(seconds: 37));
      audio.setSpeed(1.5);
      audio.setPitchSemitones(12);
      expect(controller.state.isPlaying, isTrue);
      audio.onPlaybackError(PlayerException(4001, 'Source failed', 0));
      expect(native.nativePlaying, isFalse);
      expect(controller.state.isPlaying, isFalse);
      expect(controller.state.mediaEvent.state, MediaState.error);
      expect(audio.state.error, isNotNull);
      // A queued Pause from a failed parent Retry must not hide this error.
      audio.handleCommand(const MediaCommand(MediaCommandType.pause));
      expect(controller.state.mediaEvent.state, MediaState.error);

      audio.onStateStreamChange(
          native_audio.PlayerState(true, ProcessingState.ready));
      audio.onDurationChanged(Duration.zero);
      audio.onPositionChanged(Duration.zero);
      audio.onBufferChanged(Duration.zero);
      await _flush();
      expect(controller.state.mediaEvent.state, MediaState.error);
      expect(controller.state.position, const Duration(seconds: 37));
      expect(controller.state.isPlaying, isFalse);

      retryService.metadataResult = video.copyWith(
          formatStreams: _video('fresh-song', preferred).formatStreams,
          backendPlayback: BackendPlayback(preferred),
          playbackSourceId: Object());
      retryService.metadataGate = Completer<void>();
      native.loadGate = Completer<void>();
      audio.handleCommand(const MediaCommand(MediaCommandType.play));
      await _flush();
      expect(retryService.metadataCalls, 1);
      expect(native.sources, hasLength(1));
      expect(controller.state.mediaEvent.state, MediaState.loading);
      expect(controller.state.isPlaying, isFalse);
      expect(native.playCalls, 1);

      // Another Play while the retry is pending changes intent, not readiness.
      audio.handleCommand(const MediaCommand(MediaCommandType.play));
      expect(retryService.metadataCalls, 1);
      expect(controller.state.isPlaying, isFalse);
      expect(controller.state.mediaEvent.state, MediaState.loading);
      expect(native.playCalls, 1);

      controller.seek(const Duration(seconds: 44));
      retryService.metadataGate!.complete();
      await _flush();
      expect(controller.state.mediaCommand!.type, MediaCommandType.switchVideo);
      audio.handleCommand(controller.state.mediaCommand!);
      await _flush();
      expect(native.sources, hasLength(2));
      expect(
          (native.sources.last as UriAudioSource).uri.path, '/fresh-song.mp4');
      expect(native.sourcePositions.last, const Duration(seconds: 44));

      // A pause while the explicit retry is loading must still win.
      controller.pause();
      audio.handleCommand(controller.state.mediaCommand!);
      native.loadGate!.complete();
      await _flush();
      expect(audio.state.error, isNull);
      expect(native.nativePlaying, isFalse);
      expect(controller.state.isPlaying, isFalse);
      expect(native.nativePosition, const Duration(seconds: 44));
      expect(native.nativeSpeed, 1.5);
      expect(native.nativePitch, 2);

      // Ordinary transport controls retain the admitted source.
      controller.play();
      audio.handleCommand(controller.state.mediaCommand!);
      expect(native.nativePlaying, isTrue);
      expect(controller.state.isPlaying, isTrue);
      controller.pause();
      audio.handleCommand(controller.state.mediaCommand!);
      expect(native.nativePlaying, isFalse);
      expect(controller.state.isPlaying, isFalse);
      expect(native.sources, hasLength(2));
    } finally {
      if (retryService.metadataGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      if (native.loadGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      await audio.close();
      await controller.close();
    }
  });

  test('Play after sparse music failure requests parent metadata hydration',
      () async {
    const video = Video(videoId: 'song', lengthSeconds: 120);
    const position = Duration(seconds: 33);
    final controller = _HydratingPlayer(
        PlayerState.init(null).copyWith(
            isAudio: true,
            isHidden: false,
            position: position,
            videos: [video],
            currentlyPlaying: video),
        settings);
    app_main.mediaHandler = MediaHandler(controller);
    final native = _NativeAudio();
    final audio =
        _Audio(AudioPlayerState(video: video), controller, settings, native);
    try {
      await audio.playVideo(false, startAt: position);
      expect(audio.state.error, isNotNull);
      expect(controller.state.mediaEvent.state, MediaState.error);
      audio.handleCommand(const MediaCommand(MediaCommandType.play));
      await _flush();
      expect(controller.requests, [(video: video, startAt: position)]);
      expect(native.sources, isEmpty);
      expect(native.playCalls, 0);
      expect(controller.state.isPlaying, isFalse);
      expect(controller.state.mediaEvent.state, MediaState.error);
    } finally {
      await audio.close();
      await controller.close();
    }
  });

  test('terminal audio Play resets exhausted refresh and backend budgets',
      () async {
    final exhaustedRoute = BackendPlayback(preferred).next()!.next()!;
    final initial = _video('song', preferred).copyWith(
        backendPlayback: exhaustedRoute,
        playbackConnection: exhaustedRoute,
        playbackSourceId: Object());
    final controller = _MediaSessionPlayer(
        PlayerState.init(null).copyWith(
            isAudio: true,
            isHidden: false,
            videos: [initial],
            currentlyPlaying: initial),
        settings);
    controller.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(controller);
    var current = initial;
    for (var attempt = 0; attempt < 2; attempt++) {
      current = (await controller.refreshCurrentPlayback(current,
          isCurrent: () => true))!;
    }
    expect(
        await controller.refreshCurrentPlayback(current, isCurrent: () => true),
        isNull);
    expect(retryService.refreshMetadataCalls, 2);
    final native = _NativeAudio();
    final audio =
        _Audio(AudioPlayerState(video: current), controller, settings, native);
    try {
      await audio.playVideo(false, startAt: const Duration(seconds: 24));
      audio.onPlaybackError(PlayerException(4001, 'Source failed', 0));
      final freshRoute = BackendPlayback(preferred);
      retryService.metadataResult = _video('song', preferred).copyWith(
          formatStreams: _video('fresh-song', preferred).formatStreams,
          backendPlayback: freshRoute,
          playbackConnection: freshRoute,
          playbackSourceId: Object());
      audio.handleCommand(const MediaCommand(MediaCommandType.play));
      await _flush();
      expect(retryService.metadataCalls, 1);
      expect(controller.state.mediaCommand!.type, MediaCommandType.switchVideo);
      audio.handleCommand(controller.state.mediaCommand!);
      await _flush();
      expect(
          (native.sources.last as UriAudioSource).uri.path, '/fresh-song.mp4');
      expect(native.nativePosition, const Duration(seconds: 24));
      expect(controller.state.currentlyPlaying!.backendPlayback!.retries, 0);
      expect(
          await controller.refreshCurrentPlayback(
              controller.state.currentlyPlaying!,
              isCurrent: () => true),
          isNotNull);
      expect(retryService.refreshMetadataCalls, 3);
    } finally {
      await audio.close();
      await controller.close();
    }
  });

  test('failed manual audio metadata retains the item and permits another Play',
      () async {
    final video = _video('song', preferred);
    final controller = _MediaSessionPlayer(
        PlayerState.init(null).copyWith(
            isAudio: true,
            isHidden: false,
            videos: [video],
            currentlyPlaying: video),
        settings);
    controller.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(controller);
    final native = _NativeAudio();
    final audio =
        _Audio(AudioPlayerState(video: video), controller, settings, native);
    try {
      await audio.playVideo(false, startAt: const Duration(seconds: 24));
      audio.onPlaybackError(PlayerException(4001, 'Source failed', 0));
      retryService.metadataError = StateError('Unavailable');
      audio.handleCommand(const MediaCommand(MediaCommandType.play));
      await _flush();
      expect(retryService.metadataCalls, 1);
      expect(controller.state.currentlyPlaying?.videoId, 'song');
      expect(controller.state.position, const Duration(seconds: 24));
      expect(controller.state.mediaEvent.state, MediaState.error);
      expect(native.sources, hasLength(1));
      retryService.metadataError = null;
      retryService.metadataResult = _video('song', preferred);
      audio.handleCommand(const MediaCommand(MediaCommandType.play));
      await _flush();
      expect(retryService.metadataCalls, 2);
      expect(controller.state.mediaCommand!.type, MediaCommandType.switchVideo);
      audio.handleCommand(controller.state.mediaCommand!);
      await _flush();
      expect(native.sources, hasLength(2));
      expect(native.nativePlaying, isTrue);
    } finally {
      await audio.close();
      await controller.close();
    }
  });

  test('late manual audio retry cannot replace a newer queue selection',
      () async {
    final video = _video('song', preferred);
    final controller = _MediaSessionPlayer(
        PlayerState.init(null).copyWith(
            isAudio: true,
            isHidden: false,
            videos: [video],
            currentlyPlaying: video),
        settings);
    controller.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(controller);
    final native = _NativeAudio();
    final audio =
        _Audio(AudioPlayerState(video: video), controller, settings, native);
    final gate = retryService.metadataGate = Completer<void>();
    try {
      await audio.playVideo(false);
      audio.onPlaybackError(PlayerException(4001, 'Source failed', 0));
      retryService.metadataResult = _video('song', preferred);
      audio.handleCommand(const MediaCommand(MediaCommandType.play));
      await _flush();
      expect(retryService.metadataCalls, 1);
      final replacement = _video('replacement', preferred);
      await controller.switchToVideo(replacement);
      audio.handleCommand(controller.state.mediaCommand!);
      await _flush();
      gate.complete();
      await _flush();
      expect(controller.state.currentlyPlaying?.videoId, 'replacement');
      expect(audio.state.video?.videoId, 'replacement');
      expect(native.sources, hasLength(2));
      expect(
          (native.sources.last as UriAudioSource).uri.path, '/replacement.mp4');
      expect(native.nativePlaying, isTrue);
      expect(retryService.metadataCalls, 1);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await _flush();
      await audio.close();
      await controller.close();
    }
  });

  test('audio admission honors a pause requested before metadata arrives',
      () async {
    final video = _video('song', preferred);
    final controller = _MediaSessionPlayer(
        PlayerState.init(null).copyWith(
            isAudio: true,
            isHidden: false,
            videos: [video],
            currentlyPlaying: video),
        settings);
    app_main.mediaHandler = MediaHandler(controller);
    // The parent retains this request while metadata loads, before the child
    // receives the switch command or mounts with the hydrated video.
    controller.pause();
    final native = _NativeAudio();
    final audio =
        _Audio(AudioPlayerState(video: video), controller, settings, native);
    try {
      await audio.playVideo(false, startAt: const Duration(seconds: 33));
      expect(native.sources, hasLength(1));
      expect(native.playCalls, 0);
      expect(native.nativePlaying, isFalse);
      expect(controller.state.isPlaying, isFalse);
      expect(native.nativePosition, const Duration(seconds: 33));
    } finally {
      await audio.close();
      await controller.close();
    }
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
    // Resolving a private download path performs real asynchronous directory
    // I/O. Wait for source admission, rather than a fixed number of microtasks.
    final reloaded = audio.stream
        .firstWhere((state) => !state.loading && state.error == null);
    audio.handleCommand(const MediaCommand(MediaCommandType.play));
    await reloaded;
    expect(native.sources, hasLength(2));
    expect(native.nativePlaying, isTrue);
    expect(retryService.metadataCalls, 0);
    expect(player.refreshCalls, 0);
  });

  for (final offline in [false, true]) {
    test('audio loading retains the latest seek, offline=$offline', () async {
      final native = _NativeAudio()..loadGate = Completer<void>();
      final sourceLoading = Completer<void>();
      native.onLoad = sourceLoading.complete;
      final audio = create(native,
          offlineVideo: offline
              ? const DownloadedVideo(
                  videoId: 'offline',
                  title: 'Offline',
                  lengthSeconds: 120,
                  quality: 'audio',
                  audioOnly: true)
              : null);
      final loading =
          audio.playVideo(offline, startAt: const Duration(seconds: 12));
      await sourceLoading.future;
      expect(native.sources, hasLength(1));
      audio.seek(const Duration(seconds: 35));
      audio.seek(const Duration(seconds: 45));
      expect(native.seeks, isEmpty);
      audio.pause();
      native.loadGate!.complete();
      await loading;

      expect(native.seeks, [const Duration(seconds: 45)]);
      expect(native.nativePosition, const Duration(seconds: 45));
      expect(audio.state.audioPosition, const Duration(seconds: 45));
      expect(native.nativePlaying, isFalse);
      expect(retryService.retryCalls, 0);
    });
  }

  test('a seek during audio recovery and rate setup survives replacement',
      () async {
    final native = _NativeAudio();
    final audio = create(native);
    await audio.playVideo(false, startAt: const Duration(seconds: 12));
    retryService.held = Completer<void>();
    audio.onPlaybackError(_retryable());
    await retryService.requested.future;
    audio.seek(const Duration(seconds: 35));
    expect(native.seeks, isEmpty);
    native.speedGate = Completer<void>();
    retryService.held!.complete();
    await _flush();
    expect(native.sources, hasLength(2));
    audio.seek(const Duration(seconds: 45));
    audio.pause();
    native.speedGate!.complete();
    await _flush();

    expect(native.nativePosition, const Duration(seconds: 45));
    expect(audio.state.audioPosition, const Duration(seconds: 45));
    expect(native.seeks.last, const Duration(seconds: 45));
    expect(native.nativePlaying, isFalse);
    expect(retryService.retryCalls, 1);
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
      audio.seek(const Duration(seconds: 45));
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
        expect(native.nativePosition, Duration.zero);
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

    final source = native.sources.single as UriAudioSource;
    expect(source.headers, current.headersForUrl(source.uri.toString()));
    expect(native.playCalls, 1);
    expect(retryService.retryCalls, 0);
    expect(retryService.metadataCalls, 0);
  });
}
