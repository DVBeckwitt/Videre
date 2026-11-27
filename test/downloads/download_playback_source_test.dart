import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/home/services/offline_video_downloads.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/no_server_selected.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _server = Server(
    url: 'https://inv.example',
    profileId: 'person-a',
    id: 'account-a',
    authToken: 'authorization-secret',
    sidCookie: 'cookie-secret',
    customHeaders: {'X-Api-Key': 'header-secret'});

AdaptiveFormat _audio(
        {bool defaultTrack = true, String lmt = '1700000000000'}) =>
    AdaptiveFormat(
        null,
        '128000',
        null,
        'https://inv.example/videoplayback?itag=251&sig=audio-signature',
        '251',
        'audio/webm; codecs="opus"',
        '12345',
        lmt,
        'RECTANGULAR',
        'webm',
        'opus',
        null,
        null,
        audioTrack: AudioTrack(
            id: 'en.1', displayName: 'English', audioIsDefault: defaultTrack));

AdaptiveFormat _video({String lmt = '1700000000000'}) => AdaptiveFormat(
    null,
    '1000000',
    null,
    'https://inv.example/videoplayback?itag=248&sig=video-signature',
    '248',
    'video/webm; codecs="vp9"',
    '54321',
    lmt,
    'RECTANGULAR',
    'webm',
    'vp9',
    '1080p',
    '1080');

Video _content({AdaptiveFormat? audio, AdaptiveFormat? video}) => Video(
    videoId: 'song',
    title: 'Remote title',
    lengthSeconds: 240,
    adaptiveFormats: [audio ?? _audio(), video ?? _video()]);

DownloadedVideo _saved({
  bool audioOnly = true,
  AdaptiveFormat? audio,
  String? storageUri,
  String? folderUri,
}) {
  final selectedAudio = audio ?? _audio();
  final selectedVideo = _video();
  final proof = DownloadPlaybackProvenance.create(
      video: _content(audio: selectedAudio, video: selectedVideo),
      server: _server,
      audioOnly: audioOnly,
      container: DownloadContainer.webm,
      audio: selectedAudio,
      videoFormat: audioOnly ? null : selectedVideo,
      byteLength: 10000,
      sha256: 'a' * 64)!;
  return DownloadedVideo(
      videoId: 'song',
      title: 'Saved title',
      author: 'Saved artist',
      authorUrl: '/channel/artist',
      profileId: _server.profileId,
      accountId: _server.accountId,
      audioOnly: audioOnly,
      container: DownloadContainer.webm,
      audioTrackId: selectedAudio.audioTrack?.id,
      downloadComplete: true,
      playbackProvenance: proof,
      storageUri: storageUri,
      folderUri: folderUri,
      musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
      sponsorSegments: [
        SponsorSegment('skip', [10, 15], SponsorSegmentType.sponsor)
      ],
      lengthSeconds: 240,
      quality: audioOnly ? 'audio' : '1080p');
}

class _Database extends Fake implements IDbClient {
  String activeProfile = _server.profileId;
  Server selected = _server;
  DownloadedVideo? download;
  List<DownloadedVideo> downloads = [];
  Completer<Server>? selectionResult;
  Completer<void>? selectionStarted;
  bool deserializeReads = false;
  int reads = 0;
  int selections = 0;
  Object? selectionError;

  @override
  String get profileId => activeProfile;

  @override
  Future<void> upsertServer(Server server) =>
      throw UnsupportedError('This resolver fixture does not write servers');

  @override
  Future<void> insertLogs(AppLog log) =>
      throw UnsupportedError('This resolver fixture does not write logs');

  @override
  IDbClient forProfile(String id) {
    if (id != _server.profileId) throw StateError('Unexpected profile');
    return this;
  }

  @override
  List<DownloadedVideo> getAllDownloads() => downloads;

  @override
  DownloadedVideo? getDownloadByVideoId(String videoId) {
    reads++;
    final value = download?.videoId == videoId
        ? download
        : downloads.where((row) => row.videoId == videoId).firstOrNull;
    return deserializeReads && value != null
        ? DownloadedVideo.fromJson(value.toJson())
        : value;
  }

