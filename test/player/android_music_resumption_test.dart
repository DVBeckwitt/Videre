import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/models/android_music_resumption.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

const _first = 'repeat#1';
const _second = 'repeat#2';
const _position = Duration(milliseconds: 23125);
const _recentRoot = 'system-resume-recent';
const _proof =
    '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
const _instance =
    Server(id: 'first-account', url: 'https://music.example', inUse: true);
const _download = DownloadedVideo(
  videoId: 'saved',
  title: 'Saved song',
  lengthSeconds: 120,
  quality: 'audio',
  folderUri: 'content://test.documents/tree/songs',
  storageUri: 'content://test.documents/document/saved',
  audioOnly: true,
  downloadComplete: true,
  musicMetadata: MusicMetadata(title: 'Saved song', artist: 'A'),
);

class _Player extends PlayerCubit {
  _Player(SettingsCubit settings)
      : super(PlayerState.init(null), settings, ownAudioDecoder: true);

  @override
  Future<void> onReady() async => restoreSession();

  @override
  void mapMediaEventToMediaHandler(MediaEvent event) {}
}

class _OfflineAudioPlatform extends JustAudioPlatform {
  final loaded = Completer<LoadRequest>();
  final played = Completer<void>();

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      _OfflineAudioPlayer(request.id, loaded, played);

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();

  @override
  Future<DisposePlayerResponse> disposePlayer(
          DisposePlayerRequest request) async =>
      DisposePlayerResponse();
}

class _OfflineAudioPlayer extends AudioPlayerPlatform {
  final Completer<LoadRequest> loaded;
  final Completer<void> played;

  _OfflineAudioPlayer(super.id, this.loaded, this.played);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => Stream.value(
        PlaybackEventMessage(
          processingState: ProcessingStateMessage.ready,
          updateTime: DateTime.now(),
          updatePosition: _position,
          bufferedPosition: _position,
          duration: const Duration(seconds: 120),
          icyMetadata: null,
          currentIndex: 0,
          androidAudioSessionId: null,
        ),
      );

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    if (!loaded.isCompleted) loaded.complete(request);
    return LoadResponse(duration: const Duration(seconds: 120));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (!played.isCompleted) played.complete();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
}

PlaybackSession _onlineSession() => PlaybackSession(
      videos: const [
        Video(
          videoId: 'repeat',
          queueEntryId: _first,
          musicMetadata: MusicMetadata(title: 'First occurrence', artist: 'A'),
        ),
        Video(
          videoId: 'repeat',
          queueEntryId: _second,
          musicMetadata: MusicMetadata(title: 'Second occurrence', artist: 'A'),
        ),
      ],
      currentId: _second,
      seconds: _position.inSeconds,
      positionMilliseconds: _position.inMilliseconds,
      audio: true,
      ownerProfileId: 'default',
      played: const [_first],
    );

