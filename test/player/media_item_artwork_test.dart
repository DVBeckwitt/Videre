import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/method_channel_audio_service.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _UnusedArtworkCache implements BaseCacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Content artwork must not access the file cache');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  TestPlayerCubit? player;
  const selectedServer = Server(
      url: 'https://selected.example',
      customHeaders: {'X-Instance-Access': 'selected-access'});

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(selectedServer);
    await db.useServer(selectedServer);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    await player?.close();
    player = null;
    await settings.close();
    await app.close();
    await db.close();
  });

  Video video(String thumbnail, {Server? server}) => Video(
      videoId: 'artwork-video',
      title: 'Artwork video',
      author: 'Channel',
      lengthSeconds: 42,
      videoThumbnails: [ImageObject('default', thumbnail, 320, 180)],
      backendPlayback: server == null ? null : BackendPlayback(server));

  TestPlayerCubit createPlayer(Video queued, {Video? playing}) {
    return player = TestPlayerCubit(
        PlayerState.init([queued]).copyWith(currentlyPlaying: playing),
        settings);
  }

  test('notification artwork uses the selected instance and its headers',
      () async {
    final controller =
        createPlayer(video('https://i.ytimg.com/vi/artwork-video/default.jpg'));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri,
        Uri.parse('https://selected.example/vi/artwork-video/default.jpg'));
    expect(
        item.artHeaders, selectedServer.headersForUrl(item.artUri.toString()));
    expect(item.id, 'artwork-video');
    expect(item.title, 'Artwork video');
    expect(item.artist, 'Channel');
    expect(item.duration, const Duration(seconds: 42));
  });

  test('queued artwork preserves the metadata server snapshot', () async {
    const metadataServer = Server(
        url: 'https://metadata.example',
        customHeaders: {'Cookie': 'backend=original'});
    final controller = createPlayer(
        video('https://yt3.ggpht.com/avatar=s88', server: metadataServer));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, Uri.parse('https://metadata.example/ggpht/avatar=s88'));
    expect(
        item.artHeaders, metadataServer.headersForUrl(item.artUri.toString()));
  });

  test('active artwork uses the recovered backend headers', () async {
    const queuedServer = Server(
        url: 'https://selected.example',
        customHeaders: {'Cookie': 'backend=original'});
    const recoveredServer = Server(
        url: 'https://selected.example',
        customHeaders: {'Cookie': 'backend=recovered'});
    final controller = createPlayer(
        video('/vi/artwork-video/default.jpg', server: queuedServer),
        playing:
            video('/vi/artwork-video/default.jpg', server: recoveredServer));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri,
        Uri.parse('https://selected.example/vi/artwork-video/default.jpg'));
    expect(
        item.artHeaders, recoveredServer.headersForUrl(item.artUri.toString()));
  });

  test('unrelated external artwork never receives instance headers', () async {
    const imageUrl = 'https://cdn.example/artwork.jpg';
    final controller = createPlayer(video(imageUrl));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, Uri.parse(imageUrl));
    expect(item.artHeaders, isNull);
  });

  test('missing artwork does not become an empty network request', () async {
    final controller = createPlayer(const Video(videoId: 'without-artwork'));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });

  test('music notification uses the original cover without instance access',
      () async {
    const cover = 'https://lh3.googleusercontent.com/cover';
    final music = MusicMetadata(
        title: 'Song',
        artist: 'Singer',
        album: 'Album',
        thumbnails: [ImageObject(null, cover, 500, 500)]);
    final controller = createPlayer(
        video('/vi/artwork-video/default.jpg').copyWith(musicMetadata: music));
    final item = (await controller.getMediaItem(0))!;
    expect(item.title, 'Song');
    expect(item.artist, 'Singer');
    expect(item.album, 'Album');
    expect(item.artUri, Uri.parse(cover));
    expect(item.artHeaders, isNull);

    await db.deleteServerById(selectedServer);
    expect((await controller.getMediaItem(0))!.artUri, item.artUri);
  });

  test('music notification without a cover keeps the instance video thumbnail',
      () async {
    const music = MusicMetadata(title: 'Song', artist: 'Singer');
    final controller = createPlayer(
        video('https://i.ytimg.com/vi/artwork-video/default.jpg')
            .copyWith(musicMetadata: music));
    final item = (await controller.getMediaItem(0))!;
    expect(item.artUri,
        Uri.parse('https://selected.example/vi/artwork-video/default.jpg'));
    expect(
        item.artHeaders, selectedServer.headersForUrl(item.artUri.toString()));
  });

  test('downloaded music notifications retain album and artist offline',
      () async {
    final documents =
        await Directory.systemTemp.createTemp('videre-music-art-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => documents.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await documents.delete(recursive: true);
    });
    const downloaded = DownloadedVideo(
        videoId: 'song',
        title: 'Upload',
        author: 'Channel',
        lengthSeconds: 180,
        quality: 'audio',
        audioOnly: true,
        musicMetadata:
            MusicMetadata(title: 'Song', artist: 'Singer', album: 'Album'));
    final controller = player = TestPlayerCubit(
        PlayerState.init(null).copyWith(
            offlineVideos: [downloaded], offlineCurrentlyPlaying: downloaded),
        settings);
    final item = (await controller.getMediaItem(0))!;
    expect(item.title, 'Song');
    expect(item.artist, 'Singer');
    expect(item.album, 'Album');
    expect(item.artUri!.scheme, 'file');
  });

  test('malformed artwork does not prevent notification metadata', () async {
    final controller = createPlayer(video('https://[invalid'));

    final item = (await controller.getMediaItem(0))!;

    expect(item.id, 'artwork-video');
    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });

  test('switching people clears native metadata while the session stays idle',
      () async {
    const client = MethodChannel('com.ryanheise.audio_service.client.methods');
    const native = MethodChannel('com.ryanheise.audio_service.handler.methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = StreamController<MethodCall>.broadcast();
    Map<Object?, Object?>? nativeState;
    Map<Object?, Object?>? nativeItem;
    Map<Object?, Object?>? stateAtClear;
    List<Object?>? nativeQueue;
    messenger.setMockMethodCallHandler(client, (_) async => null);
    messenger.setMockMethodCallHandler(native, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      if (call.method == 'setState') {
        nativeState = arguments['state'] as Map<Object?, Object?>;
      } else if (call.method == 'setMediaItem') {
        nativeItem = arguments['mediaItem'] as Map<Object?, Object?>;
        if (nativeItem?['id'] == '') stateAtClear = nativeState;
      } else if (call.method == 'setQueue') {
        nativeQueue = arguments['queue'] as List<Object?>;
      }
      calls.add(call);
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(client, null);
      messenger.setMockMethodCallHandler(native, null);
      await calls.close();
    });
    Future<MethodCall> waitForCall(
            String method, bool Function(MethodCall) matches) =>
        calls.stream
            .firstWhere((call) => call.method == method && matches(call))
            .timeout(const Duration(seconds: 5));

    final controller = createPlayer(const Video(videoId: 'private-video'));
    AudioServicePlatform.instance = MethodChannelAudioService();
    final handler = await AudioService.init(
        builder: () => MediaHandler(controller),
        cacheManager: _UnusedArtworkCache());
    final started = waitForCall(
        'setState', (call) => call.arguments['state']['playing'] == true);
    final titled = waitForCall('setMediaItem',
        (call) => call.arguments['mediaItem']['id'] == 'private-video');
    final queued = waitForCall(
        'setQueue', (call) => (call.arguments['queue'] as List).isNotEmpty);
    final privateItem = MediaItem(
        id: 'private-video',
        title: 'Private title',
        artist: 'Private author',
        album: 'Private album',
        artUri: Uri.parse('content://private-artwork'));
    handler.mediaItem.add(privateItem);
    handler.queue.add([privateItem]);
    handler.playbackState.add(PlaybackState(
        processingState: AudioProcessingState.ready, playing: true));
    await Future.wait([started, titled, queued]);

    final cleared = waitForCall(
        'setMediaItem', (call) => call.arguments['mediaItem']['id'] == '');
    final stopped = waitForCall('stopService', (_) => true);
    final queueCleared = waitForCall(
        'setQueue', (call) => (call.arguments['queue'] as List).isEmpty);
    await controller.prepareForProfileSwitch();
    await Future.wait([cleared, stopped, queueCleared]);

    expect(nativeItem?['id'], '');
    expect(nativeItem?['title'], '');
    expect(nativeItem?['artist'], '');
    expect(nativeItem?['album'], isNull);
    expect(nativeItem?['artUri'], isNull);
    expect(nativeItem?['extras'], isNull);
    expect(nativeQueue, isEmpty);
    expect(stateAtClear?['processingState'], AudioProcessingState.idle.index);
    expect(stateAtClear?['playing'], isFalse);
    expect(nativeState?['processingState'], AudioProcessingState.idle.index);
    expect(nativeState?['playing'], isFalse);
    expect(handler.mediaItem.value, isNull);
  });
}
