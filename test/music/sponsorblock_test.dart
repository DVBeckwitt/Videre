import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
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

class _SponsorService extends Service {
  List<SponsorSegment> segments = [];
  Completer<List<SponsorSegment>>? pending;
  bool fails = false;
  final requests = <({String id, List<SponsorSegmentType> categories})>[];

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
      String videoId, List<SponsorSegmentType> categories) async {
    requests.add((id: videoId, categories: categories));
    if (fails) throw StateError('SponsorBlock unavailable');
    if (pending != null) return pending!.future;
    return segments;
  }
}

class _SponsorPlayer extends TestPlayerCubit {
  _SponsorPlayer(super.initialState, super.settings);

  void seed(Video video) => emit(state.copyWith(
      videos: [video],
      currentlyPlaying: video,
      offlineVideos: [],
      offlineCurrentlyPlaying: null,
      isAudio: video.musicMetadata != null,
      isPlaying: true,
      position: Duration.zero));

  void seedOffline(List<SponsorSegment> segments) {
    final download = DownloadedVideo(
        videoId: song.videoId,
        title: 'Song',
        lengthSeconds: 60,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true,
        musicMetadata: song.musicMetadata,
        sponsorSegments: segments);
    emit(state.copyWith(
        currentlyPlaying: null,
        videos: [],
        offlineCurrentlyPlaying: download,
        offlineVideos: [download],
        isAudio: true,
        isPlaying: true,
        position: Duration.zero));
  }

  // These tests exercise segment admission and seeking, independently of history.
  @override
  Future<void> saveProgress(int timeInSeconds) async {}
}

SponsorSegment segment(double start, double end,
        {SponsorSegmentType category = SponsorSegmentType.sponsor,
        String action = 'skip'}) =>
    SponsorSegment(action, [start, end], category);