AndroidMusicResumption _onlineSource(Server account) => AndroidMusicResumption(
      _second,
      AndroidMusicResumeSource.online,
      sha256
          .convert(utf8.encode(jsonEncode([
            account.profileId,
            account.accountId,
            account.url,
            account.gatewayEnabled,
          ])))
          .toString(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('system metadata keeps the exact occurrence and millisecond position',
      () {
    final saved = _onlineSession();
    const source = AndroidMusicResumption(
        _second, AndroidMusicResumeSource.online, _proof);
    final encoded = saved.encode(androidResumption: source);
    final decoded = PlaybackSession.decode(encoded)!;
    expect(decoded.currentId, _second);
    expect(decoded.played, [_first]);
    expect(decoded.position, _position);
    expect(decoded.ownerProfileId, 'default');
    expect(decoded.androidResumption?.toJson(), source.toJson());
    expect(PlaybackSession.decode(decoded.encode())?.androidResumption, isNull);

    final invalid = jsonDecode(encoded) as Map<String, dynamic>;
    invalid['androidResumption']['identity'] = 'https://example.com/stream';
    final manual = PlaybackSession.decode(jsonEncode(invalid))!;
    expect(manual.androidResumption, isNull);
    expect(manual.currentId, _second);
    expect(manual.position, _position);
  });

  group('dormant Android Music', () {
    late SembastSqfDb database;
    late TestAppCubit app;
    late TestSettingsCubit settings;
    late List<_Player> players;

    setUp(() async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final previousPackage = packageInfo;
      packageInfo = PackageInfo(
          appName: 'Videre',
          packageName: 'com.github.dvbeckwitt.videre',
          version: '0',
          buildNumber: '0');
      addTearDown(() {
        packageInfo = previousPackage;
        debugDefaultTargetPlatformOverride = previousPlatform;
      });
      db = database = await SembastSqfDb.createInMemory();
      await database.upsertServer(_instance);
      final selected = await database.getCurrentlySelectedServer();
      service = Service();
      app = TestAppCubit(AppState(0, selected, HomeLayout()));
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

    _Player player() {
      final controller = _Player(settings);
      players.add(controller);
      return controller;
    }

    Future<void> save(PlaybackSession session,
            [AndroidMusicResumption? source]) =>
        database.saveSetting(SettingsValue(
            playbackSessionSetting, session.encode(androidResumption: source)));

    Future<void> seedOfflineDuplicate(bool Function() available) async {
      await database.upsertDownload(_download);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('videre/download_storage');
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'probeMusicFiles');
        return available()
            ? {
                _download.videoId: {'identity': _proof, 'byteLength': 15},
              }
            : <String, Object>{};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await save(
          PlaybackSession(
            offlineIds: const ['saved', 'saved#2'],
            currentId: 'saved#2',
            seconds: _position.inSeconds,
            positionMilliseconds: _position.inMilliseconds,
            ownerProfileId: 'default',
            audio: true,
            played: const ['saved'],
          ),
          AndroidMusicResumption('saved#2', AndroidMusicResumeSource.download,
              musicDownloadFileFingerprint(_download, _proof)!));
    }

    test('browsing and ordinary startup leave the exact saved item dormant',
        () async {
      await save(_onlineSession(), _onlineSource(_instance));
      final controller = player();
      final media = MediaHandler(controller);
      expect(controller.state.hasVideo, isFalse);
      expect(controller.state.position, _position);
      final recent = (await media.getChildren(_recentRoot)).single;
      expect(recent.title, 'Second occurrence');
      expect(recent.playable, isTrue);
      expect(controller.state.hasVideo, isFalse);
      expect(media.playbackState.value.playing, isFalse);
    });

    test('Stop revokes system playback and preserves the manual queue',
        () async {
      await save(_onlineSession(), _onlineSource(_instance));
      final controller = player();
      final media = MediaHandler(controller);
      expect(await media.getChildren(_recentRoot), hasLength(1));
      await media.stop();
      expect(await media.getChildren(_recentRoot), isEmpty);
      final reopened = player();
      expect(reopened.savedSession?.androidResumption, isNull);
      expect(reopened.savedSession?.currentId, _second);
      expect(reopened.savedSession?.position, _position);
      expect(
          await reopened.resumeMusicFromAndroid(
            () async =>
                throw StateError('Stop must prevent foreground activation'),
          ),
          isFalse);
    });

    test('profile switch during cold startup invalidates the pending Play',
        () async {
      final other = await database.createProfile('Another person');
      await save(_onlineSession(), _onlineSource(_instance));
      final controller = player();
      final starting = Completer<void>();
      final foreground = Completer<bool>();
      final attempt = controller.resumeMusicFromAndroid(() {
        starting.complete();
        return foreground.future;
      });
      await starting.future;
      await controller.prepareForProfileSwitch();
      await database.useProfile(other.id);
      await controller.reloadForProfile();
      foreground.complete(true);
      expect(await attempt, isFalse);
      expect(await controller.androidRecentMusic(), isNull);
      expect(controller.state.hasVideo, isFalse);
      expect(database.forProfile('default').getSettings(playbackSessionSetting),
          isNotNull);
    });

    test('another account at the same origin cannot resume the saved item',
        () async {
      final other = _instance.copyWith(id: 'second-account');
      await database.upsertServer(other);
      await database.useServer(other);
      app.setServer(other);
      await save(_onlineSession(), _onlineSource(_instance));
      final controller = player();
      expect(await controller.androidRecentMusic(), isNull);
      expect(
          await controller.resumeMusicFromAndroid(() async => true), isFalse);
      expect(controller.state.hasVideo, isFalse);
      expect(controller.savedSession?.currentId, _second);
    });

    test('system Play loads the saved duplicate and exact offline position',
        () async {
      final previous = JustAudioPlatform.instance;
      final platform = _OfflineAudioPlatform();
      JustAudioPlatform.instance = platform;
      addTearDown(() => JustAudioPlatform.instance = previous);
      await seedOfflineDuplicate(() => true);
      final controller = player();
      controller.audioSession = await AudioSession.instance;
      final media = MediaHandler(controller);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('videre/car_media');
      var foregroundRequests = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'awaitResumeForeground') return null;
        foregroundRequests++;
        expect(platform.loaded.isCompleted, isFalse);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      expect((await media.getChildren(_recentRoot)).single.title, 'Saved song');
      expect(platform.loaded.isCompleted, isFalse);
      await media.play();
      await platform.played.future.timeout(const Duration(seconds: 5));
      final load = await platform.loaded.future;
      final playlist =
          load.audioSourceMessage as ConcatenatingAudioSourceMessage;
      final source = playlist.children.single as UriAudioSourceMessage;
      expect(source.uri, _download.storageUri);
      expect(load.initialPosition, _position);
      expect(controller.state.currentQueueId, 'saved#2');
      expect(controller.state.playedVideos, ['saved']);
      expect(foregroundRequests, 1);
    });

    test('missing offline bytes leave the saved occurrence dormant', () async {
      var available = true;
      await seedOfflineDuplicate(() => available);
      final controller = player();
      expect((await controller.androidRecentMusic())?.title, 'Saved song');
      available = false;
      expect(await controller.androidRecentMusic(), isNull);
      expect(
          await controller.resumeMusicFromAndroid(() async => true), isFalse);
      expect(controller.state.hasVideo, isFalse);
      expect(controller.savedSession?.currentId, 'saved#2');
    });
  });
}
