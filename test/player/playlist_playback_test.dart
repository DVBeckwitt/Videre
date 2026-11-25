import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/models/song_transition.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter_bloc/flutter_bloc.dart' show Change;
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _MetadataService extends Service {
  final requests = <String>[];
  final musicRequests = <String>[];
  final playlistRequests = <int>[];
  final playlistPages = <int, Playlist>{};
  String? heldVideoId;
  Completer<Video>? heldMetadata;
  Completer<void>? heldRequested;

  @override
  Future<Playlist> getPublicPlaylists(String playlistId,
      {int? page,
      bool saveLastSeen = true,
      Server? serverOverride,
      bool enrichResults = true}) async {
    playlistRequests.add(page ?? 1);
    return playlistPages[page ?? 1]!;
  }

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    requests.add(videoId);
    return _metadata(videoId);
  }

  @override
  Future<Video> getMusicVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    musicRequests.add(videoId);
    return _metadata(videoId);
  }

  Future<Video> _metadata(String videoId) async {
    if (videoId == heldVideoId && heldMetadata != null) {
      heldRequested?.complete();
      return heldMetadata!.future;
    }
    return Video(
        videoId: videoId,
        lengthSeconds: 100,
        formatStreams: [],
        adaptiveFormats: []);
  }
}

class _MediaSessionPlayer extends PlayerCubit {
  _MediaSessionPlayer(super.initialState, super.settings);

  Completer<void>? completionStarted;
  Completer<void>? releaseCompletion;
  void Function(MediaCommand)? onNewCommand;

  @override
  Future<void> onReady() async {}

  @override
  void onChange(Change<PlayerState> change) {
    super.onChange(change);
    final command = change.nextState.mediaCommand;
    if (command != null &&
        !identical(command, change.currentState.mediaCommand)) {
      onNewCommand?.call(command);
    }
  }

  @override
  Future<void> saveProgress(int timeInSeconds) async {
    if (timeInSeconds == 100 && releaseCompletion != null) {
      if (!completionStarted!.isCompleted) completionStarted!.complete();
      await releaseCompletion!.future;
    }
    await super.saveProgress(timeInSeconds);
  }
}

class _Pages extends PlaylistLoadSession {
  final controller = StreamController<PlaylistLoadSnapshot>.broadcast();
  Playlist value;
  bool finished = false;
  int owners = 0;
  Object? failure;

  @override
  Object? get error => failure;

  _Pages(this.value, PlaylistReference reference)
      : super(playlist: value, database: db, reference: reference);

  @override
  Playlist get playlist => value;
  @override
  bool get complete => finished;
  @override
  bool get loading => !finished && failure == null;
  @override
  Stream<PlaylistLoadSnapshot> get changes => controller.stream;
  @override
  void retain() => owners++;
  @override
  void release() => owners--;

  @override
  Future<void> retry() async {
    if (failure != null) publish(value.videos);
  }

