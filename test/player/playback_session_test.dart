import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart'
    show AudioProcessingState, MediaControl, MediaItem, PlaybackState;
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/models/device_playlist_track.dart';
import 'package:clipious/music/models/local_music_browse.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_song_tap_queue_scope.dart';
import 'package:clipious/music/models/music_background_playback.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/models/song_transition.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/services/cached_music.dart';
import 'package:clipious/player/audio_playback_sources.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart'
    show ClippingAudioSource, UriAudioSource;
import 'package:sembast/sembast.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';
import 'held_music_preparer.dart';

class _GuestService extends Service {
  List<SponsorSegmentType>? requestedCategories;
  bool metadataFails = false;
  Completer<void>? metadataRequested;
  Completer<void>? releaseMetadata;
  final requestedVideoIds = <String>[];

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
      String videoId, List<SponsorSegmentType> categories) async {
    requestedCategories = categories;
    return [];
  }

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<Video> getMusicVideo(String id,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest,
          VideoLoadObserver? loadObserver}) =>
      getVideo(id,
          serverOverride: serverOverride,
          onBackendRequest: onBackendRequest,
          loadObserver: loadObserver);

  @override
  Future<Video> getVideo(String id,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    requestedVideoIds.add(id);
    if (metadataRequested?.isCompleted == false) metadataRequested!.complete();
    if (releaseMetadata != null) await releaseMetadata!.future;
    return metadataFails
        ? throw StateError('Metadata unavailable')
        : Video(videoId: id);
  }
}

class _MediaRadioCatalog extends MusicCatalogService {
  final requests = <String>[];
  final called = Completer<void>();
  Future<List<MusicTrack>>? held;

  static const related = [
    MusicTrack(
        videoId: 'radio-match', title: 'Related song', artists: ['Artist']),
  ];

  @override
  Future<List<MusicTrack>> getRelatedSongs(Iterable<String> seedIds,
      {bool Function()? isCurrent}) async {
    requests.add(seedIds.single);
    if (!called.isCompleted) called.complete();
    final pending = held;
    return pending == null ? related : await pending;
  }
}

String _mediaAction(MediaHandler handler, String label) =>
    handler.playbackState.value.controls
        .singleWhere((control) => control.label == label)
        .customAction!
        .name;

Iterable<String> _mediaActionLabels(MediaHandler handler) =>
    handler.playbackState.value.controls
        .where((control) => control.customAction != null)
        .map((control) => control.label);

class _MediaActionPlayer extends PlayerCubit {
  _MediaActionPlayer(super.initialState, super.settings);

  @override
  Future<void> onReady() async {}

  void reportDecoderPlay() => setEvent(
      const MediaEvent(state: MediaState.playing, type: MediaEventType.play));

  void reportDecoderPause() => setEvent(
      const MediaEvent(state: MediaState.pause, type: MediaEventType.pause));
}

class _RecordingHistoryService extends _GuestService {
  final syncedAccounts = <String>[];

  @override
  Future<void> syncAccountHistory(Server account,
      {IDbClient? database, bool force = false, bool pull = true}) async {
    syncedAccounts.add(account.accountId);
  }
}

class _SessionPlayer extends TestPlayerCubit {
  _SessionPlayer(super.initialState, super.settings,
      {super.learningTimeMicroseconds, this.startupGate});

  final Future<void>? startupGate;

  @override
  Future<void> onReady() => startupGate ?? super.onReady();

  void seedState(PlayerState snapshot) => emit(snapshot);

  void seedVideo(Video video) => emit(state.copyWith(currentlyPlaying: video));

  void seedDownload(DownloadedVideo video) => emit(state.copyWith(
      offlineCurrentlyPlaying: video,
      offlineVideos: [video],
      position: Duration.zero));

  void seedAudioStart(Duration startAt) =>
      emit(state.copyWith(startAt: startAt, isAudio: true));

  void reportDecoderPlay() => setEvent(
      const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
}

class _AudioStartRecorder extends AudioPlayerCubit {
  _AudioStartRecorder(super.initialState, super.player, super.settings);

  Duration? startedAt;
  bool? startedOffline;

  @override
  void initPlayer() {}

  @override
  Future<void> playVideo(bool offline, {Duration? startAt}) async {
    startedAt = startAt;
    startedOffline = offline;
    await super.playVideo(offline, startAt: startAt);
  }
}

class _ProfileStopRecorder extends _AudioStartRecorder {
  _ProfileStopRecorder(super.initialState, super.player, super.settings);

  final stopRequested = Completer<void>();
  final stopped = Completer<void>();

  @override
  Future<void> stopForProxyChange() {
    if (!stopRequested.isCompleted) stopRequested.complete();
    return stopped.future;
  }
}

class _RecordingAudioFocus extends Fake implements AudioSession {
  bool active = false;

  @override
  Future<bool> setActive(bool active,
      {AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
      AndroidAudioFocusGainType? androidAudioFocusGainType,
      AndroidAudioAttributes? androidAudioAttributes,
      bool? androidWillPauseWhenDucked,
      AudioSessionConfiguration fallbackConfiguration =
          const AudioSessionConfiguration.music()}) async {
    this.active = active;
    return true;
  }
}

class _RemoteLoadPlayer extends _SessionPlayer {
  _RemoteLoadPlayer(super.initialState, super.settings);

  // Exercise remote intent without creating a native media controller.
  @override
  Future<void> playVideo(List<Video> videos,
          {bool? audio,
          Duration? startAt,
          bool? playing,
          int? startIndex,
          String? queueTitle,
          PlaylistReference? recommendationSource,
          bool fromMusic = false,
          bool songTap = false,
          bool collectionDetail = false}) =>
      super.playVideo([],
          audio: audio,
          startAt: startAt,
          playing: playing,
          queueTitle: queueTitle,
          recommendationSource: recommendationSource,
          fromMusic: fromMusic,
          songTap: songTap);
}

class _DelayedProgressPlayer extends _SessionPlayer {
  _DelayedProgressPlayer(super.initialState, super.settings);

  final savedProgress = <int, Completer<void>>{};

