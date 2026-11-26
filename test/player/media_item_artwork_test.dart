import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/method_channel_audio_service.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/models/device_music_artwork_preferences.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/notification_artwork_cache.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _UnusedArtworkCache implements BaseCacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Content artwork must not access the file cache');
}

class _NotificationFiles implements FileSystem {
  _NotificationFiles(this.directory);

  final Directory directory;

  @override
  Future<fs.File> createFile(String name) async =>
      const LocalFileSystem().file(p.join(directory.path, name));
}

class _NotificationFilesService extends FileService {
  _NotificationFilesService(this.body);

  final Stream<List<int>> Function(String url, Map<String, String>? headers)
      body;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async =>
      HttpGetResponse(
        http.StreamedResponse(
          body(url, headers),
          200,
          headers: {
            'cache-control': 'max-age=3600',
            'content-type': 'image/jpeg'
          },
        ),
      );
}

NotificationArtworkCache _notificationCache(
  Directory root,
  _NotificationFilesService service,
  String Function() profileId, {
  int limitBytes = 10,
}) {
  final cache = NotificationArtworkCache(
    profileId: profileId,
    limitBytes: limitBytes,
    configFactory: (namespace) {
      final directory = Directory(p.join(root.path, namespace))..createSync();
      return Config(
        namespace,
        fileSystem: _NotificationFiles(directory),
        repo: JsonCacheInfoRepository.withFile(
          File(p.join(directory.path, 'index.json')),
        ),
        fileService: service,
      );
    },
  );
  addTearDown(() async {
    await cache.manager.dispose();
    await root.delete(recursive: true);
  });
  return cache;
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

  Video video(String thumbnail,
          {Server? server, String id = 'artwork-video'}) =>
      Video(
          videoId: id,
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

  test('device media items respect the cover choice with a cached track',
      () async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    const tree = 'content://documents/tree/primary%3AMusic';
    const file = '/data/cache/music-cover.jpg';
    final library = LocalMusicLibrary.instance;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return {'uri': tree, 'name': 'Music'};
        case 'listTracks':
          return [
            {
              'uri': '$tree/document/primary%3AMusic%2FSong.flac',
              'title': 'Song',
              'artPath': file,
            }
          ];
        default:
          return null;
      }
    });
    addTearDown(() async {
      await library.disable();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await library.refresh();
    final entry = localMusicPlaybackEntry(library.tracks.single, db.profileId);
    final controller = player = TestPlayerCubit(
        PlayerState.init([]).copyWith(offlineVideos: [entry]), settings);
    expect((await controller.getMediaItem(0))?.artUri, Uri.file(file));

    await DeviceMusicArtworkPreferences.setLoadCovers(db, false);
    expect(library.tracks.single.artPath, file);
    final withoutCover = await controller.getMediaItem(0);
    expect(withoutCover?.title, 'Song');
    expect(withoutCover?.artUri, isNull);
  });

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

  test('unsupported Google notification artwork never reaches the image cache',
      () async {
    final controller =
        createPlayer(video('https://s.ytimg.com/yts/img/cover.png'));
    final item = (await controller.getMediaItem(0))!;
    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
    expect(item.title, 'Artwork video');
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

  test('unrelated external metadata artwork is omitted', () async {
    const imageUrl = 'https://cdn.example/artwork.jpg';
    final controller = createPlayer(video(imageUrl));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });

  test('missing artwork does not become an empty network request', () async {
    final controller = createPlayer(const Video(videoId: 'without-artwork'));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });

  test('saved music notification routes its Google cover through the instance',
      () async {
    const cover = 'https://lh3.googleusercontent.com/cover';
    final music = MusicMetadata(
        title: 'Song',
        artist: 'Singer',
        album: 'Album',
        thumbnails: [ImageObject(null, cover, 128, 128)]);
    final queued =
        Video(videoId: 'stockSong01', musicMetadata: music, videoThumbnails: [
      ImageObject('high', '/vi/stockSong01/hqdefault.jpg', 480, 360),
    ]);
    final controller =
        createPlayer(Video.fromJson(jsonDecode(jsonEncode(queued))));
    final item = (await controller.getMediaItem(0))!;
    expect(item.title, 'Song');
    expect(item.artist, 'Singer');
    expect(item.album, 'Album');
    expect(item.artUri, Uri.parse('https://selected.example/ggpht/cover'));
    expect(
        item.artHeaders, selectedServer.headersForUrl(item.artUri.toString()));
  });

  test('music notification without a cover requests the instance thumbnail',
      () async {
    const music = MusicMetadata(title: 'Song', artist: 'Singer');
    final controller = createPlayer(video(
            'https://i.ytimg.com/vi/stockSong01/default.jpg',
            id: 'stockSong01')
        .copyWith(musicMetadata: music));
    final item = (await controller.getMediaItem(0))!;
    expect(item.artUri,
        Uri.parse('https://selected.example/vi/stockSong01/default.jpg'));
    expect(
        item.artHeaders, selectedServer.headersForUrl(item.artUri.toString()));
  });

  test('Music notification chooses the stock rendition that fits its display',
      () async {
    const id = 'stockSong01';
    final controller = createPlayer(Video(
        videoId: id,
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Singer'),
        videoThumbnails: [
          ImageObject('maxresdefault',
              'https://i.ytimg.com/vi/$id/maxresdefault.jpg', 1280, 720),
          ImageObject(
              'high', 'https://i.ytimg.com/vi/$id/hqdefault.jpg', 480, 360),
          ImageObject(
              'medium', 'https://i.ytimg.com/vi/$id/mqdefault.jpg', 320, 180),
        ]));
    final item = (await controller.getMediaItem(0))!;
    expect(item.artUri,
        Uri.parse('https://selected.example/vi/$id/hqdefault.jpg'));
    expect(
        item.artHeaders, selectedServer.headersForUrl(item.artUri.toString()));
  });

  test('saved Music fallback metadata rebinds the stock poster to the instance',
      () async {
    const cover = 'https://older.example/vi/stockSong01/default.jpg?stale=1';
    final saved = MusicLibraryEntry.song(video(cover, id: 'stockSong01')
        .copyWith(
            musicMetadata:
                const MusicMetadata(title: 'Song', artist: 'Singer')));
    final restored = MusicLibraryEntry.tryParse(saved.toJson())!.toVideo();
    final item = (await createPlayer(restored).getMediaItem(0))!;
    expect(item.artUri,
        Uri.parse('https://selected.example/vi/stockSong01/default.jpg'));
    expect(restored.musicMetadata!.thumbnails, isEmpty);
  });

  test('Music stock poster uses the mounted instance path and credentials',
      () async {
    const server = Server(
        url: 'https://backend.example/watch-service',
        customHeaders: {'X-Instance-Access': 'backend-access'});
    final queued = video(
            'https://backend.example/watch-service/vi/stockSong01/hqdefault.jpg',
            id: 'stockSong01')
        .copyWith(
            musicMetadata:
                const MusicMetadata(title: 'Song', artist: 'Singer'));
    final controller = createPlayer(queued,
        playing: queued.copyWith(playbackConnection: BackendPlayback(server)));
    final item = (await controller.getMediaItem(0))!;
    expect(
        item.artUri,
        Uri.parse(
            'https://backend.example/watch-service/vi/stockSong01/hqdefault.jpg'));
    expect(item.artHeaders, server.headersForUrl(item.artUri.toString()));
  });

  test('Music notification ignores DeArrow and another upload’s poster',
      () async {
    final queued = video(
        'https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=stockSong01',
        id: 'stockSong01');
    final controller = createPlayer(queued.copyWith(
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Singer'),
        videoThumbnails: [
          ...queued.videoThumbnails,
          ImageObject('medium', '/vi/stockSong02/default.jpg', 320, 180)
        ]));
    final item = (await controller.getMediaItem(0))!;
    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });

  test('old saved Music queue repairs instance artwork provenance', () async {
    const cover = 'https://selected.example/vi/stockSong01/default.jpg';
    // Older bookmarks copied their video fallback into both image fields.
    final legacy = video(cover, id: 'stockSong01').copyWith(
        musicMetadata: MusicMetadata(
            title: 'Song',
            artist: 'Singer',
            thumbnails: [ImageObject(null, cover, 320, 180)]));
    final restored = Video.fromJson(jsonDecode(jsonEncode(legacy)));
    final item = (await createPlayer(restored).getMediaItem(0))!;
    expect(item.artUri, Uri.parse(cover));
    expect(restored.musicMetadata!.thumbnails, isEmpty);
  });

  test('standalone Music artwork with an instance-like path remains intact',
      () {
    const cover = 'https://catalog.example/vi/song/cover.jpg';
    final metadata = MusicMetadata(
        title: 'Song',
        artist: 'Singer',
        thumbnails: [ImageObject(null, cover, 320, 180)]);
    final restoredMetadata = MusicMetadata.fromJson(metadata.toJson());
    expect(restoredMetadata.thumbnails.single.url, cover);
    final restoredVideo = Video.fromJson(jsonDecode(jsonEncode(
        const Video(videoId: 'song').copyWith(musicMetadata: metadata))));
    expect(restoredVideo.musicMetadata!.thumbnails.single.url, cover);
  });

  for (final explicit in [true, false]) {
    test(
        'downloaded Music notification uses its local cover (explicit: $explicit)',
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
      final downloaded = DownloadedVideo(
          videoId: 'stockSong01',
          title: 'Upload',
          accountId: selectedServer.accountId,
          author: 'Channel',
          lengthSeconds: 180,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true,
          musicMetadata: MusicMetadata(
              title: 'Song',
              artist: 'Singer',
              album: 'Album',
              thumbnails: [
                ImageObject(
                    null, 'https://lh3.googleusercontent.com/cover', 500, 500)
              ]));
      final first = video('/vi/stockSong01/default.jpg', id: 'stockSong01');
      final other = first.copyWith(queueEntryId: 'other-occurrence');
      final state = explicit
          ? PlayerState.init(null).copyWith(
              offlineVideos: [downloaded], offlineCurrentlyPlaying: downloaded)
          : PlayerState.init([first, other]).copyWith(
              currentlyPlaying: first.copyWith(
                  musicMetadata: downloaded.musicMetadata,
                  playbackConnection: BackendPlayback(selectedServer),
                  playbackSourceId: DownloadPlaybackSource(
                      'file:///song', null, downloaded, const {}),
                  downloadPlaybackOnly: true));
      final controller = player = TestPlayerCubit(state, settings);
      await File(await downloaded.thumbnailPath).writeAsBytes([1, 2, 3]);
      final item = (await controller.getMediaItem(0))!;
      expect(item.title, 'Song');
      expect(item.artist, 'Singer');
      expect(item.album, 'Album');
      expect(item.artUri, isNull);
      expect(item.artHeaders, isNull);

      final poster = (await downloaded.stockSongPosterFile)!;
      await poster.parent.create(recursive: true);
      await poster.writeAsBytes([7, 8, 9]);
      final withPoster = (await controller.getMediaItem(0))!;
      expect(withPoster.artUri, poster.uri);
      expect(withPoster.artHeaders, isNull);
      final cover = (await downloaded.songCoverFile)!;
      await cover.parent.create(recursive: true);
      await cover.writeAsBytes([4, 5, 6]);
      final withCover = (await controller.getMediaItem(0))!;
      expect(withCover.artUri, cover.uri);
      expect(withCover.artHeaders, isNull);
      if (!explicit) {
        final otherItem = (await controller.getMediaItem(1))!;
        expect(otherItem.title, 'Artwork video');
        expect(otherItem.artUri,
            Uri.parse('https://selected.example/vi/stockSong01/default.jpg'));
      }
    });
  }

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

  test(
    'notification storage trims its own files and can be reused after clear',
    () async {
      final root = await Directory.systemTemp.createTemp('notification-art-');
      final downloadCover = await File(
        p.join(root.path, 'download-cover.jpg'),
      ).writeAsBytes([8]);
      final deviceCover = File(
          p.join(root.path, 'music-covers-${'a' * 64}', 'device-cover.jpg'));
      await deviceCover.create(recursive: true);
      await deviceCover.writeAsBytes([9]);
      const selectedCoverKey = 'music-playlist-cover-v1:local:chosen';
      const selectedCover = 'c2VsZWN0ZWQtY292ZXI=';
      await db.saveSetting(SettingsValue(selectedCoverKey, selectedCover));
      final cache = _notificationCache(
        root,
        _NotificationFilesService(
          (_, __) => Stream.value(const [1, 2, 3, 4, 5, 6]),
        ),
        () => 'profile',
      );
      const first = 'https://instance.example/cover-a';
      const second = 'https://instance.example/cover-b';
      final manager = cache.manager;

      final older = await manager.getSingleFile(first);
      expect(await cache.read(), (
        usedBytes: 6,
        limitBytes: 10,
        canClear: true,
      ));
      final newer = await manager.getSingleFile(second);
      expect(await cache.read(), (
        usedBytes: 6,
        limitBytes: 10,
        canClear: true,
      ));
      expect(await older.exists(), isFalse);
      expect(await newer.exists(), isTrue);

      expect(await cache.clear(), (
        usedBytes: 0,
        limitBytes: 10,
        canClear: false,
      ));
      expect(await newer.exists(), isFalse);
      expect(await downloadCover.readAsBytes(), [8]);
      expect(await deviceCover.readAsBytes(), [9]);
      expect(db.getSettings(selectedCoverKey)?.value, selectedCover);
      expect(await (await manager.getSingleFile(second)).readAsBytes(), [
        1,
        2,
        3,
        4,
        5,
        6,
      ]);
    },
  );

  test(
    'notification reuse includes the owning profile and request headers',
    () async {
      final root = await Directory.systemTemp.createTemp('notification-auth-');
      var requests = 0;
      var profile = 'first-profile';
      final cache = _notificationCache(
        root,
        _NotificationFilesService((_, headers) {
          expect(headers?['X-Instance-Access'], isNotEmpty);
          return Stream.value([++requests]);
        }),
        () => profile,
      );
      const url = 'https://instance.example/same-cover';
      const firstHeaders = {'X-Instance-Access': 'first'};
      const secondHeaders = {'X-Instance-Access': 'second'};
      Future<List<int>> load(Map<String, String> headers) async =>
          (await cache.manager.getSingleFile(
            url,
            headers: headers,
          ))
              .readAsBytes();

      expect(await load(firstHeaders), [1]);
      expect(await load(firstHeaders), [1]);
      expect(await load(secondHeaders), [2]);
      profile = 'second-profile';
      expect(await load(firstHeaders), [3]);
      expect(requests, 3);
      expect(await cache.manager.getFileFromMemory(url), isNull);
    },
  );

  test(
    'clearing notification storage fences an open artwork response',
    () async {
      final root = await Directory.systemTemp.createTemp('notification-clear-');
      final subscribed = Completer<void>();
      final body = StreamController<List<int>>(onListen: subscribed.complete);
      addTearDown(body.close);
      var requests = 0;
      final cache = _notificationCache(
        root,
        _NotificationFilesService(
          (_, __) => requests++ == 0 ? body.stream : Stream.value(const [7]),
        ),
        () => 'profile',
      );
      const url = 'https://instance.example/cover';
      final fenced = expectLater(
        cache.manager.getSingleFile(url),
        throwsA(isA<HttpException>()),
      );
      await subscribed.future;
      expect(await cache.read(), (
        usedBytes: 0,
        limitBytes: 10,
        canClear: true,
      ));
      expect(await cache.clear(), (
        usedBytes: 0,
        limitBytes: 10,
        canClear: false,
      ));
      await fenced;
      final latest = await cache.manager.getSingleFile(url);
      expect(await latest.readAsBytes(), [7]);
    },
  );
}
