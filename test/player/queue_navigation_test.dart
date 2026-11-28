import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/services/cached_music.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_mix.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/music_card_origin.dart';
import 'package:clipious/music/models/song_transition.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/player/models/manual_music_preparation.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/music_queue_shuffle.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/playback_instance_fallback.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/recommendations/music_playlist_recommendation_exclusions.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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
        serverOverride ?? await db.getCurrentlySelectedServer(),
        backendRetries: PlaybackInstanceFallback.backendRetries(db));
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

  const requestAlbumSong = Video(
    videoId: 'albumSong',
    musicMetadata: MusicMetadata(title: 'Album song', artist: 'Artist'),
    formatStreams: [],
    adaptiveFormats: [],
  );
  const requestAlbumCloser = Video(
    videoId: 'albumCloser',
    musicMetadata: MusicMetadata(title: 'Closer', artist: 'Artist'),
    formatStreams: [],
    adaptiveFormats: [],
  );
  const requestedSong = Video(
    videoId: 'requestedSong',
    musicMetadata: MusicMetadata(title: 'Requested song', artist: 'Guest'),
    formatStreams: [],
    adaptiveFormats: [],
  );

  test('requests play in order and return to the same album occurrence',
      () async {
    final previousService = service;
    service = _AdjacentService();
    addTearDown(() => service = previousService);
    final source = PlaylistReference(
      kind: PlaylistSourceKind.local,
      playlistId: 'local:queue-taste',
      profileId: db.profileId,
    );
    await player.playVideo(
        [requestAlbumSong, requestAlbumSong, requestAlbumCloser],
        startIndex: 1,
        queueTitle: 'Album',
        fromMusic: true,
        recommendationSource: source);
    const position = Duration(milliseconds: 24321);
    await player.onProgress(position);
    final albumId = player.state.currentQueueId;
    final played = List.of(player.state.playedVideos);
    final next = player.state.playQueue.toList();

    expect(
        player.addMusicRequest(player.state.currentlyPlaying!,
            inheritCurrentRecommendationSource: true),
        isTrue);
    expect(player.addMusicRequest(requestedSong, recommendationSource: source),
        isTrue);
    expect(player.addMusicRequest(requestedSong), isTrue);
    final requests = player.musicRequests.map(playbackQueueId).toList();
    expect(requests.toSet(), hasLength(3));
    expect(requests, isNot(contains(albumId)));
    expect(player.state.currentQueueId, albumId);
    expect(player.state.playQueue.toList(), next);

    expect(await player.playMusicRequests(), isTrue);
    expect(player.state.currentQueueId, requests[0]);
    expect(player.captureMusicPlaybackCheckpoint()?.musicRecommendationSources,
        {requests[0]: musicPlaylistRecommendationKey(source)});
    expect(player.hasMusicRequestSuccessor, isTrue);

    final second = player.stream
        .firstWhere((state) => state.currentQueueId == requests[1]);
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await second.timeout(const Duration(seconds: 2));
    expect(player.captureMusicPlaybackCheckpoint()?.musicRecommendationSources,
        {requests[1]: musicPlaylistRecommendationKey(source)});

    final third = player.stream
        .firstWhere((state) => state.currentQueueId == requests[2]);
    await handler.skipToNext();
    await third.timeout(const Duration(seconds: 2));
    expect(player.captureMusicPlaybackCheckpoint()?.musicRecommendationSources,
        isEmpty);

    final returned =
        player.stream.firstWhere((state) => state.currentQueueId == albumId);
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await returned.timeout(const Duration(seconds: 2));
    expect(player.state.position, position);
    expect(player.state.playedVideos, played);
    expect(player.state.playQueue.toList(), next);
    expect(player.musicQueueTitle, 'Album');
    expect(player.musicRequests, isEmpty);
    expect(player.playingMusicRequests, isFalse);
  });

  test('a resumed request retains its separate order and return checkpoint',
      () async {
    final previousService = service;
    service = _AdjacentService();
    addTearDown(() => service = previousService);
    await player
        .playVideo([requestAlbumSong, requestAlbumCloser], fromMusic: true);
    const position = Duration(milliseconds: 18462);
    await player.onProgress(position);
    final albumId = player.state.currentQueueId;
    expect(player.addMusicRequest(requestedSong), isTrue);
    expect(player.addMusicRequest(requestAlbumCloser), isTrue);
    expect(await player.playMusicRequests(), isTrue);
    final requestId = player.state.currentQueueId;
    await player.close();

    player = _SessionPlayer(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = handler = MediaHandler(player);
    player.restoreSession();
    expect(player.state.isHidden, isTrue);
    expect(player.state.hasVideo, isFalse);
    expect(player.playingMusicRequests, isTrue);
    expect(player.musicRequests.single.videoId, requestAlbumCloser.videoId);
    await player.resumeSession(fromMusic: true);
    expect(player.state.currentQueueId, requestId);

    player.pause();
    expect(await player.returnFromMusicRequests(), isTrue);
    expect(player.state.currentQueueId, albumId);
    expect(player.state.position, position);
    expect(player.requestedPlaying, isFalse);
    expect(player.musicRequests.single.videoId, requestAlbumCloser.videoId);
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
    expect(player.musicQueueShuffled, isFalse);

    final currentId = player.state.currentQueueId;
    final command = player.state.mediaCommand;
    await settings
        .saveSetting(SettingsValue(musicQueueLockedSettingName, 'true'));
    expect(player.canToggleMusicQueueShuffle, isFalse);
    await player.toggleMusicQueueShuffle(expectedShuffled: false);
    expect(player.state.playQueue, ordered.skip(1).map((file) => file.videoId));

    await settings
        .saveSetting(SettingsValue(musicQueueLockedSettingName, 'false'));
    await player.toggleMusicQueueShuffle(expectedShuffled: false);
    expect(player.musicQueueShuffled, isTrue);
    expect(player.state.playQueue,
        unorderedEquals(ordered.skip(1).map((file) => file.videoId)));
    final enabled = player.state;
    await player.toggleMusicQueueShuffle(expectedShuffled: false);
    expect(player.state, same(enabled));

    await player.toggleMusicQueueShuffle(expectedShuffled: true);
    expect(player.musicQueueShuffled, isFalse);
    expect(settings.state.playerShuffleMode, isFalse);
    expect(player.state.playQueue, ordered.skip(1).map((file) => file.videoId));
    expect(player.state.currentQueueId, currentId);
    expect(player.state.mediaCommand, same(command));
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
      Future<void> reportDecoderPlay() async {
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        await (db as SembastSqfDb).db.transaction((_) async {});
      }

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
      expect(player.musicQueueShuffled, isFalse);
      expect(player.state.videos, isEmpty);
      expect(player.state.isAudio, isTrue);
      expect(db.getPlaybackHistory(PlaybackHistoryOrigin.music), isEmpty);
      await reportDecoderPlay();
      expect(db.getPlaybackHistory(PlaybackHistoryOrigin.music).single.videoId,
          order.first);
      await player.selectQueueOccurrence(order.last);
      await reportDecoderPlay();
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

    final beforeRemoval = player.state;
    final undo = player.removeInactiveQueueOccurrences({keys.first, keys[1]})!;
    expect(undo.count, 2);
    expect(player.state.currentQueueId, keys.last);
    expect(player.state.offlineVideos.map(playbackQueueId), [keys.last]);
    expect(handler.playbackState.value.queueIndex, 0);
    expect(handler.playbackState.value.controls,
        contains(MediaControl.fastForward));
    expect(db.getDownloadByVideoId('saved-a')?.downloadComplete, isTrue);

    expect(player.undoQueueRemoval(undo), isTrue);
    expect(player.state.offlineVideos.map(playbackQueueId), keys);
    expect(player.state.playedVideos, beforeRemoval.playedVideos);
    expect(player.state.playQueue, beforeRemoval.playQueue);
    expect(player.state.offlineCurrentlyPlaying,
        same(beforeRemoval.offlineCurrentlyPlaying));
    expect(player.state.mediaCommand, same(beforeRemoval.mediaCommand));
    expect(handler.playbackState.value.queueIndex, 2);
    expect(player.undoQueueRemoval(undo), isFalse);
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

  test('offline Music occurrences cannot enter a video-mode queue', () async {
    await player.playVideo(videos, audio: false);
    final before = player.state;
    expect(before.isAudio, isFalse);
    final song = videos.first;
    expect(player.canEnqueueMusicSongs([song]), isTrue);

    for (final marked in [
      song.copyWith(explicitMusicDownload: 'a' * 64),
      song.copyWith(playbackSourceId: CachedMusicPlayback('b' * 64, 'c' * 64)),
    ]) {
      expect(player.canEnqueueMusicSongs([marked]), isFalse);
      expect(await player.enqueueMusicSongs([marked], next: true), isFalse);
      expect(player.state, same(before));
    }
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

  test('only the originating card controls the edited Music queue', () async {
    const MusicCardOrigin origin = (
      surface: MusicCardSurface.homeShelf,
      collectionId: 'on-repeat',
      entryId: 'a#1',
    );
    const MusicCardOrigin otherOccurrence = (
      surface: MusicCardSurface.homeShelf,
      collectionId: 'on-repeat',
      entryId: 'a',
    );
    const MusicCardOrigin otherCollection = (
      surface: MusicCardSurface.homeShelf,
      collectionId: 'rediscover',
      entryId: 'a#1',
    );
    const MusicCardOrigin nextSong = (
      surface: MusicCardSurface.homeShelf,
      collectionId: 'on-repeat',
      entryId: 'c',
    );
    const played =
        MediaEvent(state: MediaState.playing, type: MediaEventType.play);
    const paused =
        MediaEvent(state: MediaState.pause, type: MediaEventType.pause);
    final tracks = [
      for (final video in videos)
        video.copyWith(
            lengthSeconds: 120,
            musicMetadata: MusicMetadata(title: video.videoId, artist: 'Band')),
    ];
    final queue = [tracks.first, ...tracks];
    await player.playMusicFromCard(queue, origin: origin, startIndex: 1);
    player.setEvent(played);
    expect(player.musicCardPlaying(origin), isTrue);
    expect(player.musicCardPlaying(otherOccurrence), isNull);
    expect(player.musicCardPlaying(otherCollection), isNull);

    const position = Duration(milliseconds: 24321);
    await player.onProgress(position);
    player.moveQueueOccurrence('c', beforeId: 'b');
    expect(await player.enqueueMusicSongs([tracks.first], next: false), isTrue);
    final before = player.state;
    final generation = player.playlistGeneration;
    final occurrence = player.playbackOccurrenceRevision;
    expect(before.currentQueueId, 'a#1');
    expect(before.playQueue, ['c', 'b', 'a#2']);

    expect(player.toggleMusicCard(otherOccurrence), isFalse);
    expect(player.toggleMusicCard(otherCollection), isFalse);
    expect(player.state, same(before));

    expect(player.toggleMusicCard(origin), isTrue);
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    player.setEvent(paused);
    expect(player.musicCardPlaying(origin), isFalse);
    expect(player.toggleMusicCard(origin), isTrue);
    expect(player.state.mediaCommand?.type, MediaCommandType.play);
    player.setEvent(played);
    expect(player.musicCardPlaying(origin), isTrue);
    expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
    expect(player.state.position, position);
    expect(player.state.playedVideos, before.playedVideos);
    expect(player.state.playQueue, before.playQueue);
    expect(player.state.videos, before.videos);
    expect(player.playlistGeneration, generation);
    expect(player.playbackOccurrenceRevision, occurrence);

    await player.selectQueueOccurrence('c');
    player.setEvent(played);
    expect(player.state.currentQueueId, 'c');
    expect(player.musicCardPlaying(origin), isTrue);
    expect(player.musicCardPlaying(nextSong), isNull);

    await player.playMusicFromCard(queue,
        origin: otherCollection, startIndex: 1);
    player.setEvent(played);
    expect(player.state.currentQueueId, 'a#1');
    expect(player.musicCardPlaying(otherCollection), isTrue);
    expect(player.musicCardPlaying(origin), isNull);
    expect(player.toggleMusicCard(origin), isFalse);

    await player.playVideo(queue, fromMusic: true, startIndex: 1);
    player.setEvent(played);
    expect(player.state.currentQueueId, 'a#1');
    expect(player.musicCardPlaying(otherCollection), isNull);
    expect(player.toggleMusicCard(otherCollection), isFalse);
  });

  test('queue removal Undo restores duplicate IDs and the exact shuffle order',
      () async {
    await settings.setShuffle(true);
    final songs = [videos[0], videos[1], videos[0], videos[2], videos[0]];
    await player.playVideo(songs, audio: true, fromMusic: true);
    player.setEvent(const MediaEvent(state: MediaState.playing));
    player.seek(const Duration(seconds: 7));
    final before = player.state;
    final decoder = player.backendPlaybackGeneration;
    final sourceIds = before.videos.map(playbackQueueId).toList();
    final removed = {sourceIds[2], sourceIds[4]};
    final undo =
        player.removeInactiveQueueOccurrences({...removed, sourceIds.first})!;
    expect(undo.count, 2);
    expect(player.state.playQueue,
        before.playQueue.where((id) => !removed.contains(id)));

    expect(player.undoQueueRemoval(undo), isTrue);
    expect(player.state.videos.map(playbackQueueId), sourceIds);
    expect(player.state.playQueue, before.playQueue);
    expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
    expect(player.state.position, before.position);
    expect(player.state.mediaCommand, same(before.mediaCommand));
    expect(player.backendPlaybackGeneration, decoder);

    final staleUndo = player.removeInactiveQueueOccurrences(removed)!;
    final generation = player.playlistGeneration;
    // Reuse the surviving IDs in a new queue to exercise ownership rather
    // than relying on an ID collision to reject the old Undo.
    await player.playVideo(videos, audio: true, fromMusic: true);
    expect(player.playlistGeneration, greaterThan(generation));
    final replacement = player.state;
    expect(player.undoQueueRemoval(staleUndo), isFalse);
    expect(player.state, same(replacement));
  });

  test('queue removal Undo restores each side of a newly playing song',
      () async {
    await player.playVideo(
      [videos[0], videos[1], videos[2], videos[1]],
      audio: true,
      fromMusic: true,
    );
    final ids = player.state.videos.map(playbackQueueId).toList();
    final undo = player.removeInactiveQueueOccurrences({ids[1], ids[3]})!;
    await player.selectQueueOccurrence(ids[2]);
    expect(player.state.currentQueueId, ids[2]);
    final playing = player.state.currentlyPlaying;
    final decoder = player.backendPlaybackGeneration;

    expect(player.undoQueueRemoval(undo), isTrue);
    expect(player.state.videos.map(playbackQueueId), ids);
    expect(player.state.playedVideos, ids.take(2));
    expect(player.state.playQueue, [ids[3]]);
    expect(player.state.currentlyPlaying, same(playing));
    expect(player.backendPlaybackGeneration, decoder);
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

  test('car queue IDs select occurrences and expire on queue replacement',
      () async {
    const channel = MethodChannel('videre/car_media');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var rows = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setMusicQueue') {
        rows = [
          for (final row in call.arguments as List)
            Map<Object?, Object?>.from(row as Map),
        ];
        return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final songs = [
      for (final video in [videos.first, videos.first, videos.last])
        video.copyWith(
          lengthSeconds: 120,
          musicMetadata: MusicMetadata(title: video.videoId, artist: 'Artist'),
        ),
    ];
    await player.playVideo(songs, fromMusic: true);
    await Future<void>.delayed(Duration.zero);
    final firstId = rows[0]['id']! as int;
    final duplicateId = rows[1]['id']! as int;
    expect(firstId, isNot(duplicateId));
    expect(handler.playbackState.value.queueIndex, firstId);

    await handler.skipToQueueItem(duplicateId);
    await Future<void>.delayed(Duration.zero);
    expect(player.state.currentQueueId, 'a#1');
    expect(handler.playbackState.value.queueIndex, duplicateId);

    await player.playVideo(songs, fromMusic: true, startIndex: 2);
    await Future<void>.delayed(Duration.zero);
    expect(rows[1]['id'], isNot(duplicateId));
    await handler.skipToQueueItem(duplicateId);
    expect(player.state.currentQueueId, 'c');
  });

  test(
    'car browse edits exact occurrences in the active unlocked Music queue',
    () async {
      const channel = MethodChannel('videre/car_media');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final refreshed = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'notifyChildrenChanged') {
          refreshed.add(call.arguments as String);
        }
        return call.method == 'setMusicQueue' ? true : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      Future<Object?> request(String method, Object args) async {
        final reply = await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, args)),
          null,
        );
        return channel.codec.decodeEnvelope(reply!);
      }

      Future<List<Map<Object?, Object?>>> children(String parent) async => [
            for (final row
                in await request('getQueueBrowseChildren', parent) as List)
              row as Map<Object?, Object?>,
          ];

      Future<Object?> edit(String action, Object? row) =>
          request('mutateMusicQueue', {'action': action, 'mediaId': row});

      const saved = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'queuesong01',
        title: 'First song',
      );
      await MusicLibraryService.forProfile(db, db.profileId).save(saved);
      final song = saved.toVideo().copyWith(
        lengthSeconds: 120,
        formatStreams: [],
        adaptiveFormats: [],
      );
      final third = song.copyWith(videoId: 'queuesong02');
      final fourth = song.copyWith(videoId: 'queuesong03');
      final songs = [song, song, videos[1], third, fourth];
      await player.playVideo(songs, fromMusic: true);
      await Future<void>.delayed(Duration.zero);
      final mounted = player.state.currentlyPlaying;
      expect(mounted?.videoId, song.videoId);
      final generation = player.playlistGeneration;
      final root = await children(AudioService.browsableRootId);
      final savedSongs = root
          .singleWhere((row) => row['title'] == 'Saved songs')['id'] as String;
      final queue =
          root.singleWhere((row) => row['title'] == 'Queue')['id'] as String;
      final savedRow = (await children(savedSongs)).single;
      expect(savedRow['actions'], ['addToQueue']);
      await settings.saveSetting(
        SettingsValue(musicQueueLockedSettingName, 'true'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(refreshed, contains(savedSongs));
      expect((await children(savedSongs)).single['actions'], isEmpty);
      await settings.saveSetting(
        SettingsValue(musicQueueLockedSettingName, 'false'),
      );
      expect(await edit('addToQueue', savedRow['id']), isTrue);
      expect(player.state.playQueue, [
        'queuesong01#1',
        'b',
        'queuesong02',
        'queuesong03',
        'queuesong01#2',
      ]);

      final rows = await children(queue);
      final active = rows[0];
      final duplicate = rows[1];
      expect(active['actions'], isEmpty);
      expect(duplicate['actions'], ['removeFromQueue', 'moveQueueLater']);
      expect(await edit('removeFromQueue', active['id']), isFalse);
      expect(await edit('moveQueueLater', duplicate['id']), isTrue);
      expect(player.state.playQueue, [
        'b',
        'queuesong02',
        'queuesong01#1',
        'queuesong03',
        'queuesong01#2',
      ]);
      expect(await edit('moveQueueEarlier', duplicate['id']), isTrue);
      expect(player.state.playQueue.take(2), ['b', 'queuesong01#1']);

      await settings.saveSetting(
        SettingsValue(musicQueueLockedSettingName, 'true'),
      );
      expect((await children(savedSongs)).single['actions'], isEmpty);
      expect(
        (await children(
          queue,
        ))
            .every((row) => (row['actions'] as List).isEmpty),
        isTrue,
      );
      expect(await edit('addToQueue', savedRow['id']), isFalse);
      expect(await edit('removeFromQueue', duplicate['id']), isFalse);
      expect(await edit('moveQueueLater', duplicate['id']), isFalse);
      await settings.saveSetting(
        SettingsValue(musicQueueLockedSettingName, 'false'),
      );
      expect(await edit('removeFromQueue', duplicate['id']), isTrue);
      expect(await edit('removeFromQueue', duplicate['id']), isFalse);
      expect(player.state.videos.map(playbackQueueId), [
        'queuesong01',
        'b',
        'queuesong02',
        'queuesong03',
        'queuesong01#2',
      ]);
      expect(player.state.currentlyPlaying, same(mounted));
      expect(player.playlistGeneration, generation);

      await player.playVideo(songs, fromMusic: true);
      await Future<void>.delayed(Duration.zero);
      expect(await edit('removeFromQueue', duplicate['id']), isFalse);
      expect(player.state.videos.map(playbackQueueId), [
        'queuesong01',
        'queuesong01#1',
        'b',
        'queuesong02',
        'queuesong03',
      ]);

      final next = (await children(queue))[1];
      refreshed.clear();
      await handler.playFromMediaId(next['id'] as String);
      await Future<void>.delayed(Duration.zero);
      expect(player.state.currentQueueId, 'queuesong01#1');
      expect(refreshed, contains(queue));
      expect((await children(queue))[1]['actions'], isEmpty);
    },
  );

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

  test('steering a seeded mix preserves the active track and manual edits',
      () async {
    const seed = Video(
        videoId: 'MixSeed0001',
        musicMetadata: MusicMetadata(title: 'Seed', artist: 'Seed Artist'),
        adaptiveFormats: [],
        formatStreams: []);
    const pool = [
      MusicTrack(videoId: 'MixTrack001', title: 'One', artists: ['Other']),
      MusicTrack(videoId: 'MixTrack002', title: 'Two', artists: ['Second']),
      MusicTrack(videoId: 'MixTrack003', title: 'Three', artists: ['Third']),
      MusicTrack(videoId: 'MixTrack004', title: 'Four', artists: ['Fourth']),
      MusicTrack(
          videoId: 'MixTrack005', title: 'Five', artists: ['Seed Artist']),
      MusicTrack(videoId: 'MixTrack006', title: 'Six', artists: ['Sixth']),
      MusicTrack(
          videoId: 'MixTrack007', title: 'Seven', artists: ['Seed Artist']),
    ];
    expect(
        await player.playMusicMix(seed,
            queueTitle: 'Mix from Seed',
            loadCandidates: (_) async => pool,
            isCurrent: () => true),
        isTrue);
    expect(player.state.currentQueueId, seed.videoId);
    expect(player.state.playQueue, pool.take(4).map((track) => track.videoId));

    player.enqueueQueueCopies([
      pool.first.toVideo(),
      const Video(
          videoId: 'MixManual01', adaptiveFormats: [], formatStreams: [])
    ], next: true);
    final duplicate = player.state.playQueue.first;
    expect(duplicate, isNot(pool.first.videoId));
    player.moveMusicQueueOccurrence('MixTrack004', beforeId: 'MixTrack002');
    player.removeInactiveQueueOccurrences({'MixTrack003'});
    await db.saveFilter(VideoFilter(value: 'Five')..hideFromFeed = true);
    player.seek(const Duration(seconds: 17));
    final before = player.state;

    expect(player.steerMusicMix(MusicMixSteering.moreFromSeedArtist), isTrue);
    expect(player.state.playQueue, [
      duplicate,
      'MixManual01',
      'MixTrack007',
      'MixTrack004',
      'MixTrack002'
    ]);
    expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
    expect(player.state.playedVideos, before.playedVideos);
    expect(player.state.position, before.position);
    expect(player.state.mediaCommand, same(before.mediaCommand));
    expect(player.state.videos.map(playbackQueueId), [
      seed.videoId,
      duplicate,
      'MixManual01',
      'MixTrack007',
      'MixTrack004',
      'MixTrack002',
    ]);

    await player.selectQueueOccurrence('MixManual01');
    expect(player.state.playedVideos, [seed.videoId, duplicate]);
    expect(player.steerMusicMix(MusicMixSteering.moreVariety), isTrue);
    expect(
        player.state.playQueue, ['MixTrack006', 'MixTrack004', 'MixTrack002']);
    expect(player.state.currentQueueId, 'MixManual01');
    expect(player.state.playedVideos, [seed.videoId, duplicate]);
    await player.playVideo(videos);
    expect(player.hasActiveMusicMix, isFalse);
  });

  test('mix familiarity uses permitted profile signals in editable slots',
      () async {
    const seed = Video(
        videoId: 'MixSeed0001',
        musicMetadata: MusicMetadata(title: 'Seed', artist: 'Seed Artist'),
        adaptiveFormats: [],
        formatStreams: []);
    const pool = [
      MusicTrack(
          videoId: 'MixTrack001', title: 'One', artists: ['Seed Artist']),
      MusicTrack(videoId: 'MixTrack002', title: 'Two', artists: ['Other']),
      MusicTrack(
          videoId: 'MixTrack003', title: 'Three', artists: ['Seed Artist']),
      MusicTrack(videoId: 'MixTrack004', title: 'Four', artists: ['Fourth']),
      MusicTrack(
          videoId: 'MixTrack005', title: 'Five', artists: ['Seed Artist']),
      MusicTrack(
          videoId: 'MixTrack006', title: 'Six', artists: ['Seed Artist']),
      MusicTrack(
          videoId: 'MixTrack007', title: 'Seven', artists: ['Seed Artist']),
    ];
    final library = MusicLibraryService.forProfile(db, db.profileId);
    await library.save(MusicLibraryEntry.song(pool[5].toVideo()));
    await library.save(MusicLibraryEntry.song(pool[6].toVideo()));
    await db.recordPlaybackHistory(PlaybackHistoryOrigin.music,
        HistoryVideoCache(pool[4].videoId, pool[4].title, 'Seed Artist', ''));
    expect(
        await player.playMusicMix(seed,
            queueTitle: 'Mix from Seed',
            loadCandidates: (_) async => pool,
            isCurrent: () => true),
        isTrue);
    player.enqueueQueueCopies([pool[1].toVideo()], next: true);
    final manual = player.state.playQueue.first;
    expect(manual, isNot(pool[1].videoId));
    player.removeInactiveQueueOccurrences({pool[1].videoId, pool[2].videoId});
    await db.saveFilter(VideoFilter(value: 'Seven')..hideFromFeed = true);
    player.seek(const Duration(seconds: 17));
    final before = player.state;

    expect(player.steerMusicMixFamiliarity(MusicMixFamiliarity.moreFamiliar),
        isTrue);
    expect(player.state.playQueue, [manual, 'MixTrack005', 'MixTrack006']);
    player.steerMusicMix(MusicMixSteering.moreFromSeedArtist);
    expect(player.musicMixFamiliarity, MusicMixFamiliarity.moreFamiliar);

    expect(player.steerMusicMixFamiliarity(MusicMixFamiliarity.moreDiscovery),
        isTrue);
    expect(player.state.playQueue, [manual, 'MixTrack001', 'MixTrack005']);
    expect(player.musicMixSteering, MusicMixSteering.moreFromSeedArtist);
    expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
    expect(player.state.playedVideos, before.playedVideos);
    expect(player.state.position, before.position);
    expect(player.state.mediaCommand, same(before.mediaCommand));

    await db.setMusicHistoryRecordingPaused(true);
    expect(player.steerMusicMixFamiliarity(MusicMixFamiliarity.moreFamiliar),
        isTrue);
    expect(player.state.playQueue, [manual, 'MixTrack006', 'MixTrack001']);

    await db.setMusicHistoryRecordingPaused(false);
    await RecommendationService.forProfile(db, db.profileId)
        .setLearningEnabled(RecommendationDomain.music, false);
    expect(player.musicMixLearningEnabled, isFalse);
    expect(player.steerMusicMix(MusicMixSteering.moreFromSeedArtist), isTrue);
    expect(player.state.playQueue, [manual, 'MixTrack001', 'MixTrack005']);
  });

  test('starting a seeded mix cannot replace a newer queue', () async {
    const seed = Video(
        videoId: 'MixSeed0001',
        musicMetadata: MusicMetadata(title: 'Seed', artist: 'Seed Artist'),
        adaptiveFormats: [],
        formatStreams: []);
    final result = Completer<List<MusicTrack>>();
    late bool Function() current;
    final pending = player.playMusicMix(seed,
        queueTitle: 'Mix from Seed',
        loadCandidates: (isCurrent) {
          current = isCurrent;
          return result.future;
        },
        isCurrent: () => true);
    expect(current(), isTrue);
    await player.playVideo(videos.reversed.toList());
    expect(current(), isFalse);
    result.complete([const MusicTrack(videoId: 'MixTrack001', title: 'One')]);
    expect(await pending, isNull);
    expect(player.state.currentQueueId, 'c');
    expect(player.hasActiveMusicMix, isFalse);
  });

  test('an artist mix deduplicates songs and keeps manual edits when steered',
      () async {
    const firstId = 'UCabcdefghijklmnopqrstuv';
    const secondId = 'UCABCDEFGHIJKLMNOPQRSTUV';
    const first = MusicArtist(id: firstId, name: 'Artist');
    const second = MusicArtist(id: secondId, name: 'Guest');
    const anchor = MusicTrack(
        videoId: 'MixTrack002',
        title: 'First verified song',
        artistCredits: [
          MusicArtistCredit(name: 'Artist alias', id: firstId),
        ]);
    const removed = MusicTrack(
        videoId: 'MixTrack005',
        title: 'Removed song',
        artistCredits: [
          MusicArtistCredit(name: 'Guest alias', id: secondId),
        ]);
    const replacement = MusicTrack(
        videoId: 'MixTrack006',
        title: 'Another verified song',
        artistCredits: [
          MusicArtistCredit(name: 'Guest alias', id: secondId),
        ]);
    const unverified = MusicTrack(
        videoId: 'MixTrack001', title: 'Same name', artists: ['Artist']);
    const moveTarget = MusicTrack(videoId: 'MixTrack003', title: 'Move target');
    const moved = MusicTrack(videoId: 'MixTrack004', title: 'Moved song');

    expect(
        await player.playArtistMusicMix([first, second],
            queueTitle: 'Artist mix',
            loadCandidates: (_) async => [
                  unverified,
                  anchor,
                  anchor,
                  moveTarget,
                  moved,
                  removed,
                  replacement
                ],
            isCurrent: () => true),
        isTrue);
    expect(player.state.currentQueueId, anchor.videoId);
    expect(player.musicQueueTitle, 'Artist mix');
    expect(player.state.playQueue, [
      unverified.videoId,
      moveTarget.videoId,
      moved.videoId,
      removed.videoId
    ]);

    player.enqueueQueueCopies([unverified.toVideo()], next: true);
    final manualCopy = player.state.playQueue.first;
    expect(manualCopy, isNot(unverified.videoId));
    player.moveMusicQueueOccurrence(moved.videoId,
        beforeId: moveTarget.videoId);
    player.removeInactiveQueueOccurrences({removed.videoId});
    player.seek(const Duration(seconds: 17));
    final before = player.state;

    expect(player.steerMusicMix(MusicMixSteering.moreFromSeedArtist), isTrue);
    expect(player.state.playQueue,
        [manualCopy, replacement.videoId, moved.videoId, moveTarget.videoId]);
    expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
    expect(player.state.position, before.position);
    expect(player.state.playedVideos, before.playedVideos);
  });

  test('an artist mix needs an eligible verified seed song', () async {
    const firstId = 'UCabcdefghijklmnopqrstuv';
    const first = MusicArtist(id: firstId, name: 'Artist');
    const missing = MusicArtist(id: 'UCABCDEFGHIJKLMNOPQRSTUV', name: 'Guest');
    const sameName = MusicTrack(
        videoId: 'MixTrack001', title: 'Same name', artists: ['Artist']);
    const verified = MusicTrack(
        videoId: 'MixTrack002',
        title: 'Verified song',
        artistCredits: [
          MusicArtistCredit(name: 'Artist', id: firstId),
        ]);
    await player.playVideo(videos, audio: true);
    final before = player.state;

    for (final candidates in <List<MusicTrack>>[
      [],
      [sameName],
    ]) {
      expect(
          await player.playArtistMusicMix([first, missing],
              queueTitle: 'Artist mix',
              loadCandidates: (_) async => candidates,
              isCurrent: () => true),
          isFalse);
      expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
      expect(player.state.playQueue, before.playQueue);
      expect(player.hasActiveMusicMix, isFalse);
    }

    expect(
        await player.playArtistMusicMix([first, missing],
            queueTitle: 'Artist mix',
            loadCandidates: (_) async => [verified],
            isCurrent: () => true),
        isTrue);
    expect(player.state.currentQueueId, verified.videoId);
    expect(player.state.playQueue, isEmpty);
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

  test('album shuffle groups the upcoming songs in source order for Next',
      () async {
    Video track(String id, {String? album}) => Video(
          videoId: id,
          formatStreams: const [],
          adaptiveFormats: const [],
          lengthSeconds: 120,
          musicMetadata: MusicMetadata(
            title: id,
            artist: 'Artist',
            albumPlaylistId: album,
          ),
        );
    await player.playVideo([
      track('previous'),
      track('current'),
      track('a1', album: 'OLAK5uy_a'),
      track('b1', album: 'OLAK5uy_b'),
      track('a2', album: 'OLAK5uy_a'),
      track('b2', album: 'OLAK5uy_b'),
    ], audio: true, fromMusic: true, startIndex: 1);
    player.seek(const Duration(seconds: 17));
    final before = player.state;
    final generation = player.backendPlaybackGeneration;
    expect(before.playQueue, ['a1', 'b1', 'a2', 'b2']);

    player.shuffleMusicQueueUpcoming(MusicQueueShuffle.albums);

    final shuffled = player.state;
    final upcoming = shuffled.playQueue.toList();
    expect(
        upcoming,
        anyOf(equals(['a1', 'a2', 'b1', 'b2']),
            equals(['b1', 'b2', 'a1', 'a2'])));
    expect(shuffled.videos.map(playbackQueueId),
        before.videos.map(playbackQueueId));
    expect(shuffled.playedVideos, ['previous']);
    expect(shuffled.currentQueueId, 'current');
    expect(shuffled.currentlyPlaying, same(before.currentlyPlaying));
    expect(shuffled.position, const Duration(seconds: 17));
    expect(shuffled.mediaCommand, same(before.mediaCommand));
    expect(player.backendPlaybackGeneration, generation);
    expect(settings.state.playerShuffleMode, isFalse);

    final advanced = player.stream
        .firstWhere((state) => state.currentQueueId == upcoming.first);
    player.playNext();
    final next = await advanced.timeout(const Duration(seconds: 2));
    expect(next.playedVideos, ['previous', 'current']);
    expect(next.playQueue, upcoming.skip(1));
  });

  test('fewer repeats preserves the explicitly queued next occurrence',
      () async {
    const music = MusicMetadata(title: 'Song', artist: 'Artist');
    final repeat = videos[0].copyWith(musicMetadata: music);
    await player.playVideo([
      repeat,
      repeat,
      videos[1].copyWith(musicMetadata: music),
      videos[2].copyWith(musicMetadata: music),
    ], audio: true, fromMusic: true);
    final duplicate = player.state.playQueue.first;
    expect(await player.enqueueMusicSongs([repeat], next: true), isTrue);
    final explicit = player.state.playQueue.first;
    final before = player.state.playQueue.toList();
    expect(duplicate, isNot(explicit));
    expect(explicit, isNot(player.state.currentQueueId));

    await settings
        .saveSetting(SettingsValue(musicQueueLockedSettingName, 'true'));
    player.shuffleMusicQueueUpcoming(MusicQueueShuffle.fewerRepeats);
    expect(player.state.playQueue, before);

    await settings
        .saveSetting(SettingsValue(musicQueueLockedSettingName, 'false'));
    player.shuffleMusicQueueUpcoming(MusicQueueShuffle.fewerRepeats);
    final shuffled = player.state.playQueue.toList();
    expect(shuffled, unorderedEquals(before));
    expect(shuffled.first, explicit);
    expect(shuffled[1], isNot(duplicate));

    player.moveMusicQueueOccurrence(duplicate, beforeId: shuffled[1]);
    expect(player.state.playQueue.take(2), [explicit, duplicate]);
    player.removeVideoFromQueue(duplicate);
    expect(player.state.playQueue, shuffled.where((id) => id != duplicate));
    expect(
        player.state.videos.map(playbackQueueId), isNot(contains(duplicate)));

    final advanced =
        player.stream.firstWhere((state) => state.currentQueueId == explicit);
    player.playNext();
    final next = await advanced.timeout(const Duration(seconds: 2));
    expect(next.currentlyPlaying?.videoId, repeat.videoId);
    expect(next.playedVideos, [playbackQueueId(repeat)]);

    final returned = player.stream
        .firstWhere((state) => state.currentQueueId == playbackQueueId(repeat));
    player.playPrevious();
    await returned.timeout(const Duration(seconds: 2));
    expect(player.state.playQueue.first, explicit);
    player.shuffleMusicQueueUpcoming(MusicQueueShuffle.fewerRepeats);
    expect(player.state.playQueue.first, explicit);
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
        {int index = 0,
        String? savedOnly,
        Map<String, String> albumIds = const {}}) async {
      final server = await db.getCurrentlySelectedServer();
      final songs = [
        for (final id in ids)
          Video(
              videoId: id,
              title: id,
              downloadPlaybackOnly: id == savedOnly,
              musicMetadata: MusicMetadata(
                  title: id,
                  artist: 'Artist',
                  album: 'Album',
                  albumPlaylistId: albumIds[id]))
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

    group('Music transport preferences', () {
      const completed = MediaEvent(state: MediaState.completed);
      const playing = MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.play,
      );
      const paused = MediaEvent(
        state: MediaState.pause,
        type: MediaEventType.pause,
      );

      for (final restartFirst in [false, true]) {
        test(
          'Previous applies the track policy (restart first=$restartFirst)',
          () async {
            if (restartFirst) {
              await settings.setMusicPreviousTrackPolicy(
                MusicPreviousTrackPolicy.restartCurrentAfterThreshold,
              );
            }
            await open(['a', 'b', 'c'], index: 1);
            await player.onProgress(const Duration(seconds: 4));

            await handler.skipToPrevious();
            if (restartFirst) {
              expect(player.state.currentQueueId, 'b');
              expect(player.state.position, Duration.zero);
              expect(player.state.playedVideos, ['a']);
              expect(player.state.playQueue, ['c']);
              player.playPrevious();
            }
            await until(() => player.state.currentQueueId == 'a');
            expect(player.state.playQueue, ['b', 'c']);
          },
        );
      }

      for (final keepPaused in [false, true]) {
        test(
          'manual next respects keep-paused setting ($keepPaused)',
          () async {
            await settings.setMusicKeepPausedOnSkip(keepPaused);
            await open(['a', 'b', 'c']);
            await handler.pause();
            player.setEvent(paused);

            await handler.skipToNext();
            await until(() => player.state.currentQueueId == 'b');
            expect(player.intendsPlayback, !keepPaused);
            expect(player.state.position, Duration.zero);
            if (keepPaused) {
              player.setEvent(const MediaEvent(state: MediaState.ready));
              expect(handler.playbackState.value.playing, isFalse);
            }
          },
        );
      }

      test(
        'Previous and both queue selectors preserve a Music pause',
        () async {
          await settings.setMusicKeepPausedOnSkip(true);
          await open(['a', 'b', 'c'], index: 1);
          player.pause();
          player.setEvent(paused);

          player.playPrevious();
          await until(() => player.state.currentQueueId == 'a');
          expect(player.intendsPlayback, isFalse);
          await player.selectQueueOccurrence('c');
          expect(player.state.currentQueueId, 'c');
          expect(player.intendsPlayback, isFalse);
          await handler.skipToQueueItem(1);
          expect(player.state.currentQueueId, 'b');
          expect(player.intendsPlayback, isFalse);
          player.setEvent(const MediaEvent(state: MediaState.ready));
          expect(handler.playbackState.value.playing, isFalse);
        },
      );

      test(
        'repeat-one cues the same song and waits for explicit Play',
        () async {
          await settings.setRepeatMode(PlayerRepeat.repeatOne);
          await settings.setMusicPauseAtRepeat(true);
          await open(['a', 'b']);
          await player.onProgress(const Duration(seconds: 8));

          player.setEvent(completed);
          await until(
            () =>
                player.state.position == Duration.zero &&
                !player.intendsPlayback,
          );
          expect(player.state.currentQueueId, 'a');
          expect(player.state.playQueue, ['b']);
          expect(handler.playbackState.value.playing, isFalse);

          await handler.play();
          player.setEvent(playing);
          expect(handler.playbackState.value.playing, isTrue);
          expect(player.state.currentQueueId, 'a');
        },
      );

      test(
        'repeat-all advances normally and pauses only at the queue wrap',
        () async {
          await settings.setRepeatMode(PlayerRepeat.repeatAll);
          await settings.setMusicPauseAtRepeat(true);
          await settings.setSongTransitionMode(SongTransitionMode.crossfade);
          await open(['a', 'b']);
          expect(player.automaticMusicSuccessor?.videoId, 'b');

          player.setEvent(completed);
          await until(() => player.state.currentQueueId == 'b');
          expect(player.intendsPlayback, isTrue);
          player.setEvent(playing);
          expect(player.automaticMusicSuccessor, isNull);

          player.setEvent(completed);
          await until(
            () =>
                player.state.currentQueueId == 'a' &&
                player.state.playQueue.isNotEmpty,
          );
          expect(player.state.position, Duration.zero);
          expect(player.state.playedVideos, isEmpty);
          expect(player.state.playQueue, ['b']);
          expect(player.intendsPlayback, isFalse);
          expect(handler.playbackState.value.playing, isFalse);
        },
      );
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

      for (final (shuffle, startIndex) in [(false, 0), (false, 2), (true, 0)]) {
        test(
            'collection queue preserves copies at index $startIndex '
            '(shuffle=$shuffle)', () async {
          player.manualMusicPreparer = null;
          await settings.setShuffle(true);
          final firstSource = PlaylistReference(
            kind: PlaylistSourceKind.local,
            playlistId: 'local:first-source',
            profileId: db.profileId,
          );
          final secondSource = PlaylistReference(
            kind: PlaylistSourceKind.local,
            playlistId: 'local:second-source',
            profileId: db.profileId,
          );
          final tracks = [song('a'), song('b'), song('a'), song('c')];
          final originalIds =
              assignPlaybackQueueIds(tracks).map(playbackQueueId).toList();
          final expectedSources = {
            originalIds.first: musicPlaylistRecommendationKey(firstSource),
            originalIds[2]: musicPlaylistRecommendationKey(secondSource),
          };

          await player.playMusicCollectionQueue(
            [
              tracks.first,
              song('filtered').copyWith(filtered: true),
              ...tracks.skip(1),
            ],
            queueTitle: 'Selected collections',
            shuffle: shuffle,
            startIndex: shuffle || startIndex == 0 ? null : startIndex + 1,
            recommendationSources: [
              firstSource,
              secondSource,
              null,
              secondSource,
              null,
            ],
          );

          final ordered = player.state.videos;
          final ids = ordered.map(playbackQueueId).toList();
          if (shuffle) {
            expect(ordered.map((track) => track.videoId),
                unorderedEquals(['a', 'b', 'a', 'c']));
          } else {
            expect(ordered.map((track) => track.videoId), ['a', 'b', 'a', 'c']);
          }
          expect(ids.toSet(), hasLength(tracks.length));
          expect(player.state.currentQueueId, ids[startIndex]);
          expect(player.state.playedVideos, ids.take(startIndex).toList());
          expect(player.state.playQueue, ids.skip(startIndex + 1).toList());
          expect(
              player
                  .captureMusicPlaybackCheckpoint()
                  ?.musicRecommendationSources,
              expectedSources);

          expect(
              await player.enqueueMusicCollectionQueue([song('a'), song('a')],
                  recommendationSources: [secondSource, firstSource]),
              isTrue);
          final appended = player.state.videos
              .skip(ids.length)
              .map(playbackQueueId)
              .toList();
          expect(appended.toSet(), hasLength(2));
          expect(appended.toSet().intersection(ids.toSet()), isEmpty);
          expect(player.state.currentQueueId, ids[startIndex]);
          expect(player.state.playQueue,
              [...ids.skip(startIndex + 1), ...appended]);
          expect(
              player
                  .captureMusicPlaybackCheckpoint()
                  ?.musicRecommendationSources,
              {
                ...expectedSources,
                appended.first: musicPlaylistRecommendationKey(secondSource),
                appended.last: musicPlaylistRecommendationKey(firstSource),
              });
        });
      }

      test('a cancelled collection selection cannot replace active playback',
          () async {
        final before = player.state;
        final generation = player.playlistGeneration;
        var current = true;
        final switching = player.playMusicCollectionQueue([song('new')],
            queueTitle: 'Selected collections', isCurrent: () => current);
        await until(() => preparer.requests.containsKey('new'));

        current = false;
        preparer.requests['new']!.complete(true);
        await switching;

        expect(player.playlistGeneration, generation);
        expect(player.state.currentQueueId, before.currentQueueId);
        expect(player.state.playQueue, before.playQueue);
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

      test('Back during Music selection preserves the playing occurrence',
          () async {
        player.manualMusicPreparer = null;
        await open(['a', 'b', 'a'], index: 2);
        player.manualMusicPreparer = preparer;
        final before = player.state;
        final occurrence = before.currentQueueId;
        expect(occurrence, isNot(playbackQueueId(before.videos.first)));
        expect(before.isMini, isFalse);
        expect(handler.mediaItem.value?.id, 'a');
        final selection = player.playVideo([song('new')], audio: true);
        await until(() => preparer.requests.containsKey('new'));

        expect(player.handleBackButton(false, RouteInfo()), isTrue);
        expect(player.state.isMini, isTrue);
        preparer.requests['new']!.complete(true);
        await selection;

        expect(player.state.currentQueueId, occurrence);
        expect(player.state.isMini, isTrue);
        expect(player.state.playedVideos, before.playedVideos);
        expect(player.state.playQueue, before.playQueue);
        expect(player.state.mediaCommand, same(before.mediaCommand));
        expect(handler.mediaItem.value?.id, 'a');
        expect(handler.playbackState.value.playing, isTrue);
      });

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

      test('a song tap resets shuffle only after its selection commits',
          () async {
        await settings.setShuffle(true);
        player.generatePlayQueue();
        final current = player.state.currentQueueId;
        final upcoming = player.state.playQueue.toList();
        expect(settings.state.musicRetainShuffleOnSongTap, isTrue);
        await settings.setMusicRetainShuffleOnSongTap(false);
        expect(settings.state.playerShuffleMode, isTrue);
        expect(player.state.playQueue, upcoming);

        final failed = player.playVideo([song('failed')],
            audio: true, fromMusic: true, songTap: true);
        await until(() => preparer.requests.containsKey('failed'));
        expect(settings.state.playerShuffleMode, isTrue);
        preparer.requests['failed']!.complete(false);
        await failed;
        expect(settings.state.playerShuffleMode, isTrue);
        expect(player.state.currentQueueId, current);
        expect(player.state.playQueue, upcoming);

        final replacement = [song('x'), song('y'), song('z')];
        final explicit = player.playVideo(replacement,
            audio: true, fromMusic: true, startIndex: 1);
        await until(() => preparer.requests.containsKey('y'));
        preparer.requests['y']!.complete(true);
        await explicit;
        expect(settings.state.playerShuffleMode, isTrue);
        expect(player.state.currentQueueId, 'y');
        expect(player.state.playedVideos, isEmpty);
        expect(player.state.playQueue, unorderedEquals(['x', 'z']));

        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        final tapped = player.playVideo([song('d'), song('e'), song('f')],
            audio: true, fromMusic: true, startIndex: 1, songTap: true);
        await until(() => preparer.requests.containsKey('e'));
        expect(settings.state.playerShuffleMode, isTrue);
        preparer.requests['e']!.complete(true);
        await tapped;
        expect(settings.state.playerShuffleMode, isFalse);
        expect(player.state.currentQueueId, 'e');
        expect(player.state.playedVideos, ['d']);
        expect(player.state.playQueue, ['f']);
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

      test('a failed opportunistic download tries the current online route',
          () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await db.saveSetting(SettingsValue(
            SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
        final selected = song('x');
        final server = await db.getCurrentlySelectedServer();
        final digest = 'a' * 64;
        final provenance = DownloadPlaybackProvenance.tryFromJson({
          'version': 1,
          'profileId': server.profileId,
          'accountId': server.accountId,
          'origin': Uri.parse(server.url).origin,
          'contentId': selected.videoId,
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
        await db.upsertDownload(DownloadedVideo(
            videoId: selected.videoId,
            title: selected.musicMetadata!.title,
            musicMetadata: selected.musicMetadata,
            profileId: server.profileId,
            accountId: server.accountId,
            audioOnly: true,
            folderUri: 'content://files/tree/music',
            storageUri: 'content://files/document/track',
            container: DownloadContainer.webm,
            downloadComplete: true,
            playbackProvenance: provenance,
            lengthSeconds: 120,
            quality: 'audio'));
        final started = Completer<void>();
        final response = Completer<void>();
        final requests = <Uri>[];
        final client = MockClient((request) async {
          requests.add(request.url);
          if (!started.isCompleted) started.complete();
          await response.future;
          return http.Response(
              '{"videoId":"x","title":"Upload","adaptiveFormats":[],"formatStreams":[],"captions":[]}',
              200,
              headers: {'content-type': 'application/json'});
        });
        // Keep adjacent queue preparation out of the selected song's HTTP mock.
        player.removeAdjacentMusicListener(remember);
        addTearDown(client.close);
        addTearDown(() {
          if (!response.isCompleted) response.complete();
        });
        service = Service(httpClient: client);
        final original = player.state.currentlyPlaying;
        final command = player.state.mediaCommand;
        final failure = player.musicSelectionFailureRevision.value;
        final selecting = player.playVideo([selected], audio: true);
        final local =
            await preparer.started.future.timeout(const Duration(seconds: 3));
        expect((local as Video).downloadPlaybackOnly, isTrue);
        expect(preparer.skippedDownloads['x'], isFalse);
        expect(requests, isEmpty);

        final first = preparer.requests['x']!;
        first
            .completeError(const ManualMusicSourceFailure('local unavailable'));
        await Future.any([selecting, started.future])
            .timeout(const Duration(seconds: 3));
        expect(
            requests, [Uri.parse('${server.url}/api/v1/videos/x?local=true')]);
        expect(player.state.currentlyPlaying, same(original));
        expect(player.state.mediaCommand, same(command));
        expect(player.state.isPlaying, isTrue);
        expect(handler.mediaItem.value?.id, 'a');

        response.complete();
        await until(() => !identical(preparer.requests['x'], first));
        expect(preparer.skippedDownloads['x'], isTrue);
        preparer.requests['x']!.complete(true);
        await selecting;
        final committed = player.state.currentlyPlaying!;
        expect(committed.videoId, 'x');
        expect(committed.downloadPlaybackOnly, isFalse);
        expect(committed.musicMetadata?.artist, 'Band');
        expect(requests, hasLength(1));
        expect(handler.mediaItem.value?.id, 'x');
        expect(player.musicSelectionFailureRevision.value, failure);
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
        await player.toggleMusicQueueShuffle(expectedShuffled: false);
        expect(player.musicQueueShuffled, isTrue);
        player.moveQueueOccurrence('b', beforeId: 'c');
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

    test('a preloaded next song uses the retry limit saved before activation',
        () async {
      final selector = BackendSelector('ROUTE',
          const [BackendOption('0', 'First'), BackendOption('1', 'Second')]);
      final selected =
          selector.withSelection(await db.getCurrentlySelectedServer(), '0');
      await db.upsertServer(selected);
      await open(['a', 'b']);
      await until(() => readyIds().contains('b'));
      final warmed = ready.single as Video;
      expect(warmed.playbackConnection?.backendRetryLimit, 2);
      expect(warmed.playbackConnection?.canRetry, isTrue);

      await PlaybackInstanceFallback.saveBackendRetries(db, 0);
      final next = player.stream.firstWhere((s) => s.currentQueueId == 'b');
      player.playNext();
      final playing =
          (await next.timeout(const Duration(seconds: 3))).currentlyPlaying!;
      expect(catalog.requests.where((id) => id == 'b'), hasLength(2));
      expect(playing.playbackSourceId, isNot(same(warmed.playbackSourceId)));
      expect(playing.playbackConnection?.backendRetryLimit, 0);
      expect(playing.playbackConnection?.canRetry, isFalse);
    });

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

    const sleepDeadline = Duration(minutes: 5);
    const timedSleep = SleepTimer(duration: sleepDeadline, stopVideo: false);
    const trackStarted =
        MediaEvent(state: MediaState.playing, type: MediaEventType.play);
    const trackFinished = MediaEvent(state: MediaState.completed);

    testWidgets('finish-song sleep attaches to the song playing at expiry',
        (tester) async {
      await tester.runAsync(() => open(['a', 'b', 'c']));
      player.sleep(timedSleep, finishSong: true);
      await tester.runAsync(() async {
        player.setEvent(trackFinished);
        await until(() => player.state.currentQueueId == 'b');
        player.setEvent(trackStarted);
      });
      expect(player.automaticMusicSuccessor?.videoId, 'c');

      await tester.pump(sleepDeadline);
      expect(player.state.hasTimer, isTrue);
      expect(player.state.isPlaying, isTrue);
      expect(player.automaticMusicSuccessor, isNull);

      await tester.runAsync(() async {
        await settings.setRepeatMode(PlayerRepeat.repeatOne);
        player.setEvent(trackFinished);
        player.setEvent(trackFinished);
      });
      expect(player.state.hasTimer, isFalse);
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaCommand?.type, MediaCommandType.pause);
      expect(player.state.currentQueueId, 'b');
      expect(player.state.playQueue, ['c']);
    });

    for (final expired in [false, true]) {
      testWidgets(
          'cancel finish-song sleep ${expired ? 'after' : 'before'} expiry',
          (tester) async {
        await tester.runAsync(() => open(['a', 'b']));
        player.sleep(timedSleep, finishSong: true);
        if (expired) {
          await tester.pump(sleepDeadline);
          expect(player.automaticMusicSuccessor, isNull);
        }
        player.cancelSleep();
        if (!expired) await tester.pump(sleepDeadline);

        expect(player.state.hasTimer, isFalse);
        expect(player.automaticMusicSuccessor?.videoId, 'b');
        await tester.runAsync(() async {
          player.setEvent(trackFinished);
          await until(() => player.state.currentQueueId == 'b');
          player.setEvent(trackStarted);
        });
        expect(player.state.isPlaying, isTrue);
      });
    }

    testWidgets('skipping after expiry selects the next song paused',
        (tester) async {
      await tester.runAsync(() => open(['a', 'b', 'c']));
      player.sleep(timedSleep, finishSong: true);
      await tester.runAsync(() async {
        await player.selectQueueOccurrence('b');
        player.setEvent(trackStarted);
      });
      await tester.pump(sleepDeadline);

      await tester.runAsync(() async {
        player.playNext();
        await until(() => player.state.currentQueueId == 'c');
      });
      expect(player.state.hasTimer, isFalse);
      expect(player.state.currentQueueId, 'c');
      expect(player.shouldStartPlayback, isFalse);
    });

    for (final sourceFails in [false, true]) {
      testWidgets(
          'finish-song sleep stops a switch still loading at expiry '
          '(source fails: $sourceFails)', (tester) async {
        late Completer<void> holdMetadata;
        await tester.runAsync(() {
          holdMetadata = catalog.blocked['b'] = Completer<void>();
          return open(['a', 'b']);
        });
        player.sleep(timedSleep, finishSong: true);

        await tester.runAsync(() async {
          unawaited(player.switchToVideo(player.state.videos.last));
          await until(() => player.playbackStatus == MediaState.loading);
        });
        expect(player.state.currentQueueId, 'a');
        await tester.pump(sleepDeadline);

        await tester.runAsync(() async {
          if (sourceFails) {
            holdMetadata.completeError(StateError('Source unavailable'));
          } else {
            holdMetadata.complete();
          }
          await until(() => player.state.currentQueueId == 'b');
        });
        expect(player.state.currentQueueId, 'b');
        expect(player.state.hasTimer, isFalse);
        expect(player.shouldStartPlayback, isFalse);
        if (sourceFails) expect(player.playbackStatus, MediaState.error);
      });
    }

    testWidgets('finish-song sleep clears at expiry if playback is paused',
        (tester) async {
      await tester.runAsync(() => open(['a', 'b']));
      player.sleep(timedSleep, finishSong: true);
      await tester.runAsync(() async {
        player.pause();
        player.setEvent(const MediaEvent(
            state: MediaState.pause, type: MediaEventType.pause));
      });

      await tester.pump(sleepDeadline);
      expect(player.state.hasTimer, isFalse);
      expect(player.shouldStartPlayback, isFalse);
    });

    test('track sleep counts natural completions across manual navigation',
        () async {
      await open(['a', 'b', 'c', 'd']);
      player.sleepAfterTracks(2);
      await until(() => readyIds().contains('b'));
      player.playNext();
      await until(() => player.state.currentQueueId == 'b');
      expect(player.state.sleepTracksRemaining, 2);
      player.playPrevious();
      await until(() => player.state.currentQueueId == 'a');
      expect(player.state.sleepTracksRemaining, 2);
      await player.selectQueueOccurrence('b');
      expect(player.state.sleepTracksRemaining, 2);

      const started =
          MediaEvent(state: MediaState.playing, type: MediaEventType.play);
      const completed = MediaEvent(state: MediaState.completed);
      player.setEvent(started);
      expect(player.automaticMusicSuccessor?.videoId, 'c');
      player.setEvent(completed);
      player.setEvent(completed);
      await until(() => player.state.currentQueueId == 'c');
      expect(player.state.sleepTracksRemaining, 1);

      player.setEvent(started);
      expect(player.automaticMusicSuccessor, isNull);
      player.setEvent(completed);
      expect(player.state.hasTimer, isFalse);
      expect(player.state.sleepTracksRemaining, isNull);
      expect(player.state.mediaCommand?.type, MediaCommandType.pause);
      expect(player.state.currentQueueId, 'c');
      expect(player.state.playQueue, ['d']);
      expect(handler.playbackState.value.playing, isFalse);
    });

    for (final repeat in [PlayerRepeat.repeatOne, PlayerRepeat.repeatAll]) {
      test(
          'track sleep counts finished playthroughs of the same song ($repeat)',
          () async {
        await settings.setRepeatMode(repeat);
        await open(['a']);
        player.sleepAfterTracks(2);

        const completed = MediaEvent(state: MediaState.completed);
        final original = player.state.mediaCommand;
        player.setEvent(completed);
        expect(player.state.sleepTracksRemaining, 1);
        await until(() => player.state.mediaCommand != original);
        expect(player.state.currentQueueId, 'a');
        expect(handler.playbackState.value.playing, isTrue);

        player.setEvent(const MediaEvent(state: MediaState.ready));
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        player.setEvent(completed);
        expect(player.state.sleepTracksRemaining, isNull);
        expect(player.state.hasTimer, isFalse);
        expect(player.state.mediaCommand?.type, MediaCommandType.pause);
        expect(handler.playbackState.value.playing, isFalse);
      });
    }

    test('track sleep ignores repeated EOF when autoplay is disabled',
        () async {
      await settings.setAutoplayQueue(false);
      await open(['a', 'b']);
      player.sleepAfterTracks(2);

      const completed = MediaEvent(state: MediaState.completed);
      player.setEvent(completed);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.miniDisplayChanged));
      player.setEvent(completed);
      expect(player.state.sleepTracksRemaining, 1);
      expect(player.state.currentQueueId, 'a');
      expect(player.state.playQueue, ['b']);
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
        await settings.setPreserveAlbumTransitions(true);
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

      test('album preservation bypasses the pause only for a matching release',
          () async {
        await settings.setSongTransitionMode(SongTransitionMode.pause);
        await settings.setSongTransitionSeconds(10);
        await settings.setPreserveAlbumTransitions(true);
        await open([
          'a',
          'b',
          'c'
        ], albumIds: {
          'a': 'OLAK5uy_a',
          'b': 'OLAK5uy_a',
          'c': 'OLAK5uy_b',
        });
        await until(() => readyIds().contains('b'));
        player.setEvent(const MediaEvent(state: MediaState.completed));
        await until(() => player.state.currentQueueId == 'b');
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        await until(() => readyIds().contains('c'));
        player.setEvent(const MediaEvent(state: MediaState.completed));
        expect(player.openingMusicEntry, isNull);
        expect(player.state.currentQueueId, 'b');
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
