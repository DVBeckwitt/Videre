import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/models/song_transition.dart';
import 'package:clipious/player/models/manual_music_preparation.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';
import '../podcasts/fake_podcast_player.dart';
import 'held_music_preparer.dart';

class _ArtworkFailurePlayer extends TestPlayerCubit {
  _ArtworkFailurePlayer(super.initialState, super.settings);

  @override
  Future<MediaItem?> getMediaItem(int index) async =>
      throw const FileSystemException('Artwork unavailable');
}

class _SessionPlayer extends PlayerCubit {
  _SessionPlayer(super.initialState, super.settings);

  @override
  Future<void> onReady() async {}
}

class _PodcastQueuePlayer extends TestPlayerCubit {
  _PodcastQueuePlayer(super.initialState, super.settings, this.activePodcast);

  @override
  final FakePodcastPlayer activePodcast;
}

class _DelayedMediaItemPlayer extends _SessionPlayer {
  _DelayedMediaItemPlayer(super.initialState, super.settings);

  final itemReady = Completer<void>();
  final publishItem = Completer<void>();

  @override
  Future<MediaItem?> getMediaItem(int index) async {
    final item = await super.getMediaItem(index);
    itemReady.complete();
    await publishItem.future;
    return item;
  }
}

class _PendingMetadataService extends Service {
  final started = Completer<void>();
  final response = Completer<Video>();

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
    started.complete();
    return response.future;
  }
}

class _AdjacentService extends Service {
  final requests = <String>[];
  final blocked = <String, Completer<void>>{};
  final sources = <String, Object>{};