const song = Video(
    videoId: 'sOnqjkJTMaA',
    lengthSeconds: 60,
    musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service previousService;
  late _SponsorService source;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _SponsorPlayer player;

  setUp(() async {
    previousService = service;
    service = source = _SponsorService();
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _SponsorPlayer(PlayerState.init(null), settings)..seed(song);
  });

  tearDown(() async {
    app_main.isTv = false;
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
  });

  for (final tv in [false, true]) {
    test('Music skips exact sponsor interval on ${tv ? 'TV' : 'phone'}',
        () async {
      app_main.isTv = tv;
      player.seed(song.copyWith(queueEntryId: '${song.videoId}#2'));
      source.segments = [segment(10.25, 12.75)];
      await player.setSponsorBlock();
      expect(source.requests.single.id, song.videoId);
      expect(source.requests.single.categories,
          [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);

      await player.onProgress(const Duration(milliseconds: 10200));
      expect(player.state.position, const Duration(milliseconds: 10200));
      await player.onProgress(const Duration(milliseconds: 10250));
      expect(player.state.mediaCommand?.type, MediaCommandType.seek);
      expect(player.state.position, const Duration(milliseconds: 12750));
      expect(player.state.mediaEvent.type, MediaEventType.sponsorSkipped);
    });
  }

  test('overlapping segments skip once to the combined end', () async {
    source.segments = [segment(15, 25), segment(10, 20), segment(25, 26)];
    await player.setSponsorBlock();
    await player.onProgress(const Duration(seconds: 10));
    expect(player.state.position, const Duration(seconds: 26));
    final seek = player.state.mediaCommand;
    await player.onProgress(const Duration(seconds: 26));
    expect(identical(player.state.mediaCommand, seek), isTrue);
  });

  test('end segments skip without looping or adding extra song time', () async {
    source.segments = [segment(58.5, 60.5)];
    await player.setSponsorBlock();
    await player.onProgress(const Duration(milliseconds: 58750));
    expect(player.state.position, const Duration(seconds: 60));
    final seek = player.state.mediaCommand;
    await player.onProgress(const Duration(seconds: 60));
    expect(identical(player.state.mediaCommand, seek), isTrue);
  });

  test('malformed or unsupported segments cannot interrupt playback', () async {
    source.segments = [
      SponsorSegment('skip', [], SponsorSegmentType.sponsor),
      SponsorSegment('skip', [1], SponsorSegmentType.sponsor),
      segment(double.nan, 5),
      segment(1, double.infinity),
      segment(-1, 5),
      segment(7, 7),
      segment(8, 7),
      segment(60, 70),
      segment(1, 5, action: 'mute'),
      segment(20, 22),
    ];
    await expectLater(player.setSponsorBlock(), completes);
    expect(player.state.sponsorSegments, hasLength(1));
    await player.onProgress(const Duration(seconds: 21));
    expect(player.state.position, const Duration(seconds: 22));
  });

  test('non-music sections skip by default and respect explicit opt-out',
      () async {
    source.segments = [
      segment(1, 5, category: SponsorSegmentType.musicOffTopic),
      segment(10, 12),
    ];
    await player.setSponsorBlock();
    expect(source.requests.single.categories,
        [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);
    await player.onProgress(const Duration(seconds: 2));
    expect(player.state.position, const Duration(seconds: 5));

    await settings.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    await player.setSponsorBlock();
    expect(source.requests.last.categories, [SponsorSegmentType.sponsor]);
    await player.onProgress(const Duration(seconds: 2));
    expect(player.state.position, const Duration(seconds: 2));
    await player.onProgress(const Duration(seconds: 10));
    expect(player.state.position, const Duration(seconds: 12));
  });

  test('disabling all categories makes no request and clears existing segments',
      () async {
    source.segments = [segment(1, 5)];
    await player.setSponsorBlock();
    await settings.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    await settings.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    await player.setSponsorBlock();
    expect(source.requests, hasLength(1));
    expect(player.state.sponsorSegments, isEmpty);
  });

  test('optional SponsorBlock failure does not fail Music playback', () async {
    source.fails = true;
    await expectLater(player.setSponsorBlock(), completes);
    expect(player.state.currentlyPlaying, song);
    expect(player.state.isPlaying, isTrue);
    expect(player.state.sponsorSegments, isEmpty);
  });

  test('late lookup cannot overwrite a newer setting choice on the same song',
      () async {
    final pending = source.pending = Completer<List<SponsorSegment>>();
    final first = player.setSponsorBlock();
    await settings.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    await settings.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    await player.setSponsorBlock();
    pending.complete([segment(1, 5)]);
    await first;
    expect(player.state.sponsorSegments, isEmpty);
  });

  test('late lookup cannot attach to another occurrence of the same song',
      () async {
    final pending = source.pending = Completer<List<SponsorSegment>>();
    final first = player.setSponsorBlock();
    player.seed(song.copyWith(queueEntryId: '${song.videoId}#2'));
    pending.complete([segment(1, 5)]);
    await first;
    expect(player.state.sponsorSegments, isEmpty);
  });

  test('ordinary video playback shares sponsor and non-music defaults',
      () async {
    player.seed(song.copyWith(musicMetadata: null));
    source.segments = [
      segment(1, 5),
      segment(10, 15, category: SponsorSegmentType.musicOffTopic),
    ];
    await player.setSponsorBlock();
    expect(source.requests.single.categories,
        [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);
    await player.onProgress(const Duration(seconds: 2));
    expect(player.state.position, const Duration(seconds: 5));
    await player.onProgress(const Duration(seconds: 11));
    expect(player.state.position, const Duration(seconds: 15));
  });

  test('downloaded Music skips cached segments without a network lookup',
      () async {
    player.seedOffline([
      segment(1.25, 5.75),
      segment(10, 15, category: SponsorSegmentType.musicOffTopic),
    ]);
    await player.setSponsorBlock();
    await player.onProgress(const Duration(seconds: 2));
    expect(player.state.position, const Duration(milliseconds: 5750));
    await player.onProgress(const Duration(seconds: 11));
    expect(player.state.position, const Duration(seconds: 15));
    expect(source.requests, isEmpty);

    await settings.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    await player.setSponsorBlock();
    await player.onProgress(const Duration(seconds: 2));
    expect(player.state.position, const Duration(milliseconds: 5750));
    await player.onProgress(const Duration(seconds: 11));
    expect(player.state.position, const Duration(seconds: 11));
    expect(source.requests, isEmpty);
  });

  test('old downloads without segment cache still play offline', () async {
    player.seedOffline([]);
    await player.setSponsorBlock();
    await player.onProgress(const Duration(seconds: 2));
    expect(player.state.position, const Duration(seconds: 2));
    expect(player.state.isPlaying, isTrue);
    expect(source.requests, isEmpty);
  });
}
