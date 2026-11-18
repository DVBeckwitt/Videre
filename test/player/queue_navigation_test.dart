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
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/gestures.dart';
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

class _PendingMetadataService extends Service {
  final started = Completer<void>();
  final response = Completer<Video>();

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) {
    started.complete();
    return response.future;
  }
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

  for (final mini in [false, true]) {
    test(
        'queue advance settles an interrupted ${mini ? 'mini' : 'expanded'} drag',
        () async {
      if (mini) player.showMiniPlayer();
      player.videoDragStarted(DragStartDetails());
      player.videoDragged(DragUpdateDetails(
          delta: const Offset(0, 60), globalPosition: const Offset(100, 700)));
      expect(player.state.isDragging, isTrue);
      final next = player.stream
          .firstWhere((state) => state.currentlyPlaying?.videoId == 'b');
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await next.timeout(const Duration(seconds: 2));
      expect(player.state.isDragging, isFalse);
      expect(player.state.isMini, mini);
      expect(player.state.top, mini ? isNull : 0);
      expect(player.state.dragDistance, 0);
      expect(player.state.showMiniPlaceholder, isFalse);
      expect(player.state.playQueue.toList(), ['c']);
    });
  }

  test('queue advance settles a drag begun while metadata was loading',
      () async {
    final previousService = service;
    final pending = _PendingMetadataService();
    service = pending;
    addTearDown(() => service = previousService);
    await player.playVideo([videos.first, const Video(videoId: 'b')]);
    player.showMiniPlayer();
    final next = player.stream
        .firstWhere((state) => state.currentlyPlaying?.videoId == 'b');
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await pending.started.future;
    player.videoDragStarted(DragStartDetails());
    player.videoDragged(DragUpdateDetails(
        delta: const Offset(0, 60), globalPosition: const Offset(100, 700)));
    pending.response.complete(videos[1]);
    await next.timeout(const Duration(seconds: 2));
    expect(player.state.isDragging, isFalse);
    expect(player.state.isMini, isTrue);
    expect(player.state.top, isNull);
  });

  test('replacing video with audio settles the discarded controls drag',
      () async {
    player.showMiniPlayer();
    player.videoDragStarted(DragStartDetails());
    player.videoDragged(DragUpdateDetails(
        delta: const Offset(0, 60), globalPosition: const Offset(100, 700)));
    player.switchAudio(true);
    expect(player.state.isAudio, isTrue);
    expect(player.state.isDragging, isFalse);
    expect(player.state.isMini, isTrue);
    expect(player.state.top, isNull);
  });

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

  const offlineSongs = [
    DownloadedVideo(
        videoId: 'saved-a',
        title: 'Current',
        lengthSeconds: 120,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true),
    DownloadedVideo(
        videoId: 'saved-b',
        title: 'Existing next',
        lengthSeconds: 120,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true),
    DownloadedVideo(
        videoId: 'saved-c',
        title: 'Selected first',
        lengthSeconds: 120,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true),
    DownloadedVideo(
        videoId: 'saved-d',
        title: 'Selected second',
        lengthSeconds: 120,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true),
  ];
  const selectedSavedSongs = [
    Video(videoId: 'saved-c'),
    Video(videoId: 'saved-d')
  ];

  Future<void> prepareSavedQueue() async {
    for (final song in offlineSongs) {
      await db.upsertDownload(song);
    }
    player.setAudio(true);
    await player.playOfflineVideos(offlineSongs.take(2).toList());
    player.seek(const Duration(seconds: 7));
    player.pause();
  }

  for (final next in [true, false]) {
    test(
        'music enqueue into saved queue preserves playback and order (next=$next)',
        () async {
      await prepareSavedQueue();
      final before = player.state;
      final generation = player.backendPlaybackGeneration;
      expect(player.canEnqueueMusicSongs(selectedSavedSongs), isTrue);

      expect(
          await player.enqueueMusicSongs(selectedSavedSongs,
              next: next, downloads: offlineSongs.skip(2).toList()),
          isTrue);

      expect(player.state.offlineCurrentlyPlaying,
          same(before.offlineCurrentlyPlaying));
      expect(player.state.currentlyPlaying, isNull);
      expect(player.state.videos, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
      expect(player.state.mediaCommand, same(before.mediaCommand));
      expect(player.state.isAudio, isTrue);
      expect(player.requestedPlaying, isFalse);
      expect(player.backendPlaybackGeneration, generation);
      expect(player.state.playedVideos, before.playedVideos);
      expect(
          player.state.playQueue.toList(),
          next
              ? ['saved-c', 'saved-d', 'saved-b']
              : ['saved-b', 'saved-c', 'saved-d']);
      expect(
          player.state.offlineVideos.map((song) => song.videoId),
          next
              ? ['saved-a', 'saved-c', 'saved-d', 'saved-b']
              : ['saved-a', 'saved-b', 'saved-c', 'saved-d']);
    });
  }

  test(
      'unsupported saved queue selections are rejected without any partial insertion',
      () async {
    await prepareSavedQueue();
    final before = player.state;
    for (final songs in [
      <Video>[],
      [const Video(videoId: 'saved-a')],
      [const Video(videoId: 'saved-b')],
      [const Video(videoId: 'saved-c'), const Video(videoId: 'saved-c')],
      [const Video(videoId: 'saved-c'), const Video(videoId: 'online-only')],
    ]) {
      expect(player.canEnqueueMusicSongs(songs), isFalse);
      expect(await player.enqueueMusicSongs(songs, next: true), isFalse);
      expect(player.state, same(before));
    }
    expect(
        player.canEnqueueMusicSongs(selectedSavedSongs,
            downloads: offlineSongs
                .skip(2)
                .map((song) => song.copyWith(profileId: 'other'))
                .toList()),
        isFalse);
    expect(
        await player.enqueueMusicSongs(selectedSavedSongs,
            next: false, downloads: [offlineSongs[2]]),
        isFalse);
    expect(player.state, same(before));
  });

  test('music enqueue rechecks completed saved rows when a menu becomes stale',
      () async {
    await prepareSavedQueue();
    final before = player.state;
    expect(player.canEnqueueMusicSongs(selectedSavedSongs), isTrue);
    await db.upsertDownload(offlineSongs[3].copyWith(downloadComplete: false));
    expect(await player.enqueueMusicSongs(selectedSavedSongs, next: false),
        isFalse);
    expect(player.state, same(before));
  });

  test('music enqueue cannot change an old profile queue', () async {
    await prepareSavedQueue();
    final before = player.state;
    final next = await db.createProfile('Another listener');
    await db.useProfile(next.id);
    expect(player.canEnqueueMusicSongs(selectedSavedSongs), isFalse);
    expect(await player.enqueueMusicSongs(selectedSavedSongs, next: true),
        isFalse);
    expect(player.state, same(before));
  });

  test('music enqueue retains duplicate occurrences in the active online queue',
      () async {
    await player.playVideo(
        videos.map((video) => video.copyWith(lengthSeconds: 120)).toList(),
        audio: true);
    player.seek(const Duration(seconds: 7));
    final before = player.state;
    final generation = player.backendPlaybackGeneration;
    final selection = [videos.first, videos.first];
    expect(player.canEnqueueMusicSongs(selection), isTrue);
    expect(await player.enqueueMusicSongs(selection, next: true), isTrue);
    expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
    expect(player.state.position, before.position);
    expect(player.state.mediaCommand, same(before.mediaCommand));
    expect(player.backendPlaybackGeneration, generation);
    expect(player.state.videos.map(playbackQueueId),
        ['a', 'a#1', 'a#2', 'b', 'c']);
    expect(player.state.playQueue.toList(), ['a#1', 'a#2', 'b', 'c']);
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

  test('reordering one shuffled occurrence does not reshuffle other songs',
      () async {
    await player.playVideo([
      ...videos,
      const Video(videoId: 'd', formatStreams: [], adaptiveFormats: []),
      const Video(videoId: 'e', formatStreams: [], adaptiveFormats: []),
    ]);
    await settings.setShuffle(true);
    final before = player.state.playQueue.toList();
    player.onQueueReorder(1, 5);
    expect(player.state.currentlyPlaying?.videoId, 'a');
    expect(player.state.playedVideos, isEmpty);
    expect(player.state.playQueue.last, 'b');
    expect(player.state.playQueue.where((id) => id != 'b'),
        before.where((id) => id != 'b'));
  });

  test('repeated playlist songs advance and go back by queue occurrence',
      () async {
    await player.playVideo([videos[0], videos[1], videos[0]], audio: true);
    final keys = player.state.videos.map(playbackQueueId).toList();
    expect(keys.toSet(), hasLength(3));
    expect(player.state.videos.map((video) => video.videoId), ['a', 'b', 'a']);
    expect(player.state.playQueue, [keys[1], keys[2]]);

    Future<void> move(void Function() action, String key) async {
      EasyThrottle.cancel(skipToVideoThrottleName);
      final changed =
          player.stream.firstWhere((state) => state.currentQueueId == key);
      action();
      await changed.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    await move(player.playNext, keys[1]);
    await move(player.playNext, keys[2]);
    expect(player.currentIndex, 2);
    expect(player.state.playedVideos, [keys[0], keys[1]]);
    expect(player.state.playQueue, isEmpty);
    // Android metadata and history continue identifying the real upload.
    expect(handler.mediaItem.value?.id, 'a');
    expect((await player.getMediaItem(2))?.id, 'a');
    await move(player.playPrevious, keys[1]);
    expect(player.currentIndex, 1);
    expect(player.state.playQueue, [keys[2]]);
  });

  test('shuffle selection can choose another occurrence of the same song',
      () async {
    await player.playVideo([videos[0], videos[1], videos[0]], audio: true);
    final keys = player.state.videos.map(playbackQueueId).toList();
    await settings.setShuffle(true);
    await player.skipToVideo(2);
    expect(player.state.currentQueueId, keys[2]);
    expect(player.currentIndex, 2);
    expect(player.state.playedVideos, [keys[0]]);
    expect(player.state.playQueue, [keys[1]]);
    player.generatePlayQueue();
    expect(player.state.playQueue, [keys[1]]);
  });

  test('Music queue can select another song after a metadata failure',
      () async {
    final previousService = service;
    final pending = _PendingMetadataService();
    service = pending;
    addTearDown(() => service = previousService);
    const music = MusicMetadata(title: 'Song', artist: 'Artist');
    await player.playVideo([
      videos.first.copyWith(musicMetadata: music),
      const Video(videoId: 'b', musicMetadata: music),
      videos.last.copyWith(musicMetadata: music),
    ], audio: true);

    final selection = player.selectQueueOccurrence('b');
    await pending.started.future;
    pending.response.completeError(StateError('Cannot load this song'));
    await selection;
    expect(player.state.currentQueueId, 'b');
    expect(player.state.mediaEvent.state, MediaState.error);

    await player.selectQueueOccurrence('c');
    expect(player.state.currentQueueId, 'c');
    expect(player.state.playedVideos, ['a', 'b']);
    expect(player.state.playQueue, isEmpty);
  });

  for (final shuffle in [false, true]) {
    test(
        'Muzza timeline selection retains moved occurrences (shuffle=$shuffle)',
        () async {
      await player
          .playVideo([videos[0], videos[1], videos[0], videos[2]], audio: true);
      final keys = player.state.videos.map(playbackQueueId).toList();
      await settings.setShuffle(shuffle);
      final current = player.state.currentlyPlaying;
      final command = player.state.mediaCommand;
      player.moveQueueOccurrence(keys[2], beforeId: keys[1]);
      expect(player.state.currentlyPlaying, same(current));
      expect(player.state.mediaCommand, same(command));
      expect(player.state.playedVideos, isEmpty);
      expect(player.state.playQueue, [keys[2], keys[1], keys[3]]);

      // The earlier duplicate remains a different occurrence in Previous.
      await player.selectQueueOccurrence(keys[1]);
      expect(player.state.currentQueueId, keys[1]);
      expect(player.state.playedVideos, [keys[0], keys[2]]);
      expect(player.state.playQueue, [keys[3]]);
      final previous =
          player.stream.firstWhere((state) => state.currentQueueId == keys[2]);
      player.playPrevious();
      await previous.timeout(const Duration(seconds: 2));
      expect(player.state.playedVideos, [keys[0]]);
      expect(player.state.playQueue, [keys[1], keys[3]]);
    });
  }
}