  @override
  Future<Video> getMusicVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    requests.add(videoId);
    final connection = BackendPlayback(
        serverOverride ?? await db.getCurrentlySelectedServer());
    await blocked[videoId]?.future;
    final source = sources[videoId] = Object();
    return Video(
        videoId: videoId,
        title: videoId,
        formatStreams: const [],
        adaptiveFormats: const [],
        playbackConnection: connection,
        playbackSourceId: source);
  }

  @override
  Future<bool> isLoggedIn() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late PlayerCubit player;
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

  for (final (hideComments, tab, nextTab) in [
    (true, 1, 0),
    (false, 1, 1),
    (true, 3, 3),
  ]) {
    test('tab $tab advances to $nextTab with hiding=$hideComments', () async {
      await settings.setHideCommentsByDefault(hideComments);
      player.setAudio(true);
      player.selectTab(tab);
      final next = player.stream
          .firstWhere((state) => state.currentlyPlaying?.videoId == 'b');

      player.setEvent(const MediaEvent(state: MediaState.completed));

      final advanced = await next.timeout(const Duration(seconds: 2));
      expect(advanced.selectedFullScreenIndex, nextTab);
    });
  }

  test('a new occurrence of the same video closes the comments tab', () async {
    await settings.setHideCommentsByDefault(true);
    await player.playVideo([videos.first, videos.first], audio: true);
    player.selectTab(1);
    final nextId = player.state.playQueue.single;
    final next =
        player.stream.firstWhere((state) => state.currentQueueId == nextId);

    player.setEvent(const MediaEvent(state: MediaState.completed));

    final advanced = await next.timeout(const Duration(seconds: 2));
    expect(advanced.currentlyPlaying?.videoId, videos.first.videoId);
    expect(advanced.selectedFullScreenIndex, 0);
  });

  test('reinstalling the same queue item preserves the comments tab', () async {
    await settings.setHideCommentsByDefault(true);
    player.setAudio(true);
    player.selectTab(1);

    await player.switchToVideo(videos.first);

    expect(player.state.currentQueueId, playbackQueueId(videos.first));
    expect(player.state.selectedFullScreenIndex, 1);
  });

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
        musicMetadata: MusicMetadata(title: 'Selected first', artist: 'Singer'),
        lengthSeconds: 120,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true),
    DownloadedVideo(
        videoId: 'saved-d',
        title: 'Selected second',
        musicMetadata:
            MusicMetadata(title: 'Selected second', artist: 'Singer'),
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

  Future<List<DownloadedVideo>> storeMusicDownloads() async {
    final songs = [
      for (final file in offlineSongs)
        file.copyWith(
            musicMetadata: MusicMetadata(title: file.title, artist: 'Band')),
    ];
    for (final song in songs) {
      await db.upsertDownload(song);
    }
    return songs;
  }

  test(
      'Add downloads starts an idle Music queue in the requested order with shuffle on',
      () async {
    await player.close();
    player = TestPlayerCubit(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = handler = MediaHandler(player);
    await settings.setShuffle(true);
    final files = await storeMusicDownloads();
    final ordered = [files[2], files[0], files[3], files[1]];
    expect(player.canAddMusicDownloadsToQueue, isTrue);
    expect(
        await player.addMusicDownloadsToQueue(ordered, isCurrent: () => true),
        isTrue);
    expect(
        player.state.offlineCurrentlyPlaying?.videoId, ordered.first.videoId);
    expect(player.state.offlineVideos.map((file) => file.videoId),
        ordered.map((file) => file.videoId));
    expect(player.state.playQueue, ordered.skip(1).map((file) => file.videoId));
    expect(player.state.isAudio, isTrue);
    expect(settings.state.playerShuffleMode, isTrue);
  });

  test('Add downloads leaves an active podcast alone', () async {
    await player.close();
    final podcast = FakePodcastPlayer()..start();
    player = _PodcastQueuePlayer(PlayerState.init(null), settings, podcast);
    final file = offlineSongs[2];
    await db.upsertDownload(file);
    expect(player.canAddMusicDownloadsToQueue, isFalse);
    expect(await player.addMusicDownloadsToQueue([file], isCurrent: () => true),
        isFalse);
    expect(player.state.offlineVideos, isEmpty);
    expect(podcast.active, isTrue);
    expect(podcast.stopCalls, 0);
  });

  test(
      'Add downloads appends to an existing saved queue without restarting playback or partially accepting stale files',
      () async {
    // The fixture begins in regular video playback.
    final songs = await storeMusicDownloads();
    expect(player.canAddMusicDownloadsToQueue, isFalse);
    final videoState = player.state;
    expect(await player.addMusicDownloadsToQueue(songs, isCurrent: () => true),
        isFalse);
    expect(player.state, same(videoState));
    player.setAudio(true);
    await player.playOfflineVideos(songs.take(2).toList());
    player.seek(const Duration(seconds: 7));
    player.pause();
    final before = player.state;
    final generation = player.backendPlaybackGeneration;
    final a = songs.first;
    final c = songs[2];
    expect(player.canAddMusicDownloadsToQueue, isTrue);
    for (final invalid in [
      c.copyWith(profileId: 'other'),
      c.copyWith(downloadComplete: false),
      c.copyWith(audioOnly: false),
      c.copyWith(videoId: 'absent'),
    ]) {
      expect(
          await player
              .addMusicDownloadsToQueue([a, invalid], isCurrent: () => true),
          isFalse);
      expect(player.state, same(before));
    }
    await db.upsertDownload(c.copyWith(musicMetadata: null));
    expect(await player.addMusicDownloadsToQueue([a, c], isCurrent: () => true),
        isFalse);
    expect(player.state, same(before));
    await db.upsertDownload(c);
    expect(
        await player.addMusicDownloadsToQueue([a, c], isCurrent: () => false),
        isFalse);
    expect(player.state, same(before));
    expect(await player.addMusicDownloadsToQueue([a, c], isCurrent: () => true),
        isTrue);
    final files = player.state.offlineVideos;
    expect(files.map((file) => file.videoId),
        [a.videoId, songs[1].videoId, a.videoId, c.videoId]);
    expect(files.map(playbackQueueId).toSet(), hasLength(4));
    expect(player.state.playQueue,
        [...before.playQueue, ...files.skip(2).map(playbackQueueId)]);
    expect(player.state.offlineCurrentlyPlaying,
        same(before.offlineCurrentlyPlaying));
    expect(player.state.position, before.position);
    expect(player.state.mediaCommand, same(before.mediaCommand));
    expect(player.requestedPlaying, isFalse);
    expect(player.backendPlaybackGeneration, generation);
  });

  for (final shuffle in [false, true]) {
    test('Shuffle all downloads follows its one-shot order (global=$shuffle)',
        () async {
      final files = await storeMusicDownloads();
      final original = files.map((file) => file.videoId).toList();
      await settings.setShuffle(shuffle);
      await player.shuffleMusicDownloads(files, isCurrent: () => true);
      final order = player.state.offlineVideos.map(playbackQueueId).toList();
      expect(order, unorderedEquals(original));
      expect(files.map((file) => file.videoId), original);
      expect(player.state.currentQueueId, order.first);
      expect(player.state.playedVideos, isEmpty);
      expect(player.state.playQueue, order.skip(1));
      expect(settings.state.playerShuffleMode, shuffle);
      expect(player.state.videos, isEmpty);
      expect(player.state.isAudio, isTrue);
      expect(db.getPlaybackHistory(PlaybackHistoryOrigin.music).single.videoId,
          order.first);
      await player.selectQueueOccurrence(order.last);
      expect(
          db
              .getPlaybackHistory(PlaybackHistoryOrigin.music)
              .map((entry) => entry.videoId),
          containsAll([order.first, order.last]));
    });
  }

  test('Shuffle all downloads rejects a stale or incomplete batch', () async {
    final files = await storeMusicDownloads();
    final original = player.state;
    final first = files.first;
    for (final invalid in [
      <DownloadedVideo>[],
      [first, first],
      [first, files.last.copyWith(videoId: 'missing')],
      [first, files.last.copyWith(profileId: 'another')],
      [first, files.last.copyWith(storageUri: 'content://test/replaced')],
      [first, files.last.copyWith(downloadComplete: false)],
    ]) {
      await player.shuffleMusicDownloads(invalid, isCurrent: () => true);
      expect(player.state, same(original));
    }
    await player.shuffleMusicDownloads(files, isCurrent: () => false);
    expect(player.state, same(original));
    for (final unavailable in [
      files.last.copyWith(musicMetadata: null),
      files.last.copyWith(audioOnly: false),
      files.last.copyWith(downloadFailed: true),
      files.last.copyWith(authenticationRequired: true),
    ]) {
      await db.upsertDownload(unavailable);
      await player.shuffleMusicDownloads(files, isCurrent: () => true);
      expect(player.state, same(original));
    }
  });

  for (final next in [true, false]) {
    test(
        'music enqueue into saved queue preserves playback and order (next=$next)',
        () async {
      await prepareSavedQueue();
      final before = player.state;
      final generation = player.backendPlaybackGeneration;
      final downloads = [
        for (final song in selectedSavedSongs)
          db.getDownloadByVideoId(song.videoId)!,
      ];
      expect(
          player.canEnqueueMusicSongs(selectedSavedSongs, downloads: downloads),
          isTrue);
      await db.upsertDownload(downloads.first.copyWith(
          musicMetadata:
              const MusicMetadata(title: 'Updated title', artist: 'Singer')));

      expect(
          await player.enqueueMusicSongs(selectedSavedSongs,
              next: next, downloads: downloads),
          isTrue);
      expect(
          player.state.offlineVideos
              .singleWhere((song) => song.videoId == 'saved-c')
              .musicMetadata
              ?.title,
          'Updated title');

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

  test('saved song copies have independent queue and notification identities',
      () async {
    await prepareSavedQueue();
    await player.close();
    player = _SessionPlayer(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = handler = MediaHandler(player);
    final saved = offlineSongs.first.copyWith(
        musicMetadata: const MusicMetadata(title: 'Current', artist: 'Band'));
    await db.upsertDownload(saved);
    await player.playOfflineVideos([saved], fromMusic: true);
    player.seek(const Duration(seconds: 7));
    player.pause();
    player.setEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.pause));
    expect(handler.playbackState.value.controls,
        contains(MediaControl.fastForward));
    expect(handler.mediaItem.value?.id, saved.videoId);
    final before = player.state;
    final generation = player.backendPlaybackGeneration;
    final copied = List.filled(2, const Video(videoId: 'saved-a'));
    final downloads = List.filled(2, saved);
    expect(player.canEnqueueMusicSongs(copied, downloads: downloads), isTrue);
    expect(
        await player.enqueueMusicSongs(copied,
            next: true, downloads: downloads),
        isTrue);
    final keys = player.state.offlineVideos.map(playbackQueueId).toList();
    expect(keys, ['saved-a', 'saved-a#1', 'saved-a#2']);
    expect(player.state.offlineVideos.map((song) => song.videoId),
        ['saved-a', 'saved-a', 'saved-a']);
    expect(player.state.playQueue.toList(), keys.skip(1));
    expect(player.state.offlineCurrentlyPlaying,
        same(before.offlineCurrentlyPlaying));
    expect(player.state.mediaCommand, same(before.mediaCommand));
    expect(player.state.position, before.position);
    expect(player.backendPlaybackGeneration, generation);
    expect(handler.playbackState.value.controls,
        contains(MediaControl.skipToNext));
    expect(handler.playbackState.value.playing, isFalse);

    await handler.skipToQueueItem(2);
    expect(player.state.currentQueueId, keys.last);
    expect(handler.mediaItem.value?.id, keys.last);
    expect(player.state.offlineCurrentlyPlaying?.videoId, 'saved-a');

    player.removeInactiveQueueOccurrences({keys.first, keys[1]});
    expect(player.state.currentQueueId, keys.last);
    expect(player.state.offlineVideos.map(playbackQueueId), [keys.last]);
    expect(handler.playbackState.value.queueIndex, 0);
    expect(handler.playbackState.value.controls,
        contains(MediaControl.fastForward));
    expect(db.getDownloadByVideoId('saved-a')?.downloadComplete, isTrue);
  });

  test(
      'saved queue edits refresh paused controls when the media item arrives late',
      () async {
    await player.close();
    final delayed = _DelayedMediaItemPlayer(PlayerState.init(null), settings);
    player = delayed;
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = handler = MediaHandler(player);
    final saved = offlineSongs.first.copyWith(
        musicMetadata: const MusicMetadata(title: 'Current', artist: 'Band'));
    await db.upsertDownload(saved);

    final opening = player.playOfflineVideos([saved], fromMusic: true);
    try {
      await delayed.itemReady.future.timeout(const Duration(seconds: 3));
      player.pause();
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      expect(handler.mediaItem.value, isNull);
      expect(handler.playbackState.value.controls,
          contains(MediaControl.fastForward));
      expect(
          await player.enqueueMusicSongs([Video(videoId: saved.videoId)],
              next: false, downloads: [saved]),
          isTrue);
    } finally {
      delayed.publishItem.complete();
      await opening;
    }

    expect(handler.mediaItem.value?.id, saved.videoId);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls,
        contains(MediaControl.skipToNext));
  });

  test(
      'unsupported saved queue selections are rejected without any partial insertion',
      () async {
    await prepareSavedQueue();
    final before = player.state;
    for (final songs in [
      <Video>[],
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
    expect(
        await player.enqueueMusicSongs(
            List.filled(2, const Video(videoId: 'saved-a')),
            next: false,
            downloads: [
              offlineSongs.first,
              offlineSongs.first.copyWith(profileId: 'other'),
            ]),
        isFalse);
    expect(player.state, same(before));
  });

  test('explicit saved enqueue rejects changes to the file, owner or rendition',
      () async {
    await prepareSavedQueue();
    final saved = offlineSongs.last.copyWith(
        accountId: 'account',
        folderUri: 'content://files/tree/music',
        storageUri: 'content://files/document/song',
        musicFormat: MusicDownloadFormat.mp3,
        container: DownloadContainer.webm);
    final digest = 'a' * 64;
    final provenance = DownloadPlaybackProvenance.tryFromJson({
      'version': 1,
      'profileId': saved.profileId,
      'accountId': saved.accountId,
      'origin': 'https://music.example',
      'contentId': saved.videoId,
      'audioOnly': true,
      'container': 'webm',
      'audio': {
        'itag': '251',
        'clen': '4096',
        'lmt': '1',
        'typeSha256': digest,
        'audioTrackSha256': null,
        'trackDimensionsSha256': digest,
      },
      'videoHeight': null,
      'defaultAudioTrack': true,
      'byteLength': 4096,
      'sha256': digest,
    })!;
    final explicit = [offlineSongs[2], saved];
    final before = player.state;
    for (final changed in [
      saved.copyWith(storageUri: 'content://files/document/other'),
      saved.copyWith(folderUri: 'content://files/tree/other'),
      saved.copyWith(storageUri: null, folderUri: null),
      saved.copyWith(musicFormat: MusicDownloadFormat.opus),
      saved.copyWith(container: DownloadContainer.mp4),
      saved.copyWith(accountId: 'other'),
      saved.copyWith(audioTrackId: 'another-language'),
      saved.copyWith(playbackProvenance: provenance),
    ]) {
      await db.upsertDownload(changed);
      expect(
          player.canEnqueueMusicSongs(selectedSavedSongs, downloads: explicit),
          isFalse);
      expect(
          await player.enqueueMusicSongs(selectedSavedSongs,
              next: true, downloads: explicit),
          isFalse);
      expect(player.state, same(before));
    }
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

  test('sorting upcoming preserves playlist ownership and drives normal Next',
      () async {
    Video track(String id, String? title) => Video(
          videoId: id,
          title: title,
          formatStreams: const [],
          adaptiveFormats: const [],
          lengthSeconds: 120,
        );
    final sourceId = Object();
    final source = BackendPlayback(await db.getCurrentlySelectedServer());
    final current = track('current', 'Current').copyWith(
        musicMetadata: const MusicMetadata(title: 'Current', artist: 'Artist'),
        playbackConnection: source,
        playbackSourceId: sourceId);
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLsort',
        profileId: db.profileId);
    await player.playPlaylist([
      track('previous', 'Previous'),
      current,
      track('zulu', 'Zulu'),
      track('first-echo', 'Écho'),
      track('missing', null),
      track('second-echo', ' echo '),
    ], reference: reference, fromMusic: true, audio: true, startIndex: 1);
    player.seek(const Duration(seconds: 17));
    final generation = player.backendPlaybackGeneration;
    final playlistGeneration = player.playlistGeneration;
    final before = player.state;
    final ids = before.videos.map(playbackQueueId).toList();
    final expected = [ids[3], ids[5], ids[2], ids[4]];
    expect(before.playQueue, ids.skip(2));

    player.sortMusicQueueUpcoming(MusicQueueSort.titleAscending);

    expect(player.state.playQueue, expected);
    expect(player.state.videos.map(playbackQueueId), ids);
    expect(player.state.playedVideos, [ids.first]);
    expect(player.state.currentQueueId, ids[1]);
    expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
    expect(player.state.currentlyPlaying?.playbackSourceId, same(sourceId));
    expect(player.state.currentlyPlaying?.playbackConnection, same(source));
    expect(player.state.position, const Duration(seconds: 17));
    expect(player.state.mediaCommand, same(before.mediaCommand));
    expect(player.backendPlaybackGeneration, generation);
    expect(player.playlistGeneration, playlistGeneration);
    expect(player.playlistReference, reference);

    expect(
        await player
            .enqueueMusicSongs([track('aardvark', 'Aardvark')], next: false),
        isTrue);
    final appended = playbackQueueId(player.state.videos.last);
    expect(player.state.playQueue, [...expected, appended]);
    final advanced = player.stream
        .firstWhere((state) => state.currentQueueId == expected.first);
    player.playNext();
    final next = await advanced.timeout(const Duration(seconds: 2));
    expect(next.playedVideos, [...before.playedVideos, ids[1]]);
    expect(next.playQueue, [...expected.skip(1), appended]);
  });

  test('sorting while the next song opens leaves its transition intact',
      () async {
    final previousService = service;
    final pending = _PendingMetadataService();
    service = pending;
    addTearDown(() => service = previousService);
    const opening = Video(
        videoId: 'opening',
        musicMetadata: MusicMetadata(title: 'Opening', artist: 'Artist'));
    await player.playVideo([
      videos.first,
      opening,
      videos[1].copyWith(title: 'Zulu'),
      videos[2].copyWith(title: 'Alpha'),
    ], audio: true, fromMusic: true);
    player.playNext();
    await pending.started.future.timeout(const Duration(seconds: 2));
    final before = player.state;
    final generation = player.backendPlaybackGeneration;
    final opened = player.openingMusicEntry;
    expect(opened?.videoId, opening.videoId);
    expect(before.playQueue, ['b', 'c']);

    expect(player.canSortMusicQueueUpcoming, isFalse);
    player.sortMusicQueueUpcoming(MusicQueueSort.titleAscending);

    expect(player.state, same(before));
    expect(player.openingMusicEntry, same(opened));
    expect(player.backendPlaybackGeneration, generation);
    final advanced = player.stream
        .firstWhere((state) => state.currentQueueId == opening.videoId);
    pending.response.complete(
        opening.copyWith(formatStreams: const [], adaptiveFormats: const []));
    final next = await advanced.timeout(const Duration(seconds: 2));
    expect(next.playedVideos, ['a']);
    expect(next.playQueue, ['b', 'c']);
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
    await db.upsertDownload(offlineSongs[2]);
    final switching = player.state;
    expect(player.canAddMusicDownloadsToQueue, isFalse);
    expect(
        await player
            .addMusicDownloadsToQueue([offlineSongs[2]], isCurrent: () => true),
        isFalse);
    expect(player.state, same(switching));
    pending.response.completeError(StateError('Cannot load this song'));
    await selection;
    expect(player.state.currentQueueId, 'b');
    expect(player.state.mediaEvent.state, MediaState.error);

    await player.selectQueueOccurrence('c');
    expect(player.state.currentQueueId, 'c');
    expect(player.state.playedVideos, ['a', 'b']);
    expect(player.state.playQueue, isEmpty);
  });

  group('adjacent Music preparation', () {
    late _AdjacentService catalog;
    late Service original;
    late List<IdedVideo> ready;

    void remember(List<IdedVideo> items) => ready = List.of(items);
    List<String> readyIds() => ready.map(playbackQueueId).toList();

    Future<void> until(bool Function() condition) async {
      await Future.doWhile(() async {
        if (condition()) return false;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return true;
      }).timeout(const Duration(seconds: 3));
    }

    Future<void> open(List<String> ids,
        {int index = 0, String? savedOnly}) async {
      final server = await db.getCurrentlySelectedServer();
      final songs = [
        for (final id in ids)
          Video(
              videoId: id,
              title: id,
              downloadPlaybackOnly: id == savedOnly,
              musicMetadata: MusicMetadata(title: id, artist: 'Artist'))
      ];
      songs[index] = songs[index].copyWith(
          playbackConnection: BackendPlayback(server),
          playbackSourceId: Object(),
          adaptiveFormats: const [],
          formatStreams: const []);
      await player.playVideo(songs, audio: true, startIndex: index);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
    }

    setUp(() async {
      await player.close();
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = handler = MediaHandler(player);
      original = service;
      service = catalog = _AdjacentService();
      ready = [];
      player.addAdjacentMusicListener(remember);
    });

    tearDown(() {
      player.removeAdjacentMusicListener(remember);
      for (final held in catalog.blocked.values) {
        if (!held.isCompleted) held.complete();
      }
      service = original;
    });

    group('manual Music selection while a song is playing', () {
      late HeldMusicPreparer preparer;

      Video song(String id) => Video(
          videoId: id, musicMetadata: MusicMetadata(title: id, artist: 'Band'));

      setUp(() async {
        await open(['a', 'b', 'c']);
        preparer = HeldMusicPreparer();
        player.manualMusicPreparer = preparer;
      });

      tearDown(() {
        for (final request in preparer.requests.values) {
          if (!request.isCompleted) request.complete(false);
        }
      });

      for (final succeeds in [true, false]) {
        test(
            'the media session stays active when the queue ends while a song '
            'is being selected (succeeds=$succeeds)', () async {
          player.manualMusicPreparer = null;
          await open(['last']);
          await settings.setRepeatMode(PlayerRepeat.noRepeat);
          player.manualMusicPreparer = preparer;
          final switching = player.playVideo([song('new')], audio: true);
          await until(() => preparer.requests.containsKey('new'));
          player.setEvent(const MediaEvent(state: MediaState.completed));
          expect(handler.playbackState.value.playing, isTrue);
          expect(handler.playbackState.value.processingState,
              AudioProcessingState.buffering);
          preparer.requests['new']!.complete(succeeds);
          await switching;
          if (succeeds) {
            player.setEvent(const MediaEvent(state: MediaState.ready));
            expect(handler.playbackState.value.playing, isTrue);
            player.setEvent(const MediaEvent(
                state: MediaState.playing, type: MediaEventType.play));
            expect(handler.playbackState.value.processingState,
                AudioProcessingState.ready);
          } else {
            expect(handler.playbackState.value.playing, isFalse);
            expect(handler.playbackState.value.processingState,
                AudioProcessingState.completed);
          }
        });
      }

      test(
          'a manual replacement takes over an automatic gap without releasing '
          'the Android session', () async {
        await settings.setSongTransitionMode(SongTransitionMode.pause);
        await settings.setSongTransitionSeconds(10);
        final switching = player.playVideo([song('new')], audio: true);
        await until(() => preparer.requests.containsKey('new'));
        player.setEvent(const MediaEvent(state: MediaState.completed));
        expect(handler.playbackState.value.playing, isTrue);
        preparer.requests['new']!.complete(true);
        await switching;
        player.setEvent(const MediaEvent(state: MediaState.ready));
        expect(handler.playbackState.value.playing, isTrue);
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.buffering);
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.ready);
      });

      for (final interrupt in [true, false]) {
        test(
            'pausing after EOF releases the service while a selection is held '
            '(audio focus=$interrupt)', () async {
          player.manualMusicPreparer = null;
          await open(['last']);
          await settings.setRepeatMode(PlayerRepeat.noRepeat);
          player.manualMusicPreparer = preparer;
          final switching = player.playVideo([song('new')], audio: true);
          await until(() => preparer.requests.containsKey('new'));
          player.setEvent(const MediaEvent(state: MediaState.completed));
          expect(handler.playbackState.value.playing, isTrue);
          if (interrupt) {
            player.handleAudioInterruption(
                AudioInterruptionEvent(true, AudioInterruptionType.unknown));
          } else {
            await handler.pause();
          }
          expect(handler.playbackState.value.playing, isFalse);
          preparer.requests['new']!.complete(true);
          await switching;
          player.setEvent(const MediaEvent(state: MediaState.ready));
          expect(player.shouldStartPlayback, isFalse);
          expect(handler.playbackState.value.playing, isFalse);
        });
      }

      test('a failed candidate leaves the running queue and controls intact',
          () async {
        const position = Duration(seconds: 17);
        player.setEvent(const MediaEvent(
            state: MediaState.playing,
            type: MediaEventType.progress,
            value: position));
        final mounted = player.state.currentlyPlaying;
        final command = player.state.mediaCommand;
        final generation = player.backendPlaybackGeneration;
        final failure = player.musicSelectionFailureRevision.value;
        final selecting = player.playVideo([song('x'), song('y')], audio: true);
        await until(() => preparer.requests.containsKey('x'));
        void expectOldQueue() {
          expect(player.state.currentlyPlaying, same(mounted));
          expect(player.backendPlaybackGeneration, generation);
          expect(player.state.mediaCommand, same(command));
          expect(player.state.videos.map(playbackQueueId), ['a', 'b', 'c']);
          expect(player.state.playedVideos, isEmpty);
          expect(player.state.playQueue, ['b', 'c']);
          expect(player.state.isPlaying, isTrue);
          expect(player.state.position, position);
          expect(handler.mediaItem.value?.id, 'a');
          expect(handler.playbackState.value.playing, isTrue);
        }

        expectOldQueue();
        preparer.requests['x']!.complete(false);
        await selecting;
        expectOldQueue();
        expect(player.state.mediaEvent.state, isNot(MediaState.error));
        expect(player.musicSelectionFailureRevision.value, failure + 1);
      });

      test('two queue-row taps publish only the last admitted occurrence',
          () async {
        final failure = player.musicSelectionFailureRevision.value;
        final first = player.selectQueueOccurrence('b');
        await until(() => preparer.requests.containsKey('b'));
        final second = player.selectQueueOccurrence('c');
        await until(() => preparer.requests.containsKey('c'));
        expect(preparer.current['b']!(), isFalse);
        expect(preparer.current['c']!(), isTrue);
        preparer.requests['b']!.complete(true);
        await first;
        expect(player.state.currentQueueId, 'a');
        expect(player.state.playedVideos, isEmpty);
        expect(player.state.playQueue, ['b', 'c']);
        preparer.requests['c']!.complete(true);
        await second;
        expect(player.state.currentQueueId, 'c');
        expect(player.state.playedVideos, ['a', 'b']);
        expect(player.state.playQueue, isEmpty);
        expect(player.musicSelectionFailureRevision.value, failure);
      });

      test(
          'a retryable song selection commits only the ready alternate backend',
          () async {
        final selector = BackendSelector('ROUTE',
            const [BackendOption('0', 'First'), BackendOption('1', 'Second')],
            automaticFallback: true);
        final preferred =
            selector.withSelection(await db.getCurrentlySelectedServer(), '0');
        await db.upsertServer(preferred);
        final requests = <String?>[];
        final client = MockClient((request) async {
          expect(request.url.path, '/api/v1/videos/x');
          requests.add(requestCookieValue(request.headers, 'ROUTE'));
          return http.Response(
              '{"videoId":"x","title":"Upload","adaptiveFormats":[],"formatStreams":[],"captions":[]}',
              200,
              headers: {'content-type': 'application/json'});
        });
        addTearDown(client.close);
        service = Service(httpClient: client);
        final firstRoute = BackendPlayback(preferred);
        final selected = song('x').copyWith(
            backendPlayback: firstRoute,
            playbackConnection: firstRoute,
            adaptiveFormats: const [],
            formatStreams: const []);
        final original = player.state.currentlyPlaying;
        final command = player.state.mediaCommand;
        final failure = player.musicSelectionFailureRevision.value;
        final selecting = player.playVideo([selected], audio: true);
        await preparer.started.future;
        final first = preparer.requests['x']!;
        first.completeError(const ManualMusicSourceFailure('transport'));
        await until(() => !identical(preparer.requests['x'], first));
        expect(requests, ['1']);
        expect(player.state.currentlyPlaying, same(original));
        expect(player.state.mediaCommand, same(command));
        expect(player.state.playQueue, ['b', 'c']);
        expect(player.state.isPlaying, isTrue);
        expect(handler.mediaItem.value?.id, 'a');

        preparer.requests['x']!.complete(true);
        await selecting;
        final committed = player.state.currentlyPlaying!;
        expect(committed.videoId, 'x');
        expect(committed.backendPlayback?.label, 'Second');
        expect(committed.musicMetadata?.artist, 'Band');
        expect(player.state.requestedBackend, same(committed.backendPlayback));
        expect(handler.mediaItem.value?.id, 'x');
        expect(player.musicSelectionFailureRevision.value, failure);
        expect(
            selector.selectedValue(await db.getCurrentlySelectedServer()), '0');
      });

      test('playlist ownership and duplicate occurrences change together',
          () async {
        final reference = PlaylistReference(
            kind: PlaylistSourceKind.public,
            playlistId: 'PLnew',
            profileId: db.profileId);
        final songs = assignPlaylistEntryIds([
          song('x').copyWith(index: 0),
          song('y').copyWith(index: 1),
          song('x').copyWith(index: 2)
        ]);
        final selecting = player.playPlaylist(songs,
            audio: true, reference: reference, startIndex: 2);
        final entry =
            await preparer.started.future.timeout(const Duration(seconds: 3));
        final id = playbackQueueId(entry);
        expect(id, playbackQueueId(songs.last));
        expect(player.playlistReference, isNull);
        expect(player.state.currentQueueId, 'a');
        expect(player.state.playQueue, ['b', 'c']);
        preparer.requests[id]!.complete(true);
        await selecting;
        expect(player.playlistReference, reference);
        expect(player.state.currentQueueId, id);
        expect(player.state.playedVideos, songs.take(2).map(playbackQueueId));
        expect(player.state.playQueue, isEmpty);
      });

      for (final rawIndex in [false, true]) {
        test(
            'a row reached by natural EOF already satisfies its pending tap '
            '(raw index=$rawIndex)', () async {
          final selecting = rawIndex
              ? handler.skipToQueueItem(1)
              : player.selectQueueOccurrence('b');
          await until(() => preparer.requests.containsKey('b'));
          player.setEvent(const MediaEvent(state: MediaState.completed));
          await until(() => player.state.currentQueueId == 'b');
          final command = player.state.mediaCommand;
          final generation = player.backendPlaybackGeneration;
          preparer.requests['b']!.complete(true);
          await selecting;
          expect(player.state.currentQueueId, 'b');
          expect(player.state.mediaCommand, same(command));
          expect(player.backendPlaybackGeneration, generation);
          expect(player.state.playQueue, ['c']);
        });
      }

      test('a shuffled notification selection records the last audible song',
          () async {
        await settings.setShuffle(true);
        final selecting = handler.skipToQueueItem(2);
        await until(() => preparer.requests.containsKey('c'));
        player.setEvent(const MediaEvent(state: MediaState.completed));
        await until(() => player.state.currentQueueId == 'b');
        preparer.requests['c']!.complete(true);
        await selecting;
        expect(player.state.currentQueueId, 'c');
        expect(player.state.playedVideos, ['a', 'b']);
        expect(player.state.playQueue, isEmpty);
      });

      test('a saved-song selection keeps the online queue until admission',
          () async {
        final saved = [
          for (final track in offlineSongs.take(2))
            track.copyWith(
                profileId: db.profileId,
                musicMetadata:
                    MusicMetadata(title: track.title, artist: 'Band'))
        ];
        for (final track in saved) {
          await db.upsertDownload(track);
        }
        final selecting = player.playOfflineVideos(saved, startIndex: 1);
        final entry =
            await preparer.started.future.timeout(const Duration(seconds: 3));
        expect(entry, isA<DownloadedVideo>());
        expect(entry.videoId, saved.last.videoId);
        expect(player.state.currentQueueId, 'a');
        expect(player.state.videos.map(playbackQueueId), ['a', 'b', 'c']);
        expect(player.state.offlineVideos, isEmpty);
        preparer.requests[entry.videoId]!.complete(true);
        await selecting;
        expect(
            player.state.offlineCurrentlyPlaying?.videoId, saved.last.videoId);
        expect(player.state.offlineVideos, saved);
        expect(player.state.playedVideos, [saved.first.videoId]);
        expect(player.state.videos, isEmpty);
        expect(catalog.requests, isNot(contains(saved.last.videoId)));
      });

      for (final change in [
        'none',
        'owner',
        'remove',
        'replace',
        'supersede'
      ]) {
        test('Shuffle all downloads rechecks before decoder commit ($change)',
            () async {
          final files = await storeMusicDownloads();
          final previous = player.state;
          final generation = player.backendPlaybackGeneration;
          var current = true;
          final selecting =
              player.shuffleMusicDownloads(files, isCurrent: () => current);
          final entry =
              await preparer.started.future.timeout(const Duration(seconds: 3));
          final other =
              files.firstWhere((file) => file.videoId != entry.videoId);
          expect(player.state, same(previous));
          Future<void>? newer;
          switch (change) {
            case 'owner':
              current = false;
            case 'remove':
              await db.deleteDownload(other);
            case 'replace':
              await db.upsertDownload(
                  other.copyWith(storageUri: 'content://test/replaced'));
            case 'supersede':
              newer = player.playVideo([song('newer')], audio: true);
              await until(() => preparer.requests.containsKey('newer'));
          }
          preparer.requests[entry.videoId]!.complete(true);
          await selecting;
          if (change == 'none') {
            expect(player.state.currentQueueId, entry.videoId);
            expect(player.state.offlineVideos.map(playbackQueueId),
                unorderedEquals(files.map((file) => file.videoId)));
            expect(player.state.playQueue,
                player.state.offlineVideos.skip(1).map(playbackQueueId));
          } else {
            expect(player.state, same(previous));
            expect(player.backendPlaybackGeneration, generation);
            expect(db.getPlaybackHistory(PlaybackHistoryOrigin.music), isEmpty);
          }
          if (newer != null) {
            expect(preparer.current['newer']!(), isTrue);
            preparer.requests['newer']!.complete(true);
            await newer;
            expect(player.state.currentQueueId, 'newer');
          }
        });
      }

      for (final externalSkip in [false, true]) {
        test(
            externalSkip
                ? 'notification Next cancels a pending library selection'
                : 'the current queue can finish a song while a different selection prepares',
            () async {
          final selecting =
              player.playVideo([song('x'), song('y')], audio: true);
          await until(() => preparer.requests.containsKey('x'));
          if (externalSkip) {
            await handler.skipToNext();
          } else {
            player.setEvent(const MediaEvent(state: MediaState.completed));
          }
          await until(() => player.state.currentQueueId == 'b');
          expect(player.state.playQueue, ['c']);
          expect(preparer.current['x']!(), !externalSkip);
          preparer.requests['x']!.complete(true);
          await selecting;
          expect(player.state.currentQueueId, externalSkip ? 'b' : 'x');
          expect(player.state.playQueue, externalSkip ? ['c'] : ['y']);
          expect(player.state.playedVideos, externalSkip ? ['a'] : isEmpty);
        });
      }
    });

    for (final automatic in [false, true]) {
      test('joins the pending next song with automatic=$automatic', () async {
        final gate = catalog.blocked['b'] = Completer<void>();
        await open(['a', 'b', 'c']);
        await until(() => catalog.requests.contains('b'));
        expect(catalog.requests, ['b']);
        expect(player.state.currentQueueId, 'a');

        final next = player.stream.firstWhere((s) => s.currentQueueId == 'b');
        final generation = player.backendPlaybackGeneration;
        if (automatic) {
          player.setEvent(const MediaEvent(state: MediaState.completed));
        } else {
          player.playNext();
        }
        await until(() => player.backendPlaybackGeneration != generation);
        gate.complete();
        await next.timeout(const Duration(seconds: 3));
        expect(catalog.requests.where((id) => id == 'b'), hasLength(1));
        expect(player.state.currentlyPlaying?.playbackSourceId,
            same(catalog.sources['b']));
        await until(() => readyIds().toSet().containsAll(['a', 'c']));
        expect(ready, hasLength(2));
        expect(player.state.playedVideos, ['a']);
        expect(player.state.playQueue, ['c']);
      });
    }

    test('resolves both neighbors by occurrence without warming distant songs',
        () async {
      await open(['a', 'b', 'c', 'b', 'e'], index: 2);
      final queue = player.state.videos.map(playbackQueueId).toList();
      final adjacent = [queue[3], queue[1]];
      await until(() => readyIds().toSet().containsAll(adjacent));
      expect(readyIds(), unorderedEquals(adjacent));
      expect(catalog.requests.toSet(), {'b'});

      final back =
          player.stream.firstWhere((s) => s.currentQueueId == queue[1]);
      player.playPrevious();
      await back.timeout(const Duration(seconds: 3));
      expect(player.state.currentQueueId, queue[1]);
      expect(player.state.playQueue.first, queue[2]);
    });

    test('discarding a pending neighbor cannot replace its reordered successor',
        () async {
      final stale = catalog.blocked['b'] = Completer<void>();
      await open(['a', 'b', 'c', 'd']);
      await until(() => catalog.requests.contains('b'));
      player.moveQueueOccurrence('c', beforeId: 'b');
      player.removeVideoFromQueue('b');
      stale.complete();
      await until(() => readyIds().contains('c'));
      expect(readyIds(), ['c']);
      expect(catalog.requests.where((id) => id == 'd'), isEmpty);

      final next = player.stream.firstWhere((s) => s.currentQueueId == 'c');
      player.playNext();
      await next.timeout(const Duration(seconds: 3));
      expect(catalog.requests.where((id) => id == 'c'), hasLength(1));
    });

    test('a new swipe immediately after a completed transition is accepted',
        () async {
      await open(['a', 'b', 'c']);
      await until(() => readyIds().contains('b'));
      final forward = player.stream.firstWhere((s) => s.currentQueueId == 'b');
      player.playNext();
      await forward.timeout(const Duration(seconds: 3));
      final backward = player.stream.firstWhere((s) => s.currentQueueId == 'a');
      player.playPrevious();
      await backward.timeout(const Duration(seconds: 3));
      expect(player.state.playQueue, ['b', 'c']);
    });

    test('skipping again during a slow open keeps both occurrences in history',
        () async {
      final held = catalog.blocked['b'] = Completer<void>();
      await open(['a', 'b', 'c']);
      await until(() => catalog.requests.contains('b'));
      player.playNext();
      expect(player.openingMusicEntry?.videoId, 'b');
      final changed = player.stream.firstWhere((s) => s.currentQueueId == 'c');
      player.playNext();
      expect(player.openingMusicEntry?.videoId, 'c');
      held.complete();
      await changed.timeout(const Duration(seconds: 3));
      expect(player.state.playedVideos, ['a', 'b']);
      expect(player.state.playQueue, isEmpty);
      expect(player.adjacentMusicEntry(previous: true)?.videoId, 'b');
    });

    test('preparation follows shuffle order rather than catalog order',
        () async {
      await settings.setShuffle(true);
      await open(['a', 'b', 'c', 'd', 'e'], index: 2);
      final upcoming = player.state.playQueue.toList();
      await until(() => readyIds().contains(upcoming.first));
      expect(readyIds(), [upcoming.first]);
      expect(catalog.requests, [upcoming.first]);
      player.moveQueueOccurrence(upcoming.last, beforeId: upcoming.first);
      await until(() => readyIds().contains(upcoming.last));
      expect(readyIds(), [upcoming.last]);
      expect(catalog.requests, [upcoming.first, upcoming.last]);
    });

    test('repeat-all warms the first occurrence at the end of a queue',
        () async {
      await settings.setRepeatMode(PlayerRepeat.repeatAll);
      await open(['a', 'b', 'c'], index: 2);
      await until(() => readyIds().toSet().containsAll(['a', 'b']));
      final first = player.stream.firstWhere((s) => s.currentQueueId == 'a');
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await first.timeout(const Duration(seconds: 3));
      expect(catalog.requests.where((id) => id == 'a'), hasLength(1));
    });

    test('repeat-one loops on completion and uses the prepared next on a swipe',
        () async {
      await settings.setRepeatMode(PlayerRepeat.repeatOne);
      await open(['a', 'b']);
      await until(() => readyIds().contains('b'));
      player.seek(const Duration(seconds: 1));
      player.setEvent(const MediaEvent(state: MediaState.completed));
      expect(player.state.currentQueueId, 'a');
      expect(player.state.position, Duration.zero);
      expect(player.state.playQueue, ['b']);
      final replay = player.state.mediaCommand;
      player.setEvent(const MediaEvent(state: MediaState.completed));
      expect(player.state.mediaCommand, same(replay));

      final changed = player.stream.firstWhere((s) => s.currentQueueId == 'b');
      player.playNext();
      await changed.timeout(const Duration(seconds: 3));
      expect(player.state.currentlyPlaying?.playbackSourceId,
          same(catalog.sources['b']));
      expect(catalog.requests.where((id) => id == 'b'), hasLength(1));
      expect(player.adjacentMusicEntry(previous: false), isNull);
      player.seek(const Duration(seconds: 1));
      player.playNext();
      expect(player.state.currentQueueId, 'b');
      expect(player.state.position, Duration.zero);
    });

    for (final repeat in [PlayerRepeat.repeatOne, PlayerRepeat.repeatAll]) {
      test('a single-song $repeat loop retains the Android playback session',
          () async {
        await settings.setRepeatMode(repeat);
        await open(['a']);
        final original = player.state.mediaCommand;
        player.setEvent(const MediaEvent(state: MediaState.completed));
        expect(handler.playbackState.value.playing, isTrue);
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.buffering);
        if (repeat == PlayerRepeat.repeatAll) {
          // Repeat-all reinstalls the occurrence before its decoder can play.
          await until(() => player.state.mediaCommand != original);
        }
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.ready);
      });
    }

    test('duplicate completion callbacks consume a single queue occurrence',
        () async {
      final held = catalog.blocked['b'] = Completer<void>();
      await open(['a', 'b', 'c']);
      await until(() => catalog.requests.contains('b'));
      final changed = player.stream.firstWhere((s) => s.currentQueueId == 'b');
      player.setEvent(const MediaEvent(state: MediaState.completed));
      player.setEvent(const MediaEvent(state: MediaState.completed));
      expect(player.openingMusicEntry?.videoId, 'b');
      held.complete();
      await changed.timeout(const Duration(seconds: 3));
      await until(() => readyIds().contains('c'));
      expect(player.state.currentQueueId, 'b');
      expect(player.state.playedVideos, ['a']);
      expect(player.state.playQueue, ['c']);
    });

    test('a missing saved-only neighbor never starts an online lookup',
        () async {
      await open(['before', 'current', 'missing'],
          index: 1, savedOnly: 'missing');
      await until(() => readyIds().contains('before'));
      expect(readyIds(), ['before']);
      expect(catalog.requests, ['before']);
      expect(player.state.currentQueueId, 'current');
    });

    test('a changed account rejects an old prepared source at promotion',
        () async {
      await open(['a', 'b']);
      await until(() => readyIds().contains('b'));
      final oldSource = (ready.single as Video).playbackSourceId;
      const replacement = Server(url: 'https://other.example');
      await db.upsertServer(replacement);
      await db.useServer(replacement);
      final next = player.stream.firstWhere((s) => s.currentQueueId == 'b');
      player.playNext();
      await next.timeout(const Duration(seconds: 3));
      expect(player.state.currentlyPlaying?.playbackSourceId,
          isNot(same(oldSource)));
      expect(player.state.currentlyPlaying?.playbackConnection?.server.url,
          replacement.url);
    });

    group('automatic song transitions', () {
      Future<void> openRunning() async {
        await open(['a', 'b', 'c']);
        player.setEvent(const MediaEvent(state: MediaState.playing));
        await until(() => readyIds().contains('b'));
      }

      Future<void> openWithGap() async {
        await settings.setSongTransitionMode(SongTransitionMode.pause);
        await settings.setSongTransitionSeconds(1);
        await openRunning();
      }

      test('only an eligible automatic successor may start a transition',
          () async {
        await openRunning();
        expect(player.automaticMusicSuccessor?.videoId, 'b');
        player.pause();
        expect(player.automaticMusicSuccessor, isNull);
        player.play();
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(player.automaticMusicSuccessor?.videoId, 'b');
        await settings.setRepeatMode(PlayerRepeat.repeatOne);
        expect(player.automaticMusicSuccessor, isNull);
        await settings.setRepeatMode(PlayerRepeat.noRepeat);
        player.sleepAtEndOfTrack();
        expect(player.automaticMusicSuccessor, isNull);
        player.cancelSleep();
        await settings.setAutoplayQueue(false);
        expect(player.automaticMusicSuccessor, isNull);
        await settings.setAutoplayQueue(true);
        expect(player.automaticMusicSuccessor?.videoId, 'b');
        await player.selectQueueOccurrence('c');
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(player.automaticMusicSuccessor, isNull);
      });

      for (final automatic in [true, false]) {
        test(
            'handoff identifies the incoming occurrence only for natural EOF (automatic=$automatic)',
            () async {
          final held = catalog.blocked['b'] = Completer<void>();
          await open(['a', 'b', 'c']);
          player.setEvent(const MediaEvent(state: MediaState.playing));
          await until(() => catalog.requests.contains('b'));
          final starting =
              player.stream.firstWhere((s) => s.currentQueueId == 'b');
          if (automatic) {
            player.setEvent(const MediaEvent(state: MediaState.completed));
          } else {
            player.playNext();
          }
          expect(player.isAutomaticMusicHandoffTo('b'), automatic);
          expect(player.isAutomaticMusicHandoffTo('a'), isFalse);
          expect(player.isAutomaticMusicHandoffTo('c'), isFalse);
          held.complete();
          await starting.timeout(const Duration(seconds: 3));
          player.playPrevious();
          expect(player.isAutomaticMusicHandoffTo('b'), isFalse);
          await until(() => player.state.currentQueueId == 'a');
        });
      }

      test('pause mode waits the configured gap after genuine completion',
          () async {
        await openWithGap();
        expect(handler.playbackState.value.playing, isTrue);
        final starting =
            player.stream.firstWhere((s) => s.currentQueueId == 'b');
        final elapsed = Stopwatch()..start();
        player.setEvent(const MediaEvent(state: MediaState.completed));
        expect(handler.playbackState.value.playing, isTrue);
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.buffering);
        expect(player.state.currentQueueId, 'a');
        expect(player.openingMusicEntry, isNull);
        await starting.timeout(const Duration(seconds: 4));
        expect(elapsed.elapsedMilliseconds, greaterThanOrEqualTo(990));
        expect(player.state.playedVideos, ['a']);
        player.setEvent(const MediaEvent(state: MediaState.ready));
        expect(handler.playbackState.value.playing, isTrue);
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(handler.playbackState.value.playing, isTrue);
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.ready);
      });

      test('final Music song releases the playback service', () async {
        await openRunning();
        await player.selectQueueOccurrence('c');
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        player.setEvent(const MediaEvent(state: MediaState.completed));
        expect(handler.playbackState.value.playing, isFalse);
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.completed);
      });

      for (final cancel in ['manual next', 'pause', 'seek', 'reorder']) {
        test('a $cancel cancels the previous end-of-song timer', () async {
          await openWithGap();
          player.setEvent(const MediaEvent(state: MediaState.completed));
          switch (cancel) {
            case 'manual next':
              player.playNext();
              expect(player.openingMusicEntry?.videoId, 'b');
              await until(() => player.state.currentQueueId == 'b');
            case 'pause':
              player.pause();
              expect(handler.playbackState.value.playing, isFalse);
            case 'seek':
              player.seek(Duration.zero);
              expect(handler.playbackState.value.playing, isFalse);
            case 'reorder':
              player.moveQueueOccurrence('c', beforeId: 'b');
              expect(handler.playbackState.value.playing, isFalse);
              player.moveQueueOccurrence('b', beforeId: 'c');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          expect(
              player.state.currentQueueId, cancel == 'manual next' ? 'b' : 'a');
          expect(player.state.playQueue.first,
              cancel == 'manual next' ? 'c' : 'b');
        });
      }
    });

    test('explicit downloaded neighbors stay offline', () async {
      final downloads = ['x', 'y', 'z']
          .map((id) => DownloadedVideo(
              videoId: id,
              profileId: db.profileId,
              title: id,
              lengthSeconds: 60,
              quality: 'audio',
              audioOnly: true,
              downloadComplete: true,
              musicMetadata: MusicMetadata(title: id, artist: 'Artist')))
          .toList();
      await player.playOfflineVideos(downloads);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      await until(() => readyIds().contains('y'));
      expect(ready.single, isA<DownloadedVideo>());
      final next = player.stream.firstWhere((s) => s.currentQueueId == 'y');
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await next.timeout(const Duration(seconds: 3));
      await until(() => readyIds().toSet().containsAll(['x', 'z']));
      expect(ready, everyElement(isA<DownloadedVideo>()));
      expect(catalog.requests, isEmpty);
    });
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