  @override
  Future<void> saveProgress(int timeInSeconds) =>
      savedProgress.putIfAbsent(timeInSeconds, () => Completer<void>()).future;
}

Future<void> waitForSavedPosition(int seconds,
    {String? videoId, int? fractionUs}) async {
  final database = db as SembastSqfDb;
  await database.settingsStore
      .record(playbackSessionSetting)
      .onSnapshot(database.db)
      .firstWhere((snapshot) {
    final session = PlaybackSession.decode(snapshot?.value['value'] as String?);
    return session?.seconds == seconds &&
        (videoId == null || session?.currentId == videoId) &&
        (fractionUs == null || session?.positionFractionUs == fractionUs);
  }).timeout(const Duration(seconds: 5));
}

Future<void> waitForMusicEvents(
    MusicListeningHistory history, int count) async {
  final saved = Completer<void>();
  void check() {
    if (!saved.isCompleted && history.events().length >= count) {
      saved.complete();
    }
  }

  final changes = history.changes;
  changes.addListener(check);
  try {
    check();
    await saved.future.timeout(const Duration(seconds: 5));
    expect(history.events(), hasLength(count));
  } finally {
    changes.removeListener(check);
  }
}

Future<void> flushPlaybackWrites() =>
    (db as SembastSqfDb).db.transaction((_) async {});

Future<List<LocalMusicTrack>> openDeviceFolder(
    {bool legacy = false,
    bool withExclusionFolder = false,
    bool withCueTracks = false,
    Map<String, Map<String, Object>>? catalog,
    bool Function()? canRead,
    String? Function(String)? renamedFile,
    Set<String> Function()? missingFiles,
    Map<String, String> Function()? movedFiles}) async {
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const tree =
      'content://com.android.externalstorage.documents/tree/primary%3AMusic';
  String uri(String filename) =>
      '$tree/document/primary%3AMusic%2F${Uri.encodeComponent(filename)}';
  String playbackId(String filename) =>
      LocalMusicTrack(uri: uri(filename), title: filename).playbackId;
  var selection = 0;
  Map<String, String> folder() => {
        'uri': tree,
        'name': 'Music',
        if (!legacy || selection > 1) 'selectionId': 'approval-$selection'
      };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var granted = false;
  messenger.setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'getFolder':
        return granted ? folder() : null;
      case 'pickFolder':
        if (!granted) selection++;
        granted = true;
        return folder();
      case 'checkFolderAccess':
        return granted && (canRead?.call() ?? true);
      case 'listTracks':
        expect(granted, isTrue);
        expect(call.arguments['treeUri'], tree);
        if (catalog != null) {
          return [
            for (final entry in catalog.entries)
              {
                'uri': uri('${entry.key}.mp3'),
                'title': entry.key,
                'durationMs': 60000,
                ...entry.value,
              },
          ];
        }
        final missing = missingFiles?.call() ?? const <String>{};
        final moved = movedFiles?.call() ?? const <String, String>{};
        return ['First', 'Second']
            .where((name) => !missing.contains(name))
            .map((name) {
          final originalFilename = '$name.mp3';
          final renamed = renamedFile?.call(name);
          final filename = withCueTracks
              ? 'Concert.flac'
              : moved[name] ?? renamed ?? originalFilename;
          return {
            'uri': uri(filename),
            'fileName': filename,
            if (!withCueTracks &&
                filename != originalFilename &&
                renamed == filename)
              'identityUri': uri(originalFilename),
            'title': name,
            'artist': 'Local artist',
            'album': 'Local album',
            'durationMs': withCueTracks
                ? (name == 'First' ? 5013 : 14973)
                : (name == 'First' ? 0 : 60000),
            if (withCueTracks) ...{
              'identityKey': (name == 'First' ? 'd' : 'e') * 64,
              'cueStartUs': name == 'First' ? 13333 : 5026666,
              'replayGain': {'trackGainDb': -3.0},
              if (name == 'First') 'cueEndUs': 5026666,
            },
            'visibilityKey': (name == 'First' ? 'a' : 'b') * 64,
            if (withExclusionFolder && name == 'Second')
              'folderLocations': [
                {'key': 'c' * 64, 'label': 'Music / Drafts'},
              ],
          };
        }).toList();
      case 'listMovedFileRepairs':
        expect(call.arguments['treeUri'], tree);
        final missing = missingFiles?.call() ?? const <String>{};
        final moved = movedFiles?.call() ?? const <String, String>{};
        return {
          'missing': [
            for (final name in missing)
              {
                'id': playbackId('$name.mp3'),
                'title': name,
                'fileName': '$name.mp3',
                'artist': 'Local artist',
                'album': 'Local album',
                'durationMs': name == 'First' ? 0 : 60000,
                'folder': 'Music / Old',
                'candidates': [],
              },
          ],
          'aliases': {
            for (final MapEntry(key: name, value: file) in moved.entries)
              playbackId('$name.mp3'): playbackId(file),
          },
          'missingAliases': <String, String>{},
        };
      case 'forgetFolder':
        granted = false;
        return null;
      default:
        throw UnsupportedError(call.method);
    }
  });
  final library = LocalMusicLibrary.instance;
  addTearDown(() async {
    await library.disable();
    messenger.setMockMethodCallHandler(channel, null);
  });
  await library.initialize();
  await library.chooseFolder();
  if (!library.loaded) await library.refresh();
  expect(library.tracks.map((track) => track.title),
      catalog?.keys ?? ['First', 'Second']);
  return library.tracks.toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('session keeps queue order and position without expiring stream URLs',
      () {
    const session = PlaybackSession(
        videos: [
          Video(videoId: 'first', title: 'First', dashUrl: 'https://expired'),
          Video(videoId: 'second', title: 'Second'),
        ],
        currentId: 'second',
        seconds: 42,
        queueTitle: 'Late Night Mix',
        audio: true,
        played: ['first'],
        next: []);
    final encoded = session.encode();
    final decoded = PlaybackSession.decode(encoded)!;
    expect(encoded, isNot(contains('https://expired')));
    expect(decoded.videos.map((v) => v.videoId), ['first', 'second']);
    expect(decoded.currentId, 'second');
    expect(decoded.seconds, 42);
    expect(decoded.played, ['first']);
    expect(decoded.audio, isTrue);
    expect(decoded.queueTitle, 'Late Night Mix');
  });

  test('session restores a suggested occurrence beside a manual copy', () {
    const song = Video(videoId: 'song', title: 'Song');
    final suggested = markMusicQueueSuggestion(song);
    final session = PlaybackSession(
        videos: [song, suggested],
        currentId: playbackQueueId(song),
        seconds: 42,
        next: [playbackQueueId(suggested)],
        audio: true);
    final restored = PlaybackSession.decode(session.encode())!;
    expect(restored.videos.map(isMusicQueueSuggestion), [false, true]);
    expect(restored.currentId, playbackQueueId(song));
    expect(restored.seconds, 42);
    expect(restored.next, [playbackQueueId(suggested)]);
  });

  test('invalid or future session data is ignored', () {
    const session = PlaybackSession(
        videos: [Video(videoId: 'a')], currentId: 'a', seconds: 20);
    final json = jsonDecode(session.encode()) as Map<String, dynamic>;
    expect(PlaybackSession.decode('broken'), isNull);
    expect(PlaybackSession.decode(null), isNull);
    expect(PlaybackSession.decode(jsonEncode({...json, 'version': 6})), isNull);
    for (final badId in ['music-a#-2', '../outside#1']) {
      expect(
          PlaybackSession.decode(jsonEncode({
            ...json,
            'version': 3,
            'videos': [],
            'offlineIds': ['music-a', badId],
            'currentId': badId,
          })),
          isNull);
    }
    expect(
        PlaybackSession.decode(jsonEncode({...json, 'seconds': -1})), isNull);
    expect(
        PlaybackSession.decode(jsonEncode({...json, 'currentId': 'missing'})),
        isNull);
    expect(PlaybackSession.decode(session.encode())!.queueTitle, isNull);
    expect(
        PlaybackSession.decode(jsonEncode({
          ...json,
          'queueTitle': <int>[1]
        }))!
            .queueTitle,
        isNull);
  });

  test('music sessions retain catalog labels without saving stream URLs', () {
    const music =
        MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
    const session = PlaybackSession(videos: [
      Video(videoId: 'song', musicMetadata: music, dashUrl: 'https://expired')
    ], currentId: 'song', seconds: 37, audio: true);
    final encoded = session.encode();
    final restored = PlaybackSession.decode(encoded)!;
    expect(restored.videos.single.musicMetadata!.toJson(), music.toJson());
    expect(restored.seconds, 37);
    expect(encoded, isNot(contains('https://expired')));
  });

  test('cached session retains exact owner and refuses a missing cache marker',
      () {
    const server = Server(
        url: 'https://media.example', id: 'account', profileId: 'listener');
    final owner = cachedMusicOwner(server)!;
    final song = CachedMusicSong(
        videoId: 'song',
        title: 'Song',
        artist: 'Artist',
        lengthSeconds: 93,
        rendition: '1' * 64);
    final session = PlaybackSession(
        videos: [song.playbackEntry(owner)],
        currentId: 'song',
        seconds: 37,
        audio: true);
    final encoded = session.encode();
    final decoded = PlaybackSession.decode(encoded)!;
    expect(CachedMusicPlayback.of(decoded.videos.single)?.toJson(), {
      'owner': owner,
      'rendition': song.rendition,
    });
    expect(encoded, isNot(contains(server.url)));
    final snapshot = jsonDecode(encoded) as Map<String, dynamic>;
    (snapshot['videos'] as List).single.remove('cachedMusic');
    expect(PlaybackSession.decode(jsonEncode(snapshot)), isNull);
  });

  test('Music recommendation sources follow individual saved occurrences', () {
    const source =
        'a1234567890bcdefa1234567890bcdefa1234567890bcdefa1234567890bcdef';
    const sessions = [
      PlaybackSession(
        videos: [
          Video(videoId: 'song'),
          Video(videoId: 'song', queueEntryId: 'song#1'),
        ],
        currentId: 'song',
        seconds: 20,
        audio: true,
        next: ['song#1'],
        musicRecommendationSources: {'song#1': source},
      ),
      PlaybackSession(
        offlineIds: ['song', 'song#1'],
        currentId: 'song',
        seconds: 20,
        audio: true,
        next: ['song#1'],
        musicRecommendationSources: {'song#1': source},
      ),
    ];
    for (final session in sessions) {
      final encoded = session.encode();
      final restored = PlaybackSession.decode(encoded)!;
      expect(restored.musicRecommendationSources, {'song#1': source});
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      json['musicRecommendationSources'] = {
        'song#1': source,
        'song': source.toUpperCase(),
        'removed': source,
      };
      expect(
          PlaybackSession.decode(jsonEncode(json))!.musicRecommendationSources,
          {'song#1': source});

      json['musicRecommendationSources'] = [source];
      final malformed = PlaybackSession.decode(jsonEncode(json))!;
      expect(malformed.musicRecommendationSources, isEmpty);
      expect(malformed.currentId, 'song');
      expect(malformed.next, ['song#1']);

      json.remove('musicRecommendationSources');
      final legacy = PlaybackSession.decode(jsonEncode(json))!;
      expect(legacy.musicRecommendationSources, isEmpty);
      expect(legacy.encode(), isNot(contains('musicRecommendationSources')));
    }
  });

  test('mixed offline collection retains cache, download and device proofs',
      () {
    final cache = CachedMusicPlayback('1' * 64, '2' * 64);
    final fingerprint = 'v2:${'3' * 64}:${'4' * 64}';
    final deviceId = 'device:playlist:${'5' * 64}';
    const music = MusicMetadata(title: 'Song', artist: 'Artist');
    final session = PlaybackSession(
      videos: [
        Video(videoId: 'cached', musicMetadata: music, playbackSourceId: cache),
        Video(
            videoId: 'downloaded',
            queueEntryId: 'downloaded#2',
            musicMetadata: music,
            explicitMusicDownload: fingerprint),
        Video(videoId: deviceId, musicMetadata: music),
      ],
      currentId: 'downloaded#2',
      seconds: 7,
      audio: true,
      localSelectionId: 'selected-library',
      played: ['cached'],
      next: [deviceId],
    );

    final encoded = session.encode();
    final decoded = PlaybackSession.decode(encoded)!;
    expect(decoded.videos.map(playbackQueueId),
        ['cached', 'downloaded#2', deviceId]);
    expect(
        CachedMusicPlayback.of(decoded.videos.first)?.toJson(), cache.toJson());
    expect(decoded.videos[1].explicitMusicDownload, fingerprint);
    expect(decoded.deviceTrackIds, [deviceId]);
    expect(decoded.localSelectionId, session.localSelectionId);
    expect(decoded.currentId, session.currentId);
    expect(decoded.played, session.played);
    expect(decoded.next, session.next);
    expect(PlaybackSession.decode(encoded.replaceFirst(fingerprint, 'v2:bad')),
        isNull);
  });

  group('restoration', () {
    late _SessionPlayer player;
    late TestSettingsCubit settings;
    late TestAppCubit app;
    late int playbackMicroseconds;

    void samplePlayback(int timeSeconds, int positionSeconds) {
      playbackMicroseconds = timeSeconds * Duration.microsecondsPerSecond;
      player.setEvent(MediaEvent(
          type: MediaEventType.playbackSample,
          state: MediaState.playing,
          value: Duration(seconds: positionSeconds)));
    }

    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      service = _GuestService();
      app = TestAppCubit(AppState(0, null, HomeLayout()));
      settings = TestSettingsCubit(SettingsState.init(), app);
      playbackMicroseconds = 0;
      player = _SessionPlayer(PlayerState.init(null), settings,
          learningTimeMicroseconds: () => playbackMicroseconds);
    });

    tearDown(() async {
      if (!player.isClosed) await player.close();
      await settings.close();
      await db.close();
    });

    test('SponsorBlock loads default categories and respects saved choices',
        () async {
      final guest = service as _GuestService;
      player.seedVideo(const Video(videoId: 'sponsor-test'));
      await player.setSponsorBlock();
      expect(guest.requestedCategories,
          [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);

      await settings.saveSetting(
          SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
      await settings.saveSetting(SettingsValue(
          SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
      guest.requestedCategories = null;
      await player.setSponsorBlock();
      expect(guest.requestedCategories, isNull);

      await settings.saveSetting(
          SettingsValue(SponsorSegmentType.intro.settingsName(), 'true'));
      await player.setSponsorBlock();
      expect(guest.requestedCategories, [SponsorSegmentType.intro]);
    });

    test('playback status survives presentation events until decoder recovery',
        () async {
      player.seedVideo(const Video(videoId: 'status'));
      player.setEvent(const MediaEvent(
          state: MediaState.error,
          value: PlaybackFailureReason.separateMediaHost));
      player.showMiniPlayer();
      player.setEvent(const MediaEvent(
          state: MediaState.ready,
          type: MediaEventType.speedChanged,
          value: 1.5));
      expect(player.playbackStatus, MediaState.error);
      expect(player.playbackFailureReason,
          PlaybackFailureReason.separateMediaHost);
      player.setEvent(const MediaEvent(state: MediaState.loading));
      player.showBigPlayer();
      expect(player.playbackStatus, MediaState.loading);
      expect(player.playbackFailureReason, isNull);
      player.setEvent(const MediaEvent(state: MediaState.ready));
      expect(player.playbackStatus, MediaState.ready);
      expect(player.playbackFailureReason, isNull);
    });

    test('playback status cannot leak to replacement queue or profile',
        () async {
      const song = Video(videoId: 'status', queueEntryId: 'first');
      player.seedVideo(song);
      player.setEvent(const MediaEvent(
          state: MediaState.error,
          value: PlaybackFailureReason.separateMediaHost));
      player.seedVideo(song.copyWith(queueEntryId: 'second'));
      expect(player.playbackStatus, MediaState.idle);
      expect(player.playbackFailureReason, isNull);
      player.setEvent(const MediaEvent(state: MediaState.error));
      await player.prepareForProfileSwitch();
      expect(player.playbackStatus, MediaState.idle);
      await player.reloadForProfile();
      player.seedVideo(song);
      expect(player.playbackStatus, MediaState.idle);
    });

    test('buffering pause waits for native ready without hiding completion',
        () async {
      player.seedVideo(const Video(videoId: 'status'));
      player.setEvent(const MediaEvent(state: MediaState.buffering));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      expect(player.playbackStatus, MediaState.buffering);
      player.setEvent(const MediaEvent(state: MediaState.ready));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      expect(player.playbackStatus, MediaState.ready);
      await settings.setAutoplayQueue(false);
      player.setEvent(const MediaEvent(state: MediaState.completed));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      expect(player.playbackStatus, MediaState.completed);
    });

    test('replacement loading retains status even with a shared const event',
        () {
      const loading = MediaEvent(state: MediaState.loading);
      player.seedVideo(const Video(videoId: 'status', queueEntryId: 'first'));
      player.setEvent(loading);
      player.seedState(player.state.copyWith(
          currentlyPlaying:
              const Video(videoId: 'status', queueEntryId: 'second'),
          mediaEvent: loading));
      expect(player.playbackStatus, MediaState.loading);
    });

    test('reloading the same queue occurrence replaces stale failure status',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const song = Video(
          videoId: 'status',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      await player.playVideo([song], audio: true);
      final queueId = player.state.currentQueueId;
      player.setEvent(const MediaEvent(state: MediaState.error));
      final reload = player.switchToVideo(player.state.currentlyPlaying!);
      expect(player.playbackStatus, MediaState.loading);
      await reload;
      expect(player.state.currentQueueId, queueId);
      expect(player.playbackStatus, isNot(MediaState.error));
    });

    test('stopping clears playback status before the close animation',
        () async {
      player.seedVideo(const Video(videoId: 'status'));
      player.setEvent(const MediaEvent(state: MediaState.error));
      player.hide();
      expect(player.playbackStatus, MediaState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.playbackStatus, MediaState.idle);
    });

    test('automatic PiP follows visible video playback, including downloads',
        () async {
      const channel = MethodChannel('videre/pip');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final playing = player.state.copyWith(
        currentlyPlaying: const Video(videoId: 'pip'),
        isPlaying: true,
        isHidden: false,
      );
      player.seedState(playing);
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments['enabled'], isTrue);

      for (final ineligible in [
        playing.copyWith(isPlaying: false),
        playing.copyWith(isAudio: true),
        playing.copyWith(isHidden: true),
        playing.copyWith(isClosing: true),
        playing.copyWith(currentlyPlaying: null),
      ]) {
        player.seedState(ineligible);
        await Future<void>.delayed(Duration.zero);
        expect(calls.last.arguments['enabled'], isFalse);
        player.seedState(playing);
      }
      player.seedState(playing.copyWith(
        currentlyPlaying: null,
        offlineCurrentlyPlaying: const DownloadedVideo(
            videoId: 'offline',
            title: 'Offline',
            lengthSeconds: 60,
            quality: '720p'),
        aspectRatio: 0.1,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments['enabled'], isTrue);
      expect(
          calls.last.arguments['aspectRatio'], greaterThanOrEqualTo(1 / 2.39));
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments['enabled'], isTrue);
      await player.close();
      expect(calls.last.arguments['enabled'], isFalse);
    });

    test('PiP callbacks preserve playback, position, and the previous layout',
        () async {
      const channel = MethodChannel('puntito.simple_pip_mode');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final offline in [false, true]) {
        final playing = player.state.copyWith(
          currentlyPlaying: offline ? null : const Video(videoId: 'pip'),
          offlineCurrentlyPlaying: offline
              ? const DownloadedVideo(
                  videoId: 'offline',
                  title: 'Offline',
                  lengthSeconds: 60,
                  quality: '720p')
              : null,
          isPlaying: true,
          isHidden: false,
          isMini: true,
          position: const Duration(seconds: 23),
        );
        player.seedState(playing);
        for (final active in [true, false]) {
          await messenger.handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(
                  MethodCall(active ? 'onPipEntered' : 'onPipExited')),
              (_) {});
          expect(player.state, playing.copyWith(isPip: active));
        }
      }
    });

    test('denied PiP does not change layout or playback', () async {
      const channel = MethodChannel('puntito.simple_pip_mode');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          channel, (call) async => call.method == 'isPipAvailable');
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      player.seedState(player.state.copyWith(
          currentlyPlaying: const Video(videoId: 'pip'),
          isPlaying: true,
          isHidden: false));
      final before = player.state;
      await player.enterPip();
      expect(player.state, before);
      messenger.setMockMethodCallHandler(
          channel, (call) async => throw PlatformException(code: 'denied'));
      await player.enterPip();
      expect(player.state, before);
    });

    for (final (name, audio, music, offline, fullscreen) in [
      ('online music', true, true, false, false),
      ('offline music', true, true, true, false),
      ('ordinary video', false, false, false, true),
      ('music video', false, true, false, true),
      ('ordinary audio', true, false, false, true),
    ]) {
      test('landscape rotation respects the $name presentation', () async {
        final view =
            TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
        view.devicePixelRatio = 1;
        view.physicalSize = const Size(390, 844);
        addTearDown(view.resetDevicePixelRatio);
        addTearDown(view.resetPhysicalSize);
        await settings.saveSetting(
            SettingsValue(fullScreenOnLandscapeSettingName, 'true'));
        final metadata =
            music ? const MusicMetadata(title: 'Song', artist: 'Artist') : null;
        player.seedState(player.state.copyWith(
          currentlyPlaying: offline
              ? null
              : Video(videoId: 'rotation', musicMetadata: metadata),
          offlineCurrentlyPlaying: offline
              ? DownloadedVideo(
                  videoId: 'rotation',
                  title: 'Song',
                  lengthSeconds: 180,
                  quality: 'audio',
                  musicMetadata: metadata,
                  audioOnly: true)
              : null,
          isAudio: audio,
          isHidden: false,
          isMini: false,
          orientation: Orientation.portrait,
        ));

        view.physicalSize = const Size(844, 390);
        player.didChangeMetrics();

        expect(player.state.orientation, Orientation.landscape);
        expect(
            player.state.fullScreenState,
            fullscreen
                ? FullScreenState.fullScreen
                : FullScreenState.notFullScreen);
        expect(player.state.mediaCommand?.type,
            fullscreen ? MediaCommandType.enterFullScreen : isNull);
        expect(player.state.isMini, isFalse);
      });
    }

    test(
        'media stop exits rotated audio fullscreen and restores Android chrome',
        () async {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1;
      view.physicalSize = const Size(390, 844);
      addTearDown(view.resetDevicePixelRatio);
      addTearDown(view.resetPhysicalSize);

      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await settings
          .saveSetting(SettingsValue(fullScreenOnLandscapeSettingName, 'true'));
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      player.seedState(player.state.copyWith(
          currentlyPlaying: const Video(videoId: 'rotation'),
          isAudio: true,
          isMini: false,
          isHidden: false,
          orientation: Orientation.portrait));
      view.physicalSize = const Size(844, 390);
      player.didChangeMetrics();
      expect(player.state.fullScreenState, FullScreenState.fullScreen);

      calls.clear();
      await app_main.mediaHandler.stop();
      expect(player.state.fullScreenState, FullScreenState.notFullScreen);
      // A late rotation event must not reopen the overlay during its exit animation.
      player.onOrientationChange();
      expect(player.state.fullScreenState, FullScreenState.notFullScreen);
      expect(
          calls
              .where((call) =>
                  call.method == 'SystemChrome.setEnabledSystemUIOverlays')
              .last
              .arguments,
          [SystemUiOverlay.top.toString(), SystemUiOverlay.bottom.toString()]);
      expect(
          calls
              .where((call) =>
                  call.method == 'SystemChrome.setPreferredOrientations')
              .last
              .arguments,
          isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.state.isHidden, isTrue);
      expect(player.state.fullScreenState, FullScreenState.notFullScreen);
    });

    test('resizing into PiP preserves the expanded portrait layout', () async {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1;
      view.physicalSize = const Size(390, 844);
      addTearDown(view.resetDevicePixelRatio);
      addTearDown(view.resetPhysicalSize);
      player.seedState(player.state.copyWith(
        currentlyPlaying: const Video(videoId: 'pip'),
        isHidden: false,
        isMini: false,
        orientation: Orientation.portrait,
      ));
      const channel = MethodChannel('puntito.simple_pip_mode');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('onPipEntered')),
          (_) {});
      view.physicalSize = const Size(320, 180);
      player.didChangeMetrics();
      expect(player.state.fullScreenState, FullScreenState.notFullScreen);
      expect(player.state.mediaCommand, isNull);

      await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('onPipExited')),
          (_) {});
      view.physicalSize = const Size(390, 844);
      player.didChangeMetrics();
      expect(player.state.fullScreenState, FullScreenState.notFullScreen);
      expect(player.state.isMini, isFalse);

      // A real rotation still enters fullscreen after returning to the app.
      view.physicalSize = const Size(844, 390);
      player.didChangeMetrics();
      expect(player.state.fullScreenState, FullScreenState.fullScreen);
    });

    test('restores a queue and timestamp without issuing playback commands',
        () async {
      const session = PlaybackSession(
          videos: [Video(videoId: 'a'), Video(videoId: 'b')],
          currentId: 'a',
          seconds: 17,
          next: ['b']);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
      player.restoreSession();
      expect(player.state.videos.map((v) => v.videoId), ['a', 'b']);
      expect(player.state.playQueue, ['b']);
      expect(player.state.startAt, const Duration(seconds: 17));
      expect(player.state.isHidden, isTrue);
      expect(player.state.hasVideo, isFalse);
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaCommand, isNull);
    });

    test('Music queue title is kept on resume and cleared on replacement',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const song = Video(
        videoId: 'source-test',
        musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'),
      );
      await player.playVideo([song],
          audio: true, fromMusic: true, queueTitle: ' Late Night Mix ');
      expect(player.musicQueueTitle, 'Late Night Mix');
      await waitForSavedPosition(0, videoId: song.videoId);
      expect(player.savedSession?.queueTitle, 'Late Night Mix');

      await player.playLocalMusic([], queueTitle: 'Unavailable folder');
      expect(player.musicQueueTitle, 'Late Night Mix');

      player.restoreSession();
      await player.resumeSession(fromMusic: true);
      expect(player.musicQueueTitle, 'Late Night Mix');

      await player.playVideo([song], audio: true, fromMusic: true);
      expect(player.musicQueueTitle, isNull);
    });

    test('device songs use the scanned source, local queue and media metadata',
        () async {
      final songs = await openDeviceFolder();
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      // A retained row may predate a rescan. The current library owns labels
      // and artwork for the URI, even when the caller still has an older row.
      final stale = LocalMusicTrack(uri: songs.last.uri, title: 'Old title');
      await player.playLocalMusic([songs.first, stale], startIndex: 1);
      expect(player.state.currentlyPlaying, isNull);
      expect(player.state.videos, isEmpty);
      expect(player.state.isAudio, isTrue);
      expect(player.currentIndex, 1);
      expect(player.state.offlineCurrentlyPlaying?.storageUri, songs[1].uri);
      expect(player.state.currentQueueId, songs[1].playbackId);
      expect(player.state.offlineVideos.map((item) => item.videoId),
          songs.map((song) => song.playbackId));
      final mediaItem = (await player.getMediaItem(1))!;
      expect(mediaItem.title, 'Second');
      expect(mediaItem.artist, 'Local artist');
      expect(mediaItem.album, 'Local album');
      expect(mediaItem.duration, const Duration(minutes: 1));
      expect(mediaItem.artUri, isNull);
      const measured = Duration(milliseconds: 90250);
      player.reportLocalMusicDuration(songs.first.playbackId, measured);
      expect(player.state.offlineVideos.first.lengthSeconds, 0);
      expect(player.state.offlineCurrentlyPlaying?.lengthSeconds, 60);

      await player.saveProgress(30);
      await player.skipToVideo(0);
      expect(player.state.offlineCurrentlyPlaying?.storageUri, songs.first.uri);
      expect(player.state.playQueue, [songs.last.playbackId]);
      await waitForSavedPosition(0, videoId: songs.first.playbackId);
      player.reportLocalMusicDuration(songs.first.playbackId, measured);
      expect(player.state.offlineVideos.first.lengthSeconds, 91);
      expect(player.state.offlineCurrentlyPlaying?.lengthSeconds, 91);
      expect((await player.getMediaItem(0))!.duration,
          const Duration(seconds: 91));
      player.seek(const Duration(minutes: 2));
      expect(player.state.mediaCommand!.value, const Duration(seconds: 91));
      final encoded = db.getSettings(playbackSessionSetting)!.value;
      final session = PlaybackSession.decode(encoded)!;
      expect(session.offlineIds, songs.map((song) => song.playbackId));
      expect(session.localSelectionId, 'approval-1');
      expect(encoded, isNot(contains('content://')));
      expect(encoded, isNot(contains('Local artist')));
      expect(db.getAllProgress(), isEmpty);
      expect(db.getLocalHistory(), isEmpty);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
      expect((service as _GuestService).requestedCategories, isNull);
    });

    test(
        'detail album override keeps its duplicate in the visible release order',
        () async {
      final albumKey = 'a' * 64;
      Map<String, Object> track(int disc, int number) => {
            'album': 'Shared title',
            'albumKey': albumKey,
            'discNumber': disc,
            'trackNumber': number,
          };
      final songs = await openDeviceFolder(catalog: {
        'Disc two': track(2, 1),
        'Other release': {...track(1, 1), 'albumKey': 'b' * 64},
        'Later on disc one': track(1, 2),
        'Hidden file': {...track(1, 3), 'visibilityKey': 'c' * 64},
        'Start of disc one': track(1, 1),
      });
      final library = LocalMusicLibrary.instance;
      expect(await library.hideTrack(songs[3]), isNotNull);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setMusicSongTapQueueScope(MusicSongTapQueueScope.songOnly);
      await settings.setMusicCollectionDetailSongTapQueueScope(
          MusicSongTapQueueScope.album);
      final tapped = songs[2];
      final displayed = [tapped, songs[1], tapped];

      await player.playLocalMusic(displayed,
          startIndex: 2, queueTitle: 'Displayed list', songTap: true);
      expect(player.state.offlineVideos.map((entry) => entry.storageUri),
          [tapped.uri]);

      await player.playLocalMusic(displayed,
          startIndex: 2,
          queueTitle: 'Displayed list',
          songTap: true,
          collectionDetail: true);

      final entries = player.state.offlineVideos;
      expect(entries.map((entry) => entry.storageUri),
          [songs.last.uri, tapped.uri, songs.first.uri]);
      expect(player.state.currentQueueId, startsWith('${tapped.playbackId}#'));
      expect(player.state.currentQueueId, playbackQueueId(entries[1]));
      expect(player.state.playedVideos, [songs.last.playbackId]);
      expect(player.state.playQueue, [songs.first.playbackId]);
      expect(player.musicQueueTitle, 'Shared title');
    });

    test('all songs uses the device sort and retains shuffle on a row tap',
        () async {
      final songs = await openDeviceFolder();
      final library = LocalMusicLibrary.instance;
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      final source = localMusicBrowseSourceKey(
          enabled: true,
          selectionId: library.selectionId,
          system: library.isSystem);
      await settings.setMusicCollectionPreference(
          localMusicSortSetting(source), 'title:descending');
      await settings.setMusicSongTapQueueScope(MusicSongTapQueueScope.allSongs);
      await settings.setMusicRetainShuffleOnSongTap(true);
      await settings.setShuffle(true);

      await player.playOnDeviceMusic([OnDeviceMusicEntry.device(songs.first)],
          songTap: true);

      expect(player.state.offlineVideos.map(playbackQueueId),
          [songs.last.playbackId, songs.first.playbackId]);
      expect(player.state.currentQueueId, songs.first.playbackId);
      expect(player.state.playedVideos, isEmpty);
      expect(player.state.playQueue, [songs.last.playbackId]);
      expect(settings.state.playerShuffleMode, isTrue);
    });

    test('artist tap uses existing credits and catalog order', () async {
      final songs = await openDeviceFolder(catalog: {
        'Zulu': {'artist': 'Band'},
        'Different credit': {'artist': 'Band featuring Guest'},
        'Selected': {'artist': '<unknown>', 'albumArtist': 'band'},
        'Alpha': {'artist': 'Guest', 'albumArtist': 'BAND'},
      });
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setMusicSongTapQueueScope(MusicSongTapQueueScope.artist);

      await player.playLocalMusic([songs[2]], songTap: true);

      expect(player.state.offlineVideos.map(playbackQueueId),
          [songs.first.playbackId, songs[2].playbackId, songs.last.playbackId]);
      expect(player.state.currentQueueId, songs[2].playbackId);
      expect(player.musicQueueTitle, 'Band');
    });

    test('an unverified album falls back to the selected list occurrence',
        () async {
      final songs = await openDeviceFolder();
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setMusicSongTapQueueScope(MusicSongTapQueueScope.album);
      final tapped = songs.last;

      await player.playLocalMusic([tapped, songs.first, tapped],
          startIndex: 2, queueTitle: 'Displayed list', songTap: true);

      final entries = player.state.offlineVideos;
      expect(entries.map((entry) => entry.storageUri),
          [tapped.uri, songs.first.uri, tapped.uri]);
      expect(player.state.currentQueueId, playbackQueueId(entries.last));
      expect(
          player.state.currentQueueId, isNot(playbackQueueId(entries.first)));
      expect(player.musicQueueTitle, 'Displayed list');
    });

    test('genre song tap resumes the chosen device copy from a saved playlist',
        () async {
      final songs = await openDeviceFolder(catalog: {
        'Intro': {'genre': 'Soul'},
        'Unrelated': {'genre': 'Jazz'},
        'Repeated': {'genre': 'Soul', 'visibilityKey': 'd' * 64},
        'Outro': {'genre': 'SOUL'},
      });
      final tapped = songs[2];
      final device = devicePlaylistVideo(tapped)!;
      const online = Video(
          videoId: 'catalog0001',
          musicMetadata: MusicMetadata(title: 'Online song', artist: 'Band'));
      final playlistId = await service.createLocalPlaylistWithEntries(
          'Saved playlist', [device, online, device, device]);
      final playlist = service
          .getLocalPlaylists()
          .singleWhere((row) => row.playlistId == playlistId);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setMusicSongTapQueueScope(MusicSongTapQueueScope.genre);

      await player.playPlaylist(playlist.videos,
          reference: PlaylistReference.forPlaylist(playlist, db),
          startIndex: 3,
          audio: true,
          fromMusic: true,
          songTap: true);

      final selected = '${tapped.playbackId}#2';
      final queue = [songs.first.playbackId, selected, songs.last.playbackId];
      expect(player.state.videos, isEmpty);
      expect(player.state.offlineVideos.map(playbackQueueId), queue);
      expect(player.state.currentQueueId, selected);
      expect(player.state.offlineCurrentlyPlaying?.storageUri, tapped.uri);
      expect(player.playlistReference, isNull);
      expect(player.musicQueueTitle, 'Soul');

      const position = Duration(seconds: 17);
      await player.onProgress(position);
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(position.inSeconds, videoId: selected);
      await player.close();
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();

      expect(player.state.offlineVideos.map(playbackQueueId), queue);
      expect(player.state.currentQueueId, selected);
      expect(player.state.startAt, position);
      expect(player.playlistReference, isNull);
    });

    for (final insertNext in [false, true]) {
      test('enqueue local audio when idle (playNext=$insertNext)', () async {
        final songs = await openDeviceFolder();
        player.audioSession = await AudioSession.instance;
        app_main.mediaHandler = MediaHandler(player);

        await player.enqueueLocalMusic(songs.last, playNext: insertNext);

        expect(player.isLocalMusicSession, isTrue);
        expect(
            player.state.offlineCurrentlyPlaying?.storageUri, songs.last.uri);
        expect(player.state.offlineVideos, hasLength(1));
        expect(player.state.playQueue, isEmpty);
      });
    }

    test('local queue edits refresh transport actions while paused', () async {
      final songs = await openDeviceFolder();
      player.audioSession = await AudioSession.instance;
      final handler = app_main.mediaHandler = MediaHandler(player);
      await player.playLocalMusic([songs.first]);
      await handler.mediaItem
          .firstWhere((item) => item?.id == songs.first.playbackId);

      handler.playbackState.add(PlaybackState(
        controls: [
          MediaControl.rewind,
          MediaControl.play,
          MediaControl.stop,
          MediaControl.fastForward,
        ],
        processingState: AudioProcessingState.ready,
        speed: 1.25,
      ));
      await player.enqueueLocalMusic(songs.last, playNext: true);
      final next = player.state.playQueue.single;
      expect(handler.playbackState.value.controls, [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ]);
      expect(handler.playbackState.value.speed, 1.25);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.ready);
      expect(handler.mediaItem.value?.id, songs.first.playbackId);

      player.removeInactiveQueueOccurrences({next});
      expect(handler.playbackState.value.controls, [
        MediaControl.rewind,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.fastForward,
      ]);
    });

    test('media playlist Save binds the tapped song and profile', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      player.audioSession = await AudioSession.instance;
      final handler = app_main.mediaHandler = MediaHandler(player);
      const first = DownloadedVideo(
          videoId: 'media-save-a',
          title: 'First song',
          lengthSeconds: 100,
          quality: 'audio',
          downloadComplete: true,
          audioOnly: true,
          musicMetadata: MusicMetadata(title: 'First song', artist: 'Artist'));
      final second =
          first.copyWith(videoId: 'media-save-b', title: 'Second song');
      await db.upsertDownload(first);
      await db.upsertDownload(second);
      const transport = [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ];
      handler.playbackState.add(PlaybackState(
        controls: transport,
        androidCompactActionIndices: const [0, 1, 3],
        processingState: AudioProcessingState.ready,
      ));

      await player.playOfflineVideos([first, second], fromMusic: true);
      final controls = handler.playbackState.value.controls;
      expect(
          controls.where((control) => control.customAction == null), transport);
      expect(
          handler.playbackState.value.androidCompactActionIndices, [0, 1, 3]);
      final firstAction = _mediaAction(handler, 'Save to playlist');
      final beforeTap = player.state;
      await handler.customAction(firstAction);
      expect(player.state, same(beforeTap));
      player.musicMediaSave.open();
      expect(player.musicMediaSave.hasReadyRequest, isTrue);

      await player.skipToVideo(1);
      final secondAction = _mediaAction(handler, 'Save to playlist');
      expect(secondAction, isNot(firstAction));
      player.musicMediaSave.open();
      expect(player.musicMediaSave.take()?.entry.videoId, first.videoId);
      player.musicMediaSave.finish();

      await handler.customAction(firstAction);
      player.musicMediaSave.open();
      expect(player.musicMediaSave.take(), isNull);
      await handler.customAction(secondAction);
      player.musicMediaSave.open();
      expect(player.musicMediaSave.hasReadyRequest, isTrue);
      app.setGlobalLoading(true);
      expect(player.musicMediaSave.take(), isNull);
      expect(player.state.currentQueueId, second.videoId);
      expect(player.state.offlineVideos.map((entry) => entry.videoId),
          [first.videoId, second.videoId]);
    });

    test(
        'media Like tracks the library and rejects stale occurrence and service taps',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await player.close();
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      final handler = app_main.mediaHandler = MediaHandler(player);
      final library = MusicLibraryService.forProfile(db, db.profileId);
      const first = DownloadedVideo(
          videoId: 'first-song1',
          title: 'First song',
          lengthSeconds: 100,
          quality: 'audio',
          downloadComplete: true,
          audioOnly: true,
          musicMetadata: MusicMetadata(title: 'First song', artist: 'Artist'));
      final other = first.copyWith(videoId: 'other-song2', title: 'Other song');
      await db.upsertDownload(first);
      await db.upsertDownload(other);
      handler.playbackState.add(PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        processingState: AudioProcessingState.ready,
      ));
      await player.playOfflineVideos([first, other, first], fromMusic: true);
      expect(_mediaActionLabels(handler), ['Like song', 'Save to playlist']);
      expect(
          handler.playbackState.value.androidCompactActionIndices, [0, 1, 3]);
      final like = _mediaAction(handler, 'Like song');
      await handler.customAction(like);
      expect(library.isLiked(first.videoId), isTrue);
      final initialUnlike = _mediaAction(handler, 'Unlike song');

      await player.skipToVideo(2);
      final repeatedUnlike = _mediaAction(handler, 'Unlike song');
      expect(repeatedUnlike, isNot(initialUnlike));
      await handler.customAction(initialUnlike);
      expect(library.isLiked(first.videoId), isTrue);

      final priorService = service;
      service = _GuestService();
      await handler.customAction(repeatedUnlike);
      expect(library.isLiked(first.videoId), isTrue);
      service = priorService;
      app.setGlobalLoading(true);
      await handler.customAction(repeatedUnlike);
      expect(library.isLiked(first.videoId), isTrue);
      app.setGlobalLoading(false);
      await handler.customAction(repeatedUnlike);
      expect(library.isLiked(first.videoId), isFalse);

      final live = _mediaAction(handler, 'Like song');
      expect(live, isNot(like));
      await handler.customAction(like);
      expect(library.isLiked(first.videoId), isFalse);
      await library.setSongLiked(
          MusicLibraryEntry.song(catalogMusicVideoForPlayback(first)!),
          liked: true);
      final lastUnlike = _mediaAction(handler, 'Unlike song');
      expect(lastUnlike, isNot(repeatedUnlike));
      expect(library.isLiked(other.videoId), isFalse);

      final database = db as SembastSqfDb;
      final originalProfile = database.profileId;
      final nextProfile = await database.createProfile('Another person');
      await database.useProfile(nextProfile.id);
      await handler.customAction(lastUnlike);
      expect(library.isLiked(first.videoId), isTrue);
      final nextLibrary = MusicLibraryService.forProfile(db, nextProfile.id);
      expect(nextLibrary.isLiked(first.videoId), isFalse);
      await database.useProfile(originalProfile);
    });

    test(
        'media Radio dispatches the displayed seed and rejects a stale tap or result',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final previousCatalog = musicCatalogService;
      final catalog = _MediaRadioCatalog();
      musicCatalogService = catalog;
      addTearDown(() => musicCatalogService = previousCatalog);
      await player.close();
      final radioPlayer = _MediaActionPlayer(PlayerState.init(null), settings);
      addTearDown(radioPlayer.close);
      radioPlayer.audioSession = await AudioSession.instance;
      final handler = app_main.mediaHandler = MediaHandler(radioPlayer);
      const first = Video(
          videoId: 'radio-first',
          title: 'First song',
          lengthSeconds: 100,
          musicMetadata: MusicMetadata(title: 'First song', artist: 'Artist'));
      final second = first.copyWith(
          videoId: 'radio-other',
          title: 'Second song',
          musicMetadata:
              const MusicMetadata(title: 'Second song', artist: 'Artist'));
      await radioPlayer
          .playVideo([first, second], fromMusic: true, audio: true);
      radioPlayer.reportDecoderPlay();
      expect(_mediaActionLabels(handler), ['Like song', 'Start related radio']);
      final firstRadio = _mediaAction(handler, 'Start related radio');
      radioPlayer.pause();
      radioPlayer.reportDecoderPause();
      expect(_mediaActionLabels(handler), ['Like song', 'Save to playlist']);
      await handler.customAction(firstRadio);
      expect(catalog.requests, isEmpty);
      radioPlayer.play();
      radioPlayer.reportDecoderPlay();

      final held = Completer<List<MusicTrack>>();
      catalog.held = held.future;
      final inFlight = handler.customAction(firstRadio);
      await catalog.called.future.timeout(const Duration(seconds: 2));
      expect(catalog.requests, [first.videoId]);

      await radioPlayer.skipToVideo(1);
      radioPlayer.reportDecoderPlay();
      final secondRadio = _mediaAction(handler, 'Start related radio');
      expect(secondRadio, isNot(firstRadio));
      await handler.customAction(firstRadio);
      expect(catalog.requests, [first.videoId]);
      held.complete(_MediaRadioCatalog.related);
      await inFlight;
      expect(radioPlayer.state.videos.map((entry) => entry.videoId),
          [first.videoId, second.videoId]);

      catalog.held = null;
      await handler.customAction(secondRadio);
      expect(catalog.requests, [first.videoId, second.videoId]);
      expect(radioPlayer.state.currentlyPlaying?.videoId, second.videoId);
      expect(radioPlayer.state.videos.map((entry) => entry.videoId),
          [second.videoId, 'radio-match']);
      expect(radioPlayer.musicQueueTitle, 'Radio · Second song');
    });

    test('local enqueue preserves an active online queue', () async {
      final songs = await openDeviceFolder();
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const current = Video(videoId: 'online');
      const upcoming = Video(videoId: 'next-online');
      player.seedState(PlayerState.init([current, upcoming]).copyWith(
        currentlyPlaying: current,
        position: const Duration(seconds: 45),
        isAudio: true,
        isHidden: false,
      ));
      final before = player.state;

      await player.enqueueLocalMusic(songs.first, playNext: true);
      await player.enqueueLocalMusic(songs.last, playNext: false);
      expect(await player.enqueueLocalMusicCopies(songs, next: true), isFalse);

      expect(player.state, same(before));
      expect(player.isLocalMusicSession, isFalse);
    });

    for (final next in [true, false]) {
      test('local batch copies keep selection order and playback (next=$next)',
          () async {
        final songs = await openDeviceFolder();
        player.audioSession = await AudioSession.instance;
        app_main.mediaHandler = MediaHandler(player);
        expect(
            await player.enqueueLocalMusicCopies(songs, next: next), isFalse);
        await player.playLocalMusic([songs.first, songs.last, songs.first],
            startIndex: 1);
        await player.onProgress(const Duration(seconds: 12));
        final before = player.state;
        final generation = player.backendPlaybackGeneration;
        final originalIds = before.offlineVideos.map((e) => e.videoId).toSet();
        final selection = [songs.last, songs.first, songs.last];
        const missing = LocalMusicTrack(uri: 'content://gone', title: 'Gone');
        expect(
            await player
                .enqueueLocalMusicCopies([...selection, missing], next: next),
            isFalse);
        expect(player.state, same(before));

        expect(await player.enqueueLocalMusicCopies(selection, next: next),
            isTrue);

        final copies = player.state.offlineVideos
            .where((e) => !originalIds.contains(e.videoId))
            .toList();
        final ids = copies.map((e) => e.videoId).toList();
        expect(ids.toSet(), hasLength(3));
        expect(copies.map((e) => e.storageUri), selection.map((e) => e.uri));
        final insertedAt = next ? 2 : originalIds.length;
        expect(player.state.offlineVideos.sublist(insertedAt, insertedAt + 3),
            copies);
        expect(
            player.state.playQueue,
            next
                ? [...ids, ...before.playQueue]
                : [...before.playQueue, ...ids]);
        expect(player.state.playedVideos, before.playedVideos);
        expect(player.state.offlineCurrentlyPlaying,
            same(before.offlineCurrentlyPlaying));
        expect(player.state.position, before.position);
        expect(player.state.mediaCommand, same(before.mediaCommand));
        expect(player.backendPlaybackGeneration, generation);
        expect(player.savedSession!.next, player.state.playQueue.toList());
      });
    }

    test('launcher shuffle starts and preserves its one-time local queue order',
        () async {
      final songs = await openDeviceFolder();
      await player.close();
      final started = Completer<void>();
      player = _SessionPlayer(PlayerState.init(null), settings,
          startupGate: started.future);
      var admitted = true;
      final stale = player.shuffleLocalMusic(songs,
          queueTitle: 'On this device', isCurrent: () => admitted);
      final shuffle = player.shuffleLocalMusic(songs,
          queueTitle: 'On this device', isCurrent: () => true);
      expect(player.state.offlineVideos, isEmpty);
      admitted = false;
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setShuffle(true);

      started.complete();
      await stale;
      await shuffle;
      final order = player.state.offlineVideos.map(playbackQueueId).toList();
      expect(order, unorderedEquals(songs.map((track) => track.playbackId)));
      expect(player.state.currentQueueId, order.first);
      expect(player.state.playQueue, order.skip(1));
      expect(player.intendsPlayback, isTrue);
      expect(settings.state.playerShuffleMode, isTrue);

      final library = LocalMusicLibrary.instance;
      expect(await library.hideTrack(songs.first), isNotNull);
      player.pause();
      expect(player.intendsPlayback, isFalse);
      await player.shuffleLocalMusic(library.visibleTracks,
          queueTitle: 'On this device', isCurrent: () => true);
      expect(player.state.offlineVideos.map(playbackQueueId),
          [songs.last.playbackId]);
      expect(player.intendsPlayback, isTrue);
    });

    test('shuffled local duplicates survive reorder, rename and restore',
        () async {
      final newNames = <String, String>{};
      final songs =
          await openDeviceFolder(renamedFile: (title) => newNames[title]);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setShuffle(true);
      await player.playLocalMusic(songs);
      await player.onProgress(const Duration(seconds: 12));
      final current = player.state.currentQueueId!;
      final originalSecond = player.state.playQueue.single;
      final generation = player.backendPlaybackGeneration;
      final command = player.state.mediaCommand;

      await player.enqueueLocalMusic(songs.last, playNext: false);
      final appended = player.state.playQueue.last;
      expect(appended, isNot(originalSecond));
      expect(player.state.playQueue, [originalSecond, appended]);

      await player.enqueueLocalMusic(songs.last, playNext: true);
      final inserted = player.state.playQueue.first;
      expect(player.state.playQueue, [inserted, originalSecond, appended]);
      expect({current, originalSecond, inserted, appended}, hasLength(4));
      expect(player.state.currentQueueId, current);
      expect(player.state.position, const Duration(seconds: 12));
      expect(player.backendPlaybackGeneration, generation);
      expect(player.state.mediaCommand, same(command));

      player.moveQueueOccurrence(appended, beforeId: inserted);
      expect(player.state.playQueue, [appended, inserted, originalSecond]);
      newNames['First'] = 'Renamed First.mp3';
      newNames['Second'] = 'Renamed Second.mp3';
      final library = LocalMusicLibrary.instance;
      await library.refresh();
      final renamedFirst = library.trackById(songs.first.playbackId)!;
      final renamedSecond = library.trackById(songs.last.playbackId)!;
      expect(renamedFirst.uri, isNot(songs.first.uri));
      expect(renamedSecond.uri, isNot(songs.last.uri));
      expect(player.state.currentQueueId, current);
      expect(
          player.state.offlineCurrentlyPlaying?.storageUri, renamedFirst.uri);
      expect(player.state.playQueue, [appended, inserted, originalSecond]);
      expect(player.backendPlaybackGeneration, generation);
      expect(player.state.position, const Duration(seconds: 12));
      expect(player.state.mediaCommand, same(command));

      await player.close();
      final reopened = _SessionPlayer(PlayerState.init(null), settings);
      player = reopened;
      reopened.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(reopened);
      await settings.setShuffle(false);
      expect(reopened.savedSession!.musicQueueShuffled, isTrue);
      await reopened.resumeSession();

      expect(reopened.musicQueueShuffled, isTrue);
      expect(reopened.state.currentQueueId, current);
      expect(
          reopened.state.offlineCurrentlyPlaying?.storageUri, renamedFirst.uri);
      expect(reopened.state.startAt, const Duration(seconds: 12));
      expect(reopened.state.playQueue, [appended, inserted, originalSecond]);
      expect(
        reopened.state.offlineVideos
            .where((entry) => playbackQueueId(entry) != current)
            .map((entry) => entry.storageUri),
        everyElement(renamedSecond.uri),
      );
      final advanced = reopened.stream
          .firstWhere((snapshot) => snapshot.currentQueueId == appended);
      reopened.playNext();
      final next = await advanced.timeout(const Duration(seconds: 3));
      expect(next.offlineCurrentlyPlaying?.storageUri, renamedSecond.uri);
      expect(next.playQueue, [inserted, originalSecond]);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    for (final grant in ['unchanged', 'revoked', 'replaced']) {
      test('manual Music selection rechecks the device folder ($grant)',
          () async {
        var readable = true;
        final tracks = await openDeviceFolder(canRead: () => readable);
        player.audioSession = await AudioSession.instance;
        final handler = app_main.mediaHandler = MediaHandler(player);
        const online = Video(
            videoId: 'online',
            formatStreams: [],
            adaptiveFormats: [],
            lengthSeconds: 120,
            musicMetadata: MusicMetadata(title: 'Online', artist: 'Band'));
        await player.playVideo([online], audio: true);
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        final preparer = HeldMusicPreparer();
        player.manualMusicPreparer = preparer;
        final generation = player.backendPlaybackGeneration;
        final selection = player.playLocalMusic(tracks, startIndex: 1);
        final entry = await preparer.started.future
            .timeout(const Duration(seconds: 3)) as DownloadedVideo;
        expect(entry.videoId, tracks.last.playbackId);
        expect(entry.storageUri, tracks.last.uri);
        expect(player.state.currentQueueId, 'online');
        expect(handler.mediaItem.value?.id, 'online');
        expect(player.state.offlineVideos, isEmpty);
        expect(player.backendPlaybackGeneration, generation);
        if (grant == 'revoked') {
          readable = false;
          await LocalMusicLibrary.instance.revalidate();
        } else if (grant == 'replaced') {
          final library = LocalMusicLibrary.instance;
          await library.disable();
          await library.chooseFolder();
          if (!library.loaded) await library.refresh();
          expect(library.trackById(entry.videoId)?.uri, entry.storageUri);
        }
        preparer.requests[entry.videoId]!.complete(true);
        await selection;
        if (grant != 'unchanged') {
          expect(player.state.currentQueueId, 'online');
          expect(player.state.isPlaying, isTrue);
          expect(player.state.mediaEvent.state, isNot(MediaState.error));
          expect(handler.mediaItem.value?.id, 'online');
          expect(player.state.offlineVideos, isEmpty);
        } else {
          expect(player.state.currentQueueId, tracks.last.playbackId);
          expect(player.state.videos, isEmpty);
          expect(player.state.offlineCurrentlyPlaying?.storageUri,
              tracks.last.uri);
          expect(player.state.playedVideos, [tracks.first.playbackId]);
        }
        expect((service as _GuestService).requestedVideoIds, isEmpty);
      });
    }

    test(
        'device music keeps the automatic handoff through local source admission',
        () async {
      final songs = await openDeviceFolder();
      final target = songs[1].playbackId;
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setSongTransitionMode(SongTransitionMode.crossfade);
      await player.playLocalMusic(songs);
      final prepared = Completer<DownloadedVideo>();
      void observe(List<IdedVideo> entries) {
        final candidate = entries.whereType<DownloadedVideo>().firstOrNull;
        if (candidate?.videoId == target && !prepared.isCompleted) {
          prepared.complete(candidate);
        }
      }

      player.addAdjacentMusicListener(observe);
      try {
        final standby =
            await prepared.future.timeout(const Duration(seconds: 2));
        player.reportLocalMusicDuration(
            songs.first.playbackId, const Duration(seconds: 20));
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(player.automaticMusicSuccessor?.videoId, target);
        final selected = player.stream.firstWhere((snapshot) =>
            snapshot.currentQueueId == target &&
            snapshot.mediaCommand?.type ==
                MediaCommandType.switchToOfflineVideo);
        player.setEvent(const MediaEvent(state: MediaState.completed));
        expect(player.isAutomaticMusicHandoffTo(target), isTrue);
        final command = (await selected.timeout(const Duration(seconds: 2)))
            .mediaCommand!
            .value as DownloadedVideo;
        // Playback reauthorizes the URI and reconstructs a new local adapter.
        expect(command, isNot(same(standby)));
        expect(command.storageUri, standby.storageUri);
        expect(player.isAutomaticMusicHandoffTo(target), isTrue);
        player.setEvent(const MediaEvent(state: MediaState.ready));
        expect(player.isAutomaticMusicHandoffTo(target), isTrue);
        player.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(player.isAutomaticMusicHandoffTo(target), isFalse);
      } finally {
        player.removeAdjacentMusicListener(observe);
      }
    });

    test('external grant revocation stops the active local decoder and queue',
        () async {
      var readable = true;
      final songs = await openDeviceFolder(canRead: () => readable);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playLocalMusic(songs);
      expect(player.state.currentQueueId, songs.first.playbackId);
      var stopped = false;
      player.addBeforeProfileSwitch(() async {
        stopped = true;
      });
      readable = false;
      await LocalMusicLibrary.instance.revalidate();
      expect(stopped, isTrue);
      expect(player.state.offlineCurrentlyPlaying, isNull);
      expect(player.state.offlineVideos, isEmpty);
      expect(player.state.playQueue, isEmpty);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('repair restores a missing current occurrence and its saved playhead',
        () async {
      var missing = <String>{};
      var moves = <String, String>{};
      final songs = await openDeviceFolder(
          missingFiles: () => missing, movedFiles: () => moves);
      final first = songs.first;
      final second = songs.last;
      final library = LocalMusicLibrary.instance;
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playLocalMusic([first, second, second],
          startIndex: 1, queueTitle: 'Repaired queue');
      final ids = player.state.offlineVideos.map(playbackQueueId).toList();
      await player.onProgress(const Duration(seconds: 17));
      var stopped = false;
      player.addBeforeProfileSwitch(() async => stopped = true);

      missing = {'Second'};
      await library.refresh();
      expect(stopped, isTrue);
      expect(player.state.offlineCurrentlyPlaying, isNull);
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.offlineVideos.map((song) => song.storageUri),
          [first.uri, null, null]);
      await waitForSavedPosition(17, videoId: ids[1]);
      expect(player.savedSession?.offlineIds, ids);
      expect(player.savedSession?.played, [ids.first]);
      expect(player.savedSession?.next, [ids.last]);

      await player.close();
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.offlineCurrentlyPlaying, isNull);
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.offlineVideos[1].title, second.title);
      expect(player.state.offlineVideos[1].storageUri, isNull);

      missing = {};
      moves = {'Second': 'Moved Second.mp3'};
      await library.refresh();
      final moved = library.tracks.last;
      expect(moved.playbackId, isNot(second.playbackId));
      expect(player.state.offlineVideos.map((song) => song.storageUri),
          [first.uri, moved.uri, moved.uri]);
      await player.resumeSession();
      expect(player.state.currentQueueId, ids[1]);
      expect(player.state.startAt, const Duration(seconds: 17));
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.playQueue, [ids.last]);
      expect(player.musicQueueTitle, 'Repaired queue');
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('transport skips missing occurrences until their file is repaired',
        () async {
      var missing = <String>{};
      var moves = <String, String>{};
      final songs = await openDeviceFolder(
          missingFiles: () => missing, movedFiles: () => moves);
      final first = songs.first;
      final second = songs.last;
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playLocalMusic([first, second, first, second]);
      final ids = player.state.offlineVideos.map(playbackQueueId).toList();

      missing = {'Second'};
      await LocalMusicLibrary.instance.refresh();
      await player.selectQueueOccurrence(ids[1]);
      expect(player.state.currentQueueId, ids.first);
      expect(player.state.playQueue, ids.skip(1));
      expect(
          playbackQueueId(player.adjacentMusicEntry(previous: false)!), ids[2]);

      final skipped =
          player.stream.firstWhere((state) => state.currentQueueId == ids[2]);
      player.playNext();
      await skipped.timeout(const Duration(seconds: 3));
      expect(player.state.playQueue, [ids[1], ids[3]]);

      missing = {};
      moves = {'Second': 'Moved Second.mp3'};
      await LocalMusicLibrary.instance.refresh();
      final resumed =
          player.stream.firstWhere((state) => state.currentQueueId == ids[1]);
      player.playNext();
      await resumed.timeout(const Duration(seconds: 3));
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.playQueue, [ids.last]);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test(
        'hiding the current device file preserves its duplicate and resume point',
        () async {
      final songs = await openDeviceFolder();
      final library = LocalMusicLibrary.instance;
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playLocalMusic([songs.last, songs.first, songs.last],
          startIndex: 2, queueTitle: 'My device queue');
      await player.onProgress(const Duration(seconds: 12));
      final before = player.state;
      expect(before.offlineVideos.map((track) => track.storageUri),
          [songs.last.uri, songs.first.uri, songs.last.uri]);
      final occurrenceIds =
          before.offlineVideos.map((track) => track.videoId).toList();
      expect(occurrenceIds.toSet(), hasLength(3));
      expect(before.currentQueueId, occurrenceIds.last);
      final generation = player.backendPlaybackGeneration;

      expect(await library.hideTrack(songs.last), isNotNull);
      expect(library.visibleTracks.map((track) => track.playbackId),
          [songs.first.playbackId]);
      expect(player.state.currentQueueId, before.currentQueueId);
      expect(player.state.offlineVideos.map((track) => track.videoId),
          occurrenceIds);
      expect(player.state.offlineVideos.map((track) => track.storageUri),
          before.offlineVideos.map((track) => track.storageUri));
      expect(player.state.playedVideos, before.playedVideos);
      expect(player.state.playQueue, before.playQueue);
      expect(player.state.position, const Duration(seconds: 12));
      expect(player.state.mediaCommand, same(before.mediaCommand));
      expect(player.backendPlaybackGeneration, generation);

      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(12, videoId: occurrenceIds.last);
      await player.close();
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.currentQueueId, occurrenceIds.last);
      expect(player.state.offlineVideos.map((track) => track.videoId),
          occurrenceIds);
      expect(player.state.offlineCurrentlyPlaying?.storageUri, songs.last.uri);
      expect(player.state.startAt, const Duration(seconds: 12));
      expect(player.musicQueueTitle, 'My device queue');
      expect(library.hiddenTracks.single.isAvailable, isTrue);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('CUE ranges on one document resume the exact queue occurrence',
        () async {
      final songs = await openDeviceFolder(withCueTracks: true);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playLocalMusic([songs.first, songs.last, songs.last]);
      final ids = player.state.offlineVideos.map(playbackQueueId).toList();
      expect(ids.toSet(), hasLength(3));
      expect(songs.first.uri, songs.last.uri);

      Future<AudioPlaybackSources> resolveCurrent() async =>
          (await resolveAudioPlaybackSources(
              video: null,
              offlineVideo: player.state.offlineCurrentlyPlaying,
              sessionId: 'cue-queue',
              isCurrent: () => true))!;

      final firstPlan = await resolveCurrent();
      final first = firstPlan.sources.single as ClippingAudioSource;
      expect(first.child.uri.toString(), songs.first.uri);
      expect(first.start, const Duration(microseconds: 13333));
      expect(first.end, const Duration(microseconds: 5026666));
      expect((first.tag as LocalMusicSourceTag).replayGain?.trackGainDb, -3.0);
      expect(player.duration, const Duration(microseconds: 5013333));

      await player.skipToVideo(2);
      final lastPlan = await resolveCurrent();
      final last = lastPlan.sources.single as ClippingAudioSource;
      expect(last.child.uri, first.child.uri);
      expect(last.start, first.end);
      expect(last.end, isNull);
      expect(samePreparedAudioSource(firstPlan, lastPlan), isFalse);
      expect(player.state.currentQueueId, ids.last);

      const position = Duration(seconds: 2, microseconds: 345678);
      player.seek(position);
      await waitForSavedPosition(2, videoId: ids.last, fractionUs: 345678);
      await player.close();
      final wire = db.getSettings(playbackSessionSetting)!.value;
      expect(wire, isNot(contains(songs.last.uri)));
      final checkpoint = PlaybackSession.decode(wire);
      expect(checkpoint?.positionMilliseconds, position.inMilliseconds);
      expect(checkpoint?.position, position);

      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.currentQueueId, ids.last);
      expect(player.state.startAt, position);
      expect(samePreparedAudioSource(lastPlan, await resolveCurrent()), isTrue);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('a folder exclusion keeps current and upcoming exact occurrences',
        () async {
      final tracks = await openDeviceFolder(withExclusionFolder: true);
      final first = tracks.first;
      final excluded = tracks.last;
      final library = LocalMusicLibrary.instance;
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playLocalMusic([excluded, excluded, first],
          queueTitle: 'Device sources');
      await player.onProgress(const Duration(seconds: 16));
      final before = player.state;
      final ids = before.offlineVideos.map(playbackQueueId).toList();
      final generation = player.backendPlaybackGeneration;
      expect(ids.toSet(), hasLength(3));
      expect(before.currentQueueId, ids.first);
      expect(before.playQueue, ids.skip(1));

      await library.setFolderExcluded(excluded.folderLocations.single, true);
      expect(library.visibleTracks.single.uri, first.uri);
      expect(library.excludedTracks.single.uri, excluded.uri);
      expect(player.state.currentQueueId, before.currentQueueId);
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.offlineVideos.map((track) => track.storageUri),
          [excluded.uri, excluded.uri, first.uri]);
      expect(player.state.playQueue, ids.skip(1));
      expect(player.state.position, const Duration(seconds: 16));
      expect(player.state.mediaCommand, same(before.mediaCommand));
      expect(player.backendPlaybackGeneration, generation);

      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(16, videoId: ids.first);
      await player.close();
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.currentQueueId, ids.first);
      expect(player.state.offlineCurrentlyPlaying?.storageUri, excluded.uri);
      expect(player.state.startAt, const Duration(seconds: 16));
      expect(player.state.playQueue, ids.skip(1));
      expect(library.visibleTrackById(excluded.playbackId), isNull);

      final next = player.stream.firstWhere(
        (state) => state.currentQueueId == ids[1],
      );
      player.playNext();
      final advanced = await next.timeout(const Duration(seconds: 3));
      expect(advanced.offlineCurrentlyPlaying?.storageUri, excluded.uri);
      expect(advanced.playQueue, [ids.last]);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('restoring device audio needs the current folder grant', () async {
      final songs = await openDeviceFolder(legacy: true);
      final saved = PlaybackSession(
          offlineIds: songs.map((track) => track.playbackId).toList(),
          currentId: songs.last.playbackId,
          seconds: 17,
          audio: true);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, saved.encode()));
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.offlineCurrentlyPlaying?.storageUri, songs.last.uri);
      expect(player.state.startAt, const Duration(seconds: 17));
      await waitForSavedPosition(17, videoId: songs.last.playbackId);

      await LocalMusicLibrary.instance.disable();
      await player.close();
      // Restore an old on-device session, even if its ID happens to match a
      // downloads row. Neither source can re-grant a forgotten Android tree.
      await db.upsertDownload(DownloadedVideo(
          videoId: songs.last.playbackId,
          title: 'Old download',
          storageUri: songs.last.uri,
          audioOnly: true,
          downloadComplete: true,
          lengthSeconds: 60,
          quality: ''));
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, saved.encode()));
      final reopened = _SessionPlayer(PlayerState.init(null), settings);
      addTearDown(reopened.close);
      await reopened.resumeSession();
      expect(reopened.state.currentlyPlaying, isNull);
      expect(reopened.state.offlineCurrentlyPlaying, isNull);
      expect(reopened.state.offlineVideos, isEmpty);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
      expect((service as _GuestService).requestedCategories, isNull);
    });

    test(
        'a fresh grant to the same folder cannot revive dormant queues across profiles',
        () async {
      final songs = await openDeviceFolder();
      final library = LocalMusicLibrary.instance;
      final id = songs.first.playbackId;
      final originalSelection = library.selectionId;
      expect(originalSelection, isNotNull);
      expect(await library.chooseFolder(), isTrue);
      expect(library.selectionId, originalSelection);
      final saved = PlaybackSession(
          offlineIds: [id],
          currentId: id,
          seconds: 37,
          audio: true,
          localSelectionId: originalSelection);
      final database = db as SembastSqfDb;
      final other = await database.createProfile('Second listener');
      for (final profile in [database.profileId, other.id]) {
        await database
            .forProfile(profile)
            .saveSetting(SettingsValue(playbackSessionSetting, saved.encode()));
      }
      expect(player.state.offlineVideos, isEmpty);
      await library.disable();
      expect(await library.chooseFolder(), isTrue);
      expect(library.containsUri(songs.first.uri), isTrue);
      expect(library.selectionId, isNot(originalSelection));
      player.restoreSession();
      await player.resumeSession();
      expect(player.state.offlineVideos, isEmpty);
      await player.prepareForProfileSwitch();
      await database.useProfile(other.id);
      await player.reloadForProfile();
      await player.resumeSession();
      expect(player.state.offlineCurrentlyPlaying, isNull);
      expect(player.state.offlineVideos, isEmpty);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('Search and album detail queue different songs after the same tap',
        () async {
      const reference = PlaylistReference(
          kind: PlaylistSourceKind.public,
          playlistId: 'album:tap-scope',
          profileId: 'default',
          displayTitle: 'Album');
      const first = Video(
          videoId: 'track-one',
          title: 'First',
          musicMetadata: MusicMetadata(title: 'First', artist: 'Band'),
          formatStreams: [],
          adaptiveFormats: []);
      final second = first.copyWith(videoId: 'track-two', title: 'Second');
      final songs = [first, second];

      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await settings.setMusicSongTapQueueScope(MusicSongTapQueueScope.songOnly);
      await settings.setMusicCollectionDetailSongTapQueueScope(
          MusicSongTapQueueScope.collection);

      await player.playVideo(songs,
          audio: true, fromMusic: true, songTap: true);
      expect(player.state.currentlyPlaying?.videoId, first.videoId);
      expect(player.state.videos.map((song) => song.videoId), [first.videoId]);
      expect(player.state.playQueue, isEmpty);

      await player.playPlaylist(songs,
          reference: reference,
          audio: true,
          fromMusic: true,
          songTap: true,
          collectionDetail: true);
      expect(player.state.currentlyPlaying?.videoId, first.videoId);
      expect(
          player.state.playQueue, [playbackQueueId(player.state.videos.last)]);
      final next = player.stream.firstWhere(
          (state) => state.currentlyPlaying?.videoId == second.videoId);
      player.playNext();
      await next.timeout(const Duration(seconds: 3));

      await settings.setMusicCollectionDetailSongTapQueueScope(null);
      await player.playPlaylist(songs,
          reference: reference,
          audio: true,
          fromMusic: true,
          songTap: true,
          collectionDetail: true);
      expect(player.state.currentlyPlaying?.videoId, first.videoId);
      expect(player.state.videos.map((song) => song.videoId), [first.videoId]);
      expect(player.state.playQueue, isEmpty);
    });

    test('a single-song playlist tap resumes the chosen duplicate', () async {
      const reference = PlaylistReference(
          kind: PlaylistSourceKind.local,
          profileId: 'default',
          playlistId: 'local:tap-scope',
          displayTitle: 'Listening room');
      const first = Video(
          videoId: 'repeated',
          musicMetadata: MusicMetadata(title: 'Repeated', artist: 'Band'),
          formatStreams: [],
          adaptiveFormats: []);
      final songs = [
        first,
        first.copyWith(videoId: 'other'),
        first,
      ];
      final ids = assignPlaylistEntryIds(songs).map(playbackQueueId).toList();
      final loader = PlaylistLoadSession(
          playlist: Playlist(
              title: 'Listening room',
              playlistId: reference.playlistId,
              author: '',
              videoCount: 4,
              videos: [...songs, first.copyWith(videoId: 'late-song')]),
          database: db,
          reference: reference);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      expect(settings.state.musicSongTapQueueScope,
          MusicSongTapQueueScope.collection);
      await settings.setMusicSongTapQueueScope(MusicSongTapQueueScope.songOnly);
      await settings.setShuffle(true);

      await player.playPlaylist(songs,
          reference: reference,
          playlistLoader: loader,
          audio: true,
          fromMusic: true,
          startIndex: 2,
          songTap: true);
      expect(player.state.videos.map(playbackQueueId), [ids.last]);
      expect(player.state.currentQueueId, ids.last);
      expect(player.state.playedVideos, isEmpty);
      expect(player.state.playQueue, isEmpty);
      expect(player.playlistReference, reference);
      expect(player.playlistComplete, isTrue);
      expect(settings.state.playerShuffleMode, isTrue);
      await player.onProgress(const Duration(seconds: 23));
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(23, videoId: ids.last);
      await player.close();

      await settings
          .setMusicSongTapQueueScope(MusicSongTapQueueScope.collection);
      await settings.setMusicRetainShuffleOnSongTap(false);
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession(fromMusic: true);
      expect(player.state.currentQueueId, ids.last);
      expect(player.state.startAt, const Duration(seconds: 23));
      expect(player.state.videos.map(playbackQueueId), [ids.last]);
      expect(player.state.playedVideos, isEmpty);
      expect(player.state.playQueue, isEmpty);
      expect(player.playlistReference?.playlistId, reference.playlistId);
      expect(settings.state.playerShuffleMode, isTrue);
    });

    Future<void> verifyCatalogDownloadCopies({required bool selected}) async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const reference = PlaylistReference(
          kind: PlaylistSourceKind.local,
          profileId: 'default',
          playlistId: 'local:rehearsal',
          displayTitle: 'Rehearsal');
      const music = MusicMetadata(title: 'Song', artist: 'Band');
      const online = [
        Video(
            videoId: 'track-a',
            title: 'First',
            musicMetadata: music,
            formatStreams: [],
            adaptiveFormats: []),
        Video(
            videoId: 'track-b',
            title: 'Second',
            musicMetadata: music,
            formatStreams: [],
            adaptiveFormats: []),
      ];
      await player.playPlaylist(online,
          reference: reference, audio: true, fromMusic: true);
      player.seek(const Duration(seconds: 17));
      player.pause();
      final before = player.state;
      final generation = player.backendPlaybackGeneration;
      final catalog = service as _GuestService;
      catalog.requestedVideoIds.clear();
      const owned = DownloadedVideo(
          videoId: 'track-a',
          title: 'Owned file',
          accountId: 'different-account',
          storageUri: 'content://files/owned',
          musicMetadata: music,
          audioOnly: true,
          downloadComplete: true,
          lengthSeconds: 120,
          quality: 'audio');
      final accountless = owned.copyWith(
          videoId: 'track-b',
          accountId: null,
          storageUri: 'content://files/guest');
      for (final file in [owned, accountless]) {
        await db.upsertDownload(file);
      }
      final files = [accountless, owned];
      final added = selected
          ? await player.enqueueMusicSongs(online.reversed.toList(),
              next: false, downloads: files)
          : await player.addMusicDownloadsToQueue(files, isCurrent: () => true);
      expect(added, isTrue);
      final entries = player.state.videos;
      expect(entries.map((v) => v.videoId),
          ['track-a', 'track-b', 'track-b', 'track-a']);
      expect(entries.map(playbackQueueId).toSet(), hasLength(4));
      expect(entries.take(2).map((v) => v.explicitMusicDownload),
          everyElement(isNull));
      expect(entries.skip(2).map((v) => v.explicitMusicDownload),
          files.map(musicDownloadFingerprint));
      expect(player.state.playQueue,
          [...before.playQueue, ...entries.skip(2).map(playbackQueueId)]);
      expect(player.playlistReference, reference);
      expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
      expect(player.state.position, before.position);
      expect(player.state.mediaCommand, same(before.mediaCommand));
      expect(player.backendPlaybackGeneration, generation);
      for (final (entry, file) in [
        (entries[2], accountless),
        (entries[3], owned)
      ]) {
        await player.switchToVideo(entry);
        expect(player.state.currentQueueId, playbackQueueId(entry));
        final plan = await resolveAudioPlaybackSources(
            video: player.state.currentlyPlaying,
            offlineVideo: null,
            sessionId: 'download',
            isCurrent: () => true);
        expect((plan!.sources.single as UriAudioSource).uri.toString(),
            file.storageUri);
      }
      await player.onProgress(const Duration(seconds: 31));
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(31, videoId: playbackQueueId(entries.last));
      await player.close();
      final wire = db.getSettings(playbackSessionSetting)!.value;
      expect(jsonDecode(wire)['version'], 4);
      expect(wire, isNot(contains('content://files/')));
      if (selected) {
        const otherAccount = Server(
            url: 'https://other-instance.example',
            id: 'switch-listener',
            authToken: 'test-session');
        await db.useServer(otherAccount);
        expect((await db.getCurrentlySelectedServer()).accountId,
            otherAccount.accountId);
      }
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.currentQueueId, playbackQueueId(entries.last));
      expect(player.state.startAt, const Duration(seconds: 31));
      expect(player.playlistReference?.playlistId, reference.playlistId);
      expect(player.state.videos.map(playbackQueueId),
          entries.map(playbackQueueId));
      expect(player.state.currentlyPlaying?.explicitMusicDownload,
          entries.last.explicitMusicDownload);
      final resumedPlan = await resolveAudioPlaybackSources(
          video: player.state.currentlyPlaying,
          offlineVideo: null,
          sessionId: 'resumed-download',
          isCurrent: () => true);
      expect((resumedPlan!.sources.single as UriAudioSource).uri.toString(),
          owned.storageUri);
      Future<void> expectMissingSource() => expectLater(
          resolveAudioPlaybackSources(
              video: entries.last,
              offlineVideo: null,
              sessionId: 'gone',
              isCurrent: () => true),
          throwsStateError);
      await db.deleteDownload(owned);
      await expectMissingSource();
      await player.close();
      await db.upsertDownload(owned.copyWith(
          accountId: null, storageUri: 'content://files/replacement'));
      await expectMissingSource();
      await db.saveSetting(SettingsValue(playbackSessionSetting, wire));
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.currentQueueId,
          anyOf(isNull, playbackQueueId(entries.last)));
      expect(player.state.isPlaying, isFalse);
      expect(catalog.requestedVideoIds, isEmpty);
    }

    test(
        'catalog playlist keeps distinct managed copies and restores saved bytes without a provider fallback',
        () => verifyCatalogDownloadCopies(selected: false));
    test(
        'Downloads selection restores its managed catalog copy after an account switch without provider fallback',
        () => verifyCatalogDownloadCopies(selected: true));

    test('progress for an explicitly added offline file stays on its profile',
        () async {
      final history = _RecordingHistoryService();
      service = history;
      const account = Server(
          url: 'https://example.test',
          id: 'listener',
          authToken: 'test-session');
      await db.useServer(account);
      const file = DownloadedVideo(
          videoId: 'saved-song',
          title: 'Saved song',
          accountId: 'other-listener',
          audioOnly: true,
          downloadComplete: true,
          lengthSeconds: 100,
          quality: 'audio',
          musicMetadata: MusicMetadata(title: 'Saved song', artist: 'Band'));
      await db.upsertDownload(file);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      expect(
          await player.addMusicDownloadsToQueue([file], isCurrent: () => true),
          isTrue);
      final watch = WatchRepository.forDatabase(db)!;
      await player.saveProgress(27);
      expect(db.getVideoProgress(file.videoId), 0.27);
      expect(watch.pending(account.accountId), isEmpty);
      expect(history.syncedAccounts, isEmpty);

      // An ordinary catalog listen on this same account can enqueue history.
      const catalog = Video(
          videoId: 'catalog-control',
          lengthSeconds: 100,
          formatStreams: [],
          adaptiveFormats: []);
      await player.playVideo([catalog], audio: true);
      await player.saveProgress(35);
      expect(watch.pending(account.accountId).map((entry) => entry.videoId),
          [catalog.videoId]);
      expect(history.syncedAccounts, contains(account.accountId));
    });

    for (final savedIsCurrent in [true, false]) {
      test(
          'mixed queue restoration checks the saved file and folder grant (managed current: $savedIsCurrent)',
          () async {
        final tracks = await openDeviceFolder();
        final library = LocalMusicLibrary.instance;
        player.audioSession = await AudioSession.instance;
        app_main.mediaHandler = MediaHandler(player);
        await player.playLocalMusic(tracks, queueTitle: 'On device');
        final before = player.state;
        final generation = player.backendPlaybackGeneration;
        const saved = DownloadedVideo(
            videoId: 'managed-song',
            title: 'Saved',
            lengthSeconds: 100,
            quality: 'audio',
            audioOnly: true,
            downloadComplete: true,
            storageUri: 'content://files/managed-song',
            musicMetadata: MusicMetadata(title: 'Saved', artist: 'Band'));
        await db.upsertDownload(saved);
        expect(
            await player
                .addMusicDownloadsToQueue([saved], isCurrent: () => true),
            isTrue);
        expect(player.state.offlineCurrentlyPlaying,
            same(before.offlineCurrentlyPlaying));
        expect(player.backendPlaybackGeneration, generation);
        final ids = [...tracks.map((v) => v.playbackId), saved.videoId];
        expect(player.state.offlineVideos.map(playbackQueueId), ids);
        final fingerprint = musicDownloadFingerprint(saved);
        expect(
            player.state.offlineVideos.last.explicitMusicDownload, fingerprint);
        if (savedIsCurrent) {
          await player.switchToOfflineVideo(player.state.offlineVideos.last);
        }
        final current =
            savedIsCurrent ? saved.videoId : tracks.first.playbackId;
        await player.onProgress(const Duration(seconds: 19));
        player.didChangeAppLifecycleState(AppLifecycleState.paused);
        await waitForSavedPosition(19, videoId: current);
        await player.close();
        final wire = db.getSettings(playbackSessionSetting)!.value;
        expect(jsonDecode(wire)['version'], 4);
        final checkpoint = PlaybackSession.decode(wire)!;
        expect(checkpoint.localSelectionId, library.selectionId);
        expect(checkpoint.offlineFingerprints, {saved.videoId: fingerprint});
        expect(wire, isNot(contains(saved.storageUri!)));
        Future<void> reopen() async {
          player = _SessionPlayer(PlayerState.init(null), settings);
          player.audioSession = await AudioSession.instance;
          app_main.mediaHandler = MediaHandler(player);
          await player.resumeSession();
        }

        await reopen();
        expect(player.state.currentQueueId, current);
        expect(player.state.offlineVideos.map(playbackQueueId), ids);
        expect(player.state.startAt, const Duration(seconds: 19));
        expect(
            player.state.offlineVideos.last.explicitMusicDownload, fingerprint);
        await player.close();

        await db.upsertDownload(saved.copyWith(
            storageUri: 'content://files/replacement',
            accountId: 'different-owner'));
        await db.saveSetting(SettingsValue(playbackSessionSetting, wire));
        await reopen();
        expect(player.state.offlineVideos.map(playbackQueueId),
            tracks.map((v) => v.playbackId));
        expect(player.state.playQueue, isNot(contains(saved.videoId)));
        if (savedIsCurrent) {
          expect(player.state.isHidden, isTrue);
          expect(player.state.offlineCurrentlyPlaying, isNull);
          expect(player.state.currentQueueId, isNull);
        } else {
          expect(player.state.currentQueueId, tracks.first.playbackId);
          expect(player.state.startAt, const Duration(seconds: 19));
        }
        await player.close();
        await db.upsertDownload(saved);
        await library.disable();
        await db.saveSetting(SettingsValue(playbackSessionSetting, wire));
        await reopen();
        if (savedIsCurrent) {
          expect(player.state.currentQueueId, saved.videoId);
          expect(
              player.state.offlineVideos.map(playbackQueueId), [saved.videoId]);
          expect(player.state.startAt, const Duration(seconds: 19));
        } else {
          expect(player.state.currentQueueId, isNull);
          expect(player.state.offlineCurrentlyPlaying, isNull);
        }
        expect((service as _GuestService).requestedVideoIds, isEmpty);
      });
    }

    test('a new mixed local queue keeps its exact private file across restart',
        () async {
      final platform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = platform);
      var readable = true;
      final deviceTracks = await openDeviceFolder(canRead: () => readable);
      const storage = MethodChannel('videre/download_storage');
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final documents = await Directory.systemTemp.createTemp(
        'videre-mixed-local-queue-',
      );
      messenger.setMockMethodCallHandler(
          pathProvider, (_) async => documents.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(storage, null);
        messenger.setMockMethodCallHandler(pathProvider, null);
        await documents.delete(recursive: true);
      });
      const download = DownloadedVideo(
        videoId: 'private-song',
        title: 'Private song',
        audioOnly: true,
        downloadComplete: true,
        lengthSeconds: 60,
        quality: 'audio',
        musicMetadata: MusicMetadata(title: 'Private song', artist: 'Band'),
      );
      final privateFile = File(await download.downloadPath);
      await privateFile.writeAsBytes([1, 2, 3]);
      await db.upsertDownload(download);
      final originalProof = 'b' * 64;
      String? fileProof = originalProof;
      messenger.setMockMethodCallHandler(storage, (call) async {
        if (call.method != 'probeMusicFiles') {
          throw MissingPluginException(call.method);
        }
        expect(call.arguments['profileId'], db.profileId);
        final files = call.arguments['files'] as List;
        expect(files.single['videoId'], download.videoId);
        return {
          if (fileProof case final proof?)
            files.single['key']: {
              'identity': proof,
              'byteLength': await privateFile.length(),
            },
        };
      });
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      final rows = [
        OnDeviceMusicEntry.device(deviceTracks.first),
        OnDeviceMusicEntry.download(download, originalProof),
        OnDeviceMusicEntry.device(deviceTracks.last),
      ];
      final ids = [
        deviceTracks.first.playbackId,
        download.videoId,
        deviceTracks.last.playbackId,
      ];
      final originalSelection = LocalMusicLibrary.instance.selectionId;
      await player.playOnDeviceMusic(rows, queueTitle: 'Local music');
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.currentQueueId, ids.first);
      expect(player.state.playQueue, ids.skip(1));

      Future<AudioPlaybackSources?> resolveCurrent() =>
          resolveAudioPlaybackSources(
              video: null,
              offlineVideo: player.state.offlineCurrentlyPlaying,
              sessionId: 'mixed-local-library',
              isCurrent: () => true);

      Future<void> expectSource(Uri uri) async {
        final plan = await resolveCurrent();
        expect((plan!.sources.single as UriAudioSource).uri, uri);
      }

      await expectSource(Uri.parse(deviceTracks.first.uri));
      final next = player.stream.firstWhere(
        (state) => state.currentQueueId == download.videoId,
      );
      player.playNext();
      await next.timeout(const Duration(seconds: 3));
      await expectSource(Uri.file(privateFile.path));
      await player.onProgress(const Duration(seconds: 21));
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(21, videoId: download.videoId);
      await player.close();
      final checkpoint = db.getSettings(playbackSessionSetting)!.value;
      final saved = PlaybackSession.decode(checkpoint)!;
      expect(saved.offlineIds, ids);
      expect(saved.localSelectionId, originalSelection);
      expect(saved.offlineFingerprints[download.videoId],
          'v2:${musicDownloadFingerprint(download)}:$originalProof');
      expect(checkpoint, isNot(contains(jsonEncode(privateFile.path))));
      expect(
          checkpoint, isNot(contains(Uri.file(privateFile.path).toString())));

      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession();
      expect(player.state.currentQueueId, download.videoId);
      expect(player.state.startAt, const Duration(seconds: 21));
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.playQueue, [ids.last]);
      await expectSource(Uri.file(privateFile.path));

      readable = false;
      await LocalMusicLibrary.instance.revalidate();
      expect(player.state.currentQueueId, download.videoId);
      expect(
          player.state.offlineVideos.map(playbackQueueId), [download.videoId]);
      expect(player.state.playQueue, isEmpty);
      await expectSource(Uri.file(privateFile.path));

      fileProof = null;
      await privateFile.delete();
      await expectLater(resolveCurrent(), throwsStateError);
      fileProof = 'c' * 64;
      await privateFile.writeAsBytes([4, 5, 6]);
      expect(
          musicDownloadFingerprint(db.getDownloadByVideoId(download.videoId)!),
          musicDownloadFingerprint(download));
      await expectLater(resolveCurrent(), throwsStateError);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('music hydration preserves catalog identity and restored resume time',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const music =
          MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
      const track = Video(videoId: 'song', title: 'Song', musicMetadata: music);
      await db.saveProgress(Progress(0.5, 'song'));
      await player.playVideo([track], audio: true, startAt: Duration.zero);
      expect(player.state.currentlyPlaying!.musicMetadata, music);
      expect(player.state.currentlyPlaying!.title, 'Song');
      expect(player.state.currentlyPlaying!.author, 'Artist');
      expect(player.state.startAt, Duration.zero);
      await waitForSavedPosition(0, videoId: 'song');

      const session = PlaybackSession(
          videos: [track], currentId: 'song', seconds: 37, audio: true);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
      await player.resumeSession();
      expect(player.state.startAt, const Duration(seconds: 37));
      expect(player.state.currentlyPlaying!.musicMetadata!.album, 'Album');
    });

    for (final legacy in [true, false]) {
      test(
          'explicit Music resume honors known or legacy origins (legacy=$legacy)',
          () async {
        player.audioSession = await AudioSession.instance;
        app_main.mediaHandler = MediaHandler(player);
        const song = Video(
            videoId: 'same-recording',
            musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
        final session = PlaybackSession(
            videos: const [song],
            currentId: song.videoId,
            seconds: 14,
            audio: true,
            musicHistoryEntries: legacy ? null : const {});
        await db.saveSetting(
            SettingsValue(playbackSessionSetting, session.encode()));
        player.restoreSession();
        expect(db.getLocalHistory(), isEmpty);
        await player.resumeSession(fromMusic: true);
        player.reportDecoderPlay();
        if (legacy) {
          await waitForMusicEvents(
              MusicListeningHistory.forProfile(db, db.profileId), 1);
        } else {
          await flushPlaybackWrites();
        }
        expect(
            db
                .getPlaybackHistory(PlaybackHistoryOrigin.music)
                .map((v) => v.videoId),
            legacy ? [song.videoId] : isEmpty);
        expect(
            db
                .getPlaybackHistory(PlaybackHistoryOrigin.video)
                .map((v) => v.videoId),
            legacy ? isEmpty : [song.videoId]);
      });
    }

    test(
        'history follows where each queue entry was opened, including on retry',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const song = Video(
          videoId: 'same-recording',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      const music = PlaybackHistoryOrigin.music;
      const video = PlaybackHistoryOrigin.video;
      final listening = MusicListeningHistory.forProfile(db, db.profileId);
      // An audio-only watch from Videos can have Music metadata too.
      await player.playVideo([song], audio: true);
      player.reportDecoderPlay();
      await flushPlaybackWrites();
      expect(db.getPlaybackHistory(video).single.videoId, song.videoId);
      expect(db.getPlaybackHistory(music), isEmpty);
      expect(await player.enqueueMusicSongs([song], next: true), isTrue);
      await player.skipToVideo(1);
      player.reportDecoderPlay();
      await waitForMusicEvents(listening, 1);
      expect(db.getPlaybackHistory(music).single.videoId, song.videoId);
      await db.clearPlaybackHistory(music);
      await player.retryCurrentVideo();
      player.reportDecoderPlay();
      await flushPlaybackWrites();
      expect(db.getPlaybackHistory(music), isEmpty);
      expect(db.getPlaybackHistory(video).single.videoId, song.videoId);
      await player.playVideo([song], fromMusic: true, audio: true);
      player.reportDecoderPlay();
      await waitForMusicEvents(listening, 1);
      expect(db.getPlaybackHistory(music).single.videoId, song.videoId);
      await waitForSavedPosition(0, videoId: song.videoId);
      expect(player.savedSession!.musicHistoryEntries, {song.videoId});
    });

    for (final playNext in [true, false]) {
      test(
          'queueing the active Music upload from Video retains both origins (play next: $playNext)',
          () async {
        player.audioSession = await AudioSession.instance;
        app_main.mediaHandler = MediaHandler(player);
        const song = Video(
            videoId: 'shared-song',
            musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
        await player.playVideo([song], fromMusic: true, audio: true);
        player.reportDecoderPlay();
        final listening = MusicListeningHistory.forProfile(db, db.profileId);
        await waitForMusicEvents(listening, 1);
        const watch = Video(videoId: 'shared-song');
        for (var attempt = 0; attempt < 2; attempt++) {
          if (playNext) {
            player.playVideoNext(watch);
          } else {
            player.queueVideos([watch]);
          }
        }
        final ids = player.state.videos.map(playbackQueueId).toList();
        expect(ids, hasLength(2));
        expect(ids.toSet(), hasLength(2));
        expect(player.state.currentQueueId, ids.first);
        expect(player.state.playQueue, orderedEquals([ids.last]));

        final database = db as SembastSqfDb;
        await database.settingsStore
            .record(playbackSessionSetting)
            .onSnapshot(database.db)
            .firstWhere((snapshot) =>
                PlaybackSession.decode(snapshot?.value['value'] as String?)
                    ?.next
                    .contains(ids.last) ==
                true)
            .timeout(const Duration(seconds: 5));
        expect(player.savedSession!.musicHistoryEntries, {ids.first});
        await player.resumeSession();
        player.reportDecoderPlay();
        await waitForMusicEvents(listening, 2);
        expect(player.state.currentQueueId, ids.first);
        expect(db.getPlaybackHistory(PlaybackHistoryOrigin.video), isEmpty);
        await player.skipToVideo(1);
        expect(player.state.currentQueueId, ids.last);
        expect(
            db.getPlaybackHistory(PlaybackHistoryOrigin.video).single.videoId,
            song.videoId);
        expect(
            db.getPlaybackHistory(PlaybackHistoryOrigin.music).single.videoId,
            song.videoId);
      });
    }

    test(
        'deleting a song while playback is loading fences its pending history write',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      final api = service as _GuestService;
      const song = Video(
          videoId: 'slow',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      const music = PlaybackHistoryOrigin.music;
      final listening = MusicListeningHistory.forProfile(db, db.profileId);
      await player.playVideo([song], audio: true, fromMusic: true);
      player.reportDecoderPlay();
      await waitForMusicEvents(listening, 1);
      expect(db.getPlaybackHistory(music).single.videoId, song.videoId);
      api.metadataRequested = Completer<void>();
      api.releaseMetadata = Completer<void>();
      final replay = player.playVideo([song], audio: true, fromMusic: true);
      await api.metadataRequested!.future.timeout(const Duration(seconds: 3));
      await db.deletePlaybackHistory(music, song.videoId);
      api.releaseMetadata!.complete();
      await replay;
      player.reportDecoderPlay();
      await flushPlaybackWrites();
      expect(db.getPlaybackHistory(music), isEmpty);
      await player.playVideo([song], audio: true, fromMusic: true);
      player.reportDecoderPlay();
      await waitForMusicEvents(listening, 1);
      expect(db.getPlaybackHistory(music).single.videoId, song.videoId);
    });

    test('Music records one event per started play and honors recording pause',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const song = Video(
          videoId: 'history-song',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      final listening = MusicListeningHistory.forProfile(db, db.profileId);

      Future<void> selectSong() =>
          player.playVideo([song], audio: true, fromMusic: true);

      await selectSong();
      player.setEvent(const MediaEvent(
          state: MediaState.buffering, type: MediaEventType.play));
      await flushPlaybackWrites();
      expect(listening.events(), isEmpty);
      player.reportDecoderPlay();
      player.reportDecoderPlay();
      await waitForMusicEvents(listening, 1);

      player.pause();
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      player.play();
      player.reportDecoderPlay();
      await player.retryCurrentVideo();
      player.reportDecoderPlay();
      await flushPlaybackWrites();
      expect(listening.events(trackId: song.videoId), hasLength(1));

      await listening.setRecordingPaused(true);
      expect(listening.recordingPaused, isTrue);
      await selectSong();
      player.reportDecoderPlay();
      await flushPlaybackWrites();
      expect(player.state.isPlaying, isTrue);
      expect(listening.events(trackId: song.videoId), hasLength(1));

      await listening.setRecordingPaused(false);
      player.pause();
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      player.play();
      player.reportDecoderPlay();
      await flushPlaybackWrites();
      expect(listening.events(trackId: song.videoId), hasLength(1));

      await selectSong();
      player.reportDecoderPlay();
      await waitForMusicEvents(listening, 2);
      expect(listening.events(trackId: song.videoId), hasLength(2));
    });

    test('Music history ranks fully heard short songs above a skipped song',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const metadata = MusicMetadata(title: 'Song', artist: 'Artist');
      const longSong =
          Video(videoId: 'long', lengthSeconds: 600, musicMetadata: metadata);
      const shortSong =
          Video(videoId: 'short', lengthSeconds: 4, musicMetadata: metadata);
      const lastSong =
          Video(videoId: 'last', lengthSeconds: 5, musicMetadata: metadata);
      final history = MusicListeningHistory.forProfile(db, db.profileId);

      await player.playVideo([longSong, shortSong, lastSong],
          audio: true, fromMusic: true);
      player.seedVideo(
          player.state.currentlyPlaying!.copyWith(lengthSeconds: 600));
      player.reportDecoderPlay();
      samplePlayback(0, 0);
      samplePlayback(1, 1);
      player.seek(const Duration(seconds: 500));
      samplePlayback(2, 500);
      player.pause();
      samplePlayback(302, 500);
      player.play();
      player.reportDecoderPlay();
      samplePlayback(303, 500);
      samplePlayback(304, 501);

      await player.skipToVideo(1);
      player.reportDecoderPlay();
      samplePlayback(305, 0);
      samplePlayback(309, 4);

      await player.skipToVideo(2);
      player.reportDecoderPlay();
      samplePlayback(310, 0);
      samplePlayback(315, 5);
      player.setEvent(const MediaEvent(state: MediaState.completed));

      await player.close();
      expect(history.events(), hasLength(3));
      expect(history.listenedTimeByTrack(), {
        'long': const Duration(seconds: 2),
        'short': const Duration(seconds: 4),
        'last': const Duration(seconds: 5),
      });
    });

    test('manual replay at the end adds time to the same Music listen',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const song = Video(
          videoId: 'manual-replay',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      final history = MusicListeningHistory.forProfile(db, db.profileId);

      await player.playVideo([song], audio: true, fromMusic: true);
      player.reportDecoderPlay();
      samplePlayback(0, 0);
      samplePlayback(8, 8);
      player.setEvent(const MediaEvent(state: MediaState.completed));

      player.play();
      player.reportDecoderPlay();
      samplePlayback(30, 0);
      samplePlayback(38, 8);
      await player.close();

      expect(history.events().single.elapsed, const Duration(seconds: 16));
    });

    test('pausing Music history cancels elapsed writes for the active listen',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const song = Video(
          videoId: 'elapsed-privacy',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      final history = MusicListeningHistory.forProfile(db, db.profileId);

      await player.playVideo([song], audio: true, fromMusic: true);
      player.reportDecoderPlay();
      await waitForMusicEvents(history, 1);
      samplePlayback(0, 0);
      samplePlayback(10, 10);

      await history.setRecordingPaused(true);
      samplePlayback(20, 20);
      await history.setRecordingPaused(false);
      samplePlayback(30, 30);
      await player.close();

      expect(history.events().single.elapsed, Duration.zero);
    });

    test('restoring a repeated final song retains its occurrence and real ID',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const music = MusicMetadata(title: 'Song', artist: 'Artist');
      final videos = assignPlaybackQueueIds(const [
        Video(videoId: 'song', musicMetadata: music),
        Video(videoId: 'middle', musicMetadata: music),
        Video(videoId: 'song', musicMetadata: music),
      ]);
      final keys = videos.map(playbackQueueId).toList();
      final session = PlaybackSession(
          videos: videos,
          currentId: keys[2],
          seconds: 37,
          audio: true,
          played: keys.take(2).toList());
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
      await player.resumeSession();
      expect(player.state.currentQueueId, keys[2]);
      expect(player.currentIndex, 2);
      expect(player.state.startAt, const Duration(seconds: 37));
      expect(player.state.playedVideos, keys.take(2));
      expect(player.state.playQueue, isEmpty);
      expect((service as _GuestService).requestedVideoIds, ['song']);
      expect((await player.getMediaItem(2))?.id, 'song');
      await waitForSavedPosition(37, videoId: keys[2]);
      final saved = player.savedSession!;
      expect(saved.currentId, keys[2]);
      expect(saved.videos.map(playbackQueueId), keys);
      expect(saved.videos.map((video) => video.videoId),
          ['song', 'middle', 'song']);
    });

    test('advancing a music queue starts the song instead of its watch history',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const music = MusicMetadata(title: 'Song', artist: 'Artist');
      const first = Video(videoId: 'first-song', musicMetadata: music);
      const second = Video(videoId: 'next-song', musicMetadata: music);
      await db.saveProgress(Progress(0.5, second.videoId));
      await player
          .playVideo([first, second], audio: true, startAt: Duration.zero);
      await player.skipToVideo(1);
      expect(player.state.currentlyPlaying!.videoId, second.videoId);
      expect(player.state.startAt, Duration.zero);
      expect((player.state.mediaCommand!.value as SwitchVideoValue).startAt,
          Duration.zero);
    });

    test('saved songs default to audio while explicit video mode is respected',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const song = Video(
          videoId: 'song',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      await player.playVideo([song]);
      expect(player.state.isAudio, isTrue);
      await player.playVideo([song], audio: false);
      expect(player.state.isAudio, isFalse);
      await player.playVideo([const Video(videoId: 'video')]);
      expect(player.state.isAudio, isFalse);
    });

    test('music metadata failure keeps the selected queue visible for retry',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      (service as _GuestService).metadataFails = true;
      const song = Video(
          videoId: 'song',
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      await player.playVideo([song], audio: true);
      expect(player.state.currentlyPlaying, song);
      expect(player.state.videos, [song]);
      expect(player.state.isHidden, isFalse);
      expect(player.state.isClosing, isFalse);
      expect(player.state.mediaEvent.state, MediaState.error);
      (service as _GuestService).metadataFails = false;
      await player.switchToVideo(song);
      expect(player.state.currentlyPlaying!.musicMetadata!.title, 'Song');
      expect(player.state.mediaEvent.state, isNot(MediaState.error));
    });

    for (final requested in [Duration.zero, const Duration(seconds: 37)]) {
      test('failed song retains requested $requested for visible Retry',
          () async {
        player.audioSession = await AudioSession.instance;
        app_main.mediaHandler = MediaHandler(player);
        player.seedState(player.state.copyWith(
            position: const Duration(minutes: 4, seconds: 13),
            currentlyPlaying: const Video(videoId: 'previous-video')));
        (service as _GuestService).metadataFails = true;
        const song = Video(
            videoId: 'song',
            lengthSeconds: 253,
            musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
        await player.playVideo([song], audio: true, startAt: requested);
        expect(player.state.mediaEvent.state, MediaState.error);
        expect(player.state.position, requested);
        expect(player.state.startAt, requested);

        (service as _GuestService).metadataFails = false;
        // Match the position passed by MusicPlayer's visible Retry button.
        await player.switchToVideo(player.state.currentlyPlaying!,
            startAt: player.state.position);
        expect(player.state.startAt, requested);
      });
    }

    test(
        'downloaded song selection starts over and forwards explicit resume to its decoder',
        () async {
      final previousTv = app_main.isTv;
      app_main.isTv = true;
      addTearDown(() => app_main.isTv = previousTv);
      player.audioSession = await AudioSession.instance;
      const song = DownloadedVideo(
          videoId: 'offline-song',
          title: 'Song',
          lengthSeconds: 180,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true,
          musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
      await db.saveProgress(Progress(0.5, song.videoId));
      await player.switchToOfflineVideo(song);
      expect(player.state.startAt, Duration.zero);
      final decoder =
          _AudioStartRecorder(const AudioPlayerState(), player, settings);
      addTearDown(decoder.close);
      decoder.switchToOfflineVideo(song);
      expect(decoder.startedAt, Duration.zero);
      player.seedAudioStart(const Duration(seconds: 37));
      decoder.switchToOfflineVideo(song);
      expect(decoder.startedAt, const Duration(seconds: 37));
    });

    test(
        'explicit download playback records a locally replayable history entry',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const saved = DownloadedVideo(
          videoId: 'owned',
          title: 'Owned audio',
          accountId: 'owner',
          lengthSeconds: 120,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true);
      await db.upsertDownload(saved);
      await player.playOfflineVideos([saved]);
      final entry = db.getPlaybackHistory(PlaybackHistoryOrigin.video).single;
      expect(entry.replayDownload(db), saved);
      await db.upsertDownload(saved.copyWith(accountId: 'another-owner'));
      expect(entry.replayDownload(db), isNull);
    });

    test('TV restores the chosen mode for music and ordinary video sessions',
        () async {
      final previousTv = app_main.isTv;
      app_main.isTv = true;
      addTearDown(() => app_main.isTv = previousTv);
      const music = MusicMetadata(title: 'Song', artist: 'Artist');
      for (final isMusic in [true, false]) {
        for (final audio in [true, false]) {
          final track =
              Video(videoId: 'song', musicMetadata: isMusic ? music : null);
          final session = PlaybackSession(
              videos: [track], currentId: 'song', seconds: 37, audio: audio);
          await db.saveSetting(
              SettingsValue(playbackSessionSetting, session.encode()));
          player.restoreSession();
          expect(player.state.isAudio, audio);
          expect(player.state.startAt, const Duration(seconds: 37));
        }
      }
      const offline = DownloadedVideo(
          videoId: 'offline-song',
          title: 'Song',
          lengthSeconds: 120,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true,
          musicMetadata: music);
      await db.upsertDownload(offline);
      const session = PlaybackSession(
          offlineIds: ['offline-song'],
          currentId: 'offline-song',
          seconds: 48,
          audio: true);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
      player.restoreSession();
      expect(player.state.isAudio, isTrue);
      expect(player.state.offlineVideos.single.musicMetadata!.toJson(),
          music.toJson());
      expect(player.state.startAt, const Duration(seconds: 48));
    });

    test(
        'music pause and background preserve queue metadata and exact position',
        () async {
      const music =
          MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
      const songs = [
        Video(videoId: 'first-song', lengthSeconds: 180, musicMetadata: music),
        Video(videoId: 'next-song', musicMetadata: music)
      ];
      player.seedState(PlayerState.init(songs).copyWith(
          currentlyPlaying: songs.first, isAudio: true, isHidden: false));
      await player.onProgress(const Duration(seconds: 37));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(37, videoId: 'first-song');
      expect(player.savedSession!.videos.map((v) => v.videoId),
          ['first-song', 'next-song']);
      expect(player.savedSession!.videos.first.musicMetadata!.album, 'Album');
      expect(player.savedSession!.audio, isTrue);
      expect(player.state.currentlyPlaying!.videoId, 'first-song');
      expect(player.state.isClosing, isFalse);
    });

    test('a sorted download queue resumes the same files and sorted Next',
        () async {
      DownloadedVideo savedSong(String id, String title) => DownloadedVideo(
            videoId: id,
            title: title,
            lengthSeconds: 120,
            quality: 'audio',
            storageUri: 'content://files/$id',
            downloadComplete: true,
            audioOnly: true,
            musicMetadata: MusicMetadata(title: title, artist: 'Artist'),
          );
      final files = [
        savedSong('heard', 'Heard'),
        savedSong('current', 'Current'),
        savedSong('zulu', 'Zulu'),
        savedSong('repeat', 'Repeat'),
        savedSong('alpha', 'Alpha'),
      ];
      for (final file in files) {
        await db.upsertDownload(file);
      }
      await settings.setShuffle(true);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      expect(
          await player.addMusicDownloadsToQueue(files, isCurrent: () => true),
          isTrue);
      await player.selectQueueOccurrence('current');
      final repeated = player.state.offlineVideos[3];
      expect(await player.enqueueOfflineMusicCopies([repeated], next: false),
          isTrue);
      final copy = playbackQueueId(player.state.offlineVideos.last);
      expect(copy, isNot(repeated.videoId));
      expect(player.state.playQueue, ['zulu', 'repeat', 'alpha', copy]);
      final before = player.state;
      final generation = player.backendPlaybackGeneration;

      player.sortMusicQueueUpcoming(MusicQueueSort.titleAscending);

      final expected = ['alpha', 'repeat', copy, 'zulu'];
      expect(player.state.playQueue, expected);
      expect(player.state.offlineVideos, orderedEquals(before.offlineVideos));
      expect(player.state.offlineCurrentlyPlaying,
          same(before.offlineCurrentlyPlaying));
      expect(player.state.mediaCommand, same(before.mediaCommand));
      expect(player.backendPlaybackGeneration, generation);
      await player.onProgress(const Duration(seconds: 37));
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(37, videoId: 'current');
      await player.close();

      final saved = PlaybackSession.decode(
          db.getSettings(playbackSessionSetting)!.value)!;
      expect(saved.next, expected);
      expect(saved.offlineIds, before.offlineVideos.map(playbackQueueId));
      expect(saved.offlineFingerprints, {
        for (final file in files) file.videoId: musicDownloadFingerprint(file),
        copy: musicDownloadFingerprint(files[3]),
      });

      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.resumeSession(fromMusic: true);
      final restored = player.state;
      expect(restored.currentQueueId, 'current');
      expect(restored.startAt, const Duration(seconds: 37));
      expect(restored.playedVideos, ['heard']);
      expect(restored.playQueue, expected);
      expect(restored.offlineVideos.map(playbackQueueId), saved.offlineIds);
      for (final entry in restored.offlineVideos) {
        final plan = await resolveAudioPlaybackSources(
            video: null,
            offlineVideo: entry,
            sessionId: 'sorted-download',
            isCurrent: () => true);
        expect(
            (plan!.sources.single as UriAudioSource).uri.toString(),
            files
                .singleWhere((file) => file.videoId == entry.videoId)
                .storageUri);
      }

      final advanced =
          player.stream.firstWhere((s) => s.currentQueueId == 'alpha');
      player.playNext();
      final next = await advanced.timeout(const Duration(seconds: 2));
      expect(next.playedVideos, ['heard', 'current']);
      expect(next.playQueue, expected.skip(1));
      expect(next.offlineCurrentlyPlaying?.storageUri, files.last.storageUri);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test(
        'restores the exact repeated download with its saved position and queue order',
        () async {
      const first = DownloadedVideo(
          videoId: 'music-a',
          title: 'A',
          lengthSeconds: 100,
          quality: 'audio',
          downloadComplete: true,
          audioOnly: true,
          musicMetadata: MusicMetadata(title: 'A', artist: 'Artist'));
      final middle = first.copyWith(videoId: 'music-b', title: 'B');
      final last = first.copyWith(videoId: 'music-c', title: 'C');
      for (final file in [first, middle, last]) {
        await db.upsertDownload(file);
      }
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playOfflineVideos([first, middle, first, last],
          startIndex: 2, fromMusic: true);
      final ids = player.state.offlineVideos.map(playbackQueueId).toList();
      expect(ids, hasLength(4));
      expect(ids.toSet(), hasLength(4));
      expect(player.state.currentQueueId, ids[2]);
      expect(player.state.offlineCurrentlyPlaying?.videoId, first.videoId);
      await player.onProgress(const Duration(seconds: 37));
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await waitForSavedPosition(37, videoId: ids[2]);
      await player.close();
      final wire = db.getSettings(playbackSessionSetting)!.value;
      expect(jsonDecode(wire)['version'], 3);
      final saved = PlaybackSession.decode(wire)!;
      expect(saved.offlineIds, ids);
      expect(saved.currentId, ids[2]);
      expect(saved.played, ids.take(2));
      expect(saved.next, [ids.last]);
      expect(db.getVideoProgress(first.videoId), closeTo(0.37, 0.0001));
      expect(db.getVideoProgress(ids[2]), 0);

      final updated = first.copyWith(storageUri: 'content://music/refreshed-a');
      await db.upsertDownload(updated);
      player = _SessionPlayer(PlayerState.init(null), settings);
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      player.restoreSession();
      expect(player.state.isHidden, isTrue);
      expect(player.state.offlineCurrentlyPlaying, isNull);
      expect(player.state.offlineVideos.map(playbackQueueId), ids);
      expect(player.state.offlineVideos.map((v) => v.videoId),
          [first.videoId, middle.videoId, first.videoId, last.videoId]);
      await player.resumeSession(fromMusic: true);
      expect(player.state.currentQueueId, ids[2]);
      expect(player.currentIndex, 2);
      expect(player.state.startAt, const Duration(seconds: 37));
      expect(
          player.state.offlineCurrentlyPlaying!.storageUri, updated.storageUri);
      expect(player.state.playedVideos, ids.take(2));
      expect(player.state.playQueue, [ids.last]);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test(
        'missing repeated download cannot resume a different file at its timestamp',
        () async {
      const missing = DownloadedVideo(
          videoId: 'missing',
          title: 'Missing',
          lengthSeconds: 100,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true,
          musicMetadata: MusicMetadata(title: 'Missing', artist: 'Artist'));
      final other = missing.copyWith(videoId: 'remaining', title: 'Remaining');
      await db.upsertDownload(other);
      final ids = assignDownloadedQueueIds([missing, other, missing])
          .map(playbackQueueId)
          .toList();
      final saved = PlaybackSession(
          offlineIds: ids,
          currentId: ids.last,
          played: ids.take(2).toList(),
          seconds: 47,
          audio: true);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, saved.encode()));
      player.restoreSession();
      await player.resumeSession(fromMusic: true);
      expect(player.state.isHidden, isTrue);
      expect(player.state.currentQueueId, isNull);
      expect(player.state.offlineCurrentlyPlaying, isNull);
      expect(db.getVideoProgress(other.videoId), 0);
      expect((service as _GuestService).requestedVideoIds, isEmpty);
    });

    test('ignores deleted or unfinished downloads when restoring a v2 session',
        () async {
      await db.upsertDownload(const DownloadedVideo(
          videoId: 'a',
          title: 'A',
          lengthSeconds: 100,
          quality: 'audio',
          downloadComplete: true));
      await db.upsertDownload(const DownloadedVideo(
          videoId: 'b', title: 'B', lengthSeconds: 100, quality: 'audio'));
      final v2 = jsonEncode({
        'version': 2,
        'videos': [],
        'offlineIds': ['a', 'b', 'deleted'],
        'currentId': 'a',
        'seconds': 17,
        'next': ['b', 'deleted'],
        'audio': false,
      });
      await db.saveSetting(SettingsValue(playbackSessionSetting, v2));
      player.restoreSession();
      expect(player.state.offlineVideos.map((v) => v.videoId), ['a']);
      expect(player.state.playQueue, isEmpty);
      expect(player.state.hasVideo, isFalse);
    });

    test('a queued managed song opens its updated document after renaming',
        () async {
      const original = DownloadedVideo(
          videoId: 'managed-song',
          title: 'Song',
          lengthSeconds: 100,
          quality: 'audio',
          downloadComplete: true,
          audioOnly: true,
          folderUri: 'content://provider/tree/music',
          storageUri: 'content://provider/tree/music/document/original');
      const renamed = 'content://provider/tree/music/document/renamed';
      await db.upsertDownload(original.copyWith(storageUri: renamed));

      final plan = await resolveAudioPlaybackSources(
          video: null,
          offlineVideo: original,
          sessionId: 'managed-rename',
          isCurrent: () => true);
      expect((plan!.sources.single as UriAudioSource).uri.toString(), renamed);
    });

    test('offline progress is available to resume after restarting', () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      await player.saveProgress(35);
      expect(db.getVideoProgress('a'), 0.35);
      await player.saveProgress(99);
      expect(db.getVideoProgress('a'), 1);
    });

    test(
        'manual unwatched survives progress and session callbacks from old playback',
        () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      await player.onProgress(const Duration(seconds: 94));
      final repository = WatchRepository(db as SembastSqfDb);
      await repository.mark('a', false);
      await player.onProgress(const Duration(seconds: 97));
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(db.getVideoProgress('a'), 0);
      expect(repository.isWatched('a'), isFalse);
      expect(player.savedSession?.seconds, 0);
    });

    test(
        'switching people preserves old queue and restores the new queue silently',
        () async {
      final database = db as SembastSqfDb;
      final oldDatabase = database.forProfile(database.profileId);
      final other = await database.createProfile('Another person');
      await database.forProfile(other.id).saveSetting(SettingsValue(
          playbackSessionSetting,
          const PlaybackSession(
                  videos: [Video(videoId: 'new')],
                  currentId: 'new',
                  seconds: 12)
              .encode()));
      player.seedState(player.state.copyWith(
          currentlyPlaying: const Video(videoId: 'old', lengthSeconds: 100),
          videos: const [Video(videoId: 'old', lengthSeconds: 100)],
          position: const Duration(seconds: 37),
          isHidden: false));
      await player.saveProgress(37);
      await player.prepareForProfileSwitch();
      expect(player.state.hasVideo, isFalse);
      expect(player.state.videos, isEmpty);
      await database.useProfile(other.id);
      // A late native event while switching must not create history for the new person.
      await player.onProgress(const Duration(seconds: 99));
      await player.reloadForProfile();
      expect(player.state.videos.map((video) => video.videoId), ['new']);
      expect(player.state.hasVideo, isFalse);
      expect(player.state.isHidden, isTrue);
      expect(player.state.isPlaying, isFalse);
      expect(database.getVideoProgress('old'), 0);
      expect(oldDatabase.getVideoProgress('old'), 0.37);
      expect(
          PlaybackSession.decode(
                  oldDatabase.getSettings(playbackSessionSetting)?.value)
              ?.seconds,
          37);
    });

    test('switching people retires native metadata and awaits the decoder',
        () async {
      const video =
          Video(videoId: 'old', title: 'Old title', lengthSeconds: 100);
      player.seedState(player.state.copyWith(
          currentlyPlaying: video,
          videos: [video],
          position: const Duration(seconds: 37),
          isPlaying: true,
          isHidden: false));
      final handler = MediaHandler(player);
      const item = MediaItem(id: 'old', title: 'Old title');
      handler.mediaItem.add(item);
      handler.queue.add([item]);
      handler.playbackState.add(PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
          updatePosition: const Duration(seconds: 37),
          controls: [MediaControl.pause],
          queueIndex: 0));
      final decoder = _ProfileStopRecorder(
          const AudioPlayerState(video: video), player, settings);
      addTearDown(() async {
        if (!decoder.stopped.isCompleted) decoder.stopped.complete();
        await decoder.close();
      });

      var finished = false;
      final switching = player.prepareForProfileSwitch().then((_) {
        finished = true;
      });
      await decoder.stopRequested.future;
      await Future<void>.delayed(Duration.zero);

      expect(finished, isFalse,
          reason: 'Native stop must finish before switching.');
      expect(player.state.hasVideo, isFalse);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.idle);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls, isEmpty);
      expect(handler.playbackState.value.updatePosition, Duration.zero);
      expect(handler.playbackState.value.queueIndex, isNull);
      expect(handler.queue.value, isEmpty);
      expect(handler.mediaItem.value, isNull);

      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      await handler.play();
      expect(player.requestedPlaying, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      decoder.stopped.complete();
      await switching;
      expect(player.savedSession?.currentId, 'old');
      expect(player.savedSession?.seconds, 37);
    });

    test('pause saves the exact position between periodic checkpoints',
        () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      await player.onProgress(const Duration(seconds: 35));
      await player.onProgress(const Duration(seconds: 38));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      await waitForSavedPosition(38);
      expect(player.savedSession?.seconds, 38);
    });

    test('backgrounding saves the exact position without closing the player',
        () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      for (final (index, lifecycle) in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ].indexed) {
        final checkpoint = 35 + index * 10;
        await player.onProgress(Duration(seconds: checkpoint));
        await waitForSavedPosition(checkpoint);
        await player.onProgress(Duration(seconds: checkpoint + 3));
        player.didChangeAppLifecycleState(lifecycle);
        await waitForSavedPosition(checkpoint + 3);
        expect(player.savedSession?.seconds, checkpoint + 3,
            reason: lifecycle.name);
      }
    });

    for (final audio in [true, false]) {
      test(
          'task removal stops ${audio ? 'Music' : 'video'} and saves its queue',
          () async {
        const first = Video(videoId: 'first', lengthSeconds: 120);
        const second = Video(videoId: 'second', lengthSeconds: 90);
        player.seedState(player.state.copyWith(
            currentlyPlaying: first,
            videos: [first, second],
            isAudio: audio,
            isPlaying: true,
            isHidden: false,
            position: const Duration(seconds: 35)));
        // On TV the shared service can belong to Home while a video route
        // owns the active decoder.
        final home =
            audio ? player : _SessionPlayer(PlayerState.init(null), settings);
        if (!audio) addTearDown(home.close);
        final handler = app_main.mediaHandler = MediaHandler(home);
        const item = MediaItem(id: 'first', title: 'Playing');
        handler.mediaItem.add(item);
        handler.queue.add([item]);
        handler.playbackState.add(PlaybackState(
            playing: true, processingState: AudioProcessingState.ready));
        final decoder = _ProfileStopRecorder(
            const AudioPlayerState(video: first), player, settings);
        addTearDown(() async {
          if (!decoder.stopped.isCompleted) decoder.stopped.complete();
          await decoder.close();
        });

        player.didChangeAppLifecycleState(AppLifecycleState.paused);
        await waitForSavedPosition(35);
        expect(decoder.stopRequested.isCompleted, isFalse);
        expect(player.state.isPlaying, isTrue);
        await player.onProgress(const Duration(seconds: 37));
        final removed = handler.onTaskRemoved();
        await Future.any([removed, decoder.stopRequested.future]);
        expect(decoder.stopRequested.isCompleted, isTrue);
        expect(handler.playbackState.value.processingState,
            isNot(AudioProcessingState.idle),
            reason: 'Android can destroy the detached engine upon idle.');
        decoder.stopped.complete();
        await removed;
        expect(player.state.hasVideo, isFalse);
        expect(handler.playbackState.value.processingState,
            AudioProcessingState.idle);
        expect(handler.mediaItem.value, isNull);
        expect(handler.queue.value, isEmpty);
        expect(player.savedSession?.seconds, 37);
        expect(player.savedSession?.audio, audio);
        expect(player.savedSession?.currentId, 'first');
        expect(player.savedSession?.videos.map((video) => video.videoId),
            ['first', 'second']);
      });
    }

    for (final paused in [false, true]) {
      test('keep playing on task removal respects a pending Pause: $paused',
          () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await settings.setMusicTaskRemoval(MusicTaskRemoval.keepPlaying);
        const song = Video(
          videoId: 'first',
          lengthSeconds: 120,
          musicMetadata: MusicMetadata(title: 'First', artist: 'Band'),
        );
        player.seedState(player.state.copyWith(
          currentlyPlaying: song,
          videos: [song],
          isAudio: true,
          isPlaying: true,
          isHidden: false,
          position: const Duration(seconds: 37),
        ));
        final handler = app_main.mediaHandler = MediaHandler(player);
        const item = MediaItem(id: 'first', title: 'First');
        handler.mediaItem.add(item);
        handler.queue.add([item]);
        final playing = PlaybackState(
            playing: true, processingState: AudioProcessingState.buffering);
        handler.playbackState.add(playing);
        if (paused) await handler.pause();

        await handler.onTaskRemoved();

        expect(player.savedSession?.currentId, 'first');
        expect(player.savedSession?.seconds, 37);
        expect(player.state.hasVideo, !paused);
        expect(player.requestedPlaying, !paused);
        expect(handler.mediaItem.value, paused ? isNull : same(item));
        expect(handler.playbackState.value.processingState,
            paused ? AudioProcessingState.idle : playing.processingState);
      });
    }

    test('late task cleanup preserves a reopened player and its audio focus',
        () async {
      final focus = _RecordingAudioFocus();
      player.audioSession = focus;
      final handler = app_main.mediaHandler = MediaHandler(player);
      const old = Video(videoId: 'old', lengthSeconds: 60);
      player.seedState(player.state.copyWith(
          currentlyPlaying: old,
          videos: [old],
          isPlaying: true,
          isHidden: false));
      final decoder = _ProfileStopRecorder(
          const AudioPlayerState(video: old), player, settings);
      addTearDown(() async {
        if (!decoder.stopped.isCompleted) decoder.stopped.complete();
        await decoder.close();
      });
      final removing = handler.onTaskRemoved();
      await decoder.stopRequested.future.timeout(const Duration(seconds: 3));
      final reopened = _SessionPlayer(PlayerState.init(null), settings);
      addTearDown(reopened.close);
      reopened.audioSession = focus;
      const fresh =
          Video(videoId: 'fresh', formatStreams: [], adaptiveFormats: []);
      await reopened.playVideo([fresh]);
      await focus.setActive(true);
      expect(handler.mediaItem.value?.id, 'fresh');
      decoder.stopped.complete();
      await removing;
      expect(focus.active, isTrue);
      expect(handler.mediaItem.value?.id, 'fresh');
      expect(reopened.state.currentQueueId, 'fresh');
    });

    test('a Music selection finishing after task removal cannot start',
        () async {
      const first = Video(
          videoId: 'first',
          lengthSeconds: 120,
          formatStreams: [],
          adaptiveFormats: [],
          musicMetadata: MusicMetadata(title: 'First', artist: 'Band'));
      player.audioSession = await AudioSession.instance;
      final handler = app_main.mediaHandler = MediaHandler(player);
      await player.playVideo([first], audio: true);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      final preparer = HeldMusicPreparer();
      player.manualMusicPreparer = preparer;
      final selection = player.playVideo([first.copyWith(videoId: 'next')]);
      await preparer.started.future.timeout(const Duration(seconds: 3));

      await handler.onTaskRemoved();
      preparer.requests['next']!.complete(true);
      await selection;
      expect(player.state.hasVideo, isFalse);
      expect(player.state.isPlaying, isFalse);
      expect(handler.mediaItem.value, isNull);
      expect(player.savedSession?.currentId, 'first');
    });

    test('media controls keep startup paused after delayed autoplay', () async {
      final handler = MediaHandler(player);
      player.seedVideo(const Video(videoId: 'loading'));
      player.setEvent(const MediaEvent(state: MediaState.loading));
      await handler.pause();
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      final firstPause = player.state.mediaCommand;

      // Source setup can finish after the notification or PiP pause request.
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaCommand?.type, MediaCommandType.pause);
      expect(player.state.mediaCommand, isNot(same(firstPause)));

      await handler.play();
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(player.state.isPlaying, isTrue);
    });

    test('media controls deliver play again after the decoder pauses',
        () async {
      final handler = MediaHandler(player);
      await handler.play();
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      final firstPlay = player.state.mediaCommand;

      // A decoder event does not issue a new command through PlayerCubit.
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      expect(player.state.isPlaying, isFalse);
      await handler.play();
      expect(player.state.mediaCommand?.type, MediaCommandType.play);
      expect(player.state.mediaCommand, isNot(same(firstPlay)),
          reason: 'The player listener must receive another play command.');
    });

    test('selecting another queued video clears the previous pause', () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const first = Video(videoId: 'first');
      const second = Video(videoId: 'second');
      await player.playVideo([first, second]);
      await app_main.mediaHandler.pause();
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));

      await player.switchToVideo(second);
      expect(player.state.currentlyPlaying?.videoId, 'second');
      expect(player.state.videos.map((video) => video.videoId),
          ['first', 'second']);
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(player.state.isPlaying, isTrue);
      expect(player.state.mediaCommand?.type, MediaCommandType.switchVideo);
    });

    test('opening a video during the closing animation keeps the new video',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playVideo([const Video(videoId: 'first')]);
      player.hide();
      await player.playVideo([const Video(videoId: 'second')]);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.state.currentlyPlaying?.videoId, 'second');
      expect(player.state.isClosing, isFalse);
      expect(player.state.isHidden, isFalse);
    });

    test('a late completion cannot restart the queue after Stop', () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playVideo([
        const Video(videoId: 'first'),
        const Video(videoId: 'second'),
      ]);
      await app_main.mediaHandler.stop();
      player.switchAudio(true);
      expect(player.state.isAudio, isFalse);
      player.setEvent(const MediaEvent(state: MediaState.completed));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.state.currentlyPlaying, isNull);
      expect(player.state.isHidden, isTrue);
      expect(player.state.isClosing, isFalse);
    });

    test('remote paused intent survives loading the initial video', () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      await player.playRemoteVideo('dQw4w9WgXcQ', 23, false);
      expect(player.state.currentlyPlaying?.videoId, 'dQw4w9WgXcQ');
      expect(player.state.startAt, const Duration(seconds: 23));
      expect(player.state.mediaCommand?.type, MediaCommandType.switchVideo);

      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    });

    test('a newer pause wins over delayed remote autoplay events', () async {
      final remote = _RemoteLoadPlayer(PlayerState.init(null), settings);
      addTearDown(remote.close);
      await remote.playRemoteVideo('dQw4w9WgXcQ', 123, true);
      remote.pause();
      remote.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      final firstPause = remote.state.mediaCommand;
      remote.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(remote.state.isPlaying, isFalse);
      expect(remote.state.mediaCommand?.type, MediaCommandType.pause);
      expect(remote.state.mediaCommand, isNot(same(firstPause)));
      final secondPause = remote.state.mediaCommand;
      remote.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(remote.state.mediaCommand, isNot(same(secondPause)));
      expect(remote.state.isPlaying, isFalse);
    });

    test('a newer play overrides paused remote-load intent', () async {
      final remote = _RemoteLoadPlayer(PlayerState.init(null), settings);
      addTearDown(remote.close);
      await remote.playRemoteVideo('dQw4w9WgXcQ', 123, false);
      remote.play();
      for (var event = 0; event < 2; event++) {
        remote.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(remote.state.isPlaying, isTrue);
        expect(remote.state.mediaCommand?.type, MediaCommandType.play);
      }
    });

    test('starting local playback clears previous remote pause intent',
        () async {
      final remote = _RemoteLoadPlayer(PlayerState.init(null), settings);
      addTearDown(remote.close);
      for (final start in <Future<void> Function()>[
        () => remote.playVideo([]),
        () => remote.playOfflineVideos([]),
        remote.resumeSession,
      ]) {
        await remote.playRemoteVideo('dQw4w9WgXcQ', 123, false);
        await start();
        remote.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(remote.state.isPlaying, isTrue);
      }
    });

    test('delayed progress cannot replace a newer video session timestamp',
        () async {
      final delayed = _DelayedProgressPlayer(PlayerState.init(null), settings);
      addTearDown(delayed.close);
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'old', title: 'Old', lengthSeconds: 100, quality: 'audio'));
      final progress = delayed.onProgress(const Duration(seconds: 75));
      final newSessionSaved = waitForSavedPosition(0, videoId: 'new');
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'new', title: 'New', lengthSeconds: 100, quality: 'audio'));
      delayed.savedProgress[75]!.complete();
      await progress;
      expect(delayed.state.position, Duration.zero);
      await newSessionSaved;
      expect(delayed.savedSession?.currentId, 'new');
      expect(delayed.savedSession?.seconds, 0);
    });

    test('delayed progress safely finishes after closing the player', () async {
      final delayed = _DelayedProgressPlayer(PlayerState.init(null), settings);
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      final progress = delayed.onProgress(const Duration(seconds: 75));
      await delayed.close();
      delayed.savedProgress[75]!.complete();
      await progress;
      expect(delayed.savedSession?.seconds, 75);
    });

    test('pause and background save position while progress storage is pending',
        () async {
      for (final pause in [true, false]) {
        final delayed =
            _DelayedProgressPlayer(PlayerState.init(null), settings);
        addTearDown(() async {
          if (!delayed.isClosed) await delayed.close();
        });
        delayed.seedDownload(const DownloadedVideo(
            videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
        final checkpointSaved = waitForSavedPosition(35);
        delayed.seek(const Duration(seconds: 35));
        await checkpointSaved;
        final pausedPositionSaved = waitForSavedPosition(38);
        final progress = delayed.onProgress(const Duration(seconds: 38));
        if (pause) {
          delayed.setEvent(const MediaEvent(
              state: MediaState.playing, type: MediaEventType.pause));
        } else {
          delayed.didChangeAppLifecycleState(AppLifecycleState.paused);
        }
        await pausedPositionSaved;
        expect(delayed.state.position, const Duration(seconds: 38));
        expect(delayed.savedSession?.seconds, 38);
        delayed.savedProgress[38]!.complete();
        await progress;
        await delayed.close();
      }
    });

    test('out-of-order progress writes do not move playback backwards',
        () async {
      final delayed = _DelayedProgressPlayer(PlayerState.init(null), settings);
      addTearDown(delayed.close);
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      final older = delayed.onProgress(const Duration(seconds: 35));
      final newer = delayed.onProgress(const Duration(seconds: 38));
      delayed.savedProgress[38]!.complete();
      await newer;
      delayed.savedProgress[35]!.complete();
      await older;
      expect(delayed.state.position, const Duration(seconds: 38));
    });

    test(
        'fresh audio uses exact session time even after progress rounds to watched',
        () async {
      await db.saveProgress(Progress(1, 'a'));
      player.seedAudioStart(const Duration(seconds: 95));
      for (final offline in [false, true]) {
        final audio = _AudioStartRecorder(
            AudioPlayerState(
                video: offline
                    ? null
                    : const Video(videoId: 'a', lengthSeconds: 100),
                offlineVideo: offline
                    ? const DownloadedVideo(
                        videoId: 'a',
                        title: 'A',
                        lengthSeconds: 100,
                        quality: 'audio')
                    : null),
            player,
            settings);
        expect(audio.startedAt, const Duration(seconds: 95));
        expect(audio.startedOffline, offline);
        expect(db.getVideoProgress('a'), 1);
        await audio.close();
      }
    });

    test('switching audio publishes the current position before mounting',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const video = Video(videoId: 'a', lengthSeconds: 2000);
      await player.playVideo([video], startAt: const Duration(seconds: 1200));
      await player.onProgress(const Duration(seconds: 1309));
      player.pause();
      player.switchAudio(true);
      final audio = _AudioStartRecorder(
          const AudioPlayerState(video: video), player, settings);
      addTearDown(audio.close);
      // A newly mounted decoder must not receive the original resume point.
      final mountedAt = audio.startedAt;
      await Future<void>.delayed(Duration.zero);
      expect(mountedAt, const Duration(seconds: 1309));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(player.state.isPlaying, isFalse);

      await player.onProgress(const Duration(seconds: 1400));
      player.switchAudio(false);
      expect(player.state.startAt, const Duration(seconds: 1400));
      expect(player.state.currentlyPlaying?.videoId, 'a');
    });

    test('Watch audio choice stays with one occurrence across mode and retry',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      const first =
          Video(videoId: 'watch', queueEntryId: 'first', lengthSeconds: 100);
      const second =
          Video(videoId: 'watch', queueEntryId: 'second', lengthSeconds: 100);
      final queue = [first, second];
      await player.playVideo(queue, startAt: const Duration(seconds: 12));
      final mounted = player.state.currentlyPlaying!;
      final queueId = player.state.currentQueueId;
      const combined = 'https://instance.example/original.mp4';
      player.rememberWatchProgressiveAudio(mounted, combined, null);
      player.pause();
      player.switchAudio(true);
      expect(player.watchAudioPreferenceFor(mounted),
          (trackId: null, progressiveUrl: combined));
      player.rememberWatchAudioTrack(mounted, 'es.1');
      player.rememberWatchAudioTrack(mounted, 'en.1', explicit: false);
      player.switchAudio(false);
      player.rememberWatchProgressiveAudio(mounted, combined, 'en.1');
      expect(player.watchAudioPreferenceFor(mounted),
          (trackId: 'es.1', progressiveUrl: combined));
      expect(player.state.isPlaying, isFalse);
      expect(player.state.startAt, const Duration(seconds: 12));

      await player.retryCurrentVideo();
      final retried = player.state.currentlyPlaying!;
      expect(player.state.currentQueueId, queueId);
      expect(player.watchAudioPreferenceFor(retried),
          (trackId: 'es.1', progressiveUrl: combined));

      await player.playVideo(queue, startIndex: 1);
      expect(player.state.currentlyPlaying?.videoId, 'watch');
      expect(player.state.currentQueueId, isNot(queueId));
      expect(player.watchAudioPreferenceFor(player.state.currentlyPlaying!),
          (trackId: null, progressiveUrl: null));
      expect(player.watchAudioPreferenceFor(mounted), isNull);
    });

    test('closing an older player cannot replace the newer saved session',
        () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'old', title: 'Old', lengthSeconds: 100, quality: 'audio'));
      final next = _SessionPlayer(PlayerState.init(null), settings);
      next.seedDownload(const DownloadedVideo(
          videoId: 'new', title: 'New', lengthSeconds: 100, quality: 'audio'));
      await player.close();
      expect(next.savedSession?.currentId, 'new');
      await next.close();
      expect(
          PlaybackSession.decode(db.getSettings(playbackSessionSetting)?.value)
              ?.currentId,
          'new');
    });
  });
}
