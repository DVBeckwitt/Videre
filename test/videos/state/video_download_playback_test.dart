import 'dart:async';
import 'dart:io';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _server =
    Server(url: 'https://inv.example', profileId: 'person-a', id: 'account-a');
const _remote = Video(videoId: 'video', title: 'Remote title');

DownloadedVideo _saved() {
  final audio = AdaptiveFormat(
      null,
      '128000',
      null,
      'https://inv.example/audio?itag=251',
      '251',
      'audio/webm; codecs="opus"',
      '12345',
      '1700000000000',
      'RECTANGULAR',
      'webm',
      'opus',
      null,
      null);
  final video = AdaptiveFormat(
      null,
      '1000000',
      null,
      'https://inv.example/video?itag=248',
      '248',
      'video/webm; codecs="vp9"',
      '54321',
      '1700000000000',
      'RECTANGULAR',
      'webm',
      'vp9',
      '1080p',
      '1080');
  final proof = DownloadPlaybackProvenance.create(
      video: Video(videoId: 'video', adaptiveFormats: [audio, video]),
      server: _server,
      audioOnly: false,
      container: DownloadContainer.webm,
      audio: audio,
      videoFormat: video,
      byteLength: 10000,
      sha256: 'a' * 64)!;
  return DownloadedVideo(
      videoId: 'video',
      title: 'Saved title',
      profileId: _server.profileId,
      accountId: _server.accountId,
      author: 'Saved artist',
      lengthSeconds: 120,
      quality: '1080p',
      downloadComplete: true,
      container: DownloadContainer.webm,
      playbackProvenance: proof);
}

class _Database extends Fake implements IDbClient {
  String activeProfile = _server.profileId;
  Server selected = _server;
  DownloadedVideo? download;
  bool throwLookup = false;
  bool throwServerLookup = false;

  @override
  String get profileId => activeProfile;

  @override
  IDbClient forProfile(String id) => this;

  @override
  List<SettingsValue> getAllSettings() => [];

  @override
  SettingsValue? getSettings(String name) => null;

  @override
  DownloadedVideo? getDownloadByVideoId(String videoId) {
    if (throwLookup) throw StateError('Optional library lookup unavailable');
    return download?.videoId == videoId ? download : null;
  }

  @override
  Future<Server> getCurrentlySelectedServer() async {
    if (throwServerLookup) {
      throw StateError('Optional account lookup unavailable');
    }
    return selected.copyWith(profileId: activeProfile);
  }

  @override
  Future<void> upsertServer(Server server) =>
      throw UnsupportedError('This fixture does not write accounts');

  @override
  Future<void> insertLogs(AppLog log) =>
      throw UnsupportedError('This fixture does not write logs');
}

class _Settings extends Fake implements SettingsCubit {
  @override
  SettingsState get state => SettingsState.init();

  @override
  Stream<SettingsState> get stream => const Stream.empty();
}

class _Player extends Fake implements PlayerCubit {
  final prepared = <String>[];
  Completer<List<SponsorSegment>>? heldPreparation;
  Object? preparationError;
  bool asynchronousPreparationError = false;

  @override
  Future<List<SponsorSegment>> prepareSponsorSegments(String videoId) {
    prepared.add(videoId);
    if (preparationError case final error?) {
      if (asynchronousPreparationError) return Future.error(error);
      throw error;
    }
    return heldPreparation?.future ?? Future.value([]);
  }
}

class _Downloads extends Fake implements DownloadManagerCubit {
  final _Database database;
  _Downloads(this.database);

  @override
  DownloadManagerState get state => DownloadManagerState(
      videos: [if (database.download case final download?) download]);

  @override
  Stream<DownloadManagerState> get stream => const Stream.empty();
}

class _Metadata extends Fake implements Service {
  int calls = 0;
  int loginCalls = 0;
  Completer<Video>? held;
  Completer<bool>? heldLogin;
  final started = Completer<void>();
  final loginStarted = Completer<void>();
  VideoLoadObserver? observer;
  void Function(BackendPlayback)? backendObserver;

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    calls++;
    observer = loadObserver;
    backendObserver = onBackendRequest;
    if (!started.isCompleted) started.complete();
    final pending = held;
    if (pending != null) return pending.future;
    return _remote;
  }

  @override
  Future<bool> isLoggedIn() async {
    loginCalls++;
    if (!loginStarted.isCompleted) loginStarted.complete();
    final pending = heldLogin;
    if (pending != null) return pending.future;
    return false;
  }
}

/// Keep constructor autostart out of controlled interleavings, then execute the
/// real onReady body for every load, including overlapping generations.
class _Video extends VideoCubit {
  _Video(_Database database)
      : super(VideoState.init(videoId: 'video'), _Downloads(database),
            _Player(), _Settings());

  @override
  Future<void> onReady() async {}

