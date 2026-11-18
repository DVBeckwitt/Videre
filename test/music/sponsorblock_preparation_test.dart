import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _server = Server(url: 'https://inv.example', id: 'account-a');
const _id = 'sOnqjkJTMaA';

SponsorSegment _segment(double start, double end,
        {SponsorSegmentType category = SponsorSegmentType.sponsor}) =>
    SponsorSegment('skip', [start, end], category);

class _SponsorService extends Service {
  List<SponsorSegment> segments = [];
  Completer<List<SponsorSegment>>? pending;
  int metadataCalls = 0;
  final requests = <({String id, List<SponsorSegmentType> types})>[];
  final requested = Completer<void>();
  final allPending = <Completer<List<SponsorSegment>>>[];

  Completer<List<SponsorSegment>> hold() {
    final next = Completer<List<SponsorSegment>>();
    pending = next;
    allPending.add(next);
    return next;
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
      String videoId, List<SponsorSegmentType> categories) async {
    requests.add((id: videoId, types: List.of(categories)));
    if (!requested.isCompleted) requested.complete();
    final response = pending;
    if (response != null) return response.future;
    return segments;
  }

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    metadataCalls++;
    return Video(
        videoId: videoId,
        lengthSeconds: 60,
        formatStreams: [],
        adaptiveFormats: []);
  }
}

class _SponsorPlayer extends TestPlayerCubit {
  _SponsorPlayer(super.initialState, super.settings);

  @override
  Future<void> saveProgress(int timeInSeconds) async {}
}

