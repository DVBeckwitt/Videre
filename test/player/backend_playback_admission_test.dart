import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _AdmissionService extends Service {
  final requested = Completer<void>();
  final result = Completer<Video>();
  final ids = <String>[];
  void Function(BackendPlayback request)? observer;

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest}) {
    ids.add(videoId);
    observer = onBackendRequest;
    if (!requested.isCompleted) requested.complete();
    return result.future;
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];

  @override
  Future<bool> isLoggedIn() async => false;
}

Video _loaded(String id, Server server) => Video(
    videoId: id,
    formatStreams: [],
    adaptiveFormats: [],
    backendPlayback: BackendPlayback(server));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late Service previousService;
  late _AdmissionService admission;
  late Server original;
  late Server updated;

  setUp(() async {
    previousService = service;
    service = admission = _AdmissionService();
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
        'backend',
        const [
          BackendOption('a', 'Backend A'),
          BackendOption('b', 'Backend B')
        ],
        automaticFallback: true);
    original = selector.withSelection(
        Server(url: 'https://instance.example', backendSelector: selector),
        'a');
    updated =
        original.copyWith(customHeaders: {'Cookie': 'backend=b; login=new'});
    await db.upsertServer(updated);
    await db.useServer(updated);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    admission.httpClient.close();
    service = previousService;
  });

  test('cached loaded queue metadata is refetched after credentials change',
      () async {
    final cached = _loaded('cached', original);
    final current = _loaded('cached', updated);
    admission.result.complete(current);
    await player.playVideo([cached]);
    expect(admission.ids, ['cached']);
    expect(player.state.currentlyPlaying, same(current));
    expect(player.state.requestedBackend, same(current.backendPlayback));
    expect(player.state.currentlyPlaying!.backendPlayback!.server.customHeaders,
        updated.customHeaders);
  });

  test('a new queue supersedes a pending stale-context refresh', () async {
    final oldSwitch = player.playVideo([_loaded('old', original)]);
    await admission.requested.future;
    final staleObserver = admission.observer!;
    final replacement = _loaded('new', updated);
    await player.playVideo([replacement]);
    staleObserver(BackendPlayback(updated).next()!);
    admission.result.complete(_loaded('old', updated));
    await oldSwitch;
    expect(admission.ids, ['old']);
    expect(player.state.currentlyPlaying, same(replacement));
    expect(player.state.videos.single.videoId, 'new');
    expect(player.state.requestedBackend, same(replacement.backendPlayback));
  });

  test('queued metadata exposes named requests and keeps the successful one',
      () async {
    final loading = player.playVideo([const Video(videoId: 'pending')]);
    await admission.requested.future;
    final initial = BackendPlayback(updated);
    admission.observer!(initial);
    expect(player.state.requestedBackend, same(initial));
    final retry = initial.next()!;
    admission.observer!(retry);
    expect(player.state.requestedBackend, same(retry));
    expect(player.state.mediaEvent.type, MediaEventType.backendRetry);
    expect(player.state.mediaEvent.value, retry.label);
    admission.result
        .complete(_loaded('pending', updated).copyWith(backendPlayback: retry));
    await loading;
    player.setEvent(const MediaEvent(state: MediaState.playing));
    expect(player.state.requestedBackend, same(retry));
  });

  test('new video clears a previous request before metadata returns', () async {
    final old = _loaded('old', updated);
    await player.playVideo([old]);
    player.setRequestedBackend('old', old.backendPlayback!.next());
    final loading = player.playVideo([const Video(videoId: 'pending')]);
    await admission.requested.future;
    expect(player.state.requestedBackend, isNull);
    player.setRequestedBackend('old', old.backendPlayback);
    expect(player.state.requestedBackend, isNull);
    admission.result.complete(const Video(videoId: 'pending'));
    await loading;
    expect(player.state.requestedBackend, isNull);
  });

  test('same-video reload ignores the old decoder while metadata is pending',
      () async {
    final old = _loaded('same', updated);
    await player.playVideo([old]);
    final loading = player.switchToVideo(const Video(videoId: 'same'));
    await admission.requested.future;
    final fresh = _loaded('same', updated);
    admission.observer!(fresh.backendPlayback!);
    expect(player.setRequestedBackend('same', old.backendPlayback!.next()),
        isFalse);
    expect(player.state.requestedBackend, same(fresh.backendPlayback));
    admission.result.complete(fresh);
    await loading;
    expect(player.state.requestedBackend, same(fresh.backendPlayback));
  });

  test('offline playback and closing clear the requested backend', () async {
    final online = _loaded('online', updated);
    await player.playVideo([online]);
    await player.switchToOfflineVideo(const DownloadedVideo(
        videoId: 'offline',
        title: 'Offline',
        lengthSeconds: 10,
        quality: '360p'));
    expect(player.state.requestedBackend, isNull);
    player.setRequestedBackend('online', online.backendPlayback);
    expect(player.state.requestedBackend, isNull);
    await player.playVideo([online]);
    player.hide();
    expect(player.state.requestedBackend, isNull);
    player.setRequestedBackend('online', online.backendPlayback);
    expect(player.state.requestedBackend, isNull);
  });
}
