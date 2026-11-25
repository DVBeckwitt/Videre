import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:audio_session/audio_session.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/recommendations/music_playlist_recommendation_exclusions.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/recommendation_snapshot.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

class _LearningPlayer extends PlayerCubit {
  _LearningPlayer(SettingsCubit settings, int Function() clock)
      : super(PlayerState.init(null), settings,
            learningTimeMicroseconds: clock);

  @override
  Future<void> onReady() async {}

  @override
  void mapMediaEventToMediaHandler(MediaEvent event) {}

  void seed(Video video) => emit(state.copyWith(
      videos: [video],
      currentlyPlaying: video,
      isPlaying: true,
      isHidden: false));

  void seedDevice(LocalMusicTrack track) {
    final item = localMusicPlaybackEntry(track, db.profileId);
    emit(state.copyWith(
        videos: [],
        currentlyPlaying: null,
        offlineVideos: [item],
        offlineCurrentlyPlaying: item,
        isAudio: true,
        isPlaying: true,
        isHidden: false));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/recommendations');
  const video = Video(
      videoId: 'abcdefghijk', title: 'Actual playback', lengthSeconds: 100);
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _LearningPlayer player;
  late List<Map<Object?, Object?>> events;
  var time = 0;

  void sample(int seconds, {int? position}) {
    time = seconds * 1000000;
    player.setEvent(MediaEvent(
        type: MediaEventType.playbackSample,
        state: MediaState.playing,
        value: Duration(seconds: position ?? seconds)));
  }

  setUp(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _LearningPlayer(settings, () => time)..seed(video);
    events = [];
    time = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      events.addAll((args['events'] as List).cast<Map<Object?, Object?>>());
      return {
        'state': {'schemaVersion': 1, 'domain': args['domain']},
        'ranked': <Object?>[],
        'summary': <String, Object?>{},
      };
    });
  });

  tearDown(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    if (!player.isClosed) await player.close();
    await RecommendationService.flushPending();
    RecommendationService.forgetProfile(db, db.profileId);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await settings.close();
    await app.close();
    await db.close();
  });

  test('animated UI progress never becomes consumption evidence', () async {
    for (final seconds in [0, 50, 90]) {
      time = seconds * 1000000;
      player.setEvent(MediaEvent(
          type: MediaEventType.progress,
          state: MediaState.playing,
          value: Duration(seconds: seconds)));
    }
    await player.close();
    expect(events, isEmpty);
  });

  test('native samples count time once and exclude seek jumps', () async {
    sample(0);
    sample(10);
    player.seek(const Duration(seconds: 80));
    sample(11, position: 80);
    sample(13, position: 82);
    await player.close();
    expect(events, hasLength(1));
    expect(events.single['playedMs'], 12000);
    expect(events.single['skipped'], isFalse);
  });

  test('device audio never contributes native samples to recommendations',
      () async {
    player.seedDevice(const LocalMusicTrack(
        uri: 'content://media/tree/music/document/local',
        title: 'Local recording',
        durationMs: 60000));
    sample(0);
    sample(15);
    sample(30);
    await player.close();
    await RecommendationService.flushPending();
    expect(events, isEmpty);
    expect(
        db.getSettings(recommendationSettingName(RecommendationDomain.music)),
        isNull);
  });

  test('excluded playlist playback keeps history but never checkpoints',
      () async {
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    for (final type in SponsorSegmentType.values) {
      await db.saveSetting(SettingsValue(type.settingsName(), 'false'));
    }
    player.audioSession = await AudioSession.instance;
    final source = PlaylistReference(
        kind: PlaylistSourceKind.local,
        playlistId: 'local:quiet',
        profileId: db.profileId);
    final exclusions = MusicPlaylistRecommendationExclusions.forDatabase(db);
    await exclusions.setExcluded(source, excluded: true, isCurrent: () => true);
    final song = video.copyWith(
        musicMetadata:
            const MusicMetadata(title: 'Shared song', artist: 'Creator'),
        formatStreams: [],
        adaptiveFormats: []);
    final setting = recommendationSettingName(RecommendationDomain.music);
    final history = MusicListeningHistory.forProfile(db, db.profileId);

    await player.playPlaylist([song], reference: source, fromMusic: true);
    expect(player.state.currentlyPlaying?.videoId, song.videoId);
    final recorded = Completer<void>();
    void onHistoryChanged() {
      if (!recorded.isCompleted &&
          history.events(trackId: song.videoId).isNotEmpty) {
        recorded.complete();
      }
    }

    history.changes.addListener(onHistoryChanged);
    try {
      player.setEvent(const MediaEvent(
          type: MediaEventType.play, state: MediaState.playing));
      await recorded.future.timeout(const Duration(seconds: 5));
    } finally {
      history.changes.removeListener(onHistoryChanged);
    }
    expect(db.getPlaybackHistory(PlaybackHistoryOrigin.music).single.videoId,
        song.videoId);
    sample(0);
    sample(18);
    await RecommendationService.flushPending();
    expect(db.getSettings(setting), isNull);

    await exclusions.setExcluded(source,
        excluded: false, isCurrent: () => true);
    sample(35);
    await RecommendationService.flushPending();
    expect(db.getSettings(setting), isNull);
    await history.setRecordingPaused(true);
    await player.playPlaylist([song], reference: source, fromMusic: true);
    player.setEvent(
        const MediaEvent(type: MediaEventType.play, state: MediaState.playing));
    sample(36, position: 0);
    sample(53, position: 17);
    await player.close();
    expect(events, hasLength(1));
    expect(events.single['playedMs'], 17000);
    expect(history.events(trackId: song.videoId), hasLength(1));
  });

  test('a queued playlist occurrence is excluded independently of its copy',
      () async {
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    for (final type in SponsorSegmentType.values) {
      await db.saveSetting(SettingsValue(type.settingsName(), 'false'));
    }
    player.audioSession = await AudioSession.instance;
    final source = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLquiet',
        profileId: db.profileId);
    await MusicPlaylistRecommendationExclusions.forDatabase(db)
        .setExcluded(source, excluded: true, isCurrent: () => true);
    final song = video.copyWith(
        musicMetadata:
            const MusicMetadata(title: 'Shared song', artist: 'Creator'),
        formatStreams: [],
        adaptiveFormats: []);

    await player.playVideo([song], fromMusic: true);
    expect(
        await player.enqueueMusicSongs([song],
            next: false, recommendationSource: source),
        isTrue);
    final queueIds = player.state.videos.map(playbackQueueId).toList();
    expect(queueIds, hasLength(2));
    expect(queueIds.toSet(), hasLength(2));
    sample(0);
    sample(20);
    await player.selectQueueOccurrence(queueIds.last);
    expect(player.state.currentQueueId, queueIds.last);
    sample(21, position: 0);
    sample(45, position: 24);
    await player.close();
    expect(events, hasLength(1));
    expect(events.single['playedMs'], 20000);
    expect(player.savedSession?.musicRecommendationSources, {
      queueIds.last: musicPlaylistRecommendationKey(source),
    });
  });

  test('background and pause checkpoints preserve one seek-immune occurrence',
      () async {
    final key = recommendationSettingName(RecommendationDomain.video);
    Future<RecommendationSnapshot> saved() async {
      await RecommendationService.flushPending();
      return RecommendationSnapshot.tryParse(db.getSettings(key)?.value)!;
    }

    sample(0);
    sample(16);
    final periodic = (await saved()).pendingPlayback.single;
    expect(periodic.playedMs, 16000);
    // Same command path as a SponsorBlock jump. The new position is not time.
    player.seek(const Duration(seconds: 75));
    sample(17, position: 75);
    sample(20, position: 78);
    player.didChangeAppLifecycleState(AppLifecycleState.paused);
    final background = (await saved()).pendingPlayback.single;
    expect(background.id, periodic.id);
    expect(background.playedMs, 19000);
    expect(player.requestedPlaying, isTrue);
    sample(23, position: 81);
    player.pause();
    final paused = (await saved()).pendingPlayback.single;
    expect(paused.id, periodic.id);
    expect(paused.playedMs, 22000);
    expect(events, isEmpty);

    await player.close();
    expect(events.single['id'], periodic.id);
    expect(events.single['playedMs'], 22000);
    expect((await saved()).pendingPlayback, isEmpty);
  });

  test('Next without a successor does not split a listening session', () async {
    sample(0);
    sample(10);
    player.playNext();
    await Future<void>.delayed(Duration.zero);
    sample(20);
    await player.close();
    expect(events, hasLength(1));
    expect(events.single['playedMs'], 20000);
    expect(events.single['skipped'], isFalse);
  });

  for (final previous in [true, false]) {
    test(
        '${previous ? 'Previous at the start' : 'repeat-one Next'} is a rewind',
        () async {
      if (!previous) await settings.setRepeatMode(PlayerRepeat.repeatOne);
      sample(0);
      sample(15);
      if (previous) {
        player.playPrevious();
      } else {
        player.playNext();
      }
      await Future<void>.delayed(Duration.zero);
      sample(16, position: 0);
      sample(21, position: 5);
      await player.close();
      expect(events, hasLength(1));
      expect(events.single['playedMs'], 20000);
      expect(events.single['skipped'], isFalse);
    });
  }

  test('a completed repeat-one occurrence starts a new Music listen', () async {
    player.seed(video.copyWith(
        musicMetadata:
            const MusicMetadata(title: 'Repeated track', artist: 'Creator')));
    await settings.setRepeatMode(PlayerRepeat.repeatOne);
    sample(0);
    sample(60);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await Future<void>.delayed(Duration.zero);
    sample(61, position: 0);
    sample(121, position: 60);
    await player.close();
    expect(events, hasLength(2));
    expect(events.map((event) => event['playedMs']), [60000, 60000]);
    expect(events.map((event) => event['id']).toSet(), hasLength(2));
    expect(events.map((event) => event['completed']), [true, false]);
    expect(events.every((event) => event['skipped'] == false), isTrue);
  });

  test('only an explicit advancing watch records a selection, not autoplay',
      () async {
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    for (final type in SponsorSegmentType.values) {
      await db.saveSetting(SettingsValue(type.settingsName(), 'false'));
    }
    player.audioSession = await AudioSession.instance;
    final first = video.copyWith(formatStreams: [], adaptiveFormats: []);
    final second = first.copyWith(videoId: 'abcdefghijl');
    player.noteWatchSelection(first.videoId);
    await player.playVideo([first, second], playing: true);
    // Setup and a single initial observation are not a confirmed view.
    sample(0);
    await RecommendationService.flushPending();
    expect(events, isEmpty);
    sample(3);
    await RecommendationService.flushPending();
    expect(events.single['type'], 'click');

    final advanced = player.stream.firstWhere(
        (state) => state.currentlyPlaying?.videoId == second.videoId);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await advanced.timeout(const Duration(seconds: 2));
    player.setEvent(
        const MediaEvent(type: MediaEventType.play, state: MediaState.playing));
    sample(4, position: 0);
    sample(8, position: 4);
    await player.close();
    expect(events.where((event) => event['type'] == 'click'), hasLength(1));
    expect(events.where((event) => event['type'] == 'listen'), hasLength(2));
  });

  test('reset during playback discards all pre-reset consumption', () async {
    sample(0);
    sample(40);
    await RecommendationService.forProfile(db, db.profileId)
        .reset(RecommendationDomain.video);
    sample(45);
    sample(50);
    await player.close();
    expect(events, hasLength(1));
    expect(events.single['playedMs'], 5000);
  });

  test('natural completion records one completed session, never a skip',
      () async {
    await settings.setAutoplayQueue(false);
    sample(0);
    sample(90);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await player.close();
    expect(events, hasLength(1));
    expect(events.single['completed'], isTrue);
    expect(events.single['skipped'], isFalse);
  });
}
