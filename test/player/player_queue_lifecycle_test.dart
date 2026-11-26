import 'dart:collection';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _QueuePlayer extends TestPlayerCubit {
  _QueuePlayer(super.initialState, super.settings);

  void seedProgress(int lengthSeconds, Duration position) {
    final video = Video(videoId: 'progress', lengthSeconds: lengthSeconds);
    emit(state.copyWith(
        videos: [video], currentlyPlaying: video, position: position));
  }

  void seedQueue({bool offline = false, List<Video> unscheduled = const []}) {
    final videos = [
      const Video(videoId: 'a'),
      const Video(videoId: 'b'),
      const Video(videoId: 'c'),
      ...unscheduled,
    ];
    final downloads = videos
        .map((video) => DownloadedVideo(
            videoId: video.videoId,
            title: video.videoId,
            lengthSeconds: 60,
            quality: '720p'))
        .toList();
    emit(state.copyWith(
      videos: offline ? [] : videos,
      offlineVideos: offline ? downloads : [],
      currentlyPlaying: offline ? null : videos[1],
      offlineCurrentlyPlaying: offline ? downloads[1] : null,
      playedVideos: ['a'],
      playQueue: ListQueue.of(['c']),
    ));
  }

  void seedDuplicateQueue() {
    final videos = assignPlaybackQueueIds(const [
      Video(videoId: 'a'),
      Video(videoId: 'b'),
      Video(videoId: 'a'),
    ]);
    emit(state.copyWith(
        videos: videos,
        currentlyPlaying: videos[2],
        playedVideos: videos.take(2).map(playbackQueueId).toList(),
        playQueue: ListQueue<String>()));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _QueuePlayer player;

  setUp(() async {
    db = await createPlayerTestDatabase();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _QueuePlayer(PlayerState.init(null), settings);
  });

  tearDown(() async {
    if (!player.isClosed) await player.close();
    await settings.close();
    await db.close();
  });

  for (final offline in [false, true]) {
    for (final (oldIndex, newIndex, order, played, next) in [
      (0, 3, ['b', 'c', 'a'], <String>[], ['c', 'a']),
      (0, 2, ['b', 'a', 'c'], <String>[], ['a', 'c']),
      (2, 0, ['c', 'a', 'b'], ['c', 'a'], <String>[]),
      (1, 3, ['a', 'c', 'b'], ['a', 'c'], <String>[]),
    ]) {
      test(
          'reorder $oldIndex to $newIndex keeps queue order (offline=$offline)',
          () {
        player.seedQueue(offline: offline);
        player.onQueueReorder(oldIndex, newIndex);

        final videos =
            offline ? player.state.offlineVideos : player.state.videos;
        expect(videos.map((video) => video.videoId), order);
        expect(player.state.playedVideos, played);
        expect(player.state.playQueue, next);
        expect(
            player.state.currentlyPlaying?.videoId ??
                player.state.offlineCurrentlyPlaying?.videoId,
            'b');
      });
    }
  }

  test('reordering shuffled videos preserves actual playback history',
      () async {
    await settings.setShuffle(true);
    player.seedQueue();
    player.onQueueReorder(0, 3);
    expect(player.state.videos.map((video) => video.videoId), ['b', 'c', 'a']);
    expect(player.state.playedVideos, ['a']);
    expect(player.state.playQueue, ['c']);
  });

  test('reorder retains the selected occurrence of a repeated song', () {
    player.seedDuplicateQueue();
    final selected = player.state.currentQueueId;
    final first = playbackQueueId(player.state.videos[0]);
    player.onQueueReorder(2, 0);
    expect(player.state.currentQueueId, selected);
    expect(player.currentIndex, 0);
    expect(player.state.playedVideos, isEmpty);
    expect(player.state.playQueue, [first, 'b']);
  });

  for (final offline in [false, true]) {
    test('Music order moves previous and upcoming across current ($offline)',
        () {
      player.seedQueue(offline: offline);
      final active = player.state.currentlyPlaying;
      final activeDownload = player.state.offlineCurrentlyPlaying;
      Iterable<String> sourceIds() =>
          (offline ? player.state.offlineVideos : player.state.videos)
              .map(playbackQueueId);

      player.moveMusicQueueOccurrence('a', beforeId: 'c');
      expect(sourceIds(), ['b', 'a', 'c']);
      expect(player.state.playedVideos, isEmpty);
      expect(player.state.playQueue, ['a', 'c']);

      player.moveMusicQueueOccurrence('c', beforeId: 'b');
      expect(sourceIds(), ['c', 'b', 'a']);
      expect(player.state.playedVideos, ['c']);
      expect(player.state.playQueue, ['a']);
      expect(player.state.currentlyPlaying, same(active));
      expect(player.state.offlineCurrentlyPlaying, same(activeDownload));
    });
  }

  test('shuffled Music reorder preserves the mounted repeat and source order',
      () async {
    await settings.setShuffle(true);
    await settings.setRepeatMode(PlayerRepeat.repeatAll);
    player.seedDuplicateQueue();
    final source = player.state.videos;
    final active = player.state.currentlyPlaying;
    final first = playbackQueueId(source.first);
    final repeated = playbackQueueId(source.last);

    player.moveMusicQueueOccurrence(first);
    expect(player.state.playedVideos, ['b']);
    expect(player.state.playQueue, [first]);

    player.moveMusicQueueOccurrence(first, beforeId: 'b');
    expect(player.state.playedVideos, [first, 'b']);
    expect(player.state.playQueue, isEmpty);
    expect(player.state.currentQueueId, repeated);
    expect(player.state.currentlyPlaying, same(active));
    expect(player.state.videos, source);
  });

  test('Music reorder respects visible songs missing from a saved next queue',
      () {
    player.seedQueue(unscheduled: const [
      Video(videoId: 'd'),
      Video(videoId: 'e'),
      Video(videoId: 'f'),
    ]);
    final active = player.state.currentlyPlaying;
    player.moveMusicQueueOccurrence('a', beforeId: 'e');
    expect(player.state.playedVideos, isEmpty);
    expect(player.state.playQueue, ['c', 'd', 'a']);
    expect(player.state.videos.map(playbackQueueId),
        ['b', 'c', 'd', 'a', 'e', 'f']);

    player.moveMusicQueueOccurrence('c');
    expect(player.state.playQueue, ['d', 'a', 'e', 'f', 'c']);
    expect(player.state.currentlyPlaying, same(active));
  });

  test('removing one repeated song leaves the current occurrence intact', () {
    player.seedDuplicateQueue();
    final selected = player.state.currentQueueId;
    player.removeVideoFromQueue(playbackQueueId(player.state.videos[0]));
    expect(player.state.videos.map((video) => video.videoId), ['b', 'a']);
    expect(player.state.currentQueueId, selected);
    expect(player.currentIndex, 1);
    expect(player.state.playedVideos, ['b']);
    expect(player.state.isClosing, isFalse);
  });

  test('dropping an item in its existing slot leaves playback untouched', () {
    player.seedQueue();
    final before = player.state;
    player.onQueueReorder(0, 1);
    expect(player.state, same(before));
  });

  test('adding overlapping video batches keeps one entry per video', () {
    player.seedQueue();
    player.queueVideos(const [
      Video(videoId: 'c'),
      Video(videoId: 'd'),
      Video(videoId: 'd'),
      Video(videoId: 'e'),
    ]);

    expect(player.state.videos.map((video) => video.videoId),
        ['a', 'b', 'c', 'd', 'e']);
    expect(player.state.playQueue, ['c', 'd', 'e']);
  });

  test('repeated play-next requests move an existing video without duplicates',
      () {
    player.seedQueue();
    player.playVideoNext(const Video(videoId: 'd'));
    player.playVideoNext(const Video(videoId: 'c'));
    player.playVideoNext(const Video(videoId: 'c'));

    expect(player.state.videos.map((video) => video.videoId),
        ['a', 'b', 'c', 'd']);
    expect(player.state.playQueue, ['c', 'd']);
    expect(player.state.currentlyPlaying?.videoId, 'b');
  });

  test('adding no videos preserves audio mode and the current queue', () {
    player.seedQueue();
    player.setAudio(true);
    final before = player.state;

    player.queueVideos([]);

    expect(player.state, same(before));
  });

  test('playback progress is finite and bounded for unknown or stale duration',
      () {
    for (final (length, seconds, expected) in [
      (0, 0, 0.0),
      (0, 10, 0.0),
      (-1, 10, 0.0),
      (100, -1, 0.0),
      (100, 25, 0.25),
      (100, 105, 1.0),
    ]) {
      player.seedProgress(length, Duration(seconds: seconds));
      expect(player.progress, expected);
    }
  });

  testWidgets('closing a player cancels sleep, seek and drag callbacks',
      (tester) async {
    player.sleep(const SleepTimer(duration: Duration(seconds: 2)));
    player.fastForward();
    player.rewind();
    player.videoDragStarted(DragStartDetails());
    player.videoDraggedEnd(DragEndDetails());
    await tester.runAsync(player.close);

    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  test('rewind clamps a fractional underflow to the beginning of the song', () {
    final step = Duration(seconds: player.state.rewindStep);
    player.seedProgress(180, step - const Duration(milliseconds: 200));
    player.rewind();
    expect(player.state.position, Duration.zero);
    expect(player.state.mediaCommand?.type, MediaCommandType.seek);
    expect(player.state.mediaCommand?.value, Duration.zero);
  });

  test('seek keeps subsecond precision and clamps a fractional overflow', () {
    player.seedProgress(60, Duration.zero);
    const inside = Duration(milliseconds: 59750);
    player.seek(inside);
    expect(player.state.mediaCommand?.value, inside);
    player.seek(const Duration(milliseconds: 60250));
    expect(player.state.position, const Duration(minutes: 1));
    expect(player.state.mediaCommand?.value, const Duration(minutes: 1));
  });

  testWidgets('players keep independent sleep deadlines', (tester) async {
    final other = _QueuePlayer(PlayerState.init(null), settings);
    addTearDown(() => tester.runAsync(other.close));
    player.sleep(
        const SleepTimer(duration: Duration(seconds: 1), stopVideo: false));
    other.sleep(
        const SleepTimer(duration: Duration(seconds: 2), stopVideo: false));

    await tester.pump(const Duration(seconds: 1));
    expect(player.state.hasTimer, isFalse);
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    expect(other.state.hasTimer, isTrue);
    expect(other.state.mediaCommand, isNull);
    await tester.runAsync(player.close);
    await tester.pump(const Duration(seconds: 1));
    expect(other.state.hasTimer, isFalse);
    expect(other.state.mediaCommand?.type, MediaCommandType.pause);
  });

  testWidgets('players keep independent seek reset deadlines', (tester) async {
    final other = _QueuePlayer(PlayerState.init(null), settings);
    addTearDown(() => tester.runAsync(other.close));
    player.fastForward();
    player.rewind();
    await tester.pump(const Duration(milliseconds: 500));
    other.fastForward();
    other.rewind();

    await tester.pump(const Duration(milliseconds: 500));
    expect(player.state.totalFastForward, 0);
    expect(player.state.totalRewind, 0);
    expect(other.state.totalFastForward, greaterThan(0));
    expect(other.state.totalRewind, greaterThan(0));
    await tester.runAsync(player.close);
    await tester.pump(const Duration(milliseconds: 500));
    expect(other.state.totalFastForward, 0);
    expect(other.state.totalRewind, 0);
  });

  testWidgets('cancelling sleep leaves playback unchanged at the old deadline',
      (tester) async {
    player.sleep(const SleepTimer(duration: Duration(seconds: 1)));
    player.cancelSleep();
    await tester.pump(const Duration(seconds: 2));
    expect(player.state.hasTimer, isFalse);
    expect(player.state.mediaCommand, isNull);
    await tester.runAsync(player.close);
  });
}
