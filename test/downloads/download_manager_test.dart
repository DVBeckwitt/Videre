import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/states/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Player extends Fake implements PlayerCubit {}

class _Settings extends Fake implements SettingsCubit {
  @override
  SettingsState get state => SettingsState.init();

  @override
  Stream<SettingsState> get stream => const Stream.empty();
}

class _DownloadTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _DirectHttpOverrides extends HttpOverrides {}

class _DownloadService extends Service {
  final Future<Video> Function(String) fetch;
  final void Function(Server?)? onServer;
  final Future<String> Function(String, Caption, Server)? captions;
  final Future<List<SponsorSegment>> Function(String, List<SponsorSegmentType>)?
      sponsors;

  _DownloadService(this.fetch,
      {this.onServer, this.sponsors, this.captions, super.httpClient});

  @override
  Future<String> getPlaybackCaptions(String videoId, Caption caption,
          {required Server server}) =>
      captions!(videoId, caption, server);

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) {
    onServer?.call(serverOverride);
    return fetch(videoId);
  }

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
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) =>
      sponsors?.call(videoId, categories) ?? Future.value([]);
}

class _VideoCubit extends VideoCubit {
  _VideoCubit(DownloadManagerCubit manager)
      : super(
            VideoState(
                videoId: 'abcdefghijk',
                isLoggedIn: false,
                video: Video(videoId: 'abcdefghijk')),
            manager,
            _Player(),
            _Settings());

  @override
  Future<void> onReady() async => getDownloadStatus();
}

class _AndroidDownloadStorage extends DownloadStorage {
  @override
  bool get supportsSharedMusic => true;
}