  Future<void> load() => super.onReady();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late _Database database;
  late _Metadata metadata;
  late Service previousService;
  late _Video cubit;
  final states = <VideoState>[];
  StreamSubscription<VideoState>? subscription;
  Completer<void>? pathGate;
  late Completer<void> pathStarted;
  int pathCalls = 0;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    previousService = service;
    db = database = _Database()..download = _saved();
    service = metadata = _Metadata();
    documents = await Directory.systemTemp.createTemp('videre-video-route-');
    pathGate = null;
    pathStarted = Completer<void>();
    pathCalls = 0;
    states.clear();
    messenger.setMockMethodCallHandler(pathProvider, (_) async {
      pathCalls++;
      if (!pathStarted.isCompleted) pathStarted.complete();
      if (pathCalls == 1) await pathGate?.future;
      return documents.path;
    });
    cubit = _Video(database);
    subscription = cubit.stream.listen(states.add);
  });

  tearDown(() async {
    if (pathGate?.isCompleted == false) pathGate!.complete();
    if (!cubit.isClosed) await cubit.close();
    await subscription?.cancel();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
    service = previousService;
    debugDefaultTargetPlatformOverride = null;
  });

  test('route primes optional skips before metadata without waiting for them',
      () async {
    database.download = null;
    metadata.held = Completer<Video>();
    final player = cubit.player as _Player;
    final sponsor = player.heldPreparation = Completer<List<SponsorSegment>>();
    final loading = cubit.load();
    expect(player.prepared, ['video']);
    await metadata.started.future;
    expect(sponsor.isCompleted, isFalse);
    metadata.held!.complete(_remote);
    await loading;
    expect(cubit.state.video, _remote);
    expect(cubit.state.loadingVideo, isFalse);
    expect(sponsor.isCompleted, isFalse);
    sponsor.complete([]);
  });

  for (final saved in [false, true]) {
    for (final asynchronous in [false, true]) {
      test(
          '${asynchronous ? 'async' : 'sync'} optional preparation failure preserves ${saved ? 'local' : 'metadata'} playback',
          () async {
        if (!saved) database.download = null;
        metadata.held = Completer<Video>();
        final player = cubit.player as _Player
          ..preparationError = StateError('Optional preparation unavailable')
          ..asynchronousPreparationError = asynchronous;
        final loading = cubit.load();
        await metadata.started.future;
        expect(player.prepared, ['video']);
        if (saved) {
          expect(cubit.state.video?.downloadPlaybackOnly, isTrue);
          expect(cubit.state.loadingVideo, isFalse);
        }
        metadata.held!.complete(_remote);
        await loading;
        expect(cubit.state.video, _remote);
        expect(cubit.state.error, isEmpty);
      });
    }
  }

  test('compatible video publishes locally before metadata and login finish',
      () async {
    metadata.held = Completer<Video>();
    metadata.heldLogin = Completer<bool>();
    final pending = cubit.load();
    await metadata.started.future;
    expect(cubit.state.video!.downloadPlaybackOnly, isTrue);
    expect(cubit.state.video!.title, 'Saved title');
    expect(cubit.state.video!.adaptiveFormats, isNull);
    expect(cubit.state.video!.formatStreams, isNull);
    expect(cubit.state.loadingVideo, isFalse);
    expect(cubit.state.retryingVideo, isFalse);
    expect(cubit.state.error, isEmpty);
    expect(cubit.state.downloadedVideo, database.download);
    expect(metadata.calls, 1);
    expect(metadata.loginCalls, 0);
    metadata.backendObserver?.call(BackendPlayback(_server));
    metadata.observer!.onRetry();
    expect(cubit.state.requestedBackend, isNull);
    expect(cubit.state.retryingVideo, isFalse);
    metadata.held!.complete(_remote);
    await metadata.loginStarted.future;
    expect(cubit.state.video!.downloadPlaybackOnly, isTrue);
    expect(cubit.state.loadingVideo, isFalse);
    metadata.heldLogin!.complete(true);
    await pending;
    expect(cubit.state.video, _remote);
    expect(cubit.state.isLoggedIn, isTrue);
    expect(cubit.state.error, isEmpty);
  });

  test('optional enrichment failure retains the playable local details',
      () async {
    metadata.held = Completer<Video>();
    final pending = cubit.load();
    await metadata.started.future;
    final local = cubit.state.video;
    expect(local!.downloadPlaybackOnly, isTrue);
    metadata.held!.completeError(StateError('Instance unavailable'));
    await pending;
    expect(cubit.state.video, same(local));
    expect(cubit.state.loadingVideo, isFalse);
    expect(cubit.state.error, isEmpty);
    expect(metadata.loginCalls, 0);
  });

  for (final kind in ['absent', 'legacy', 'unknown-version']) {
    test('$kind provenance uses the ordinary metadata path', () async {
      final saved = database.download!;
      if (kind == 'absent') {
        database.download = null;
      } else if (kind == 'legacy') {
        database.download = saved.copyWith(playbackProvenance: null);
      } else {
        database.download = DownloadedVideo.fromJson({
          ...saved.toJson(),
          'playbackProvenance': {
            ...saved.playbackProvenance!.toJson(),
            'version': 99,
          },
        });
      }
      await cubit.load();
      expect(cubit.state.video, _remote);
      expect(cubit.state.loadingVideo, isFalse);
      expect(metadata.calls, 1);
      expect(metadata.loginCalls, 1);
      expect(pathCalls, 0);
    });
  }

  for (final kind in ['download lookup', 'account lookup', 'path lookup']) {
    test('optional $kind failure retains normal metadata fallback', () async {
      if (kind == 'download lookup') database.throwLookup = true;
      if (kind == 'account lookup') database.throwServerLookup = true;
      if (kind == 'path lookup') {
        messenger.setMockMethodCallHandler(pathProvider,
            (_) async => throw PlatformException(code: 'unavailable'));
      }
      await cubit.load();
      expect(cubit.state.video, _remote);
      expect(cubit.state.error, isEmpty);
      expect(metadata.calls, 1);
    });
  }

  for (final change in ['profile', 'database', 'close']) {
    test('$change while local preparation waits cannot publish or fetch',
        () async {
      pathGate = Completer<void>();
      final pending = cubit.load();
      await pathStarted.future;
      if (change == 'profile') {
        database.activeProfile = 'person-b';
      } else if (change == 'database') {
        db = _Database()..download = _saved();
      } else {
        await cubit.close();
      }
      pathGate!.complete();
      await pending;
      expect(cubit.state.video, isNull);
      expect(states.where((state) => state.video != null), isEmpty);
      expect(metadata.calls, 0);
      expect(metadata.loginCalls, 0);
    });
  }

  test(
      'a second load replaces an older local preparation without stale publish',
      () async {
    pathGate = Completer<void>();
    metadata.held = Completer<Video>();
    final first = cubit.load();
    await pathStarted.future;
    database.download = _saved().copyWith(title: 'Replacement title');
    final second = cubit.load();
    await metadata.started.future;
    expect(cubit.state.video!.title, 'Replacement title');
    pathGate!.complete();
    await first;
    expect(cubit.state.video!.title, 'Replacement title');
    expect(
        states
            .where((state) => state.video != null)
            .map((state) => state.video!.title)
            .toSet(),
        {'Replacement title'});
    expect(metadata.calls, 1);
    metadata.held!.complete(_remote);
    await second;
    expect(cubit.state.video, _remote);
  });

  for (final change in [
    'profile',
    'close',
    'account',
    'origin',
    'credentials',
    'headers',
  ]) {
    test('late enrichment after $change cannot replace published local details',
        () async {
      metadata.held = Completer<Video>();
      final pending = cubit.load();
      await metadata.started.future;
      final local = cubit.state.video;
      expect(local!.downloadPlaybackOnly, isTrue);
      if (change == 'profile') {
        database.activeProfile = 'person-b';
      } else if (change == 'close') {
        await cubit.close();
      } else if (change == 'account') {
        database.selected = _server.copyWith(id: 'account-b');
      } else if (change == 'credentials') {
        database.selected = _server.copyWith(authToken: 'changed-token');
      } else if (change == 'headers') {
        database.selected =
            _server.copyWith(customHeaders: {'X-Instance-Key': 'changed-key'});
      } else {
        database.selected = _server.copyWith(url: 'https://other.example');
      }
      metadata.held!.complete(_remote);
      await pending;
      expect(cubit.state.video, same(local));
      expect(cubit.state.error, isEmpty);
      expect(cubit.state.loadingVideo, isFalse);
    });
  }

  for (final change in ['profile', 'database']) {
    test('late remote completion after $change cannot commit or request login',
        () async {
      database.download = null;
      metadata.held = Completer<Video>();
      final pending = cubit.load();
      await metadata.started.future;
      if (change == 'profile') {
        database.activeProfile = 'person-b';
      } else {
        db = _Database();
      }
      expect(metadata.observer!.isCurrent(), isFalse);
      metadata.observer!.onRetry();
      metadata.backendObserver?.call(BackendPlayback(_server));
      metadata.held!.complete(_remote);
      await pending;
      expect(cubit.state.video, isNull);
      expect(cubit.state.requestedBackend, isNull);
      expect(cubit.state.retryingVideo, isFalse);
      expect(metadata.loginCalls, 0);
    });
  }

  test('profile change during login check prevents late remote publication',
      () async {
    database.download = null;
    metadata.heldLogin = Completer<bool>();
    final pending = cubit.load();
    await metadata.loginStarted.future;
    database.activeProfile = 'person-b';
    metadata.heldLogin!.complete(true);
    await pending;
    expect(cubit.state.video, isNull);
    expect(cubit.state.isLoggedIn, isFalse);
    expect(states.where((state) => state.video != null), isEmpty);
  });

  test('late remote error after profile change does not replace route state',
      () async {
    database.download = null;
    metadata.held = Completer<Video>();
    final pending = cubit.load();
    await metadata.started.future;
    database.activeProfile = 'person-b';
    metadata.held!.completeError(StateError('Old profile metadata failed'));
    await pending;
    expect(cubit.state.video, isNull);
    expect(cubit.state.error, isEmpty);
  });
}
