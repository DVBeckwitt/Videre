import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart'
    show AudioProcessingState, MediaControl, MediaItem, PlaybackState;
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/song_transition.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/player/audio_playback_sources.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show UriAudioSource;
import 'package:sembast/sembast.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';
import 'held_music_preparer.dart';

class _GuestService extends Service {
  List<SponsorSegmentType>? requestedCategories;
  bool metadataFails = false;
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
    return metadataFails
        ? throw StateError('Metadata unavailable')
        : Video(videoId: id);
  }
}

class _SessionPlayer extends TestPlayerCubit {
  _SessionPlayer(super.initialState, super.settings);

  void seedState(PlayerState snapshot) => emit(snapshot);

  void seedVideo(Video video) => emit(state.copyWith(currentlyPlaying: video));

  void seedDownload(DownloadedVideo video) => emit(state.copyWith(
      offlineCurrentlyPlaying: video,
      offlineVideos: [video],
      position: Duration.zero));

  void seedAudioStart(Duration startAt) =>
      emit(state.copyWith(startAt: startAt, isAudio: true));
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
          {bool? audio, Duration? startAt, bool? playing, int? startIndex}) =>
      super.playVideo([], audio: audio, startAt: startAt, playing: playing);
}

class _DelayedProgressPlayer extends _SessionPlayer {
  _DelayedProgressPlayer(super.initialState, super.settings);

  final savedProgress = <int, Completer<void>>{};

  @override
  Future<void> saveProgress(int timeInSeconds) =>
      savedProgress.putIfAbsent(timeInSeconds, () => Completer<void>()).future;
}

Future<void> waitForSavedPosition(int seconds, {String? videoId}) async {
  final database = db as SembastSqfDb;
  await database.settingsStore
      .record(playbackSessionSetting)
      .onSnapshot(database.db)
      .firstWhere((snapshot) {
    final session = PlaybackSession.decode(snapshot?.value['value'] as String?);
    return session?.seconds == seconds &&
        (videoId == null || session?.currentId == videoId);
  }).timeout(const Duration(seconds: 5));
}

Future<List<LocalMusicTrack>> openDeviceFolder(
    {bool legacy = false,
    bool Function()? canRead,
    String? Function(String)? renamedFile}) async {
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const tree =
      'content://com.android.externalstorage.documents/tree/primary%3AMusic';
  String uri(String filename) =>
      '$tree/document/primary%3AMusic%2F${Uri.encodeComponent(filename)}';
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
        return ['First', 'Second'].map((name) {
          final originalFilename = '$name.mp3';
          final filename = renamedFile?.call(name) ?? originalFilename;
          return {
            'uri': uri(filename),
            'fileName': filename,
            if (filename != originalFilename)
              'identityUri': uri(originalFilename),
            'title': name,
            'artist': 'Local artist',
            'album': 'Local album',
            'durationMs': name == 'First' ? 0 : 60000,
          };
        }).toList();
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
  expect(library.tracks.map((track) => track.title), ['First', 'Second']);
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
  });

  test('invalid or future session data is ignored', () {
    const session = PlaybackSession(
        videos: [Video(videoId: 'a')], currentId: 'a', seconds: 20);
    final json = jsonDecode(session.encode()) as Map<String, dynamic>;
    expect(PlaybackSession.decode('broken'), isNull);
    expect(PlaybackSession.decode(null), isNull);
    expect(PlaybackSession.decode(jsonEncode({...json, 'version': 3})), isNull);
    expect(
        PlaybackSession.decode(jsonEncode({...json, 'seconds': -1})), isNull);
    expect(
        PlaybackSession.decode(jsonEncode({...json, 'currentId': 'missing'})),
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

  group('restoration', () {
    late _SessionPlayer player;
    late TestSettingsCubit settings;
    late TestAppCubit app;

    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      service = _GuestService();
      app = TestAppCubit(AppState(0, null, HomeLayout()));
      settings = TestSettingsCubit(SettingsState.init(), app);
      player = _SessionPlayer(PlayerState.init(null), settings);
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
      player.setEvent(const MediaEvent(state: MediaState.error));
      player.showMiniPlayer();
      player.setEvent(const MediaEvent(
          state: MediaState.ready,
          type: MediaEventType.speedChanged,
          value: 1.5));
      expect(player.playbackStatus, MediaState.error);
      player.setEvent(const MediaEvent(state: MediaState.loading));
      player.showBigPlayer();
      expect(player.playbackStatus, MediaState.loading);
      player.setEvent(const MediaEvent(state: MediaState.ready));
      expect(player.playbackStatus, MediaState.ready);
    });

    test('playback status cannot leak to replacement queue or profile',
        () async {
      const song = Video(videoId: 'status', queueEntryId: 'first');
      player.seedVideo(song);
      player.setEvent(const MediaEvent(state: MediaState.error));
      player.seedVideo(song.copyWith(queueEntryId: 'second'));
      expect(player.playbackStatus, MediaState.idle);
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

      expect(player.state, same(before));
      expect(player.isLocalMusicSession, isFalse);
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
      await reopened.resumeSession();

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

    test('ignores deleted or unfinished downloads when restoring', () async {
      await db.upsertDownload(const DownloadedVideo(
          videoId: 'a',
          title: 'A',
          lengthSeconds: 100,
          quality: 'audio',
          downloadComplete: true));
      await db.upsertDownload(const DownloadedVideo(
          videoId: 'b', title: 'B', lengthSeconds: 100, quality: 'audio'));
      const session = PlaybackSession(
          offlineIds: ['a', 'b', 'deleted'],
          currentId: 'a',
          seconds: 17,
          next: ['b', 'deleted']);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
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
