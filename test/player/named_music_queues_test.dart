import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/named_music_queue.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/recommendations/music_playlist_recommendation_exclusions.dart';
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
import 'package:sembast/sembast.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _music = MusicMetadata(title: 'Song', artist: 'Artist');

Video _song(String id) => Video(
      videoId: id,
      lengthSeconds: 120,
      musicMetadata: _music,
      formatStreams: const [],
      adaptiveFormats: const [],
    );

class _MusicService extends Service {
  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];

  @override
  Future<Video> getMusicVideo(String videoId,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest,
          VideoLoadObserver? loadObserver}) async =>
      _song(videoId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late List<TestPlayerCubit> players;

  Future<TestPlayerCubit> createPlayer() async {
    final player = TestPlayerCubit(PlayerState.init(null), settings);
    players.add(player);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    return player;
  }

  setUp(() async {
    db = database = await SembastSqfDb.createInMemory();
    service = _MusicService();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    players = [];
  });

  tearDown(() async {
    for (final player in players) {
      if (!player.isClosed) await player.close();
    }
    await settings.close();
    await app.close();
    await database.close();
  });

  test('switch and restart keep the duplicate, playhead, order and source',
      () async {
    var player = await createPlayer();
    const source = PlaylistReference(
      kind: PlaylistSourceKind.public,
      playlistId: 'PLoriginal',
      profileId: 'default',
      displayTitle: 'Original playlist',
    );
    await player.playPlaylist(
      [_song('repeat'), _song('repeat'), _song('third'), _song('fourth')],
      reference: source,
      fromMusic: true,
      startIndex: 1,
    );
    final occurrences = player.state.videos.map(playbackQueueId).toList();
    final sourceKey = musicPlaylistRecommendationKey(source);
    final recommendationSources = {
      for (final id in occurrences) id: sourceKey,
    };
    expect(occurrences[0], isNot(occurrences[1]));
    player.moveQueueOccurrence(occurrences[3], beforeId: occurrences[2]);
    final sourceOrder = player.state.videos.map(playbackQueueId).toList();
    final upcoming = [occurrences[3], occurrences[2]];
    const firstPosition = Duration(milliseconds: 23125);
    player.seek(firstPosition);
    expect(player.canSaveNamedMusicQueue, isTrue);
    final first = (await player.saveNamedMusicQueue('Evening'))!;
    expect(first.snapshot.currentId, occurrences[1]);
    expect(first.snapshot.position, firstPosition);
    expect(first.snapshot.playlistReference, source);
    expect(first.snapshot.musicRecommendationSources, recommendationSources);
    expect(player.activeNamedMusicQueueId, first.id);

    // This edit occurs within the current periodic checkpoint interval.
    const lastPosition = Duration(milliseconds: 23875);
    player.seek(lastPosition);
    await player.playVideo([_song('another')], fromMusic: true);
    final second = (await player.saveNamedMusicQueue('Morning'))!;
    expect(second.snapshot.musicRecommendationSources, isEmpty);
    expect(second.id, isNot(first.id));
    expect(player.activeNamedMusicQueueId, second.id);

    Future<void> checkResume() async {
      expect(await player.resumeNamedMusicQueue(first.id),
          NamedMusicQueueResumeResult.restored);
      expect(player.activeNamedMusicQueueId, first.id);
      expect(player.state.currentQueueId, occurrences[1]);
      expect(player.state.currentlyPlaying?.videoId, 'repeat');
      expect(player.state.position, lastPosition);
      expect(player.state.startAt, lastPosition);
      expect(player.state.videos.map(playbackQueueId), sourceOrder);
      expect(player.state.playedVideos, [occurrences[0]]);
      expect(player.state.playQueue, upcoming);
      expect(player.playlistReference, source);
      expect(
          player.captureMusicPlaybackCheckpoint()?.musicRecommendationSources,
          recommendationSources);
    }

    await checkResume();
    await player.close();
    player = await createPlayer();
    await player.reloadForProfile();
    expect(player.state.isHidden, isTrue);
    expect(player.state.hasVideo, isFalse);
    expect(player.activeNamedMusicQueueId, first.id);
    expect(player.namedMusicQueues.map((queue) => queue.name),
        unorderedEquals(['Evening', 'Morning']));
    await checkResume();
  });

  test('a missing current download leaves the other named queue active',
      () async {
    final player = await createPlayer();
    const download = DownloadedVideo(
      videoId: 'saved',
      title: 'Saved track',
      lengthSeconds: 120,
      quality: 'audio',
      musicMetadata: _music,
      audioOnly: true,
      downloadComplete: true,
    );
    final next = download.copyWith(videoId: 'still-available');
    for (final file in [download, next]) {
      await database.upsertDownload(file);
    }
    await player.playOfflineVideos([download, next], fromMusic: true);
    final offline = (await player.saveNamedMusicQueue('Offline'))!;
    await player.playVideo([_song('playing')], fromMusic: true);
    final active = (await player.saveNamedMusicQueue('Playing'))!;
    const position = Duration(milliseconds: 15300);
    player.seek(position);
    final command = player.state.mediaCommand;
    await database.deleteDownload(download);

    expect(await player.resumeNamedMusicQueue(offline.id),
        NamedMusicQueueResumeResult.unavailable);
    expect(player.activeNamedMusicQueueId, active.id);
    expect(player.state.currentQueueId, 'playing');
    expect(player.state.position, position);
    expect(player.state.mediaCommand, same(command));
    expect(player.namedMusicQueues.map((queue) => queue.id),
        unorderedEquals([offline.id, active.id]));

    await database
        .upsertDownload(download.copyWith(quality: 'other-rendition'));
    expect(await player.resumeNamedMusicQueue(offline.id),
        NamedMusicQueueResumeResult.unavailable);
    expect(player.state.currentQueueId, 'playing');

    await database.upsertDownload(download);
    await database.deleteDownload(next);
    expect(await player.resumeNamedMusicQueue(offline.id),
        NamedMusicQueueResumeResult.restored);
    expect(player.state.currentQueueId, download.videoId);
    expect(player.state.playQueue, isEmpty);
  });

  test('named queue IDs and active selection are scoped to the profile',
      () async {
    final player = await createPlayer();
    final other = await database.createProfile('Second listener');
    await player.playVideo([_song('only-default')], fromMusic: true);
    final personal = (await player.saveNamedMusicQueue('Favorites'))!;

    await player.prepareForProfileSwitch();
    await database.useProfile(other.id);
    await player.reloadForProfile();
    expect(player.namedMusicQueues, isEmpty);
    expect(player.activeNamedMusicQueueId, isNull);
    expect(await player.resumeNamedMusicQueue(personal.id),
        NamedMusicQueueResumeResult.unavailable);

    await player.playVideo([_song('only-second')], fromMusic: true);
    final theirs = (await player.saveNamedMusicQueue('Favorites'))!;
    expect(theirs.id, isNot(personal.id));
    await player.prepareForProfileSwitch();
    await database.useProfile('default');
    await player.reloadForProfile();
    expect(player.namedMusicQueues.single.id, personal.id);
    expect(player.activeNamedMusicQueueId, personal.id);
    expect(player.state.hasVideo, isFalse);
    expect(await player.resumeNamedMusicQueue(theirs.id),
        NamedMusicQueueResumeResult.unavailable);
  });

  test('a legacy Music session is copied once and continues to restore',
      () async {
    final oldSnapshot = PlaybackSession(
      videos: [_song('old-song'), _song('next-song')],
      currentId: 'old-song',
      seconds: 19,
      next: ['next-song'],
      audio: true,
    );
    final legacy = jsonDecode(oldSnapshot.encode()) as Map<String, dynamic>;
    legacy['version'] = 1;
    legacy.remove('musicHistoryEntries');
    final encoded = jsonEncode(legacy);
    await database.saveSetting(SettingsValue(playbackSessionSetting, encoded));
    final player = await createPlayer();
    await player.reloadForProfile();
    await database.settingsStore
        .record(namedMusicQueuesSetting)
        .onSnapshot(database.db)
        .firstWhere((record) => record != null)
        .timeout(const Duration(seconds: 5));

    final migrated = player.namedMusicQueues.single;
    expect(migrated.usesDefaultName, isTrue);
    expect(migrated.snapshot.currentId, 'old-song');
    expect(migrated.snapshot.position, const Duration(seconds: 19));
    expect(migrated.snapshot.next, ['next-song']);
    expect(player.state.startAt, const Duration(seconds: 19));
    expect(player.state.hasVideo, isFalse);
    expect(database.getSettings(playbackSessionSetting)?.value, encoded);
    expect(await player.renameNamedMusicQueue(migrated.id, 'Renamed'), isTrue);
    expect(player.namedMusicQueues.single.name, 'Renamed');
    expect(await player.deleteNamedMusicQueue(migrated.id), isTrue);
    await player.reloadForProfile();
    expect(player.namedMusicQueues, isEmpty);
    expect(player.savedSession?.currentId, 'old-song');
  });
}