  void publish(List<Video> videos, {bool complete = false, Object? error}) {
    value = value.copyWith(videos: videos);
    finished = complete;
    failure = error;
    controller.add(PlaylistLoadSnapshot(value,
        loading: loading, complete: complete, error: error));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late PlayerCubit player;
  late _MetadataService metadata;
  late Service previousService;
  late PlaylistReference reference;
  const entries = [
    Video(videoId: 'a', index: 0, lengthSeconds: 100),
    Video(videoId: 'b', index: 1, lengthSeconds: 100),
    Video(videoId: 'a', index: 2, lengthSeconds: 100),
    Video(videoId: 'c', index: 3, lengthSeconds: 100),
  ];

  setUp(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    previousService = service;
    service = metadata = _MetadataService();
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
    app_main.mediaHandler = MediaHandler(player);
    reference = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLtest',
        profileId: db.profileId);
  });

  tearDown(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
  });

  test('a middle occurrence starts atomically with previous and next intact',
      () async {
    await player.playPlaylist(entries, reference: reference, startIndex: 1);
    final ids = player.state.videos.map(playbackQueueId).toList();
    expect(metadata.requests, ['b']);
    expect(player.state.currentQueueId, ids[1]);
    expect(player.state.playedVideos, [ids[0]]);
    expect(player.state.playQueue.toList(), [ids[2], ids[3]]);
    expect(ids.toSet(), hasLength(4));
    final checkpoint =
        PlaylistProgressService.forProfile(db, db.profileId).get(reference)!;
    expect(checkpoint.resolve(player.state.videos)!.index, 1);
  });

  test('a repeated upload selects its requested occurrence', () async {
    await player.playPlaylist(entries, reference: reference, startIndex: 2);
    expect(metadata.requests, ['a']);
    expect(player.currentIndex, 2);
    expect(player.state.playedVideos, hasLength(2));
    final checkpoint =
        PlaylistProgressService.forProfile(db, db.profileId).get(reference)!;
    expect(checkpoint.resolve(player.state.videos)!.index, 2);
    // Fresh stream metadata does not contain the playlist's source position.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.savedSession!.videos[2].index, 2);
  });

  test('explicit resume past the watched threshold keeps precise time',
      () async {
    await player.playPlaylist(entries,
        reference: reference,
        startIndex: 1,
        startAt: const Duration(seconds: 95));
    final progress = db.getVideoPlaybackProgress('b');
    expect(progress.progress, 1);
    expect(progress.positionSeconds, 95);
    expect(progress.durationSeconds, 100);
    expect(progress.resumePosition(), const Duration(seconds: 95));
    expect(player.state.position, const Duration(seconds: 95));
    expect((player.state.mediaCommand!.value as SwitchVideoValue).startAt,
        const Duration(seconds: 95));
    final checkpoint =
        PlaylistProgressService.forProfile(db, db.profileId).get(reference)!;
    expect(checkpoint.completed, isFalse);
    expect(checkpoint.resolve(player.state.videos)!.index, 1);
  });

  test('playlist resume retains audio mode after another video plays',
      () async {
    await player.playPlaylist(entries,
        reference: reference, startIndex: 1, audio: true);
    await player.saveProgress(4);
    player.pause();
    await player.playVideo([entries.last], audio: false);
    final checkpoint =
        PlaylistProgressService.forProfile(db, db.profileId).get(reference)!;
    expect(checkpoint.audio, isTrue);
    final target = checkpoint.resolve(entries)!;
    await player.playPlaylist(entries,
        reference: reference,
        startIndex: target.index,
        startAt:
            db.getVideoPlaybackProgress(target.video.videoId).resumePosition(),
        audio: checkpoint.audio);
    expect(player.state.isAudio, isTrue);
    expect(player.state.position, const Duration(seconds: 4));
  });

  for (final replaceWithPlaylist in [true, false]) {
    test(
        'pending ${replaceWithPlaylist ? 'playlist' : 'video'} replacement keeps a coherent saved session',
        () async {
      await player.playPlaylist(entries,
          reference: reference, startIndex: 1, audio: true);
      await player.onProgress(const Duration(seconds: 37));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      metadata.heldVideoId = 'replacement';
      metadata.heldMetadata = Completer<Video>();
      metadata.heldRequested = Completer<void>();
      final replacementReference = PlaylistReference(
          kind: PlaylistSourceKind.public,
          playlistId: 'PLreplacement',
          profileId: db.profileId);
      const replacement = [Video(videoId: 'replacement', index: 0)];
      final pending = replaceWithPlaylist
          ? player.playPlaylist(replacement,
              reference: replacementReference, audio: false)
          : player.playVideo(replacement, audio: false);
      await metadata.heldRequested!.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final saved = player.savedSession!;
      expect(saved.playlistReference, reference);
      expect(saved.currentId, playbackQueueId(player.state.currentlyPlaying!));
      expect(saved.videos.map((video) => video.videoId), ['a', 'b', 'a', 'c']);
      expect(saved.audio, isTrue);
      expect(saved.seconds, 37);

      metadata.heldMetadata!.complete(const Video(
          videoId: 'replacement',
          lengthSeconds: 100,
          formatStreams: [],
          adaptiveFormats: []));
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final replaced = player.savedSession!;
      expect(replaced.playlistReference,
          replaceWithPlaylist ? replacementReference : null);
      expect(replaced.videos.single.videoId, 'replacement');
      expect(replaced.currentId, playbackQueueId(replaced.videos.single));
      expect(replaced.audio, isFalse);
      expect(replaced.seconds, 0);
    });
  }

  test('stopping a pending replacement retains the previous coherent session',
      () async {
    await player.playPlaylist(entries,
        reference: reference, startIndex: 1, audio: true);
    await player.onProgress(const Duration(seconds: 37));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final before = player.savedSession!.encode();
    metadata.heldVideoId = 'replacement';
    metadata.heldMetadata = Completer<Video>();
    metadata.heldRequested = Completer<void>();
    final pending =
        player.playVideo([const Video(videoId: 'replacement')], audio: false);
    await metadata.heldRequested!.future.timeout(const Duration(seconds: 2));
    player.hide();
    metadata.heldMetadata!.complete(const Video(
        videoId: 'replacement',
        lengthSeconds: 100,
        formatStreams: [],
        adaptiveFormats: []));
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.savedSession!.encode(), before);
  });

  test(
      'progress during replacement does not write the incoming playlist cursor',
      () async {
    await player.playPlaylist(entries,
        reference: reference, startIndex: 1, audio: true);
    metadata.heldVideoId = 'b';
    metadata.heldMetadata = Completer<Video>();
    metadata.heldRequested = Completer<void>();
    final replacementReference = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLreplacement',
        profileId: db.profileId);
    final pending = player.playPlaylist(entries,
        reference: replacementReference, startIndex: 1, audio: false);
    await metadata.heldRequested!.future.timeout(const Duration(seconds: 2));
    await player.saveProgress(42);
    final checkpoints = PlaylistProgressService.forProfile(db, db.profileId);
    expect(checkpoints.get(replacementReference), isNull);
    expect(checkpoints.get(reference)!.audio, isTrue);
    metadata.heldMetadata!.complete(const Video(
        videoId: 'b',
        lengthSeconds: 100,
        formatStreams: [],
        adaptiveFormats: []));
    await pending;
    expect(checkpoints.get(replacementReference)!.audio, isFalse);
  });

  for (final version in [1, 2]) {
    test(
        'an ordinary version $version restored queue repeats after its last item',
        () async {
      final data = jsonDecode(PlaybackSession(
          videos: entries.take(2).toList(),
          currentId: 'b',
          seconds: 37,
          played: const ['a']).encode()) as Map<String, dynamic>;
      data['version'] = version;
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, jsonEncode(data)));
      await settings.setRepeatMode(PlayerRepeat.repeatAll);
      await player.resumeSession();
      expect(player.playlistReference, isNull);
      expect(player.playlistComplete, isTrue);
      final next = player.stream
          .firstWhere((state) => state.currentlyPlaying?.videoId == 'a');
      player.playNext();
      await next.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.state.playQueue.toList(), ['b']);
      expect(metadata.requests, ['b', 'a']);
    });
  }

  test('a paused mode toggle updates the playlist resume choice', () async {
    await player.playPlaylist(entries,
        reference: reference, startIndex: 1, audio: false);
    player.pause();
    final checkpoints = PlaylistProgressService.forProfile(db, db.profileId);
    expect(checkpoints.get(reference)!.audio, isFalse);
    final changed = Completer<void>();
    void updated() {
      if (checkpoints.get(reference)?.audio == true && !changed.isCompleted) {
        changed.complete();
      }
    }

    checkpoints.changes.addListener(updated);
    try {
      player.switchAudio(true);
      await changed.future.timeout(const Duration(seconds: 2));
    } finally {
      checkpoints.changes.removeListener(updated);
    }
    expect(checkpoints.get(reference)!.audio, isTrue);
  });

  test('late playback progress cannot recreate cleared playlist history',
      () async {
    await player.playPlaylist(entries, reference: reference, startIndex: 1);
    await player.saveProgress(40);
    final checkpoints = PlaylistProgressService.forProfile(db, db.profileId);
    expect(checkpoints.get(reference), isNotNull);
    await db.clearLocalHistory();
    await player.saveProgress(50);
    expect(checkpoints.get(reference), isNull);
    expect(db.getVideoPlaybackProgress('b').positionSeconds, isNull);
    await player.playPlaylist(entries, reference: reference, startIndex: 2);
    expect(checkpoints.get(reference)!.resolve(player.state.videos)!.index, 2);
  });

  test('filtering cannot shift the selected item to its neighbour', () async {
    final filtered = [entries[0].copyWith(filtered: true), ...entries.skip(1)];
    await player.playPlaylist(filtered, reference: reference, startIndex: 1);
    expect(metadata.requests, ['b']);
    expect(player.currentIndex, 0);
    await expectLater(
        player.playPlaylist(filtered, reference: reference, startIndex: 0),
        throwsStateError);
    expect(metadata.requests, ['b']);
  });

  test('an invalid index or another profile leaves the queue untouched',
      () async {
    await player.playVideo([entries[0]]);
    final before = player.state;
    await expectLater(
        player.playPlaylist(entries,
            reference: reference, startIndex: entries.length),
        throwsRangeError);
    await expectLater(
        player.playPlaylist(entries,
            reference: PlaylistReference(
                kind: PlaylistSourceKind.public,
                playlistId: 'PLtest',
                profileId: 'another')),
        throwsStateError);
    expect(player.state, before);
  });

  test('late pages cannot replace a newer playback request', () async {
    final ordered = assignPlaylistEntryIds(entries);
    await player.playPlaylist(ordered.take(2).toList(), reference: reference);
    final generation = player.playlistGeneration;
    await player.playVideo([entries.last]);
    expect(
        player.appendPlaylistVideos(ordered,
            reference: reference, generation: generation),
        isFalse);
    expect(player.state.videos.map((video) => video.videoId), ['c']);
    expect(player.playlistReference, isNull);
  });

  test('page retries preserve manual edits and never restore removed entries',
      () async {
    final ordered = assignPlaylistEntryIds(entries);
    await player.playPlaylist(ordered.take(3).toList(), reference: reference);
    final removedId = playbackQueueId(player.state.videos[1]);
    player.removeVideoFromQueue(removedId);
    player.queueVideos([const Video(videoId: 'manual')]);
    final previousQueue = player.state.playQueue.toList();
    expect(
        player.appendPlaylistVideos(ordered,
            reference: reference, generation: player.playlistGeneration),
        isTrue);
    expect(
        player.state.videos.any((video) => playbackQueueId(video) == removedId),
        isFalse);
    expect(player.state.playQueue.toList(),
        [...previousQueue, playbackQueueId(ordered.last)]);
    expect(
        player.appendPlaylistVideos(ordered,
            reference: reference, generation: player.playlistGeneration),
        isTrue);
    expect(player.state.playQueue.toList(),
        [...previousQueue, playbackQueueId(ordered.last)]);
  });

  test('restored paging preserves removals and manually queued entries',
      () async {
    final ordered = assignPlaylistEntryIds(entries);
    final pages = _Pages(
        Playlist(
            title: 'Test',
            playlistId: reference.playlistId,
            author: '',
            videoCount: 4,
            videos: ordered.take(2).toList()),
        reference);
    addTearDown(pages.controller.close);
    await player.playPlaylist(ordered.take(2).toList(),
        reference: reference, playlistLoader: pages);
    player.removeVideoFromQueue(playbackQueueId(ordered[1]));
    player.queueVideos([const Video(videoId: 'manual')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.savedSession!.playlistEntries.map(playbackQueueId),
        ordered.take(2).map(playbackQueueId));
    metadata.playlistPages[1] = Playlist(
        title: 'Test',
        playlistId: reference.playlistId,
        author: '',
        videoCount: 4,
        videos: ordered.take(2).toList());
    metadata.playlistPages[2] =
        metadata.playlistPages[1]!.copyWith(videos: ordered.skip(2).toList());
    player.restoreSession();
    expect(player.playlistReference, reference);
    expect(player.state.hasVideo, isFalse);
    expect(metadata.playlistRequests, isEmpty);
    await player.resumeSession();
    if (!player.playlistComplete) {
      final complete = Completer<void>();
      void changed() {
        if (player.playlistComplete && !complete.isCompleted) {
          complete.complete();
        }
      }

      player.playlistLoadingRevision.addListener(changed);
      try {
        await complete.future.timeout(const Duration(seconds: 2));
      } finally {
        player.playlistLoadingRevision.removeListener(changed);
      }
    }
    expect(metadata.playlistRequests, [1, 2]);
    expect(player.state.videos.map((video) => video.videoId),
        ['a', 'manual', 'a', 'c']);
    expect(player.state.playQueue.toList(),
        ['manual', playbackQueueId(ordered[2]), playbackQueueId(ordered[3])]);
  });

  test('restoring an edited public source does not duplicate shifted indices',
      () async {
    final pages = _Pages(
        Playlist(
            title: 'Test',
            playlistId: reference.playlistId,
            author: '',
            videoCount: 5,
            videos: entries),
        reference);
    addTearDown(pages.controller.close);
    await player.playPlaylist(entries,
        reference: reference, playlistLoader: pages);
    player.removeVideoFromQueue(playbackQueueId(player.state.videos[1]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final changed = assignPlaylistEntryIds(const [
      Video(videoId: 'c', index: 0),
      Video(videoId: 'a', index: 1),
      Video(videoId: 'new', index: 2),
      Video(videoId: 'a', index: 3),
      Video(videoId: 'b', index: 4),
    ]);
    metadata.playlistPages[1] = Playlist(
        title: 'Changed',
        playlistId: reference.playlistId,
        author: '',
        videoCount: 5,
        videos: changed);
    player.restoreSession();
    final appended = player.stream.firstWhere(
        (state) => state.videos.any((video) => video.videoId == 'new'));
    await player.resumeSession();
    await appended.timeout(const Duration(seconds: 2));
    expect(player.state.videos.map((video) => video.videoId),
        ['a', 'a', 'c', 'new']);
    expect(player.state.playQueue, hasLength(3));
  });

  test('a complete restored source keeps its snapshot without refetching pages',
      () async {
    await player.playPlaylist(entries, reference: reference, startIndex: 2);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.savedSession!.playlistComplete, isTrue);
    player.restoreSession();
    await player.resumeSession();
    expect(player.playlistReference, reference);
    expect(player.playlistComplete, isTrue);
    expect(player.currentIndex, 2);
    expect(metadata.playlistRequests, isEmpty);
  });

  test('manually queued videos do not replace the source playlist cursor',
      () async {
    await player.playPlaylist(entries, reference: reference, startIndex: 1);
    player.queueVideos([const Video(videoId: 'manual')]);
    await player.skipToVideo(player.state.videos.length - 1);
    await player.saveProgress(42);
    final checkpoint =
        PlaylistProgressService.forProfile(db, db.profileId).get(reference)!;
    expect(checkpoint.videoId, 'b');
    expect(checkpoint.resolve(player.state.videos)!.index, 1);
  });

  test('manual queue order and Play Next preserve source occurrence progress',
      () async {
    final ordered = assignPlaylistEntryIds(entries);
    await player.playPlaylist(ordered, reference: reference, startIndex: 2);
    player.onQueueReorder(2, 0);
    await player.skipToVideo(0);
    await player.saveProgress(30);
    final checkpoints = PlaylistProgressService.forProfile(db, db.profileId);
    expect(checkpoints.get(reference)!.occurrence, 1);
    expect(checkpoints.get(reference)!.resolve(ordered)!.index, 2);
    player.playVideoNext(const Video(videoId: 'manual-next'));
    final next = player.stream.firstWhere(
        (state) => state.currentlyPlaying?.videoId == 'manual-next');
    player.playNext();
    await next.timeout(const Duration(seconds: 2));
    await player.saveProgress(42);
    expect(checkpoints.get(reference)!.occurrence, 1);
    expect(checkpoints.get(reference)!.resolve(ordered)!.index, 2);
  });

  test('Previous keeps pages that arrive while metadata is loading', () async {
    final ordered =
        assignPlaylistEntryIds([entries[0], entries[1], entries[3]]);
    await player.playPlaylist(ordered.take(2).toList(),
        reference: reference, startIndex: 1);
    metadata.heldVideoId = 'a';
    metadata.heldMetadata = Completer<Video>();
    metadata.heldRequested = Completer<void>();
    player.playPrevious();
    await metadata.heldRequested!.future.timeout(const Duration(seconds: 2));
    player.appendPlaylistVideos(ordered,
        reference: reference, generation: player.playlistGeneration);
    final previous = player.stream
        .firstWhere((state) => state.currentlyPlaying?.videoId == 'a');
    metadata.heldMetadata!.complete(const Video(
        videoId: 'a',
        lengthSeconds: 100,
        formatStreams: [],
        adaptiveFormats: []));
    await previous.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
        player.state.playQueue.toList(), ordered.skip(1).map(playbackQueueId));
  });

  test('native completion saves the source before advancing to a manual item',
      () async {
    await player.playPlaylist(entries, reference: reference, startIndex: 1);
    player.playVideoNext(const Video(videoId: 'manual-next'));
    final next = player.stream.firstWhere(
        (state) => state.currentlyPlaying?.videoId == 'manual-next');
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await next.timeout(const Duration(seconds: 2));
    final checkpoint =
        PlaylistProgressService.forProfile(db, db.profileId).get(reference)!;
    expect(checkpoint.videoId, 'b');
    expect(checkpoint.completed, isTrue);
    expect(checkpoint.resolve(entries)!.index, 2);
    expect(db.getVideoPlaybackProgress('b').positionSeconds, 100);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('pending completion cannot advance a newer playback request', () async {
    await player.playPlaylist(entries, reference: reference, startIndex: 1);
    player.playVideoNext(const Video(videoId: 'manual-next'));
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await player.playVideo([const Video(videoId: 'replacement')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.state.currentlyPlaying?.videoId, 'replacement');
    expect(metadata.requests, ['b', 'replacement']);
  });

  test('profile switching releases the loader and refuses late pages',
      () async {
    final ordered = assignPlaylistEntryIds(entries);
    final pages = _Pages(
        Playlist(
            title: 'Test',
            playlistId: reference.playlistId,
            author: '',
            videoCount: 4,
            videos: ordered.take(1).toList()),
        reference);
    addTearDown(pages.controller.close);
    await player.playPlaylist(pages.videos,
        reference: reference, playlistLoader: pages);
    final generation = player.playlistGeneration;
    await player.prepareForProfileSwitch();
    expect(pages.owners, 0);
    pages.publish(ordered, complete: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.state.videos, isEmpty);
    expect(player.playlistReference, isNull);
    expect(
        player.appendPlaylistVideos(ordered,
            reference: reference, generation: generation),
        isFalse);
  });

  test('Music keeps foreground playback across both mixed queue boundaries',
      () async {
    await settings.setSongTransitionMode(SongTransitionMode.pause);
    await settings.setSongTransitionSeconds(5);
    await player.close();
    player = _MediaSessionPlayer(PlayerState.init(null), settings);
    player.audioSession = await AudioSession.instance;
    final handler = app_main.mediaHandler = MediaHandler(player);
    const song = Video(
        videoId: 'song',
        lengthSeconds: 100,
        adaptiveFormats: [],
        formatStreams: [],
        musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
    const untagged = Video(
        videoId: 'manual', queueEntryId: 'ordinary-copy', lengthSeconds: 100);
    const last = Video(
        videoId: 'last',
        queueEntryId: 'music-copy',
        lengthSeconds: 100,
        musicMetadata: MusicMetadata(title: 'Last', artist: 'Artist'));
    await player.playVideo([song], audio: true, fromMusic: true);
    player.queueVideos([untagged, last]);
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    expect(handler.playbackState.value.playing, isTrue);
    expect(player.state.playQueue, ['ordinary-copy', 'music-copy']);

    for (final target in [untagged, last]) {
      final targetId = playbackQueueId(target);
      expect(player.automaticMusicSuccessor, isNull);
      if (target == last) {
        // An earlier ordinary skip must not suppress automatic EOF traversal.
        EasyThrottle.throttle(
            skipToVideoThrottleName, const Duration(seconds: 5), () {});
      }
      metadata.heldVideoId = target.videoId;
      metadata.heldMetadata = Completer<Video>();
      metadata.heldRequested = Completer<void>();
      final next =
          player.stream.firstWhere((s) => s.currentQueueId == targetId);
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await metadata.heldRequested!.future.timeout(const Duration(seconds: 2));
      final duringLoad = handler.playbackState.value;
      final fadesIn = player.isAutomaticMusicHandoffTo(targetId);
      metadata.heldMetadata!
          .complete(target.copyWith(adaptiveFormats: [], formatStreams: []));
      await next.timeout(const Duration(seconds: 2));

      expect(player.state.isAudio, isTrue);
      expect(fadesIn, isFalse);
      expect(player.isAutomaticMusicHandoffTo(targetId), isFalse);
      expect(duringLoad.processingState, AudioProcessingState.buffering,
          reason: 'While loading ${target.videoId}');
      expect(duringLoad.playing, isTrue,
          reason: 'While loading ${target.videoId}');
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.ready);
      expect(handler.playbackState.value.playing, isTrue);
    }
    expect(metadata.requests, ['manual']);
    expect(metadata.musicRequests, ['last']);
    expect(player.state.playedVideos, ['song', 'ordinary-copy']);
    expect(player.state.playQueue, isEmpty);
  });

  group('Music repeat at EOF across a temporary focus loss', () {
    final loss = AudioInterruptionEvent(true, AudioInterruptionType.pause);
    final gain = AudioInterruptionEvent(false, AudioInterruptionType.pause);
    const completed = MediaEvent(state: MediaState.completed);
    const paused =
        MediaEvent(state: MediaState.ready, type: MediaEventType.pause);
    late _MediaSessionPlayer session;
    late MediaHandler handler;
    late List<MediaCommand> commands;
    void Function(MediaCommand)? onNewCommand;
    late String occurrence;

    setUp(() async {
      await player.close();
      player = session = _MediaSessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = handler = MediaHandler(player);
      await player.playPlaylist([
        entries.first.copyWith(
            musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
            adaptiveFormats: const [],
            formatStreams: const []),
      ],
          reference: reference,
          audio: true,
          fromMusic: true,
          startAt: const Duration(seconds: 20));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      occurrence = player.state.currentQueueId!;
      commands = [];
      onNewCommand = null;
      session.onNewCommand = (command) {
        commands.add(command);
        onNewCommand?.call(command);
      };
    });

    Future<void> interruptAtEnd({required bool beforeEnd}) async {
      session.completionStarted = Completer<void>();
      final release = session.releaseCompletion = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      if (beforeEnd) {
        player.handleAudioInterruption(loss);
        player.setEvent(paused);
      }
      player.setEvent(completed);
      await session.completionStarted!.future
          .timeout(const Duration(seconds: 2));
      if (!beforeEnd) {
        player.handleAudioInterruption(loss);
        player.setEvent(paused);
      }
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(player.state.currentQueueId, occurrence);
      expect(player.state.position, const Duration(seconds: 20));
      expect(commands, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
    }

    for (final repeat in [PlayerRepeat.repeatOne, PlayerRepeat.repeatAll]) {
      for (final beforeEnd in [true, false]) {
        test('$repeat recovers once (focus loss before EOF=$beforeEnd)',
            () async {
          await settings.setRepeatMode(repeat);
          await interruptAtEnd(beforeEnd: beforeEnd);
          final replayType = repeat == PlayerRepeat.repeatOne
              ? MediaCommandType.play
              : MediaCommandType.switchVideo;
          final generation = player.backendPlaybackGeneration;
          final replay = Completer<void>();
          // Queue state emissions can carry the initial switch command while
          // the new source loads. Wait for the recorder to see a new command.
          onNewCommand = (command) {
            if (command.type == replayType && !replay.isCompleted) {
              replay.complete();
            }
          };
          player.handleAudioInterruption(gain);
          player.handleAudioInterruption(gain);
          await replay.future.timeout(const Duration(seconds: 2));

          expect(player.state.currentQueueId, occurrence);
          expect(player.state.playQueue, isEmpty);
          expect(player.state.playedVideos, isEmpty);
          final types = commands.map((command) => command.type);
          if (repeat == PlayerRepeat.repeatOne) {
            expect(types, [MediaCommandType.seek, MediaCommandType.play]);
            expect(player.state.position, Duration.zero);
            expect(player.backendPlaybackGeneration, generation);
          } else {
            expect(types, [MediaCommandType.switchVideo]);
            expect(player.backendPlaybackGeneration, generation + 1);
            final switching = commands.single.value as SwitchVideoValue;
            expect(switching.startAt, Duration.zero);
            expect(playbackQueueId(switching.video), occurrence);
          }
        });
      }

      for (final change in [
        'Pause',
        'Stop',
        'permanent focus loss',
        'repeat disabled',
        'autoplay disabled',
        'paused replacement',
      ]) {
        test('$repeat stays stopped on focus gain after $change', () async {
          await settings.setRepeatMode(repeat);
          await interruptAtEnd(beforeEnd: true);
          switch (change) {
            case 'Pause':
              await handler.pause();
            case 'Stop':
              await handler.stop();
            case 'permanent focus loss':
              player.handleAudioInterruption(
                  AudioInterruptionEvent(true, AudioInterruptionType.unknown));
            case 'repeat disabled':
              await settings.setRepeatMode(PlayerRepeat.noRepeat);
            case 'autoplay disabled':
              await settings.setAutoplayQueue(false);
            case 'paused replacement':
              await player.playVideo([
                const Video(
                    videoId: 'replacement',
                    lengthSeconds: 100,
                    adaptiveFormats: [],
                    formatStreams: [],
                    musicMetadata:
                        MusicMetadata(title: 'Replacement', artist: 'Artist')),
              ], audio: true, playing: false, fromMusic: true);
          }
          await Future<void>.delayed(Duration.zero);
          commands.clear();
          final current = player.state.currentQueueId;
          final position = player.state.position;

          player.handleAudioInterruption(gain);
          await Future<void>.delayed(Duration.zero);
          expect(commands, isEmpty);
          expect(player.state.currentQueueId, current);
          expect(player.state.position, position);
          expect(player.state.isPlaying, isFalse);
          expect(handler.playbackState.value.playing, isFalse);
        });
      }
    }
  });

  group('temporary audio focus at Music EOF', () {
    setUp(() async {
      await settings.setSongTransitionMode(SongTransitionMode.pause);
      await settings.setSongTransitionSeconds(1);
      final songs = [
        for (final id in ['a', 'b', 'c'])
          Video(
              videoId: id,
              lengthSeconds: 100,
              adaptiveFormats: const [],
              formatStreams: const [],
              musicMetadata: MusicMetadata(title: id, artist: 'Artist')),
      ];
      await player.playVideo(songs, audio: true, fromMusic: true);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
    });

    for (final focusBeforeEnd in [true, false]) {
      test(
          'resumes the next occurrence once (focus before EOF=$focusBeforeEnd)',
          () async {
        final loss = AudioInterruptionEvent(true, AudioInterruptionType.pause);
        if (focusBeforeEnd) player.handleAudioInterruption(loss);
        player.setEvent(const MediaEvent(state: MediaState.completed));
        if (!focusBeforeEnd) player.handleAudioInterruption(loss);
        await Future<void>.delayed(const Duration(milliseconds: 1050));
        expect(player.state.currentQueueId, 'a');
        expect(player.state.playQueue, ['b', 'c']);
        expect(player.state.playedVideos, isEmpty);

        final next = player.stream.firstWhere((s) => s.currentQueueId == 'b');
        player.handleAudioInterruption(
            AudioInterruptionEvent(false, AudioInterruptionType.pause));
        await next.timeout(const Duration(seconds: 3));
        expect(player.state.playedVideos, ['a']);
        expect(player.state.playQueue, ['c']);
      });
    }

    test('an explicit pause cancels the pending advance on focus gain',
        () async {
      player.setEvent(const MediaEvent(state: MediaState.completed));
      player.handleAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause));
      player.pause();
      player.handleAudioInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 1050));
      expect(player.requestedPlaying, isFalse);
      expect(player.state.currentQueueId, 'a');
      expect(player.state.playedVideos, isEmpty);
      expect(player.state.playQueue, ['b', 'c']);
    });
  });

  for (final latePage in [false, true]) {
    test(
        'time awaiting a new Music page counts towards its gap (late=$latePage)',
        () async {
      await settings.setSongTransitionMode(SongTransitionMode.pause);
      await settings.setSongTransitionSeconds(1);
      final ordered = assignPlaylistEntryIds(entries
          .take(2)
          .map((video) => video.copyWith(
              adaptiveFormats: const [],
              formatStreams: const [],
              musicMetadata:
                  MusicMetadata(title: video.videoId, artist: 'Artist')))
          .toList());
      final pages = _Pages(
          Playlist(
              title: 'Test',
              playlistId: reference.playlistId,
              author: '',
              videoCount: ordered.length,
              videos: [ordered.first]),
          reference);
      addTearDown(pages.controller.close);
      await player.playPlaylist(pages.videos,
          reference: reference, playlistLoader: pages, audio: true);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      final waiting = Completer<void>();
      void waitingForPage() {
        if (!waiting.isCompleted) waiting.complete();
      }

      player.playlistLoadingRevision.addListener(waitingForPage);
      final elapsed = Stopwatch()..start();
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await waiting.future.timeout(const Duration(seconds: 3));
      player.playlistLoadingRevision.removeListener(waitingForPage);
      if (latePage) {
        await Future<void>.delayed(const Duration(milliseconds: 1050));
      }
      expect(player.state.currentlyPlaying?.videoId, 'a');
      final next =
          player.stream.firstWhere((s) => s.currentlyPlaying?.videoId == 'b');
      pages.publish(ordered, complete: true);
      await Future<void>.delayed(Duration.zero);
      final target = player.openingMusicEntry ?? player.state.currentlyPlaying;
      expect(target?.videoId, latePage ? 'b' : 'a');
      await next.timeout(const Duration(seconds: 3));
      expect(elapsed.elapsedMilliseconds, greaterThanOrEqualTo(990));
    });
  }

  group('Music waiting for a playlist page', () {
    late List<Video> songs;
    late _Pages pages;
    late MediaHandler handler;

    setUp(() async {
      await player.close();
      player = _MediaSessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = handler = MediaHandler(player);
      songs = assignPlaylistEntryIds([
        for (final song in entries.take(2))
          song.copyWith(
              adaptiveFormats: const [],
              formatStreams: const [],
              musicMetadata: MusicMetadata(title: song.videoId, artist: 'Band'))
      ]);
      pages = _Pages(
          Playlist(
              title: 'Waiting',
              playlistId: reference.playlistId,
              author: '',
              videoCount: 2,
              videos: [songs.first]),
          reference);
      addTearDown(pages.controller.close);
      await player.playPlaylist(pages.videos,
          audio: true, reference: reference, playlistLoader: pages);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      final waiting = Completer<void>();
      void changed() {
        if (!waiting.isCompleted) waiting.complete();
      }

      player.playlistLoadingRevision.addListener(changed);
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await waiting.future.timeout(const Duration(seconds: 2));
      player.playlistLoadingRevision.removeListener(changed);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.buffering);
    });

    for (final change in ['autoplay off', 'repeat one', 'focus loss']) {
      test('changing $change ends the active page wait immediately', () async {
        switch (change) {
          case 'autoplay off':
            await settings.setAutoplayQueue(false);
          case 'repeat one':
            await settings.setRepeatMode(PlayerRepeat.repeatOne);
          case 'focus loss':
            player.handleAudioInterruption(
                AudioInterruptionEvent(true, AudioInterruptionType.unknown));
        }
        await Future<void>.delayed(Duration.zero);
        final session = handler.playbackState.value;
        expect(
            session.playing &&
                session.processingState == AudioProcessingState.buffering,
            isFalse,
            reason: 'No page should hold the service after $change');
        pages.publish(songs, complete: true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(player.state.currentQueueId, playbackQueueId(songs.first));
      });
    }

    for (final change in ['none', 'autoplay off', 'focus loss']) {
      test('page failure releases the service and retry honors $change',
          () async {
        final stopped =
            handler.playbackState.firstWhere((state) => !state.playing);
        pages.publish([songs.first], error: StateError('Page unavailable'));
        await stopped.timeout(const Duration(seconds: 2));
        if (change == 'autoplay off') await settings.setAutoplayQueue(false);
        if (change == 'focus loss') {
          player.handleAudioInterruption(
              AudioInterruptionEvent(true, AudioInterruptionType.unknown));
        }
        player.retryPlaylistLoading();
        expect(pages.loading, isTrue);
        pages.publish(songs, complete: true);
        if (change == 'none') {
          await player.stream
              .firstWhere((state) =>
                  state.currentQueueId == playbackQueueId(songs.last))
              .timeout(const Duration(seconds: 2));
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(player.state.currentQueueId, playbackQueueId(songs.first));
          expect(player.state.playQueue, [playbackQueueId(songs.last)]);
          expect(handler.playbackState.value.playing, isFalse);
        }
      });
    }

    test('explicit Next after a page failure can advance with autoplay off',
        () async {
      final stopped =
          handler.playbackState.firstWhere((state) => !state.playing);
      pages.publish([songs.first], error: StateError('Page unavailable'));
      await stopped.timeout(const Duration(seconds: 2));
      await settings.setAutoplayQueue(false);
      await handler.skipToNext();
      player.retryPlaylistLoading();
      final next = player.stream.firstWhere(
          (state) => state.currentQueueId == playbackQueueId(songs.last));
      pages.publish(songs, complete: true);
      await next.timeout(const Duration(seconds: 2));
      expect(player.state.playedVideos, [playbackQueueId(songs.first)]);
    });
  });

  test('a page boundary waits for metadata then continues with the next entry',
      () async {
    final ordered = assignPlaylistEntryIds(entries.take(2));
    final pages = _Pages(
        Playlist(
            title: 'Test',
            playlistId: 'PLtest',
            author: '',
            videoCount: 2,
            videos: ordered.take(1).toList()),
        reference);
    addTearDown(pages.controller.close);
    await player.playPlaylist(pages.videos,
        reference: reference, playlistLoader: pages);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.state.currentlyPlaying?.videoId, 'a');
    expect(player.state.playedVideos, isEmpty);
    final next = player.stream
        .firstWhere((state) => state.currentlyPlaying?.videoId == 'b');
    pages.publish(ordered, complete: true);
    await next.timeout(const Duration(seconds: 2));
    expect(metadata.requests, ['a', 'b']);
    expect(player.state.playedVideos, [playbackQueueId(ordered.first)]);
    // Let the successful switch finish its guarded persistence writes.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('pause cancels an automatic wait at a page boundary', () async {
    final ordered = assignPlaylistEntryIds(entries.take(2));
    final pages = _Pages(
        Playlist(
            title: 'Test',
            playlistId: 'PLtest',
            author: '',
            videoCount: 2,
            videos: ordered.take(1).toList()),
        reference);
    addTearDown(pages.controller.close);
    await player.playPlaylist(pages.videos,
        reference: reference, playlistLoader: pages);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    player.pause();
    pages.publish(ordered, complete: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.state.currentlyPlaying?.videoId, 'a');
    expect(metadata.requests, ['a']);
    expect(player.state.playQueue.toList(), [playbackQueueId(ordered.last)]);
  });

  test('the same loader can serve another selection without losing ownership',
      () async {
    final ordered = assignPlaylistEntryIds(entries);
    final pages = _Pages(
        Playlist(
            title: 'Test',
            playlistId: 'PLtest',
            author: '',
            videoCount: 4,
            videos: ordered),
        reference);
    addTearDown(pages.controller.close);
    await player.playPlaylist(ordered,
        reference: reference, playlistLoader: pages);
    await player.playPlaylist(ordered,
        reference: reference, startIndex: 2, playlistLoader: pages);
    expect(pages.owners, 1);
    await player.playVideo([entries.last]);
    expect(pages.owners, 0);
  });

  test('versioned sessions keep playlist context and read legacy data', () {
    final session = PlaybackSession(
        videos: entries,
        currentId: 'b',
        seconds: 94,
        playlistReference: reference,
        playlistComplete: true);
    final encoded = jsonDecode(session.encode()) as Map<String, dynamic>;
    expect(encoded['version'], 2);
    final restored = PlaybackSession.decode(session.encode())!;
    expect(restored.playlistReference, reference);
    expect(restored.playlistComplete, isTrue);
    expect(restored.videos[1].index, 1);
    final legacy = {...encoded, 'version': 1}
      ..remove('playlistReference')
      ..remove('playlistComplete');
    expect(PlaybackSession.decode(jsonEncode(legacy))!.seconds, 94);
    expect(
        PlaybackSession.decode(jsonEncode(legacy))!.playlistReference, isNull);
    expect(
        PlaybackSession.decode(jsonEncode(legacy))!.playlistComplete, isFalse);
  });
}