void main() {
  _DownloadTestBinding();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const storageChannel = MethodChannel('videre/download_storage');
  const folder = 'content://documents/tree/primary%3AVidere';
  const document = '$folder/document/primary%3AVidere%2Fvideo.webm';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Service originalService;
  late DownloadManagerCubit manager;
  late Directory documentsDirectory;
  HttpServer? mediaServer;
  const video = DownloadedVideo(
      videoId: 'abcdefghijk',
      title: 'A video',
      lengthSeconds: 12,
      quality: '720p');

  test('malformed download IDs cannot delete files outside the download folder',
      () async {
    await manager.addDownloads([]);
    final sentinel = File('${documentsDirectory.path}/outside.webm');
    await sentinel.writeAsString('preserve');
    final malicious = video.copyWith(videoId: '../outside', audioOnly: true);
    await expectLater(
        manager.deleteVideo(malicious), throwsA(isA<FormatException>()));
    expect(await sentinel.readAsString(), 'preserve');
  });

  test('untrusted download IDs are rejected before queueing or building paths',
      () async {
    for (final id in [
      '../escape',
      r'..\escape',
      '/absolute',
      'a/b',
      'a:b',
      '',
      'a' * 129,
      'line\nbreak',
      'trailing\n'
    ]) {
      expect(await manager.addDownload(id), isFalse);
      expect(db.getDownloadByVideoId(id), isNull);
      final invalid = video.copyWith(videoId: id);
      expect(() => invalid.fileName, throwsA(isA<FormatException>()));
      await expectLater(invalid.downloadPath, throwsA(isA<FormatException>()));
      await expectLater(invalid.thumbnailPath, throwsA(isA<FormatException>()));
    }
  });

  Future<void> openManager() async {
    manager = DownloadManagerCubit(const DownloadManagerState(), _Player());
    await manager.addDownloads([]); // Wait for saved preferences to load.
  }

  Future<void> openAndroidStorageManager(
      {List<MusicDownloadFormat>? encodings}) async {
    await manager.close();
    manager = DownloadManagerCubit(const DownloadManagerState(), _Player(),
        storage: _AndroidDownloadStorage(), encodeMusic: (
            {required input,
            required output,
            required video,
            required token,
            inputFormat,
            sourceCodec}) async {
      encodings?.add(video.musicFormat!);
      await File(output).writeAsBytes(
          [video.musicFormat!.index, ...await File(input).readAsBytes()]);
    });
    await manager.addDownloads([]);
  }

  Future<void> waitFor(bool Function(DownloadManagerState) predicate,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (!predicate(manager.state)) {
      await manager.stream.firstWhere(predicate).timeout(timeout);
    }
  }

  Future<Video> audioVideo(String videoId,
      {void Function(HttpRequest)? onRequest}) async {
    const bytes = [0, 1, 2, 3, 4, 5, 6, 7];
    mediaServer!.listen((request) async {
      onRequest?.call(request);
      request.response.add(bytes);
      await request.response.close();
    });
    return Video(videoId: videoId, title: 'Resolved title', adaptiveFormats: [
      AdaptiveFormat(
          null,
          '128000',
          null,
          'http://127.0.0.1:${mediaServer!.port}/audio',
          '251',
          'audio/webm',
          '${bytes.length}',
          '1',
          '',
          'webm',
          'opus',
          null,
          null)
    ]);
  }

  Future<Video> audioVideoWithArtwork({
    required Future<void> Function(HttpRequest) onArtwork,
    void Function(HttpRequest)? onAudio,
    Duration audioDelay = Duration.zero,
  }) async {
    const bytes = [0, 1, 2, 3, 4, 5, 6, 7];
    mediaServer!.listen((request) async {
      try {
        if (request.uri.path.startsWith('/vi/') ||
            request.uri.path.startsWith('/ggpht/')) {
          await onArtwork(request);
        } else {
          onAudio?.call(request);
          await Future<void>.delayed(audioDelay);
          request.response.add(bytes);
          await request.response.close();
        }
      } on IOException {
        // Cancellation intentionally closes an in-flight response.
      }
    });
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    final server = Server(
        url: origin, customHeaders: {'X-Instance-Key': 'artwork-instance'});
    await db.upsertServer(server);
    await db.useServer(server);
    return Video(
        videoId: video.videoId,
        title: 'Resolved title',
        videoThumbnails: [
          ImageObject('default',
              'https://i.ytimg.com/vi/${video.videoId}/default.jpg', 320, 180)
        ],
        adaptiveFormats: [
          AdaptiveFormat(
              null,
              '128000',
              null,
              '$origin/audio',
              '251',
              'audio/webm',
              '${bytes.length}',
              '1',
              '',
              'webm',
              'opus',
              null,
              null)
        ]);
  }

  setUp(() async {
    originalService = service;
    documentsDirectory =
        await Directory.systemTemp.createTemp('videre-download-manager-test-');
    mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documentsDirectory.path);
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(
        Server(url: 'http://127.0.0.1:${mediaServer!.port}', inUse: true));
    await db.saveSetting(SettingsValue('downloads-wifi-only', 'true'));
    await db.upsertDownload(video);
    await openManager();
  });

  tearDown(() async {
    await manager.close();
    await mediaServer?.close(force: true);
    await db.close();
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockMethodCallHandler(storageChannel, null);
    await documentsDirectory.delete(recursive: true);
    service = originalService;
  });

  test('interrupted jobs remain queued and respect Wi-Fi-only after restart',
      () {
    expect(manager.state.videos.single.downloadFailed, false);
    expect(manager.state.videos.single.downloadComplete, false);
    expect(manager.state.wifiOnly, true);
    expect(manager.state.waitingForWifi, true);
    expect(manager.state.downloadProgresses, isEmpty);
    expect(manager.state.totalProgress, 0);
  });

  test('folder selection persists, cancellation and reset preserve old jobs',
      () async {
    messenger.setMockMethodCallHandler(
        storageChannel, (_) async => {'uri': folder, 'name': 'Videre'});
    await manager.chooseFolder();
    await manager.addDownload('12345678901');
    expect(db.getDownloadByVideoId(video.videoId)!.folderUri, isNull);
    expect(db.getDownloadByVideoId('12345678901')!.folderUri, folder);
    await manager.close();
    await openManager();
    expect(manager.state.folderName, 'Videre');
    expect(manager.state.folderUri, folder);
    messenger.setMockMethodCallHandler(storageChannel, (_) async => null);
    await manager.chooseFolder();
    expect(manager.state.folderUri, folder);
    await manager.usePrivateFolder();
    expect(manager.state.folderUri, isNull);
    expect(manager.state.usePrivateStorage, isTrue);
    await manager.close();
    await openManager();
    expect(manager.state.usePrivateStorage, isTrue);
    await manager.useDefaultFolder();
    expect(manager.state.usePrivateStorage, isFalse);
    expect(db.getSettings(downloadFolderSetting), isNull);
    expect(db.getDownloadByVideoId('12345678901')!.folderUri, folder);
  });

  test('only Music defaults to shared storage and legacy picker is cancellable',
      () async {
    const shared = 'content://media/external_primary/audio/media';
    var modern = true;
    var approve = false;
    var picks = 0;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'sharedMusicFolder') return modern ? shared : null;
      if (call.method == 'pickFolder') {
        picks++;
        return approve ? {'uri': folder, 'name': 'My songs'} : null;
      }
      fail('Unexpected ${call.method}');
    });
    await openAndroidStorageManager();
    Future<bool> queue(String id) => manager.addDownload(id,
        audioOnly: true,
        quality: highestAudioDownloadQuality,
        video: Video(
            videoId: id,
            musicMetadata:
                const MusicMetadata(title: 'Song', artist: 'Artist')));
    expect(await queue('modern'), isTrue);
    expect(db.getDownloadByVideoId('modern')!.folderUri, shared);
    expect(db.getDownloadByVideoId('modern')!.musicFormat,
        MusicDownloadFormat.mp3);
    expect(await manager.addDownload('watch', audioOnly: true), isTrue);
    expect(db.getDownloadByVideoId('watch')!.folderUri, isNull);
    expect(picks, 0);
    modern = false;
    expect(await queue('cancel'), isFalse);
    expect(db.getDownloadByVideoId('cancel'), isNull);
    approve = true;
    expect(await manager.prepareMusicDownloads(), isTrue);
    expect(await queue('approved'), isTrue);
    expect(db.getDownloadByVideoId('approved')!.folderUri, folder);
    await openAndroidStorageManager();
    expect(await queue('another'), isTrue);
    expect(db.getDownloadByVideoId('another')!.folderUri, folder);
    expect(picks, 2);
    expect(manager.state.folderUri, isNull);
  });

  test(
      'existing private Music export reuses a pending document and preserves the source',
      () async {
    const shared = 'content://media/external_primary/audio/media';
    const row = '$shared/42';
    final encodings = <MusicDownloadFormat>[];
    final previousDestinations = <String?>[];
    final written = <int>[];
    final removed = <String>[];
    var failWrite = true;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      switch (call.method) {
        case 'sharedMusicFolder':
          return shared;
        case 'prepareDocument':
          expect(call.arguments['folder'], shared);
          expect(call.arguments['name'], endsWith('.mp3'));
          expect(call.arguments['mime'], 'audio/mpeg');
          previousDestinations.add(call.arguments['existing'] as String?);
          return row;
        case 'writeDocument':
          if (failWrite) throw PlatformException(code: 'DOWNLOAD_STORAGE');
          written.addAll(
              await File(call.arguments['source'] as String).readAsBytes());
          return null;
        case 'exportExists':
          return true;
        case 'deleteDocument':
          removed.add(call.arguments['uri'] as String);
          return null;
        default:
          fail('Unexpected ${call.method}');
      }
    });
    await openAndroidStorageManager(encodings: encodings);
    final original = video.copyWith(
        audioOnly: true,
        downloadComplete: true,
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
    await db.upsertDownload(original);
    final file = File(await original.effectivePath);
    await file.writeAsBytes([9, 8]);
    await expectLater(
        manager.exportMusic(original), throwsA(isA<PlatformException>()));
    expect(db.getDownloadByVideoId(original.videoId)!.exportedMusic!.complete,
        isFalse);
    await openAndroidStorageManager(encodings: encodings);
    failWrite = false;
    expect(
        await Future.wait(
            [manager.exportMusic(original), manager.exportMusic(original)]),
        [true, true]);
    expect(await manager.exportMusic(original), isTrue);
    expect(previousDestinations, [null, row]);
    expect(encodings, [MusicDownloadFormat.mp3, MusicDownloadFormat.mp3]);
    expect(written, [0, 9, 8]);
    expect(await file.readAsBytes(), [9, 8]);
    expect(db.getDownloadByVideoId(original.videoId)!.storageUri, isNull);
    await manager.deleteVideo(original);
    expect(removed, isEmpty);
  });

  test('export retries only create a copy after confirming it is missing',
      () async {
    const shared = 'content://media/external_primary/audio/media';
    const previous = ExportedMusicCopy(
        shared, '$shared/42', MusicDownloadFormat.mp3,
        complete: true);
    const replacement = '$shared/43';
    bool? exists;
    var creates = 0;
    var writes = 0;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      switch (call.method) {
        case 'sharedMusicFolder':
          return shared;
        case 'exportExists':
          expect(call.arguments['uri'], previous.uri);
          expect(call.arguments['folderUri'], shared);
          if (exists == null) throw PlatformException(code: 'DOWNLOAD_STORAGE');
          return exists;
        case 'prepareDocument':
          expect(call.arguments['existing'], isNull);
          creates++;
          return replacement;
        case 'writeDocument':
          expect(call.arguments['uri'], replacement);
          writes++;
          return null;
        default:
          fail('Unexpected ${call.method}');
      }
    });
    await openAndroidStorageManager();
    final original = video.copyWith(
        audioOnly: true,
        musicFormat: MusicDownloadFormat.mp3,
        downloadComplete: true,
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
        exportedMusic: previous);
    await db.upsertDownload(original);
    await File(await original.effectivePath).writeAsBytes([1, 2]);
    await expectLater(
        manager.exportMusic(original), throwsA(isA<PlatformException>()));
    expect(db.getDownloadByVideoId(original.videoId)!.exportedMusic, previous);
    exists = true;
    expect(await manager.exportMusic(original), isTrue);
    expect(creates, 0);
    expect(writes, 0);
    exists = false;
    expect(await manager.exportMusic(original), isTrue);
    expect(creates, 1);
    expect(writes, 1);
    expect(db.getDownloadByVideoId(original.videoId)!.exportedMusic!.uri,
        replacement);
  });

  test(
      'export reads legacy granted documents without modifying or fetching the source',
      () async {
    const shared = 'content://media/external_primary/audio/media';
    const row = '$shared/49';
    final encodings = <MusicDownloadFormat>[];
    String? localInput;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      switch (call.method) {
        case 'sharedMusicFolder':
          return shared;
        case 'readDocument':
          expect(call.arguments['uri'], document);
          expect(call.arguments['folderUri'], folder);
          localInput = call.arguments['destination'] as String;
          await File(localInput!).writeAsBytes([4, 6]);
          return null;
        case 'prepareDocument':
          expect(call.arguments['name'], endsWith('.m4a'));
          expect(call.arguments['mime'], 'audio/mp4');
          return row;
        case 'writeDocument':
          expect(call.arguments['uri'], row);
          expect(await File(call.arguments['source'] as String).readAsBytes(),
              [2, 4, 6]);
          return null;
        default:
          fail('Unexpected ${call.method}');
      }
    });
    await openAndroidStorageManager(encodings: encodings);
    await MusicDownloadFormat.m4a.save(db);
    final original = video.copyWith(
        audioOnly: true,
        downloadComplete: true,
        folderUri: folder,
        storageUri: document,
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
    await db.upsertDownload(original);
    expect(await manager.exportMusic(original), isTrue);
    expect(db.getDownloadByVideoId(original.videoId)!.storageUri, document);
    expect(encodings, [MusicDownloadFormat.m4a]);
    expect(await File(localInput!).exists(), isFalse);
  });

  test('audio-only MP4 saves selected language as M4A across a restart',
      () async {
    final paths = <String>[];
    mediaServer!.listen((request) async {
      paths.add(request.uri.path);
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    AdaptiveFormat audio(String language, String type, String encoding) =>
        AdaptiveFormat(null, '128000', null, '$origin/$language', '140', type,
            '4', '1', '', null, encoding, null, null,
            audioTrack: AudioTrack(
                id: language,
                displayName: language,
                audioIsDefault: language == 'en'));
    service =
        _DownloadService((id) async => Video(videoId: id, adaptiveFormats: [
              audio('en', 'audio/webm', 'opus'),
              audio('en', 'audio/mp4', 'aac'),
              audio('es', 'audio/mp4', 'aac')
            ]));
    await manager.deleteVideo(video);
    await manager.addDownloads([video.videoId],
        audioOnly: true, container: DownloadContainer.mp4, audioTrackId: 'es');
    await manager.close();
    await openManager();
    expect(manager.state.videos.single.audioTrackId, 'es');
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);
    final completed = db.getDownloadByVideoId(video.videoId)!;
    expect(paths, ['/es']);
    expect(completed.extension, 'm4a');
    expect(completed.mimeType, 'audio/mp4');
    expect(completed.playbackProvenance?.audioOnly, isTrue);
    expect(completed.playbackProvenance?.byteLength, 4);
    expect(completed.playbackProvenance?.sha256,
        sha256.convert([1, 2, 3, 4]).toString());
    expect(completed.playbackProvenance?.defaultAudioTrack, isFalse);
    expect(
        await File(await completed.effectivePath).readAsBytes(), [1, 2, 3, 4]);
  });

  for (final (name, outputFormat, opusBitrate, requested, expected) in const [
    (
      'Music automatic picks higher-bitrate AAC for default MP3 output',
      MusicDownloadFormat.mp3,
      96000,
      null,
      DownloadContainer.mp4
    ),
    (
      'Music automatic picks higher-bitrate Opus for Ogg output',
      MusicDownloadFormat.opus,
      192000,
      null,
      DownloadContainer.webm
    ),
    (
      'explicit M4A source preserves lower-bitrate AAC for M4A output',
      MusicDownloadFormat.m4a,
      192000,
      DownloadContainer.mp4,
      DownloadContainer.mp4
    ),
    (
      'Video audio-only retains WebM with Music metadata',
      null,
      96000,
      null,
      DownloadContainer.webm
    ),
  ]) {
    test('$name after restarting the download queue', () async {
      const media = {
        '/aac': [140],
        '/opus': [251]
      };
      final paths = <String>[];
      mediaServer!.listen((request) async {
        final path = request.uri.path;
        paths.add(path);
        final bytes = media[path];
        if (bytes == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
      final origin = 'http://127.0.0.1:${mediaServer!.port}';
      final track = Video(
          videoId: video.videoId,
          musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
          adaptiveFormats: [
            AdaptiveFormat(null, '160000', null, '$origin/aac', '140',
                'audio/mp4', '1', '1', '', null, 'aac', null, null),
            AdaptiveFormat(null, '$opusBitrate', null, '$origin/opus', '251',
                'audio/webm', '1', '1', '', null, 'opus', null, null),
          ]);
      service = _DownloadService((_) async => track);
      await manager.deleteVideo(video);
      await manager.usePrivateFolder();
      final preference = outputFormat ?? MusicDownloadFormat.m4a;
      if (preference != MusicDownloadFormat.mp3) await preference.save(db);
      final added = outputFormat != null
          ? await manager.addDownload(track.videoId,
              audioOnly: true,
              quality: highestAudioDownloadQuality,
              container: requested,
              video: track)
          : await manager.addDownload(track.videoId,
              audioOnly: true, video: track);
      expect(added, isTrue);
      await manager.close();
      final nextPreference = preference == MusicDownloadFormat.mp3
          ? MusicDownloadFormat.m4a
          : MusicDownloadFormat.mp3;
      await nextPreference.save(db);
      final encoderInputs = <List<int>>[];
      final encoderCodecs = <String?>[];
      manager = DownloadManagerCubit(const DownloadManagerState(), _Player(),
          encodeMusic: ({
        required input,
        required output,
        required video,
        required token,
        inputFormat,
        sourceCodec,
      }) async {
        final bytes = await File(input).readAsBytes();
        encoderInputs.add(bytes);
        encoderCodecs.add(sourceCodec);
        await File(output).writeAsBytes([7, ...bytes]);
      });
      await manager.addDownloads([]);
      final queued = manager.state.videos.single;
      expect(queued.quality,
          outputFormat != null ? highestAudioDownloadQuality : '720p');
      expect(queued.musicFormat, outputFormat);
      expect(queued.container, requested);
      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.videos.single.downloadComplete ||
          state.videos.single.downloadFailed);

      final completed = db.getDownloadByVideoId(track.videoId)!;
      final expectedPath = expected == DownloadContainer.mp4 ? '/aac' : '/opus';
      expect(completed.downloadComplete, isTrue);
      expect(paths, [expectedPath]);
      expect(completed.container, expected);
      expect(completed.musicFormat, outputFormat);
      final bytes = media[expectedPath]!;
      if (outputFormat == null) {
        expect(encoderInputs, isEmpty);
      } else {
        expect(encoderInputs, [bytes]);
        expect(encoderCodecs,
            [expected == DownloadContainer.mp4 ? 'aac' : 'opus']);
      }
      final extension = switch (outputFormat) {
        null => 'webm',
        MusicDownloadFormat.mp3 => 'mp3',
        MusicDownloadFormat.opus => 'ogg',
        MusicDownloadFormat.m4a => 'm4a',
      };
      final file = File(await completed.effectivePath);
      expect(file.path, endsWith('.$extension'));
      expect(await file.readAsBytes(),
          outputFormat == null ? bytes : [7, ...bytes]);
    });
  }

  test('default audio discovered only in DASH remains downloadable', () async {
    final paths = <String>[];
    mediaServer!.listen((request) async {
      paths.add(request.uri.path);
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    var discoveries = 0;
    service = _DownloadService(
        (id) async => Video(videoId: id, dashUrl: '$origin/manifest'),
        httpClient: MockClient((request) async {
      discoveries++;
      return http.Response('''
<MPD type="static"><Period>
  <AdaptationSet mimeType="audio/mp4" lang="en" label="English">
    <Role value="main"/>
    <Representation id="140" codecs="mp4a.40.2" bandwidth="128000">
      <BaseURL>$origin/audio?clen=4</BaseURL>
      <SegmentBase indexRange="2-3"><Initialization range="0-1"/></SegmentBase>
    </Representation>
  </AdaptationSet>
</Period></MPD>
''', 200, request: request);
    }));
    await manager.deleteVideo(video);
    await manager.addDownload(video.videoId, audioOnly: true);
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadComplete ||
        state.videos.single.downloadFailed);
    final completed = db.getDownloadByVideoId(video.videoId)!;
    expect(completed.downloadComplete, isTrue);
    expect(discoveries, 1);
    expect(paths, ['/audio']);
    expect(completed.extension, 'm4a');
    expect(
        await File(await completed.effectivePath).readAsBytes(), [1, 2, 3, 4]);
  });

  for (final container in DownloadContainer.values) {
    test('selected subtitles are embedded in $container and staging is removed',
        () async {
      const muxChannel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
      const muxEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
      const vtt = 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHola\n';
      final origin = 'http://127.0.0.1:${mediaServer!.port}';
      mediaServer!.listen((request) async {
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      final isMp4 = container == DownloadContainer.mp4;
      AdaptiveFormat track(bool audio) => AdaptiveFormat(
          null,
          '128000',
          null,
          '$origin/${audio ? 'audio' : 'video'}',
          audio ? '140' : '137',
          '${audio ? 'audio' : 'video'}/${container.name}',
          '4',
          '1',
          '',
          null,
          audio ? (isMp4 ? 'aac' : 'opus') : (isMp4 ? 'h264' : 'vp9'),
          audio ? null : '720p',
          null);
      service = _DownloadService(
          (id) async => Video(
              videoId: id,
              adaptiveFormats: [track(true), track(false)],
              captions: [Caption('Spanish', 'es', '/captions')]),
          captions: (id, caption, server) async {
        expect(id, video.videoId);
        expect(caption.label, 'Spanish');
        expect(server.url, origin);
        return vtt;
      });
      late List<String> arguments;
      String? subtitlePath;
      messenger.setMockMethodCallHandler(muxEvents, (_) async => null);
      messenger.setMockMethodCallHandler(muxChannel, (call) async {
        switch (call.method) {
          case 'ffmpegSession':
            arguments = List<String>.from(call.arguments['arguments'] as List);
            subtitlePath =
                arguments.firstWhere((arg) => arg.endsWith('.caption.vtt'));
            expect(await File(subtitlePath!).readAsString(), vtt);
            return {'sessionId': 1};
          case 'ffmpegSessionExecute':
            await File(arguments.last).writeAsBytes([1, 2, 3, 4]);
            return null;
          case 'abstractSessionGetReturnCode':
            return 0;
          default:
            return null;
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(muxEvents, null);
        messenger.setMockMethodCallHandler(muxChannel, null);
      });
      await manager.deleteVideo(video);
      await manager.addDownload(video.videoId,
          container: container, captionLabel: 'Spanish');
      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.videos.single.downloadComplete &&
          state.downloadProgresses.isEmpty);
      expect(
          arguments,
          containsAllInOrder([
            '-map',
            '0:v:0',
            '-map',
            '1:a:0',
            '-map',
            '2:s:0',
            '-c:s',
            isMp4 ? 'mov_text' : 'webvtt'
          ]));
      expect(await File(subtitlePath!).exists(), isFalse);
      final saved = manager.state.videos.single;
      final offlineSubtitles = File(await saved.subtitlePath);
      expect(await offlineSubtitles.readAsString(), vtt);
      await manager.deleteVideo(saved);
      expect(await offlineSubtitles.exists(), isFalse);
    });
  }

  test('missing selected language fails without downloading a default track',
      () async {
    var requests = 0;
    service =
        _DownloadService((id) => audioVideo(id, onRequest: (_) => requests++));
    await manager.deleteVideo(video);
    await manager.addDownload(video.videoId,
        audioOnly: true, audioTrackId: 'es');
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadFailed);
    expect(requests, 0);
    expect(manager.state.videos.single.downloadComplete, isFalse);
  });

  test('missing selected subtitle fails without discarding the requested track',
      () async {
    var requests = 0;
    service = _DownloadService((id) async {
      final source = await audioVideo(id, onRequest: (_) => requests++);
      return source.copyWith(adaptiveFormats: [
        ...source.adaptiveFormats!,
        AdaptiveFormat(
            null,
            '128000',
            null,
            'http://127.0.0.1:${mediaServer!.port}/video',
            '247',
            'video/webm',
            '8',
            '1',
            '',
            null,
            'vp9',
            '720p',
            null)
      ]);
    });
    await manager.deleteVideo(video);
    await manager.addDownload(video.videoId, captionLabel: 'Spanish');
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadFailed);
    expect(requests, 0);
    expect(manager.state.videos.single.captionLabel, 'Spanish');
  });

  test('completed external media keeps its URI and frees private staging files',
      () async {
    final audio = video.copyWith(audioOnly: true, folderUri: folder);
    await db.upsertDownload(audio);
    service = _DownloadService((_) => audioVideo(audio.videoId));
    List<int>? savedBytes;
    String? deleted;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'prepareDocument') {
        expect(call.arguments['folder'], folder);
        expect(call.arguments['mime'], 'audio/webm');
        expect(call.arguments['existing'], isNull);
        return document;
      }
      if (call.method == 'writeDocument') {
        expect(db.getDownloadByVideoId(video.videoId)!.storageUri, document);
        expect(
            db.getDownloadByVideoId(video.videoId)!.downloadComplete, isFalse);
        savedBytes =
            await File(call.arguments['source'] as String).readAsBytes();
      }
      if (call.method == 'deleteDocument') {
        deleted = call.arguments['uri'] as String;
      }
      if (call.method == 'inspectDocument') {
        expect(call.arguments['uri'], document);
        expect(call.arguments['folderUri'], folder);
        return {
          'byteLength': savedBytes!.length,
          'sha256': sha256.convert(savedBytes!).toString(),
        };
      }
      return null;
    });
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadComplete &&
        state.downloadProgresses.isEmpty);
    final completed = db.getDownloadByVideoId(video.videoId)!;
    expect(savedBytes, [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(await completed.effectivePath, document);
    expect(completed.playbackProvenance?.sha256,
        sha256.convert(savedBytes!).toString());
    expect(await File(await audio.downloadPath).exists(), isFalse);
    expect(
        await File('${await audio.downloadPath}.mux.webm').exists(), isFalse);
    await manager.close();
    await openManager();
    expect(await manager.state.videos.single.effectivePath, document);
    await manager.deleteVideo(manager.state.videos.single);
    expect(deleted, document);
    expect(manager.state.videos, isEmpty);
  });

  for (final deleting in [false, true]) {
    test(
        'cancels the active mux and joins it before cleanup (delete: $deleting)',
        () async {
      const muxChannel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
      const muxEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final finished = Completer<void>();
      final origin = 'http://127.0.0.1:${mediaServer!.port}';
      mediaServer!.listen((request) async {
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      AdaptiveFormat track(bool audio) => AdaptiveFormat(
          null,
          '128000',
          null,
          '$origin/${audio ? 'audio' : 'video'}',
          audio ? '251' : '243',
          '${audio ? 'audio' : 'video'}/webm',
          '4',
          '1',
          '',
          'webm',
          audio ? 'opus' : 'vp9',
          audio ? null : '720p',
          null);
      service = _DownloadService((id) async =>
          Video(videoId: id, adaptiveFormats: [track(true), track(false)]));
      late List<String> arguments;
      final cancelledSessions = <int>[];
      messenger.setMockMethodCallHandler(muxEvents, (_) async => null);
      messenger.setMockMethodCallHandler(muxChannel, (call) async {
        switch (call.method) {
          case 'ffmpegSession':
            arguments = List<String>.from(call.arguments['arguments'] as List);
            return {'sessionId': 42};
          case 'ffmpegSessionExecute':
            await File(arguments.last).writeAsBytes([1, 2]);
            started.complete();
            await finished.future;
            return null;
          case 'cancelSession':
            cancelledSessions.add(call.arguments['sessionId'] as int);
            if (!cancelled.isCompleted) cancelled.complete();
            return null;
          case 'cancel':
            fail('A download must not cancel unrelated FFmpeg sessions');
          case 'abstractSessionGetReturnCode':
            return 255;
          default:
            return null;
        }
      });
      Future<void>? stopping;
      try {
        await manager.setWifiOnly(false);
        await started.future.timeout(const Duration(seconds: 5));
        var stopped = false;
        stopping = (deleting
                ? manager.deleteVideo(video)
                : manager.pauseForProfileSwitch())
            .then((_) => stopped = true);
        await cancelled.future.timeout(const Duration(seconds: 1));
        expect(cancelledSessions, isNotEmpty);
        expect(cancelledSessions, everyElement(42));
        expect(stopped, isFalse);
        expect(await File(arguments.last).exists(), isTrue);
        expect(await File('${await video.stagingPath}.audio.part').exists(),
            isTrue);
        finished.complete();
        await stopping.timeout(const Duration(seconds: 2));
        if (deleting) {
          expect(db.getDownloadByVideoId(video.videoId), isNull);
          expect(await File(arguments.last).exists(), isFalse);
        } else {
          final saved = db.getDownloadByVideoId(video.videoId)!;
          expect(saved.downloadComplete, isFalse);
          expect(saved.downloadFailed, isFalse);
          expect(manager.state.pausedVideoIds, contains(video.videoId));
          expect(await File('${await video.stagingPath}.audio.part').exists(),
              isTrue);
        }
      } finally {
        if (!finished.isCompleted) finished.complete();
        await stopping;
        await waitFor((state) => state.downloadProgresses.isEmpty);
        messenger.setMockMethodCallHandler(muxEvents, null);
        messenger.setMockMethodCallHandler(muxChannel, null);
      }
    });
  }

  test('cancellation survives a mux starting after the first cancel request',
      () async {
    const muxChannel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
    const muxEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
    final queued = Completer<void>();
    final start = Completer<void>();
    final finished = Completer<void>();
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    mediaServer!.listen((request) async {
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    AdaptiveFormat track(bool audio) => AdaptiveFormat(
        null,
        '128000',
        null,
        '$origin/${audio ? 'audio' : 'video'}',
        audio ? '251' : '243',
        '${audio ? 'audio' : 'video'}/webm',
        '4',
        '1',
        '',
        'webm',
        audio ? 'opus' : 'vp9',
        audio ? null : '720p',
        null);
    service = _DownloadService((id) async =>
        Video(videoId: id, adaptiveFormats: [track(true), track(false)]));
    var running = false;
    var cancellations = 0;
    var cancellationsAfterStart = 0;
    messenger.setMockMethodCallHandler(muxEvents, (_) async => null);
    messenger.setMockMethodCallHandler(muxChannel, (call) async {
      switch (call.method) {
        case 'ffmpegSession':
          return {'sessionId': 44};
        case 'ffmpegSessionExecute':
          queued.complete();
          await start.future;
          // The native executor resets its cancellation flag on startup.
          running = true;
          await finished.future;
          running = false;
          return null;
        case 'cancelSession':
          expect(call.arguments['sessionId'], 44);
          cancellations++;
          if (running) {
            cancellationsAfterStart++;
            if (!finished.isCompleted) finished.complete();
          } else if (!start.isCompleted) {
            start.complete();
          }
          return null;
        case 'cancel':
          fail('A download must not cancel unrelated FFmpeg sessions');
        case 'abstractSessionGetReturnCode':
          return 255;
        default:
          return null;
      }
    });
    Future<void>? stopping;
    try {
      await manager.setWifiOnly(false);
      await queued.future.timeout(const Duration(seconds: 5));
      stopping = manager.pauseForProfileSwitch();
      await stopping.timeout(const Duration(seconds: 2));
      expect(cancellationsAfterStart, greaterThan(0));
      expect(db.getDownloadByVideoId(video.videoId)!.downloadFailed, isFalse);
      expect(manager.state.pausedVideoIds, contains(video.videoId));
      final completedCancellations = cancellations;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(cancellations, completedCancellations,
          reason: 'A joined mux must not leave cancellation retries running');
    } finally {
      if (!start.isCompleted) start.complete();
      if (!finished.isCompleted) finished.complete();
      await stopping;
      await waitFor((state) => state.downloadProgresses.isEmpty);
      messenger.setMockMethodCallHandler(muxEvents, null);
      messenger.setMockMethodCallHandler(muxChannel, null);
    }
  });

  test('cancellation while creating a mux session prevents its execution',
      () async {
    const muxChannel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
    const muxEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
    final creating = Completer<void>();
    final created = Completer<void>();
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    mediaServer!.listen((request) async {
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    AdaptiveFormat track(bool audio) => AdaptiveFormat(
        null,
        '128000',
        null,
        '$origin/${audio ? 'audio' : 'video'}',
        audio ? '251' : '243',
        '${audio ? 'audio' : 'video'}/webm',
        '4',
        '1',
        '',
        'webm',
        audio ? 'opus' : 'vp9',
        audio ? null : '720p',
        null);
    service = _DownloadService((id) async =>
        Video(videoId: id, adaptiveFormats: [track(true), track(false)]));
    var executions = 0;
    messenger.setMockMethodCallHandler(muxEvents, (_) async => null);
    messenger.setMockMethodCallHandler(muxChannel, (call) async {
      switch (call.method) {
        case 'ffmpegSession':
          creating.complete();
          await created.future;
          return {'sessionId': 43};
        case 'ffmpegSessionExecute':
          executions++;
          return null;
        case 'abstractSessionGetReturnCode':
          return 255;
        default:
          return null;
      }
    });
    try {
      await manager.setWifiOnly(false);
      await creating.future.timeout(const Duration(seconds: 5));
      await manager.pauseDownload(video);
      created.complete();
      await waitFor((state) => state.downloadProgresses.isEmpty);
      expect(executions, 0);
      expect(db.getDownloadByVideoId(video.videoId)!.downloadFailed, isFalse);
    } finally {
      if (!created.isCompleted) created.complete();
      await waitFor((state) => state.downloadProgresses.isEmpty);
      messenger.setMockMethodCallHandler(muxEvents, null);
      messenger.setMockMethodCallHandler(muxChannel, null);
    }
  });

  test('HD MP4 uses AAC and saves a matching external document across reloads',
      () async {
    const muxChannel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
    const muxEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
    const mp4 = '$folder/document/primary%3AVidere%2Fvideo.mp4';
    const mediaBytes = [1, 2, 3, 4];
    final requests = <String>[];
    mediaServer!.listen((request) async {
      requests.add(request.uri.path);
      request.response.add(mediaBytes);
      await request.response.close();
    });
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    AdaptiveFormat track(String id, String type, String encoding,
            [String? quality]) =>
        AdaptiveFormat(null, '128000', null, '$origin/$id', id, type,
            '${mediaBytes.length}', '1', '', null, encoding, quality, quality);
    service = _DownloadService((id) async =>
        Video(videoId: id, title: 'Resolved title', adaptiveFormats: [
          track('251', 'audio/webm', 'opus'),
          track('140', 'audio/mp4', 'aac'),
          track('243', 'video/webm', 'vp9', '360p'),
          track('137', 'video/mp4', 'h264', '1080p'),
        ]));

    late List<String> muxArguments;
    messenger.setMockMethodCallHandler(muxEvents, (_) async => null);
    messenger.setMockMethodCallHandler(muxChannel, (call) async {
      switch (call.method) {
        case 'ffmpegSession':
          muxArguments = List<String>.from(call.arguments['arguments'] as List);
          return {'sessionId': 1};
        case 'ffmpegSessionExecute':
          await File(muxArguments.last).writeAsBytes(mediaBytes);
          return null;
        case 'abstractSessionGetReturnCode':
          return 0;
        default:
          return null;
      }
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(muxEvents, null);
      messenger.setMockMethodCallHandler(muxChannel, null);
    });
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      switch (call.method) {
        case 'pickFolder':
          return {'uri': folder, 'name': 'Videre'};
        case 'prepareDocument':
          expect(call.arguments['name'], endsWith('.mp4'));
          expect(call.arguments['mime'], 'video/mp4');
          return mp4;
        case 'writeDocument':
          expect(call.arguments['uri'], mp4);
          final saved = db.getDownloadByVideoId(video.videoId)!;
          expect(saved.container, DownloadContainer.mp4);
          expect(saved.downloadComplete, isFalse);
          expect(await File(call.arguments['source'] as String).readAsBytes(),
              mediaBytes);
          return null;
        default:
          return null;
      }
    });

    await manager.deleteVideo(video);
    await manager.chooseFolder();
    expect(await manager.addDownload(video.videoId, quality: '1080p'), isTrue);
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadComplete &&
        state.downloadProgresses.isEmpty);

    expect(requests, ['/140', '/137']);
    expect(muxArguments.last, endsWith('.mux.mp4'));
    expect(await File(muxArguments.last).exists(), isFalse);
    await manager.close();
    await openManager();
    final completed = manager.state.videos.single;
    expect(completed.container, DownloadContainer.mp4);
    expect(await completed.effectivePath, mp4);
  });

  test('failed folder writes retry the same document instead of duplicating it',
      () async {
    final audio = video.copyWith(audioOnly: true, folderUri: folder);
    await db.upsertDownload(audio);
    final remote = await audioVideo(audio.videoId);
    service = _DownloadService((_) async => remote);
    var writes = 0;
    final previousUris = <String?>[];
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'prepareDocument') {
        previousUris.add(call.arguments['existing'] as String?);
        return document;
      }
      if (call.method == 'writeDocument' && ++writes == 1) {
        throw PlatformException(code: 'DOWNLOAD_STORAGE');
      }
      return null;
    });
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadFailed && state.downloadProgresses.isEmpty);
    expect(manager.state.videos.single.storageFailed, isTrue);
    expect(manager.state.videos.single.storageUri, document);
    await manager.retryDownload(manager.state.videos.single);
    await waitFor((state) => state.videos.single.downloadComplete);
    expect(previousUris, [null, document]);
    expect(manager.state.videos.single.storageFailed, isFalse);
  });

  test(
      'failed external deletion preserves the record and local files for retry',
      () async {
    final completed = video.copyWith(
        folderUri: folder, storageUri: document, downloadComplete: true);
    await db.upsertDownload(completed);
    manager.setVideos();
    final artwork = File(await completed.thumbnailPath);
    final staging = File('${await completed.downloadPath}.mux.webm');
    await artwork.writeAsBytes([1, 2]);
    await staging.writeAsBytes([3, 4]);
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      expect(call.method, 'deleteDocument');
      expect(call.arguments['uri'], document);
      throw PlatformException(code: 'DOWNLOAD_STORAGE');
    });

    await expectLater(
        manager.deleteVideo(completed), throwsA(isA<PlatformException>()));
    expect(db.getDownloadByVideoId(video.videoId), completed);
    expect(manager.state.videos.single, completed);
    expect(await artwork.readAsBytes(), [1, 2]);
    expect(await staging.readAsBytes(), [3, 4]);

    messenger.setMockMethodCallHandler(storageChannel, (_) async => null);
    await manager.deleteVideo(completed);
    expect(db.getDownloadByVideoId(video.videoId), isNull);
    expect(manager.state.videos, isEmpty);
    expect(await artwork.exists(), isFalse);
    expect(await staging.exists(), isFalse);
  });

  test('lost folder access fails before fetching media and preserves the job',
      () async {
    await db.upsertDownload(video.copyWith(folderUri: folder));
    var fetched = false;
    service = _DownloadService((_) async {
      fetched = true;
      return Video(videoId: video.videoId);
    });
    messenger.setMockMethodCallHandler(storageChannel,
        (_) async => throw PlatformException(code: 'DOWNLOAD_STORAGE'));
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.storageFailed);
    expect(fetched, isFalse);
    expect(manager.state.videos.single.downloadComplete, isFalse);
    expect(manager.state.videos.single.folderUri, folder);
  });

  test(
      'delete cancels an external write and removes its newly recorded document',
      () async {
    final audio = video.copyWith(audioOnly: true, folderUri: folder);
    await db.upsertDownload(audio);
    service = _DownloadService((_) => audioVideo(audio.videoId));
    final started = Completer<void>(), cancelled = Completer<void>();
    String? deleted;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'prepareDocument') return document;
      if (call.method == 'writeDocument') {
        started.complete();
        await cancelled.future;
        throw PlatformException(code: 'DOWNLOAD_STORAGE');
      }
      if (call.method == 'cancelWrite') cancelled.complete();
      if (call.method == 'deleteDocument') {
        deleted = call.arguments['uri'] as String;
      }
      return null;
    });
    await manager.setWifiOnly(false);
    await started.future.timeout(const Duration(seconds: 5));
    await manager.deleteVideo(audio).timeout(const Duration(seconds: 5));
    expect(deleted, document);
    expect(manager.state.videos, isEmpty);
    expect(
        await File('${await audio.downloadPath}.mux.webm').exists(), isFalse);
  });

  test('legacy downloads keep their private path and filenames stay portable',
      () async {
    final legacy = DownloadedVideo.fromJson({
      'videoId': video.videoId,
      'title': video.title,
      'lengthSeconds': 12,
      'quality': '720p',
      'downloadComplete': true,
    });
    expect(legacy.storageUri, isNull);
    expect(legacy.folderUri, isNull);
    expect(legacy.toJson()['sponsorSegments'], isEmpty);
    expect(await legacy.effectivePath, endsWith('${video.videoId}.mp4'));
    await File(await legacy.downloadPath).writeAsBytes([1]);
    expect(await legacy.effectivePath, await legacy.downloadPath);
    expect(video.copyWith(title: '../Title: a/b').fileName,
        '.._Title_ a_b_${video.videoId}.webm');
    expect(video.copyWith(title: List.filled(200, '🙂').join()).fileName.length,
        lessThan(150));
  });

  test('different people keep separate files for the same video', () async {
    final other = video.copyWith(profileId: 'another-person');
    final originalMedia = File(await video.downloadPath);
    final otherMedia = File(await other.downloadPath);
    expect(otherMedia.path, isNot(originalMedia.path));
    expect(await other.thumbnailPath, isNot(await video.thumbnailPath));
    await originalMedia.writeAsString('original');
    await otherMedia.writeAsString('other');
    await otherMedia.delete();
    expect(await originalMedia.readAsString(), 'original');

    for (final id in ['../outside', r'..\outside', '', 'a' * 129]) {
      await expectLater(video.copyWith(profileId: id).downloadPath,
          throwsA(isA<FormatException>()));
    }
  });

  test('pause survives restart and resume keeps the queued job', () async {
    await manager.pauseDownload(video);
    await manager.close();
    await openManager();
    expect(manager.state.pausedVideoIds, contains(video.videoId));
    await manager.retryDownload(video);
    expect(manager.state.pausedVideoIds, isEmpty);
    expect(manager.state.videos.single, video);
    expect(manager.state.waitingForWifi, true);
  });

  test('stale retry actions preserve completed downloads', () async {
    final completed = video.copyWith(
        title: 'Resolved title', downloadComplete: true, audioOnly: true);
    await db.upsertDownload(completed);
    manager.setVideos();

    await manager.retryDownload(video);

    expect(db.getDownloadByVideoId(video.videoId), completed);
    expect(manager.state.videos.single, completed);
  });

  test('stale retry actions cannot recreate deleted downloads', () async {
    await manager.deleteVideo(video);

    await manager.retryDownload(video);

    expect(db.getDownloadByVideoId(video.videoId), isNull);
    expect(manager.state.videos, isEmpty);
  });

  test('a failed deletion does not leave the download permanently blocked',
      () async {
    final failed = video.copyWith(downloadFailed: true);
    await db.upsertDownload(failed);
    manager.setVideos();
    messenger.setMockMethodCallHandler(pathProvider,
        (_) async => throw PlatformException(code: 'storage-unavailable'));

    await expectLater(
        manager.deleteVideo(failed), throwsA(isA<PlatformException>()));
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documentsDirectory.path);
    await manager.retryDownload(failed);

    expect(manager.state.videos.single.downloadFailed, isFalse);
  });

  test('retry clears failure on the saved job without restoring stale metadata',
      () async {
    final failed = video.copyWith(
        title: 'Resolved title', downloadFailed: true, audioOnly: true);
    await db.upsertDownload(failed);
    manager.setVideos();

    await manager.retryDownload(video);

    expect(db.getDownloadByVideoId(video.videoId),
        failed.copyWith(downloadFailed: false));
    expect(manager.state.videos.single, failed.copyWith(downloadFailed: false));
  });

  test('batch queues unique jobs and skips existing videos', () async {
    final added = await manager.addDownloads(
        ['abcdefghijk', '12345678901', '12345678901', 'zyxwvutsrqp'],
        audioOnly: true);
    expect(added, 2);
    expect(manager.state.videos, hasLength(3));
    expect(manager.state.videos.where((v) => v.audioOnly), hasLength(2));
  });

  test(
      'music audio download keeps catalog metadata through restart and hydration',
      () async {
    await manager.deleteVideo(video);
    const music = MusicMetadata(
        title: 'Catalog song',
        artist: 'Catalog artist',
        album: 'Catalog album');
    const song = Video(
        videoId: '12345678901',
        title: 'Catalog song',
        lengthSeconds: 180,
        musicMetadata: music);
    final remote = await audioVideo(song.videoId);
    service = _DownloadService((_) async => remote);
    expect(
        await manager.addDownload(song.videoId, audioOnly: true, video: song),
        isTrue);
    final queued = db.getDownloadByVideoId(song.videoId)!;
    expect(queued.audioOnly, isTrue);
    expect(queued.title, music.title);
    expect(queued.author, music.artist);
    expect(DownloadedVideo.fromJson(queued.toJson()).musicMetadata?.toJson(),
        music.toJson());

    await manager.close();
    await openManager();
    expect(manager.state.videos.single.musicMetadata?.toJson(), music.toJson());
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    final downloaded = db.getDownloadByVideoId(song.videoId)!;
    expect(downloaded.musicMetadata?.toJson(), music.toJson());
    expect(downloaded.title, music.title);
    expect(downloaded.author, music.artist);
    expect(downloaded.lengthSeconds, song.lengthSeconds);
    expect(downloaded.audioOnly, isTrue);
  });

  test('music download caches enabled SponsorBlock data across restart',
      () async {
    final music = video.copyWith(
        audioOnly: true,
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
    await db.upsertDownload(music);
    await db.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    await db.saveSetting(
        SettingsValue(SponsorSegmentType.musicOffTopic.settingsName(), 'true'));
    await db.saveSetting(
        SettingsValue(SponsorSegmentType.intro.settingsName(), 'true'));
    final segments = [
      SponsorSegment('skip', [1.25, 2.75], SponsorSegmentType.musicOffTopic),
      SponsorSegment('mute', [3, 4], SponsorSegmentType.intro),
    ];
    final calls = <String>[];
    List<SponsorSegmentType>? requestedCategories;
    service = _DownloadService((_) => audioVideo(music.videoId),
        sponsors: (id, categories) async {
      calls.add(id);
      requestedCategories = categories;
      return [
        ...segments,
        SponsorSegment('skip', [double.nan, 7], SponsorSegmentType.intro),
      ];
    });

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(calls, [music.videoId]);
    expect(requestedCategories,
        [SponsorSegmentType.intro, SponsorSegmentType.musicOffTopic]);
    final downloaded = db.getDownloadByVideoId(music.videoId)!;
    final expected = segments.map((segment) => segment.toJson()).toList();
    expect(downloaded.toJson()['sponsorSegments'], expected);
    final roundTrip = DownloadedVideo.fromJson(
        jsonDecode(jsonEncode(downloaded.toJson())) as Map<String, dynamic>);
    expect(roundTrip.toJson()['sponsorSegments'], expected);
    await manager.close();
    await openManager();
    expect(manager.state.videos.single.toJson()['sponsorSegments'], expected);
    expect(calls, [music.videoId]);
  });

  for (final nonMusicOptOut in [false, true]) {
    test(
        'Music download caches default categories (non-music opt-out: $nonMusicOptOut)',
        () async {
      final music = video.copyWith(
          audioOnly: true,
          musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
      await db.upsertDownload(music);
      if (nonMusicOptOut) {
        await db.saveSetting(SettingsValue(
            SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
      }
      final segments = [
        SponsorSegment('skip', [1, 2], SponsorSegmentType.sponsor),
        if (!nonMusicOptOut)
          SponsorSegment('skip', [3, 4], SponsorSegmentType.musicOffTopic),
      ];
      List<SponsorSegmentType>? requestedCategories;
      service = _DownloadService((_) => audioVideo(music.videoId),
          sponsors: (_, categories) async {
        requestedCategories = categories;
        return segments;
      });

      await manager.setWifiOnly(false);
      await waitFor((state) => state.videos.single.downloadComplete);

      expect(requestedCategories, [
        SponsorSegmentType.sponsor,
        if (!nonMusicOptOut) SponsorSegmentType.musicOffTopic,
      ]);
      expect(
          db.getDownloadByVideoId(music.videoId)!.toJson()['sponsorSegments'],
          segments.map((segment) => segment.toJson()).toList());
    });
  }

  for (final musicEnabled in [true, false]) {
    test(
        musicEnabled
            ? 'music download does not fetch disabled SponsorBlock categories'
            : 'ordinary download does not fetch Music SponsorBlock cache',
        () async {
      final audio = video.copyWith(
          audioOnly: true,
          musicMetadata: musicEnabled
              ? const MusicMetadata(title: 'Song', artist: 'Artist')
              : null);
      await db.upsertDownload(audio);
      if (musicEnabled) {
        await db.saveSetting(
            SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
        await db.saveSetting(SettingsValue(
            SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
      }
      var calls = 0;
      service = _DownloadService((_) => audioVideo(audio.videoId),
          sponsors: (_, __) async {
        calls++;
        return [];
      });

      await manager.setWifiOnly(false);
      await waitFor((state) => state.videos.single.downloadComplete);

      expect(calls, 0);
      expect(db.getDownloadByVideoId(audio.videoId)!.sponsorSegments, isEmpty);
    });
  }

  for (final timeout in [false, true]) {
    test(
        'SponsorBlock ${timeout ? 'timeout' : 'failure'} does not fail Music download',
        () async {
      final previous = timeout
          ? <SponsorSegment>[]
          : [
              SponsorSegment('skip', [1, 2], SponsorSegmentType.sponsor)
            ];
      final music = video.copyWith(
          audioOnly: true,
          musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
          sponsorSegments: previous);
      await db.upsertDownload(music);
      final response = Completer<List<SponsorSegment>>();
      var calls = 0;
      String? requestedId;
      List<SponsorSegmentType>? requestedCategories;
      service = _DownloadService((_) => audioVideo(music.videoId),
          sponsors: (id, categories) {
        calls++;
        requestedId = id;
        requestedCategories = categories;
        if (!timeout) throw StateError('Optional SponsorBlock unavailable');
        return response.future;
      });

      await manager.setWifiOnly(false);
      await waitFor((state) => state.videos.single.downloadComplete);

      expect(calls, 1);
      expect(requestedId, music.videoId);
      expect(requestedCategories,
          [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);
      final expected = previous.map((segment) => segment.toJson()).toList();
      expect(
          db.getDownloadByVideoId(music.videoId)!.toJson()['sponsorSegments'],
          expected);
      expect(manager.state.videos.single.downloadFailed, isFalse);
      if (timeout) {
        response.complete([
          SponsorSegment('skip', [5, 6], SponsorSegmentType.sponsor),
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(
            db.getDownloadByVideoId(music.videoId)!.sponsorSegments, isEmpty);
      }
    });
  }

  test('SponsorBlock HTTP failure preserves previously cached Music segments',
      () async {
    final previous =
        SponsorSegment('skip', [1.25, 2.75], SponsorSegmentType.sponsor);
    final music = video.copyWith(
        audioOnly: true,
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
        sponsorSegments: [previous]);
    await db.upsertDownload(music);
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return http.Response('temporarily unavailable', 503);
    });
    addTearDown(client.close);
    final sponsorService = Service(httpClient: client);
    service = _DownloadService((_) => audioVideo(music.videoId),
        sponsors: sponsorService.getSponsorSegments);

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(requests, hasLength(1));
    expect(requests.single.host, 'sponsor.ajay.app');
    expect(requests.single.queryParameters['videoID'], music.videoId);
    expect(requests.single.queryParameters['categories'],
        '["sponsor","music_offtopic"]');
    final downloaded = db.getDownloadByVideoId(music.videoId)!;
    expect(downloaded.downloadFailed, isFalse);
    expect(downloaded.toJson()['sponsorSegments'], [previous.toJson()]);
  });

  for (final action in ['delete', 'profile switch', 'close']) {
    test('pending Music SponsorBlock lookup does not block $action', () async {
      final music = video.copyWith(
          audioOnly: true,
          musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
      await db.upsertDownload(music);
      final ownerLibrary = db.forProfile(db.profileId);
      final response = Completer<List<SponsorSegment>>();
      final started = Completer<void>(), mediaReceived = Completer<void>();
      List<SponsorSegmentType>? requestedCategories;
      final remote = await audioVideo(music.videoId,
          onRequest: (_) => mediaReceived.complete());
      service =
          _DownloadService((_) async => remote, sponsors: (_, categories) {
        requestedCategories = categories;
        started.complete();
        return response.future;
      });

      await manager.setWifiOnly(false);
      await started.future;
      await mediaReceived.future;
      expect(requestedCategories,
          [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);
      switch (action) {
        case 'delete':
          await manager.deleteVideo(music).timeout(const Duration(seconds: 2));
        case 'profile switch':
          await manager
              .pauseForProfileSwitch()
              .timeout(const Duration(seconds: 2));
          final person = await db.createProfile('Another person');
          await db.useProfile(person.id);
          await db.saveSetting(SettingsValue(
              SponsorSegmentType.musicOffTopic.settingsName(), 'true'));
          await manager.reloadForProfile();
        case 'close':
          await manager.close().timeout(const Duration(seconds: 2));
      }
      response.complete([
        SponsorSegment('skip', [5, 6], SponsorSegmentType.sponsor),
      ]);
      await Future<void>.delayed(Duration.zero);

      final saved = ownerLibrary.getDownloadByVideoId(music.videoId);
      if (action == 'delete') {
        expect(saved, isNull);
      } else {
        expect(saved!.downloadComplete, isFalse);
        expect(saved.downloadFailed, isFalse);
        expect(saved.sponsorSegments, isEmpty);
      }
      if (action == 'profile switch') {
        expect(manager.state.videos, isEmpty);
        expect(db.getAllDownloads(), isEmpty);
      }
      expect(await File(await music.downloadPath).exists(), isFalse);
    });
  }

  test('download metadata cannot be attached to a different video ID',
      () async {
    expect(
        await manager.addDownload('12345678901',
            audioOnly: true, video: const Video(videoId: 'different01')),
        isFalse);
    expect(db.getDownloadByVideoId('12345678901'), isNull);
  });

  test('concurrent duplicate requests create just one job', () async {
    final results = await Future.wait([
      manager.addDownload('12345678901'),
      manager.addDownload('12345678901')
    ]);
    expect(results.where((accepted) => accepted), hasLength(1));
    expect(manager.state.videos, hasLength(2));
  });

  test('pausing a metadata request prevents transfer and resume completes it',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    var requests = 0;
    final remote =
        await audioVideo(audio.videoId, onRequest: (_) => requests++);
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    var fetches = 0;
    service = _DownloadService((_) {
      fetches++;
      if (fetches == 1) metadataStarted.complete();
      return fetches == 1 ? metadata.future : Future.value(remote);
    });
    await manager.setWifiOnly(false);
    await metadataStarted.future;
    await manager.pauseDownload(audio);
    metadata.complete(remote);
    await waitFor((state) => state.downloadProgresses.isEmpty);
    expect(requests, 0);
    expect(manager.state.videos.single.downloadFailed, false);

    await manager.retryDownload(manager.state.videos.single);
    await waitFor((state) => state.videos.single.downloadComplete);
    expect(fetches, 2);
    expect(requests, 1);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('switching servers during metadata keeps the original transfer headers',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final receivedKeys = <String?>[];
    final remote = await audioVideo(audio.videoId,
        onRequest: (request) =>
            receivedKeys.add(request.headers.value('X-Instance-Key')));
    final originalServer = Server(
        url: 'http://127.0.0.1:${mediaServer!.port}',
        customHeaders: {'X-Instance-Key': 'original-instance'});
    final nextServer = Server(
        url: 'http://localhost:${mediaServer!.port}',
        customHeaders: {'X-Instance-Key': 'next-instance'});
    await db.upsertServer(originalServer);
    await db.useServer(originalServer);
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    Server? metadataServer;
    service = _DownloadService((_) {
      metadataStarted.complete();
      return metadata.future;
    }, onServer: (server) => metadataServer = server);

    await manager.setWifiOnly(false);
    await metadataStarted.future;
    await db.useServer(nextServer);
    metadata.complete(remote);
    await waitFor((state) =>
        state.videos.single.downloadComplete ||
        state.videos.single.downloadFailed);

    expect(manager.state.videos.single.downloadComplete, isTrue);
    expect(receivedKeys, ['original-instance']);
    expect(metadataServer?.url, originalServer.url);
    expect(metadataServer?.customHeaders, originalServer.customHeaders);
    expect((await db.getCurrentlySelectedServer()).url, nextServer.url);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  for (final proxyVideos in [false, true]) {
    test('download ignores legacy proxy=$proxyVideos and stays on its instance',
        () async {
      final audio = video.copyWith(audioOnly: true);
      await db.upsertDownload(audio);
      final received = <(String, Uri, String?)>[];
      final remote = await audioVideo(audio.videoId, onRequest: (request) {
        received.add(
            ('instance', request.uri, request.headers.value('X-Instance-Key')));
      });
      const source = 'https://r1---sn-test.googlevideo.com/videoplayback'
          '?sig=signed%2Bvalue&itag=251&duplicate=first&duplicate=second';
      remote.adaptiveFormats!.single.url = source;
      final original = Server(
          url: 'http://127.0.0.1:${mediaServer!.port}/proxy',
          customHeaders: {'X-Instance-Key': 'original-instance'});
      final other = Server(
          url: 'http://localhost:${mediaServer!.port}/other',
          customHeaders: {'X-Instance-Key': 'other-instance'});
      await db.useServer(original);
      await db.saveSetting(
          SettingsValue(useProxySettingName, proxyVideos.toString()));
      service = _DownloadService((_) async {
        await db.useServer(other);
        return remote;
      });

      final destinations = <Uri>[];
      await HttpOverrides.runZoned(() async {
        await manager.setWifiOnly(false);
        await waitFor((state) =>
            state.videos.single.downloadComplete ||
            state.videos.single.downloadFailed);
      }, createHttpClient: (context) {
        return _DirectHttpOverrides().createHttpClient(context)
          ..connectionFactory = (uri, _, __) {
            destinations.add(uri);
            // A legacy direct setting must not reach a Google connection at
            // all. Never resolve or open an official endpoint in this test.
            expect(uri.host, '127.0.0.1');
            return Socket.startConnect(
                InternetAddress.loopbackIPv4, mediaServer!.port);
          };
      });

      expect(manager.state.videos.single.downloadComplete, isTrue);
      expect(destinations, hasLength(1));
      expect(received, hasLength(1));
      expect(received.single.$1, 'instance');
      expect(received.single.$3, 'original-instance');
      expect(destinations.single.host, '127.0.0.1');
      expect(received.single.$2.path, '/proxy/videoplayback');
      expect(received.single.$2.queryParameters['sig'], 'signed+value');
      expect(received.single.$2.queryParametersAll['duplicate'],
          ['first', 'second']);
      expect(received.single.$2.queryParameters['host'],
          'r1---sn-test.googlevideo.com');
      expect(await File(await audio.downloadPath).readAsBytes(),
          [0, 1, 2, 3, 4, 5, 6, 7]);
    });
  }

  test('download rejects an unrelated media origin before opening a connection',
      () async {
    await db.upsertDownload(video.copyWith(audioOnly: true));
    var requests = 0;
    final remote =
        await audioVideo(video.videoId, onRequest: (_) => requests++);
    remote.adaptiveFormats!.single.url =
        'http://localhost:${mediaServer!.port}/unrelated';
    service = _DownloadService((_) async => remote);
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadComplete ||
        state.videos.single.downloadFailed);
    expect(manager.state.videos.single.downloadFailed, isTrue);
    expect(requests, 0);
  });

  test('download ranks only tracks that can use the selected instance',
      () async {
    await db.upsertDownload(video.copyWith(audioOnly: true));
    final requests = <String>[];
    final remote = await audioVideo(video.videoId,
        onRequest: (request) => requests.add(request.uri.path));
    final mixed = remote.copyWith(adaptiveFormats: [
      ...remote.adaptiveFormats!,
      AdaptiveFormat(null, '256000', null, 'https://unrelated.example/audio',
          '252', 'audio/webm', '8', '1', '', 'webm', 'opus', null, null),
    ]);
    service = _DownloadService((_) async => mixed);

    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadComplete ||
        state.videos.single.downloadFailed);
    expect(manager.state.videos.single.downloadComplete, isTrue);
    expect(requests, ['/audio']);
    expect(
        await File(await video.copyWith(audioOnly: true).downloadPath)
            .readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('a queued download retains its account after a same-server switch',
      () async {
    await manager.deleteVideo(video);
    final remote = await audioVideo(video.videoId);
    final original = Server(
        id: 'first-account',
        url: 'http://127.0.0.1:${mediaServer!.port}',
        authToken: 'first');
    final other = Server(
        id: 'second-account',
        url: 'http://127.0.0.1:${mediaServer!.port}',
        authToken: 'second');
    await db.useServer(original);
    await manager.addDownload(video.videoId, audioOnly: true);
    await db.useServer(other);
    await manager.close();
    await openManager();
    Server? requestedAccount;
    service = _DownloadService((_) async => remote,
        onServer: (server) => requestedAccount = server);

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(requestedAccount?.accountId, original.accountId);
    expect(requestedAccount?.authToken, original.authToken);
    expect(
        db.getDownloadByVideoId(video.videoId)!.accountId, original.accountId);
    expect((await db.getCurrentlySelectedServer()).accountId, other.accountId);
  });

  test('download retries cannot move to a different account on the same server',
      () async {
    final remote = await audioVideo(video.videoId);
    final original = Server(
        id: 'retry-original',
        url: 'http://127.0.0.1:${mediaServer!.port}',
        authToken: 'first');
    final other = Server(
        id: 'retry-other',
        url: 'http://127.0.0.1:${mediaServer!.port}',
        authToken: 'second');
    await db.useServer(original);
    await db.upsertDownload(video.copyWith(audioOnly: true));
    final requests = <String>[];
    var attempts = 0;
    service = _DownloadService((_) async {
      if (++attempts == 1) {
        await db.useServer(other);
        throw const SocketException('Temporary failure');
      }
      return remote;
    }, onServer: (server) => requests.add(server!.accountId));

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(requests, [original.accountId, original.accountId]);
    expect(
        db.getDownloadByVideoId(video.videoId)!.accountId, original.accountId);
  });

  for (final removeOriginal in [false, true]) {
    test(
        'a legacy download ${removeOriginal ? 'rejects a replacement account' : 'retains its existing account'} at the same URL',
        () async {
      await manager.deleteVideo(video);
      final remote = await audioVideo(video.videoId);
      final original = Server(
          url: 'http://127.0.0.1:${mediaServer!.port}',
          authToken: 'legacy-account');
      final replacement = Server(
          id: 'replacement-account',
          url: 'http://127.0.0.1:${mediaServer!.port}',
          authToken: 'replacement-account');
      await db.upsertServer(original);
      await db.useServer(original);
      await manager.addDownload(video.videoId, audioOnly: true);
      final queued = db.getDownloadByVideoId(video.videoId)!;
      final partial = File('${await queued.downloadPath}.audio.part');
      await partial.writeAsBytes([0, 1, 2]);
      await db.upsertServer(replacement);
      await db.useServer(replacement);
      if (removeOriginal) await db.deleteServer(original);
      final requests = <Server>[];
      service = _DownloadService((_) async => remote,
          onServer: (server) => requests.add(server!));

      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.videos.single.downloadComplete ||
          state.videos.single.downloadFailed);

      final saved = db.getDownloadByVideoId(video.videoId)!;
      expect(saved.accountId, original.accountId);
      if (removeOriginal) {
        expect(requests, isEmpty);
        expect(saved.downloadFailed, isTrue);
        expect(saved.downloadComplete, isFalse);
        expect(await partial.readAsBytes(), [0, 1, 2]);
      } else {
        expect(requests.single.accountId, original.accountId);
        expect(requests.single.authToken, original.authToken);
        expect(saved.downloadComplete, isTrue);
      }
      expect((await db.getCurrentlySelectedServer()).accountId,
          replacement.accountId);
    });
  }

  for (final wrapped in [false, true]) {
    test('expired gateway pauses a download across restart (Dio: $wrapped)',
        () async {
      await db.upsertDownload(video.copyWith(audioOnly: true));
      final partial = File('${await video.downloadPath}.audio.part');
      await partial.writeAsBytes([0, 1, 2]);
      var requests = 0;
      service = _DownloadService((_) async {
        requests++;
        if (wrapped) {
          throw DioException(
              requestOptions: RequestOptions(path: '/audio'),
              error: const GatewayAuthenticationRequired());
        }
        throw const GatewayAuthenticationRequired();
      });

      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.videos.single.authenticationRequired &&
          state.downloadProgresses.isEmpty);
      expect(requests, 1);
      expect(manager.state.videos.single.downloadFailed, isFalse);
      expect(manager.state.pausedVideoIds, contains(video.videoId));
      expect(await partial.readAsBytes(), [0, 1, 2]);
      await manager.close();
      await openManager();
      expect(manager.state.videos.single.authenticationRequired, isTrue);
      expect(requests, 1);

      final remote = await audioVideo(video.videoId);
      service = _DownloadService((_) async => remote);
      await manager.retryDownload(manager.state.videos.single);
      await waitFor((state) => state.videos.single.downloadComplete);
      expect(manager.state.videos.single.authenticationRequired, isFalse);
      expect(manager.state.pausedVideoIds, isEmpty);
    });
  }

  for (final (label, failure, signInRequired) in <(String, Object, bool)>[
    ('missing key', const NerdVpnAccessRequired('missing'), true),
    ('expired key', const NerdVpnAccessRequired('signInRequired'), true),
    ('waiting', const NerdVpnAccessRequired('waiting'), false),
    ('disabled', const NerdVpnAccessRequired('disabled'), false),
    ('denied', const NerdVpnAccessRequired('denied'), false),
    ('cooldown', const NerdVpnAccessRequired('unavailable'), false),
    (
      'Dio disabled',
      DioException(
          requestOptions: RequestOptions(path: '/audio'),
          error: const NerdVpnAccessRequired('disabled')),
      false
    ),
    (
      'gateway disabled',
      InvidiousServiceError('API access disabled',
          statusCode: 403,
          errorCode: 'access_disabled',
          isGatewayResponse: true),
      false
    ),
    (
      'gateway expired key',
      InvidiousServiceError('Invalid API key',
          statusCode: 401,
          errorCode: 'invalid_credentials',
          isGatewayResponse: true),
      true
    ),
    (
      'gateway cooldown',
      InvidiousServiceError('Try later',
          statusCode: 429, errorCode: 'rate_limited', isGatewayResponse: true),
      false
    ),
  ]) {
    test('NerdVPN $label pauses without download retries across restart',
        () async {
      await db.upsertDownload(video.copyWith(audioOnly: true));
      final partial = File('${await video.downloadPath}.audio.part');
      await partial.writeAsBytes([0, 1, 2]);
      var requests = 0;
      service = _DownloadService((_) async {
        requests++;
        throw failure;
      });

      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.downloadProgresses.isEmpty &&
          (state.videos.single.downloadFailed ||
              state.pausedVideoIds.contains(video.videoId)));
      expect(requests, 1);
      expect(manager.state.videos.single.downloadFailed, isFalse);
      expect(
          manager.state.videos.single.authenticationRequired, signInRequired);
      expect(manager.state.pausedVideoIds, contains(video.videoId));
      expect(await partial.readAsBytes(), [0, 1, 2]);
      await manager.close();
      await openManager();
      expect(
          manager.state.videos.single.authenticationRequired, signInRequired);
      expect(manager.state.pausedVideoIds, contains(video.videoId));
      expect(requests, 1);

      final remote = await audioVideo(video.videoId);
      service = _DownloadService((_) async => remote);
      await manager.retryDownload(manager.state.videos.single);
      await waitFor((state) => state.videos.single.downloadComplete);
      expect(manager.state.videos.single.authenticationRequired, isFalse);
      expect(manager.state.pausedVideoIds, isEmpty);
    });
  }

  test('switching people cancels metadata and ignores its late completion',
      () async {
    final originalLibrary = db.forProfile(db.profileId);
    final metadata = Completer<Video>();
    final started = Completer<void>();
    service = _DownloadService((_) {
      started.complete();
      return metadata.future;
    });
    await manager.setWifiOnly(false);
    await started.future;
    await manager.pauseForProfileSwitch().timeout(const Duration(seconds: 2));
    final person = await db.createProfile('Another person');
    await db.useProfile(person.id);
    await db.useServer(Server(
        profileId: person.id,
        id: 'another-account',
        url: 'https://instance.invalid'));
    await manager.reloadForProfile();
    metadata.complete(Video(videoId: video.videoId, title: 'Late result'));
    await Future<void>.delayed(Duration.zero);

    expect(manager.state.videos, isEmpty);
    expect(db.getAllDownloads(), isEmpty);
    expect(originalLibrary.getAllDownloads(), hasLength(1));
    expect(originalLibrary.getAllDownloads().single.downloadFailed, isFalse);
    expect(originalLibrary.getSettings('downloads-paused')!.value,
        contains(video.videoId));
    expect(await File(await video.downloadPath).exists(), isFalse);
  });

  test('stale actions cannot delete or resume another person\'s matching video',
      () async {
    final original = video.copyWith(downloadComplete: true);
    await db.upsertDownload(original);
    await File(await original.downloadPath).writeAsString('original');
    await manager.pauseForProfileSwitch();
    final person = await db.createProfile('Another person');
    await db.useProfile(person.id);
    await db.saveSetting(SettingsValue('downloads-wifi-only', 'true'));
    final other = video.copyWith(
        profileId: person.id, title: 'Other', downloadComplete: true);
    await db.upsertDownload(other);
    await File(await other.downloadPath).writeAsString('other');
    await manager.reloadForProfile();

    await manager.deleteVideo(original);
    await manager.retryDownload(original);
    await manager.pauseDownload(original);

    expect(db.getAllDownloads(), [other]);
    expect(manager.state.videos, [other]);
    expect(manager.state.pausedVideoIds, isEmpty);
    expect(await File(await other.downloadPath).readAsString(), 'other');
    expect(await File(await original.downloadPath).readAsString(), 'original');
  });

  test('a profile switch preserves an active partial and resumes its owner',
      () async {
    const originalBytes = [0, 1, 2, 3, 4, 5, 6, 7];
    const otherBytes = [8, 9, 10, 11, 12, 13, 14, 15];
    final releaseFirstResponse = Completer<void>();
    addTearDown(() {
      if (!releaseFirstResponse.isCompleted) releaseFirstResponse.complete();
    });
    final ranges = <String?>[];
    var originalRequests = 0;
    mediaServer!.listen((request) async {
      try {
        if (request.uri.queryParameters['person'] != 'default') {
          request.response.add(otherBytes);
        } else {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          if (++originalRequests == 1) {
            request.response.bufferOutput = false;
            request.response.add(originalBytes.take(3).toList());
            await request.response.flush();
            await releaseFirstResponse.future;
            request.response.add(originalBytes.skip(3).toList());
          } else {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers
                .set(HttpHeaders.contentRangeHeader, 'bytes 3-7/8');
            request.response.add(originalBytes.skip(3).toList());
          }
        }
        await request.response.close();
      } on SocketException {
        // The profile switch intentionally closes the first response early.
      } on HttpException {
        // A cancelled connection can reject the remaining response bytes.
      }
    });
    Server? requestedAccount;
    service = _DownloadService((_) async {
      return Video(videoId: video.videoId, adaptiveFormats: [
        AdaptiveFormat(
            null,
            '128000',
            null,
            'http://127.0.0.1:${mediaServer!.port}/audio?person=${requestedAccount!.profileId}',
            '251',
            'audio/webm',
            '8',
            '1',
            '',
            'webm',
            'opus',
            null,
            null)
      ]);
    }, onServer: (server) => requestedAccount = server);
    await db.upsertDownload(video.copyWith(audioOnly: true));
    await manager.setWifiOnly(false);
    await waitFor((state) => state.totalProgress > 0).onError<TimeoutException>(
        (_, __) =>
            throw StateError('First transfer did not start: ${manager.state}'));
    await manager.pauseForProfileSwitch().timeout(const Duration(seconds: 2));
    releaseFirstResponse.complete();
    final originalLibrary = db.forProfile('default');
    final partial = File('${await video.downloadPath}.audio.part');
    expect(await partial.readAsBytes(), originalBytes.take(3).toList());

    final person = await db.createProfile('Other downloader');
    await db.useProfile(person.id);
    await db.useServer(Server(
        profileId: person.id,
        id: 'other-download-account',
        url: 'http://127.0.0.1:${mediaServer!.port}'));
    await manager.reloadForProfile();
    await manager.addDownload(video.videoId, audioOnly: true);
    await waitFor((state) => state.videos.single.downloadComplete)
        .onError<TimeoutException>((_, __) => throw StateError(
            'Other transfer did not complete: ${manager.state}'));
    final other = manager.state.videos.single;
    expect(await File(await other.downloadPath).readAsBytes(), otherBytes);
    expect(originalLibrary.getAllDownloads().single.downloadComplete, isFalse);
    expect(await partial.readAsBytes(), originalBytes.take(3).toList());

    await manager.pauseForProfileSwitch();
    await db.useProfile('default');
    await manager.reloadForProfile();
    await manager.close();
    await openManager();
    expect(manager.state.pausedVideoIds, contains(video.videoId));
    await manager.retryDownload(manager.state.videos.single);
    await waitFor((state) => state.videos.single.downloadComplete)
        .onError<TimeoutException>((_, __) => throw StateError(
            'Original resume did not complete: ${manager.state}'));
    expect(ranges, [null, 'bytes=3-']);
    expect(await File(await video.downloadPath).readAsBytes(), originalBytes);
    expect(await File(await other.downloadPath).readAsBytes(), otherBytes);
  });

  test('malformed image error bodies cannot fail the media download', () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    var mediaRequests = 0;
    final remote = await audioVideoWithArtwork(
        audioDelay: const Duration(milliseconds: 200),
        onAudio: (_) => mediaRequests++,
        onArtwork: (request) async {
          request.response.statusCode = 502;
          request.response.headers.contentType = ContentType.json;
          request.response.write('upstream gateway unavailable');
          await request.response.close();
        });
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await waitFor((state) => state.downloadProgresses.isEmpty);

    expect(manager.state.videos.single.downloadFailed, isFalse);
    expect(manager.state.videos.single.downloadComplete, isTrue);
    expect(mediaRequests, 1);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
    final cover = await audio.thumbnailPath;
    expect(await File(cover).exists(), isFalse);
    expect(await File('$cover.part').exists(), isFalse);
  });

  test('music audio download saves its proxied cover with instance headers',
      () async {
    const coverPath = '/ggpht/music-cover';
    final requests = <(String, String?)>[];
    final remote = await audioVideoWithArtwork(onArtwork: (request) async {
      requests.add((request.uri.path, request.headers.value('X-Instance-Key')));
      request.response.add([10, 11, 12]);
      await request.response.close();
    }, onAudio: (request) {
      requests.add((request.uri.path, request.headers.value('X-Instance-Key')));
    });
    const cover = 'https://lh3.googleusercontent.com/music-cover';
    final audio = video.copyWith(
        audioOnly: true,
        musicMetadata: MusicMetadata(
            title: 'Song',
            artist: 'Artist',
            thumbnails: [ImageObject(null, cover, 500, 500)]));
    // The generic path can belong to a video thumbnail left by an older
    // version. A new cover must be independently fetched and stored.
    final poster = File(await audio.thumbnailPath);
    await poster.writeAsBytes([1, 2]);
    await db.upsertDownload(audio);
    manager.setVideos();
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(
        requests,
        unorderedEquals(
            [(coverPath, 'artwork-instance'), ('/audio', 'artwork-instance')]));
    final saved = manager.state.videos.single;
    final localCover = (await saved.existingSongCover)!;
    expect(await localCover.readAsBytes(), [10, 11, 12]);
    final stockPoster = (await saved.stockSongPosterFile)!;
    await stockPoster.writeAsBytes([3]);
    expect((await saved.existingSongArtwork)?.path, localCover.path);
    expect(await poster.readAsBytes(), [1, 2]);
    expect(await saved.copyWith(accountId: 'other-account').existingSongCover,
        isNull);
    expect(await saved.copyWith(profileId: 'other-profile').existingSongCover,
        isNull);
    expect(
        await saved
            .copyWith(
                musicMetadata: MusicMetadata(
                    title: 'Song',
                    artist: 'Artist',
                    thumbnails: [
                  ImageObject(
                      null, 'https://lh3.googleusercontent.com/other', 500, 500)
                ]))
            .existingSongCover,
        isNull);
    await manager.deleteVideo(saved);
    expect(await localCover.exists(), isFalse);
    expect(await (await saved.songCoverDirectory).exists(), isFalse);
  });

  test('unsupported Google cover is skipped without delaying audio download',
      () async {
    final remote = await audioVideoWithArtwork(onArtwork: (_) async {
      fail('Unsupported artwork must not start a transfer');
    });
    final audio = video.copyWith(
        audioOnly: true,
        musicMetadata:
            MusicMetadata(title: 'Song', artist: 'Artist', thumbnails: [
          ImageObject(null, 'https://s.ytimg.com/yts/img/cover.png', 500, 500)
        ]));
    await db.upsertDownload(audio);
    manager.setVideos();
    service =
        _DownloadService((_) async => remote.copyWith(videoThumbnails: []));
    final destinations = <Uri>[];
    await HttpOverrides.runZoned(() async {
      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.videos.single.downloadComplete ||
          state.videos.single.downloadFailed);
    },
        createHttpClient: (context) => _DirectHttpOverrides()
            .createHttpClient(context)
          ..connectionFactory = (uri, _, __) {
            destinations.add(uri);
            if (uri.host != '127.0.0.1') {
              throw const SocketException('Unexpected artwork connection');
            }
            return Socket.startConnect(InternetAddress.loopbackIPv4, uri.port);
          });
    expect(manager.state.videos.single.downloadComplete, isTrue);
    expect(destinations.map((uri) => uri.path), ['/audio']);
    expect(await File(await audio.thumbnailPath).exists(), isFalse);
  });

  for (final source in ['music', 'video', 'video fallback']) {
    test('download chooses usable artwork from $source', () async {
      final paths = <String>[];
      final audioPaths = <String>[];
      final remote = await audioVideoWithArtwork(onArtwork: (request) async {
        paths.add(request.uri.path);
        expect(request.headers.value('X-Instance-Key'), 'artwork-instance');
        request.response.add([10, 11, 12]);
        await request.response.close();
      }, onAudio: (request) {
        audioPaths.add(request.uri.path);
        expect(request.headers.value('X-Instance-Key'), 'artwork-instance');
      });
      final unsupported = ImageObject(
          null, 'https://s.ytimg.com/yts/img/cover.png', 1000, 1000);
      final supported = ImageObject(
          null,
          source == 'music'
              ? 'https://lh3.googleusercontent.com/music-cover'
              : 'https://i.ytimg.com/vi/music-cover/cover.jpg',
          100,
          100);
      final audio = video.copyWith(
          audioOnly: true,
          musicMetadata: source == 'video'
              ? null
              : MusicMetadata(title: 'Song', artist: 'Artist', thumbnails: [
                  unsupported,
                  if (source == 'music') supported,
                ]));
      await db.upsertDownload(audio);
      manager.setVideos();
      service = _DownloadService((_) async => source == 'video'
          ? remote.copyWith(videoThumbnails: [unsupported, supported])
          : remote);
      final destinations = <Uri>[];

      await HttpOverrides.runZoned(() async {
        await manager.setWifiOnly(false);
        await waitFor((state) =>
            state.videos.single.downloadComplete ||
            state.videos.single.downloadFailed);
      },
          createHttpClient: (context) => _DirectHttpOverrides()
              .createHttpClient(context)
            ..connectionFactory = (uri, _, __) {
              destinations.add(uri);
              if (uri.host != '127.0.0.1') {
                throw const SocketException('Unexpected artwork connection');
              }
              return Socket.startConnect(
                  InternetAddress.loopbackIPv4, uri.port);
            });

      expect(manager.state.videos.single.downloadComplete, isTrue);
      expect(paths, [
        if (source == 'music') '/ggpht/music-cover',
        if (source == 'video') '/vi/music-cover/cover.jpg',
        if (source == 'video fallback') '/vi/${video.videoId}/default.jpg',
      ]);
      expect(audioPaths, ['/audio']);
      // Both HTTP transfers may share one loopback keep-alive connection.
      expect(destinations, isNotEmpty);
      expect(destinations.every((uri) => uri.host == '127.0.0.1'), isTrue);
      expect(await File(await audio.downloadPath).readAsBytes(),
          [0, 1, 2, 3, 4, 5, 6, 7]);
      final poster = File(await audio.thumbnailPath);
      if (source == 'video') {
        expect(await poster.readAsBytes(), [10, 11, 12]);
      } else {
        expect(await poster.exists(), isFalse);
        final cover = await manager.state.videos.single.existingSongCover;
        if (source == 'music') {
          expect(await cover!.readAsBytes(), [10, 11, 12]);
        } else {
          expect(cover, isNull);
          final saved = manager.state.videos.single;
          final stock = (await saved.stockSongPosterFile)!;
          expect((await saved.existingSongArtwork)?.path, stock.path);
          expect(await stock.readAsBytes(), [10, 11, 12]);
          expect(await saved.copyWith(accountId: 'other').existingSongArtwork,
              isNull);
          expect(await saved.copyWith(profileId: 'other').existingSongArtwork,
              isNull);
          await manager.deleteVideo(saved);
          expect(await stock.exists(), isFalse);
        }
      }
    });
  }

  for (final relative in [false, true]) {
    test(
        'old queued Music frame is saved as a stock poster (relative=$relative)',
        () async {
      final headers = <String?>[];
      final remote = await audioVideoWithArtwork(onArtwork: (request) async {
        headers.add(request.headers.value('X-Instance-Key'));
        if (headers.last != 'artwork-instance') {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          request.response.add([10, 11, 12]);
        }
        await request.response.close();
      });
      final cover = relative
          ? '/vi/${video.videoId}/default.jpg'
          : 'http://127.0.0.1:${mediaServer!.port}/vi/${video.videoId}/default.jpg';
      final fallback = ImageObject(null, cover, 320, 180);
      final audio = video.copyWith(
          audioOnly: true,
          musicMetadata: MusicMetadata(
              title: 'Song', artist: 'Artist', thumbnails: [fallback]));
      // Model a queued download saved by older bookmarks, which copied the
      // backend fallback into MusicMetadata without its source information.
      await db.upsertDownload(audio);
      manager.setVideos();
      service = _DownloadService(
          (_) async => remote.copyWith(videoThumbnails: [fallback]));

      await manager.setWifiOnly(false);
      await waitFor((state) => state.videos.single.downloadComplete);

      expect(headers, ['artwork-instance']);
      expect(await File(await audio.thumbnailPath).exists(), isFalse);
      final saved = manager.state.videos.single;
      expect(saved.musicMetadata!.thumbnails, isEmpty);
      expect(await saved.existingSongCover, isNull);
      expect(
          await (await saved.existingSongArtwork)!.readAsBytes(), [10, 11, 12]);
    });
  }

  test('missing catalog and HD covers use the available Art Track rendition',
      () async {
    final paths = <String>[];
    final remote = await audioVideoWithArtwork(onArtwork: (request) async {
      paths.add(request.uri.path);
      expect(request.headers.value('X-Instance-Key'), 'artwork-instance');
      if (request.uri.path.startsWith('/ggpht/') ||
          request.uri.path.endsWith('/maxresdefault.jpg')) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    final audio = video.copyWith(
        audioOnly: true,
        musicMetadata:
            MusicMetadata(title: 'Song', artist: 'Artist', thumbnails: [
          ImageObject(
              null, 'https://lh3.googleusercontent.com/missing', 500, 500),
        ]));
    await db.upsertDownload(audio);
    manager.setVideos();
    service = _DownloadService((_) async => remote.copyWith(
            author: 'Artist - Topic',
            title: 'Song',
            genre: 'Music',
            description:
                'Provided to YouTube by Label\n\nSong · Artist\n\nAlbum\n\n℗ Label\n\nAuto-generated by YouTube.',
            videoThumbnails: [
              ImageObject(null, '/vi/${video.videoId}/default.jpg', 1280, 720),
              ImageObject(
                  null, '/vi/${video.videoId}/maxresdefault.jpg', 1280, 720),
              ImageObject(null, '/vi/${video.videoId}/hqdefault.jpg', 480, 360),
              ImageObject(null, '/vi/wrongSongID/maxres.jpg', 2560, 1440),
            ]));
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);
    final saved = manager.state.videos.single;
    expect(saved.musicMetadata!.isArtTrack, isTrue);
    expect(saved.musicMetadata!.album, 'Album');
    expect(paths, [
      '/ggpht/missing',
      '/vi/${video.videoId}/maxresdefault.jpg',
      '/vi/${video.videoId}/hqdefault.jpg'
    ]);
    expect(await saved.existingSongCover, isNull);
    expect(await (await saved.existingSongArtwork)!.readAsBytes(), [1, 2, 3]);
  });

  test('media starts while artwork is pending and artwork is committed whole',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final artworkStarted = Completer<void>();
    final mediaStarted = Completer<void>();
    final releaseArtwork = Completer<void>();
    addTearDown(() {
      if (!releaseArtwork.isCompleted) releaseArtwork.complete();
    });
    final headers = <String?>[];
    final remote = await audioVideoWithArtwork(onArtwork: (request) async {
      headers.add(request.headers.value('X-Instance-Key'));
      request.response.add([10, 11]);
      await request.response.flush();
      artworkStarted.complete();
      await releaseArtwork.future;
      request.response.add([12, 13]);
      await request.response.close();
    }, onAudio: (request) {
      headers.add(request.headers.value('X-Instance-Key'));
      mediaStarted.complete();
    });
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await artworkStarted.future.timeout(const Duration(seconds: 2));
    await mediaStarted.future.timeout(const Duration(seconds: 2));
    final artwork = File(await audio.thumbnailPath);
    expect(await artwork.exists(), isFalse);
    expect(manager.state.videos.single.downloadComplete, isFalse);
    releaseArtwork.complete();
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(headers, ['artwork-instance', 'artwork-instance']);
    expect(await artwork.readAsBytes(), [10, 11, 12, 13]);
    expect(await File('${artwork.path}.part').exists(), isFalse);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('stalled artwork has a deadline and does not retry completed media',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final releaseArtwork = Completer<void>();
    addTearDown(() {
      if (!releaseArtwork.isCompleted) releaseArtwork.complete();
    });
    var mediaRequests = 0;
    var metadataRequests = 0;
    final remote = await audioVideoWithArtwork(
        onArtwork: (request) async {
          request.response.add([10, 11]);
          await request.response.flush();
          await releaseArtwork.future;
          await request.response.close();
        },
        onAudio: (_) => mediaRequests++);
    service = _DownloadService((_) async {
      metadataRequests++;
      return remote;
    });

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete,
        timeout: const Duration(seconds: 8));

    expect(metadataRequests, 1);
    expect(mediaRequests, 1);
    expect(manager.state.videos.single.downloadFailed, isFalse);
    final path = await audio.thumbnailPath;
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.part').exists(), isFalse);
  });

  test('deleting during artwork transfer joins cleanup before removing files',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final artworkStarted = Completer<void>();
    final releaseArtwork = Completer<void>();
    addTearDown(() {
      if (!releaseArtwork.isCompleted) releaseArtwork.complete();
    });
    final remote = await audioVideoWithArtwork(onArtwork: (request) async {
      request.response.add([10, 11]);
      await request.response.flush();
      artworkStarted.complete();
      await releaseArtwork.future;
      request.response.add([12, 13]);
      await request.response.close();
    });
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await artworkStarted.future;
    await manager.deleteVideo(audio).timeout(const Duration(seconds: 2));
    releaseArtwork.complete();

    expect(db.getDownloadByVideoId(audio.videoId), isNull);
    expect(manager.state.videos, isEmpty);
    expect(manager.state.downloadProgresses, isEmpty);
    expect(await File(await audio.downloadPath).exists(), isFalse);
    final path = await audio.thumbnailPath;
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.part').exists(), isFalse);
  });

  for (final music in [false, true]) {
    test(
        'pausing partial artwork retries it without keeping partial cover data (Music: $music)',
        () async {
      final audio = video.copyWith(
          audioOnly: true,
          musicMetadata: music
              ? MusicMetadata(title: 'Song', artist: 'Artist', thumbnails: [
                  ImageObject(
                      null, 'https://lh3.googleusercontent.com/album', 300, 300)
                ])
              : null);
      await db.upsertDownload(audio);
      manager.setVideos();
      final artworkStarted = Completer<void>();
      final releaseFirstArtwork = Completer<void>();
      addTearDown(() {
        if (!releaseFirstArtwork.isCompleted) releaseFirstArtwork.complete();
      });
      var artworkRequests = 0;
      final remote = await audioVideoWithArtwork(onArtwork: (request) async {
        artworkRequests++;
        if (artworkRequests == 1) {
          request.response.add([99]);
          await request.response.flush();
          artworkStarted.complete();
          await releaseFirstArtwork.future;
        } else {
          request.response.add([10, 11, 12]);
        }
        await request.response.close();
      });
      service = _DownloadService((_) async => remote);

      await manager.setWifiOnly(false);
      await artworkStarted.future;
      await manager.pauseDownload(audio);
      await waitFor((state) => state.downloadProgresses.isEmpty);
      final saved = manager.state.videos.single;
      final artwork = music
          ? (await saved.songCoverFile)!
          : File(await saved.thumbnailPath);
      expect(await artwork.exists(), isFalse);
      expect(await File('${artwork.path}.part').exists(), isFalse);
      releaseFirstArtwork.complete();
      await manager.retryDownload(manager.state.videos.single);
      await waitFor((state) => state.videos.single.downloadComplete);

      expect(artworkRequests, 2);
      expect(await artwork.readAsBytes(), [10, 11, 12]);
    });
  }

  test('deleting a download does not wait for its pending metadata request',
      () async {
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    service = _DownloadService((_) {
      metadataStarted.complete();
      return metadata.future;
    });
    await manager.setWifiOnly(false);
    await metadataStarted.future;
    final deleting = manager.deleteVideo(video);
    try {
      await deleting.timeout(const Duration(seconds: 2));
    } finally {
      metadata.complete(Video(videoId: video.videoId, adaptiveFormats: []));
      await deleting;
    }
    expect(manager.state.videos, isEmpty);
    expect(db.getDownloadByVideoId(video.videoId), isNull);
    expect(manager.state.downloadProgresses, isEmpty);
  });

  test('proxy change cancels downloads before a slower consumer finishes',
      () async {
    final proxy = NetworkProxy.instance;
    await proxy.initialize(saved: '{}', configureNative: false);
    // Model playback being created before the downloads tab is first opened.
    await manager.close();
    final slowStarted = Completer<void>();
    final releaseSlow = Completer<void>();
    Future<void> stopSlowConsumer() {
      slowStarted.complete();
      return releaseSlow.future;
    }

    proxy.addBeforeApply(stopSlowConsumer);
    await openManager();
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    var fetches = 0;
    service = _DownloadService((_) {
      fetches++;
      metadataStarted.complete();
      return metadata.future;
    });
    Future<void>? applying;
    try {
      await manager.setWifiOnly(false);
      await metadataStarted.future;
      final token =
          manager.state.downloadProgresses[video.videoId]!.cancelToken;
      var applied = false;
      applying = proxy
          .apply(SocksProxyConfig(enabled: true))
          .then((_) => applied = true);
      // Cancellation is synchronous; no other listener's native disposal can
      // delay it. A connection failure after this point must not retry/fail.
      expect(token.isCancelled, isTrue);
      await slowStarted.future;
      await waitFor((state) => state.pausedVideoIds.contains(video.videoId));
      metadata.completeError(const SocketException('Connection reset'));
      await waitFor((state) => state.downloadProgresses.isEmpty);
      expect(fetches, 1);
      expect(manager.state.videos.single.downloadFailed, isFalse);
      expect(manager.state.videos.single.downloadComplete, isFalse);
      expect(applied, isFalse);
      releaseSlow.complete();
      await applying;
      expect(applied, isTrue);
    } finally {
      if (!metadata.isCompleted) {
        metadata.completeError(const SocketException('Test cleanup'));
      }
      if (!releaseSlow.isCompleted) releaseSlow.complete();
      await applying;
      proxy.removeBeforeApply(stopSlowConsumer);
      await proxy.initialize(saved: '{}', configureNative: false);
    }
  });

  test('a failed job does not block the next queued audio download', () async {
    const nextId = 'zyxwvutsrqp';
    final remote = await audioVideo(nextId);
    service = _DownloadService((id) async {
      if (id == video.videoId) throw StateError('No downloadable streams');
      return remote;
    });
    await manager.addDownload(nextId, audioOnly: true);
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos
        .any((item) => item.videoId == nextId && item.downloadComplete));
    expect(db.getDownloadByVideoId(video.videoId)!.downloadFailed, true);
    expect(db.getDownloadByVideoId(nextId)!.downloadFailed, false);
  });

  test('video details observe queued jobs through failure and completion',
      () async {
    final viewer = _VideoCubit(manager);
    expect(viewer.state.downloadedVideo, video);
    expect(viewer.state.downloading, false);
    final failed = viewer.stream.firstWhere((state) => state.downloadFailed);
    await db.upsertDownload(video.copyWith(downloadFailed: true));
    manager.setVideos();
    await failed;
    final complete = viewer.stream
        .firstWhere((state) => state.downloadedVideo?.downloadComplete == true);
    await db.upsertDownload(video.copyWith(downloadComplete: true));
    manager.setVideos();
    await complete;
    expect(viewer.state.downloadFailed, false);
    expect(viewer.state.downloadProgress, 1);
    await viewer.close();
    manager.setVideos();
  });
}
