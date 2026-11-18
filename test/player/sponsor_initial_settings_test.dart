import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
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
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _DelayedMetadataService extends Service {
  final metadataStarted = Completer<void>();
  final metadata = Completer<Video>();
  final sponsorPrepared = Completer<void>();
  final sponsorRequests = <List<SponsorSegmentType>>[];

  @override
  Future<Video> getMusicVideo(String videoId,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest,
          VideoLoadObserver? loadObserver}) =>
      getVideo(videoId,
          serverOverride: serverOverride,
          onBackendRequest: onBackendRequest,
          loadObserver: loadObserver);

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) {
    metadataStarted.complete();
    return metadata.future;
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
      String videoId, List<SponsorSegmentType> categories) async {
    sponsorRequests.add(List.of(categories));
    sponsorPrepared.complete();
    return [
      SponsorSegment('skip', [0, 10], SponsorSegmentType.sponsor)
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = Video(
      videoId: 'abcdefghijk',
      lengthSeconds: 60,
      musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late Service previousService;
  late bool previousTv;
  late _DelayedMetadataService source;

  setUp(() async {
    previousService = service;
    previousTv = app_main.isTv;
    service = source = _DelayedMetadataService();
    // TV source setup does not initialize an Android notification service.
    app_main.isTv = true;
    db = await SembastSqfDb.createInMemory();
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    await db.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'true'));
    await db.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
    app_main.isTv = previousTv;
  });

  test('disabling a prepared sponsor category prevents an initial source skip',
      () async {
    final commands = <MediaCommand>[];
    final observation = player.stream.listen((state) {
      final command = state.mediaCommand;
      if (command != null &&
          (commands.isEmpty || !identical(commands.last, command))) {
        commands.add(command);
      }
    });
    addTearDown(observation.cancel);

    final playback = player.playVideo([song], audio: true);
    await source.metadataStarted.future.timeout(const Duration(seconds: 2));
    await source.sponsorPrepared.future.timeout(const Duration(seconds: 2));
    // Drain the completed prefetch's callback while metadata is still held.
    await Future<void>.delayed(Duration.zero);
    expect(source.sponsorRequests, [
      [SponsorSegmentType.sponsor]
    ]);
    expect(
        commands
            .where((command) => command.type == MediaCommandType.switchVideo),
        isEmpty);

    await settings.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    source.metadata
        .complete(song.copyWith(formatStreams: [], adaptiveFormats: []));
    await playback.timeout(const Duration(seconds: 2));

    final switches = commands
        .where((command) => command.type == MediaCommandType.switchVideo)
        .toList();
    expect(switches, hasLength(1));
    expect((switches.single.value as SwitchVideoValue).startAt, Duration.zero);
    expect(player.state.startAt, Duration.zero);
    expect(player.state.position, Duration.zero);
    expect(player.state.sponsorSegments, isEmpty);
    expect(commands.where((command) => command.type == MediaCommandType.seek),
        isEmpty);
    expect(source.sponsorRequests, hasLength(1));
  });
}