Video _content({required bool audioOnly, String occurrence = 'first'}) {
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
  return Video(
      videoId: _id,
      queueEntryId: occurrence,
      title: 'Song',
      lengthSeconds: 60,
      musicMetadata: audioOnly
          ? const MusicMetadata(title: 'Song', artist: 'Artist')
          : null,
      adaptiveFormats: [audio, video],
      formatStreams: []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Service previous;
  late _SponsorService source;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _SponsorPlayer player;
  late Directory documents;

  Future<Video> save(
      {required bool audioOnly, List<SponsorSegment>? segments}) async {
    final video = _content(audioOnly: audioOnly);
    final proof = DownloadPlaybackProvenance.create(
        video: video,
        server: _server,
        audioOnly: audioOnly,
        container: DownloadContainer.webm,
        audio: video.adaptiveFormats!.first,
        videoFormat: audioOnly ? null : video.adaptiveFormats!.last,
        byteLength: 10000,
        sha256: 'a' * 64)!;
    await db.upsertDownload(DownloadedVideo(
        videoId: _id,
        title: 'Saved song',
        accountId: _server.accountId,
        lengthSeconds: 60,
        quality: audioOnly ? 'audio' : '1080p',
        audioOnly: audioOnly,
        container: DownloadContainer.webm,
        downloadComplete: true,
        playbackProvenance: proof,
        musicMetadata: video.musicMetadata,
        sponsorSegments: segments ?? [_segment(0, 8), _segment(20, 25)]));
    return video;
  }

  Future<PlayerState> switchedAfter(
      Future<void> Function() start, void Function(Future<void>) capture) {
    final previousCommand = player.state.mediaCommand;
    final switched = player.stream.firstWhere((state) =>
        state.mediaCommand?.type == MediaCommandType.switchVideo &&
        !identical(state.mediaCommand, previousCommand));
    capture(start());
    return switched;
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    app_main.isTv = true;
    previous = service;
    service = source = _SponsorService();
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(_server);
    await db.useServer(_server);
    documents = await Directory.systemTemp.createTemp('videre-sponsor-prep-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _SponsorPlayer(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
  });

  tearDown(() async {
    for (final pending in source.allPending) {
      if (!pending.isCompleted) pending.complete([]);
    }
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    source.httpClient.close();
    service = previous;
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
    app_main.isTv = false;
    debugDefaultTargetPlatformOverride = null;
  });

  test('early preparation rejects invalid identifiers before optional requests',
      () async {
    for (final id in [
      '',
      'short',
      '${_id}extra',
      '$_id&category=sponsor',
      'bad?query=x',
      '$_id\n',
    ]) {
      expect(await player.prepareSponsorSegments(id), isEmpty);
    }
    expect(source.requests, isEmpty);
  });

  for (final audioOnly in [true, false]) {
    for (final response in ['empty', 'error']) {
      test(
          'saved ${audioOnly ? 'music' : 'video'} skips immediately and keeps fallback on remote $response',
          () async {
        final video = await save(audioOnly: audioOnly);
        final pending = source.hold();
        late Future<void> loading;
        final switched = await switchedAfter(
            () => player
                .playVideo([video], audio: audioOnly, startAt: Duration.zero),
            (value) => loading = value);
        final command = switched.mediaCommand!;
        expect(switched.offlineCurrentlyPlaying, isNull);
        expect(switched.currentlyPlaying!.downloadPlaybackOnly, isTrue);
        expect(switched.startAt, const Duration(seconds: 8));
        expect(switched.position, const Duration(seconds: 8));
        expect((command.value as SwitchVideoValue).startAt,
            const Duration(seconds: 8));
        expect(source.metadataCalls, 0);
        expect(source.requests, hasLength(1));
        if (response == 'empty') {
          pending.complete([]);
        } else {
          pending.completeError(StateError('Optional SponsorBlock failed'));
        }
        await loading;
        expect(player.state.mediaCommand, same(command));
        expect(
            player.state.sponsorSegments.map((pair) => (pair.first, pair.last)),
            [(0, 8000), (20000, 25000)]);
        await player.onProgress(const Duration(seconds: 21));
        expect(player.state.mediaCommand!.type, MediaCommandType.seek);
        expect(player.state.mediaCommand!.value, const Duration(seconds: 25));
      });
    }
  }

  test(
      'ready remote segments take priority over saved fallback for initial skip',
      () async {
    final video = await save(audioOnly: true);
    source.segments = [_segment(0, 3)];
    await player.prepareSponsorSegments(_id);
    await player.playVideo([video], audio: true, startAt: Duration.zero);
    expect(player.state.startAt, const Duration(seconds: 3));
    expect((player.state.mediaCommand!.value as SwitchVideoValue).startAt,
        const Duration(seconds: 3));
    expect(source.requests, hasLength(1));
  });

  test('route preparation and playback share one pending SponsorBlock request',
      () async {
    final video = await save(audioOnly: true);
    final pending = source.hold();
    final primed = player.prepareSponsorSegments(_id);
    await source.requested.future;
    late Future<void> loading;
    final switched = await switchedAfter(
        () => player.playVideo([video], audio: true, startAt: Duration.zero),
        (value) => loading = value);
    expect(switched.startAt, const Duration(seconds: 8));
    expect(source.requests, hasLength(1));
    final command = switched.mediaCommand;
    pending.complete([_segment(0, 3)]);
    await primed;
    await loading;
    expect(source.requests, hasLength(1));
    expect(player.state.mediaCommand, same(command));
    expect(player.state.sponsorSegments.map((pair) => pair.last), [3000]);
  });

  test('current disabled categories filter saved fallback before source setup',
      () async {
    final video = await save(audioOnly: true, segments: [
      _segment(0, 8),
      _segment(10, 15, category: SponsorSegmentType.musicOffTopic),
    ]);
    await settings.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    source.segments = [];
    await player.playVideo([video], audio: true, startAt: Duration.zero);
    expect(player.state.startAt, Duration.zero);
    expect(player.state.sponsorSegments.map((pair) => (pair.first, pair.last)),
        [(10000, 15000)]);
    expect(source.requests.single.types, [SponsorSegmentType.musicOffTopic]);
    await settings.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    await player.setSponsorBlock();
    expect(player.state.sponsorSegments, isEmpty);
    expect(source.requests, hasLength(1));
  });

  test('disabling categories while a request waits cannot restore saved skips',
      () async {
    final video = await save(audioOnly: false);
    final pending = source.hold();
    late Future<void> loading;
    await switchedAfter(
        () => player.playVideo([video], audio: false, startAt: Duration.zero),
        (value) => loading = value);
    await settings.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    await settings.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    await player.setSponsorBlock();
    pending.complete([_segment(0, 8)]);
    await loading;
    expect(player.state.sponsorSegments, isEmpty);
  });

  for (final change in ['occurrence', 'account']) {
    test('saved fallback cannot follow a new $change without an admitted file',
        () async {
      final video = await save(audioOnly: true);
      final pending = source.hold();
      late Future<void> firstLoading;
      final first = await switchedAfter(
          () => player.playVideo([video], audio: true, startAt: Duration.zero),
          (value) => firstLoading = value);
      expect(first.startAt, const Duration(seconds: 8));
      if (change == 'occurrence') {
        await db.deleteDownload(db.getDownloadByVideoId(_id)!);
      } else {
        final next = _server.copyWith(id: 'account-b');
        await db.upsertServer(next);
        await db.useServer(next);
      }
      late Future<void> secondLoading;
      final second = await switchedAfter(
          () => player.playVideo([video.copyWith(queueEntryId: 'second')],
              audio: true, startAt: Duration.zero),
          (value) => secondLoading = value);
      expect(second.currentlyPlaying!.downloadPlaybackOnly, isFalse);
      expect(second.startAt, Duration.zero);
      expect(second.sponsorSegments, isEmpty);
      pending.complete([]);
      await firstLoading;
      await secondLoading;
      expect(player.state.currentlyPlaying!.queueEntryId, 'second');
      expect(player.state.sponsorSegments, isEmpty);
    });
  }

  test('old profile response cannot attach to the new profile queue', () async {
    final video = await save(audioOnly: true);
    final oldResponse = source.hold();
    late Future<void> firstLoading;
    await switchedAfter(
        () => player.playVideo([video], audio: true, startAt: Duration.zero),
        (value) => firstLoading = value);
    await player.prepareForProfileSwitch();
    final profile = await db.createProfile('Second person');
    await db.useProfile(profile.id);
    final otherServer =
        _server.copyWith(profileId: profile.id, id: 'account-b');
    await db.upsertServer(otherServer);
    await db.useServer(otherServer);
    await player.reloadForProfile();
    final nextResponse = source.hold();
    late Future<void> secondLoading;
    final second = await switchedAfter(
        () => player.playVideo([video.copyWith(queueEntryId: 'other-person')],
            audio: true, startAt: Duration.zero),
        (value) => secondLoading = value);
    expect(second.startAt, Duration.zero);
    expect(second.sponsorSegments, isEmpty);
    oldResponse.complete([_segment(0, 8)]);
    await firstLoading;
    expect(player.state.sponsorSegments, isEmpty);
    nextResponse.complete([]);
    await secondLoading;
    expect(player.state.currentlyPlaying!.queueEntryId, 'other-person');
    expect(player.state.sponsorSegments, isEmpty);
  });
}
