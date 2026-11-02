import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _ArtworkFailurePlayer extends TestPlayerCubit {
  _ArtworkFailurePlayer(super.initialState, super.settings);

  @override
  Future<MediaItem?> getMediaItem(int index) async =>
      throw const FileSystemException('Artwork unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late MediaHandler handler;
  const videos = [
    Video(videoId: 'a', formatStreams: [], adaptiveFormats: []),
    Video(videoId: 'b', formatStreams: [], adaptiveFormats: []),
    Video(videoId: 'c', formatStreams: [], adaptiveFormats: []),
  ];

  setUp(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    db = await SembastSqfDb.createInMemory();
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    await db.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = handler = MediaHandler(player);
    await player.playVideo(videos);
  });

  tearDown(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  test(
      'turning queue autoplay off stops at completion and preserves manual next',
      () async {
    await settings.setAutoplayQueue(false);
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(player.state.currentlyPlaying?.videoId, 'a');
    expect(player.state.playQueue.toList(), ['b', 'c']);
    expect(player.state.playedVideos, isEmpty);
    expect(player.state.isPlaying, isFalse);
    // A late native play event cannot resume a stopped completion.
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    expect(player.state.isPlaying, isFalse);

    final next = player.stream
        .firstWhere((state) => state.currentlyPlaying?.videoId == 'b');
    player.playNext();
    await next.timeout(const Duration(seconds: 2));
    expect(player.state.playQueue.toList(), ['c']);
  });

  for (final audio in [false, true]) {
    test('queue autoplay defaults on and advances with audio=$audio', () async {
      expect(settings.state.autoplayQueue, isTrue);
      player.setAudio(audio);
      final next = player.stream
          .firstWhere((state) => state.currentlyPlaying?.videoId == 'b');
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await next.timeout(const Duration(seconds: 2));
      expect(player.state.playQueue.toList(), ['c']);
    });
  }

  for (final repeat in PlayerRepeat.values) {
    test('queue autoplay off also stops completion in ${repeat.name}',
        () async {
      await settings.setAutoplayQueue(false);
      await settings
          .saveSetting(SettingsValue(playerRepeat, '${repeat.index}'));
      player.setAudio(true);
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.state.currentlyPlaying?.videoId, 'a');
      expect(player.state.playQueue.toList(), ['b', 'c']);
      expect(player.state.isPlaying, isFalse);
      expect(player.requestedPlaying, isFalse);
    });
  }

  test('offline completion with autoplay off records watched and retains queue',
      () async {
    await settings.setAutoplayQueue(false);
    const downloads = [
      DownloadedVideo(
          videoId: 'offline-a',
          title: 'First',
          lengthSeconds: 10,
          quality: '720p',
          downloadComplete: true),
      DownloadedVideo(
          videoId: 'offline-b',
          title: 'Second',
          lengthSeconds: 10,
          quality: '720p',
          downloadComplete: true),
    ];
    await player.playOfflineVideos(downloads);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(player.state.offlineCurrentlyPlaying?.videoId, 'offline-a');
    expect(player.state.playQueue.toList(), ['offline-b']);
    expect(db.getVideoProgress('offline-a'), 1);
  });

  test(
      'media queue selection switches playback and publishes matching metadata',
      () async {
    await handler.skipToQueueItem(1);

    expect(player.state.currentlyPlaying?.videoId, 'b');
    expect(player.state.playedVideos, ['a']);
    expect(player.state.playQueue, ['c']);
    expect(handler.mediaItem.value?.id, 'b');
  });

  test('stale media queue indices leave playback unchanged', () async {
    for (final index in [-1, videos.length]) {
      await handler.skipToQueueItem(index);
      expect(player.state.currentlyPlaying?.videoId, 'a');
      expect(handler.mediaItem.value?.id, 'a');
    }
  });

  test('notification artwork failures do not stop a playable video', () async {
    await player.close();
    player = _ArtworkFailurePlayer(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = handler = MediaHandler(player);

    await player.playVideo([videos.first]);

    expect(player.state.currentlyPlaying?.videoId, 'a');
    expect(player.state.isClosing, isFalse);
    expect(player.state.videos, [videos.first]);
  });

  test('selecting a shuffled video removes it from upcoming playback',
      () async {
    await settings.setShuffle(true);
    // Leave the predictable initial order in place; shuffle must preserve it
    // apart from the selected item, rather than reshuffling after each tap.
    final switched = player.stream
        .firstWhere((state) => state.currentlyPlaying?.videoId == 'b');
    player.skipToVideo(1);
    await switched;

    expect(player.state.playedVideos, ['a']);
    expect(player.state.playQueue, ['c']);
    final next = player.stream
        .firstWhere((state) => state.currentlyPlaying?.videoId == 'c');
    player.playNext();
    await next;
    expect(player.state.playedVideos, ['a', 'b']);
    expect(player.state.playQueue, isEmpty);
  });
}