  @override
  Future<Server> getCurrentlySelectedServer() async {
    selections++;
    if (selectionError case final error?) throw error;
    final started = selectionStarted;
    if (started != null && !started.isCompleted) started.complete();
    final pending = selectionResult;
    if (pending != null) return pending.future;
    return selected;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const storageChannel = MethodChannel('videre/download_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late _Database database;
  bool current = true;
  int pathCalls = 0;
  Completer<void>? pathStarted;
  Completer<void>? pathGate;

  Future<DownloadPlaybackSource?> resolve({
    Video? video,
    Server server = _server,
    bool audioOnly = true,
    int? quality,
  }) =>
      resolveDownloadPlaybackSource(
          database: database,
          video: video ?? _content(),
          server: server,
          audioOnly: audioOnly,
          sessionId: 'session-a',
          isCurrent: () => current,
          preferredQuality: quality);

  Future<Video?> prepare({
    Video video = const Video(videoId: 'song', queueEntryId: 'occurrence'),
    Server server = _server,
    bool audioOnly = true,
    int? quality,
  }) =>
      prepareDownloadedPlaybackVideo(
          database: database,
          video: video,
          server: server,
          audioOnly: audioOnly,
          isCurrent: () => current,
          preferredQuality: quality);

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    documents =
        await Directory.systemTemp.createTemp('videre-playback-source-');
    database = _Database()..download = _saved();
    current = true;
    pathCalls = 0;
    pathStarted = null;
    pathGate = null;
    messenger.setMockMethodCallHandler(pathProvider, (_) async {
      pathCalls++;
      final started = pathStarted;
      if (started != null && !started.isCompleted) started.complete();
      await pathGate?.future;
      return documents.path;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockMethodCallHandler(storageChannel, null);
    debugDefaultTargetPlatformOverride = null;
    await documents.delete(recursive: true);
  });

  test('optional preparation skips account lookup without usable provenance',
      () async {
    final saved = database.download!;
    database.selectionError = NoServerSelected();
    for (final download in [
      null,
      saved.copyWith(playbackProvenance: null),
      saved.copyWith(downloadComplete: false),
      saved.copyWith(storageFailed: true),
    ]) {
      database.download = download;
      expect(
          await prepareDownloadedPlaybackVideo(
              database: database,
              video: const Video(videoId: 'song'),
              audioOnly: true,
              isCurrent: () => true),
          isNull);
    }
    expect(database.selections, 0);
    expect(pathCalls, 0);
  });

  test('unavailable optional account skips local preparation without throwing',
      () async {
    database.selectionError = NoServerSelected();
    expect(
        await prepareDownloadedPlaybackVideo(
            database: database,
            video: const Video(videoId: 'song'),
            audioOnly: true,
            isCurrent: () => true),
        isNull);
    expect(database.selections, 1);
    expect(pathCalls, 0);
  });

  test('completed audio uses its whole file and exact current rendition',
      () async {
    final source = await resolve();
    expect(source, isNotNull);
    expect(source!.uri, startsWith('file:'));
    expect(Uri.parse(source.uri).toFilePath(),
        await database.download!.effectivePath);
    expect(source.videoQuality, isNull);
    final descriptor = source.playbackCache['download'] as Map;
    expect(descriptor['uri'], source.uri);
    expect(descriptor['remoteUri'], _audio().url);
    expect(descriptor['byteLength'], 10000);
    expect(descriptor['sha256'], 'a' * 64);
    expect(source.playbackCache['profileId'], _server.profileId);
    expect(source.playbackCache['accountId'], _server.accountId);
    expect(source.playbackCache['resources'], isNotEmpty);
    // File existence/integrity is deliberately checked by the guarded native
    // source. The Dart candidate must not synchronously hash on the UI isolate.
    expect(await File.fromUri(Uri.parse(source.uri)).exists(), isFalse);
    expect(await resolve(video: _content(audio: _audio(lmt: '1700000000001'))),
        isNull);
  });

  test('video source requires the complete mux and both current renditions',
      () async {
    database.download = _saved(audioOnly: false);
    final source = await resolve(audioOnly: false, quality: 1080);
    expect(source, isNotNull);
    expect(source!.videoQuality, '1080p');
    expect(
        (source.playbackCache['download'] as Map)['remoteUri'], _video().url);
    expect(await resolve(), isNull);
    expect(
        await resolve(
            audioOnly: false,
            video: _content(audio: _audio(lmt: '1700000000001'))),
        isNull);
    expect(
        await resolve(
            audioOnly: false,
            video: _content(video: _video(lmt: '1700000000001'))),
        isNull);
  });

  test(
      'sparse queue prepares local metadata without a stream or network request',
      () async {
    var networkClients = 0;
    await HttpOverrides.runZoned(() async {
      final prepared = await prepare();
      expect(prepared, isNotNull);
      expect(prepared!.downloadPlaybackOnly, isTrue);
      expect(prepared.videoId, 'song');
      expect(prepared.queueEntryId, 'occurrence');
      expect(prepared.title, 'Saved title');
      expect(prepared.author, 'Saved artist');
      expect(prepared.lengthSeconds, 240);
      expect(prepared.musicMetadata?.title, 'Song');
      expect(prepared.adaptiveFormats, isNull);
      expect(prepared.formatStreams, isNull);
      expect(prepared.dashUrl, isNull);
      expect(prepared.hlsUrl, isNull);
      expect(prepared.backendPlayback, isNull);
      expect(prepared.playbackConnection?.server, _server);
      expect(prepared.playbackSourceId, isNotNull);
      final local = (await resolve(video: prepared))!;
      expect(local.playbackCache['resources'], isEmpty);
      final descriptor = local.playbackCache['download'] as Map;
      expect(descriptor.containsKey('remoteUri'), isFalse);
      expect(descriptor['uri'], local.uri);
      final encoded = jsonEncode(local.playbackCache);
      for (final secret in [
        'authorization-secret',
        'cookie-secret',
        'header-secret',
        'audio-signature',
        'video-signature',
        'videoplayback',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
    }, createHttpClient: (_) {
      networkClients++;
      throw StateError('Saved-source selection must not create an HTTP client');
    });
    expect(networkClients, 0);
  });

  test('prepare replaces stale remote URLs with saved-only metadata', () async {
    final prepared = (await prepare(
        video: _content().copyWith(
            dashUrl: 'https://inv.example/stale.mpd',
            hlsUrl: 'https://inv.example/stale.m3u8')))!;
    expect(prepared.adaptiveFormats, isNull);
    expect(prepared.formatStreams, isNull);
    expect(prepared.dashUrl, isNull);
    expect(prepared.hlsUrl, isNull);
    expect(prepared.toJson().containsKey('downloadPlaybackOnly'), isFalse);
  });

  test('saved audio keeps artwork from either download or queued metadata',
      () async {
    final cover =
        ImageObject('high', 'https://inv.example/vi/song/cover.jpg', 320, 180);
    final saved = database.download!;
    final queued = Video(
        videoId: saved.videoId,
        musicMetadata: MusicMetadata(
            title: 'Queued song',
            artist: 'Queued artist',
            thumbnails: [cover]));
    final prepared = (await prepare(video: queued))!;
    expect(prepared.musicMetadata?.title, saved.musicMetadata?.title);
    expect(prepared.musicMetadata?.thumbnails.single, cover);

    database.download = saved.copyWith(musicMetadata: queued.musicMetadata);
    final sparse = queued.copyWith(
        musicMetadata:
            const MusicMetadata(title: 'Queued song', artist: 'Queued artist'));
    final savedCover =
        (await prepare(video: sparse))!.preservingMusicMetadataFrom(sparse);
    expect(savedCover.videoThumbnails.single, cover);
  });

  test('preparation exposes saved metadata from the admitted source only',
      () async {
    DownloadPlaybackSource? admitted;
    final prepared = await prepareDownloadedPlaybackVideo(
        database: database,
        video: const Video(videoId: 'song'),
        server: _server,
        audioOnly: true,
        isCurrent: () => current,
        onPrepared: (source) => admitted = source);
    expect(prepared, isNotNull);
    expect(admitted, isNotNull);
    expect(admitted!.download, same(database.download));
    expect(prepared!.playbackSourceId, same(admitted));
    expect(admittedMusicDownload(prepared), same(database.download));
    expect(admittedMusicDownload(prepared.copyWith(playbackSourceId: Object())),
        isNull);
    expect(admitted!.download.sponsorSegments, hasLength(1));
    expect(admitted!.download.sponsorSegments.single.segment, [10, 15]);
    expect(admitted!.playbackCache['accountId'], _server.accountId);
  });

  test('queued cover is kept when an older download contains only a frame',
      () async {
    final frame = ImageObject(null, '/vi/song/default.jpg', 640, 360);
    final cover = ImageObject(
        null, 'https://lh3.googleusercontent.com/album=w500-h500', 500, 500);
    database.download = database.download!.copyWith(
        musicMetadata: MusicMetadata(
            title: 'Saved title', artist: 'Saved artist', thumbnails: [frame]));
    final queued = Video(
        videoId: 'song',
        musicMetadata: MusicMetadata(
            title: 'Song', artist: 'Artist', thumbnails: [cover]));
    final prepared = (await prepare(video: queued))!;
    expect(prepared.musicMetadata!.thumbnails, [cover]);
    expect(admittedMusicDownload(prepared)!.musicMetadata!.thumbnails, [frame]);
  });

  test('rejected local preparation cannot expose saved segment metadata',
      () async {
    var callbacks = 0;
    Future<Video?> attempt() => prepareDownloadedPlaybackVideo(
        database: database,
        video: const Video(videoId: 'song'),
        server: _server,
        audioOnly: true,
        isCurrent: () => current,
        onPrepared: (_) => callbacks++);
    current = false;
    expect(await attempt(), isNull);
    current = true;
    database.download = _saved().copyWith(accountId: 'another-account');
    expect(await attempt(), isNull);
    database.download = _saved().copyWith(playbackProvenance: null);
    expect(await attempt(), isNull);
    expect(callbacks, 0);
  });

  test('metadata-free video honors exact quality and original playback mode',
      () async {
    database.download = _saved(audioOnly: false);
    final prepared = await prepare(audioOnly: false, quality: 1080);
    expect(prepared, isNotNull);
    expect(
        (await resolve(video: prepared, audioOnly: false, quality: 1080))!
            .videoQuality,
        '1080p');
    expect(await prepare(audioOnly: false, quality: 720), isNull);
    expect(await prepare(audioOnly: false, quality: 2160), isNull);
    expect(await prepare(), isNull);
    database.download = _saved();
    expect(await prepare(audioOnly: false), isNull);
  });

  test(
      'metadata-free nondefault track owner origin and live mismatches fall back',
      () async {
    database.download = _saved(audio: _audio(defaultTrack: false));
    expect(await prepare(), isNull);
    database.download = _saved();
    expect(await prepare(server: _server.copyWith(id: 'other')), isNull);
    expect(await prepare(server: _server.copyWith(profileId: 'other')), isNull);
    expect(
        await prepare(server: _server.copyWith(url: 'https://other.example')),
        isNull);
    expect(await prepare(video: const Video(videoId: 'song', liveNow: true)),
        isNull);
    expect(await prepare(video: const Video(videoId: 'other')), isNull);
  });

  test(
      'legacy incomplete failed and owner-mismatched records remain ineligible',
      () async {
    final valid = _saved();
    for (final saved in <DownloadedVideo?>[
      null,
      valid.copyWith(playbackProvenance: null),
      valid.copyWith(downloadComplete: false),
      valid.copyWith(downloadFailed: true),
      valid.copyWith(storageFailed: true),
      valid.copyWith(authenticationRequired: true),
      valid.copyWith(accountId: null),
      valid.copyWith(accountId: 'other'),
      valid.copyWith(profileId: 'other'),
      valid.copyWith(container: null),
      valid.copyWith(container: DownloadContainer.mp4),
    ]) {
      database.download = saved;
      expect(await resolve(), isNull);
      expect(await prepare(), isNull);
    }
    expect(pathCalls, 0);
  });

  test('non-Android platforms and cancelled requests do not select files',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await resolve(), isNull);
    expect(await prepare(), isNull);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    current = false;
    expect(await resolve(), isNull);
    expect(await prepare(), isNull);
    expect(pathCalls, 0);
  });

  test('SAF candidate retains only its own tree and document URI', () async {
    const folder = 'content://documents/tree/primary%3AVidere';
    const document = '$folder/document/primary%3AVidere%2Fsong.webm';
    database.download = _saved(storageUri: document, folderUri: folder);
    final prepared = (await prepare())!;
    final local = (await resolve(video: prepared))!;
    expect(local.uri, document);
    expect((local.playbackCache['download'] as Map)['folderUri'], folder);
    expect(pathCalls, 0);
  });

  test('deserialized authoritative record remains the same value', () async {
    database.deserializeReads = true;
    final local = await resolve();
    expect(local, isNotNull);
    expect(local!.download.toJson(), database.download!.toJson());
    expect(identical(local.download, database.download), isFalse);
    expect(await prepare(), isNotNull);
  });

  test('deletion or replacement while obtaining the path revokes the candidate',
      () async {
    for (final replacement in <DownloadedVideo?>[
      null,
      _saved().copyWith(title: 'Replaced record'),
      _saved().copyWith(playbackProvenance: null),
    ]) {
      database.download = _saved();
      pathStarted = Completer<void>();
      pathGate = Completer<void>();
      final pending = resolve();
      await pathStarted!.future;
      database.download = replacement;
      pathGate!.complete();
      expect(await pending, isNull);
    }
  });

  test(
      'profile change or cancellation while obtaining the path revokes selection',
      () async {
    for (final switchProfile in [true, false]) {
      database.activeProfile = _server.profileId;
      current = true;
      pathStarted = Completer<void>();
      pathGate = Completer<void>();
      final pending = resolve();
      await pathStarted!.future;
      if (switchProfile) {
        database.activeProfile = 'person-b';
      } else {
        current = false;
      }
      pathGate!.complete();
      expect(await pending, isNull);
    }
    expect(database.selections, 0);
  });

  test(
      'account origin or profile change during server lookup revokes selection',
      () async {
    for (final selected in [
      _server.copyWith(id: 'account-b'),
      _server.copyWith(url: 'https://other.example'),
      _server.copyWith(profileId: 'person-b'),
    ]) {
      database.selectionStarted = Completer<void>();
      database.selectionResult = Completer<Server>();
      final pending = resolve();
      await database.selectionStarted!.future;
      database.selectionResult!.complete(selected);
      expect(await pending, isNull);
    }
  });

  test('active profile is rechecked after a stale selected-server result',
      () async {
    database.selectionStarted = Completer<void>();
    database.selectionResult = Completer<Server>();
    final pending = resolve();
    await database.selectionStarted!.future;
    database.activeProfile = 'person-b';
    database.selectionResult!.complete(_server);
    expect(await pending, isNull);
  });

  test(
      'authoritative deletion or cancellation after server await revokes selection',
      () async {
    for (final delete in [true, false]) {
      database.download = _saved();
      current = true;
      database.selectionStarted = Completer<void>();
      database.selectionResult = Completer<Server>();
      final pending = resolve();
      await database.selectionStarted!.future;
      if (delete) {
        database.download = null;
      } else {
        current = false;
      }
      database.selectionResult!.complete(_server);
      expect(await pending, isNull);
    }
  });

  test('unavailable path or selected server safely falls back', () async {
    messenger.setMockMethodCallHandler(pathProvider,
        (_) async => throw PlatformException(code: 'unavailable'));
    expect(await resolve(), isNull);
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    database.selectionStarted = Completer<void>();
    database.selectionResult = Completer<Server>();
    final pending = resolve();
    await database.selectionStarted!.future;
    database.selectionResult!.completeError(StateError('Account was removed'));
    expect(await pending, isNull);
  });

  group('offline Home downloads', () {
    const video = DownloadedVideo(
        videoId: 'legacy',
        profileId: 'person-a',
        title: 'Downloaded video',
        quality: '720p',
        lengthSeconds: 60,
        downloadComplete: true);
    const folder = 'content://storage/tree/downloads';
    DownloadedVideo document(String id) => video.copyWith(
        videoId: id, storageUri: '$folder/document/$id', folderUri: folder);
    final storage = DownloadStorage();

    test('probes legacy MP4 and owned documents and skips unavailable files',
        () async {
      final mp4 = File(p.join(documents.path, 'downloads', 'profiles',
          video.profileId, 'legacy.mp4'));
      await mp4.parent.create(recursive: true);
      await mp4.writeAsBytes([1, 2, 3]);
      final privateMissing = video.copyWith(videoId: 'missing');
      final shared = document('shared');
      final denied = document('denied');
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        expect(call.method, 'probeMusicFiles');
        expect(call.arguments['profileId'], video.profileId);
        final files = (call.arguments['files'] as List).cast<Map>();
        expect(files.map((file) => file['key']),
            ['legacy', 'missing', 'shared', 'denied']);
        expect(Uri.parse(files[0]['uri'] as String).toFilePath(), mp4.path);
        expect(files[0]['folderUri'], isNull);
        expect(files[2]['uri'], shared.storageUri);
        expect(files[2]['folderUri'], folder);
        return {
          'legacy': {'identity': 'a' * 64, 'byteLength': 3},
          'shared': {'identity': 'b' * 64, 'byteLength': 9},
          'denied': {'identity': 'c' * 64, 'byteLength': 0},
        };
      });

      expect(
          await storage.probeVideoFiles(video.profileId, [
            video,
            privateMissing,
            shared,
            denied,
            document('audio').copyWith(audioOnly: true),
            document('pending').copyWith(downloadComplete: false),
            document('failed').copyWith(downloadFailed: true),
            document('storage-failed').copyWith(storageFailed: true),
            document('auth').copyWith(authenticationRequired: true),
            document('other').copyWith(profileId: 'person-b'),
            document('unowned').copyWith(folderUri: null),
          ]),
          [video, shared]);
    });

    test('fills the bounded shelf past missing and filtered rows', () async {
      final candidates = ['f', 'e', 'd', 'c', 'b', 'a'].map(document).toList();
      database.downloads = candidates;
      final probes = <String>[];
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        final ids = (call.arguments['files'] as List)
            .map((file) => file['key'] as String);
        probes.addAll(ids);
        return {
          for (final id in ids)
            if (id != 'a') id: {'identity': 'a' * 64, 'byteLength': 3}
        };
      });

      final shelf = await readableHomeDownloads(
          owner: database,
          storage: storage,
          isCurrent: () => current,
          include: (video) => video.videoId != 'c',
          limit: 2);

      expect(shelf.map((row) => row.videoId), ['b', 'd']);
      expect(probes, ['a', 'b', 'd']);
    });

    test('rejects taps when the file, session or owning row changes', () async {
      final saved = document('saved');
      for (final change in ['missing', 'session', 'profile', 'replacement']) {
        database.activeProfile = saved.profileId;
        database.downloads = [saved];
        current = true;
        messenger.setMockMethodCallHandler(storageChannel, (_) async {
          switch (change) {
            case 'missing':
              return <String, Object?>{};
            case 'session':
              current = false;
            case 'profile':
              database.activeProfile = 'person-b';
            case 'replacement':
              database.downloads = [saved.copyWith(title: 'Replacement')];
          }
          return {
            'saved': {'identity': 'a' * 64, 'byteLength': 3}
          };
        });

        final shelf = await readableHomeDownloads(
            owner: database,
            storage: storage,
            isCurrent: () => current,
            selection: saved);
        expect(shelf, isEmpty, reason: change);
      }
    });
  });
}
