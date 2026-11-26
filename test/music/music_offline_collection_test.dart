import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/services/cached_music.dart';
import 'package:clipious/music/services/music_offline_collection.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = Server(url: 'https://example.test', id: 'first', inUse: true);
const _folder = 'content://documents/tree/primary%3AMusic';
const _uri = '$_folder/document/primary%3AMusic%2Ffixture.webm';
const _metadata = MusicMetadata(title: 'Saved title', artist: 'An artist');
const _song = Video(
    videoId: 'exact-song', title: 'Saved title', musicMetadata: _metadata);
final _sha = 'a' * 64;
final _fileIdentity = 'b' * 64;

DownloadedVideo _download() {
  final audio = AdaptiveFormat(
      null,
      '128000',
      null,
      '${_server.url}/videoplayback?itag=251',
      '251',
      'audio/webm; codecs="opus"',
      '12345',
      '1700000000000',
      'RECTANGULAR',
      'webm',
      'opus',
      null,
      null);
  return DownloadedVideo(
    videoId: _song.videoId,
    title: 'Original title',
    musicMetadata: _metadata,
    accountId: _server.accountId,
    audioOnly: true,
    downloadComplete: true,
    container: DownloadContainer.webm,
    folderUri: _folder,
    storageUri: _uri,
    playbackProvenance: DownloadPlaybackProvenance.create(
      video: _song.copyWith(adaptiveFormats: [audio]),
      server: _server,
      audioOnly: true,
      container: DownloadContainer.webm,
      audio: audio,
      byteLength: 50,
      sha256: _sha,
    )!,
    lengthSeconds: 20,
    quality: 'audio',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const downloadChannel = MethodChannel('videre/download_storage');
  const cacheChannel = MethodChannel('videre/proxy');
  const deviceChannel =
      MethodChannel('com.github.dvbeckwitt.videre/local_music');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SembastSqfDb database;
  late AppState session;
  late int downloadProbes;
  late String? fileIdentity;
  late List<Object?> cachedSongs;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    database = await SembastSqfDb.createInMemory();
    db = database;
    await database.upsertServer(_server);
    session = AppState(0, _server, HomeLayout());
    downloadProbes = 0;
    fileIdentity = _fileIdentity;
    cachedSongs = [];

    messenger.setMockMethodCallHandler(downloadChannel, (call) async {
      expect(call.method, 'probeMusicFiles');
      final args = call.arguments as Map;
      expect(args['profileId'], _server.profileId);
      expect((args['files'] as List).single, {
        'key': _song.videoId,
        'videoId': _song.videoId,
        'uri': _uri,
        'folderUri': _folder,
        'expectedSha256': _sha,
      });
      downloadProbes++;
      return {
        if (fileIdentity case final identity?)
          _song.videoId: {'identity': identity, 'byteLength': 50},
      };
    });
    messenger.setMockMethodCallHandler(cacheChannel, (call) async {
      expect(call.method, 'cachedMusicSongs');
      return cachedSongs;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(downloadChannel, null);
    messenger.setMockMethodCallHandler(cacheChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
    debugDefaultTargetPlatformOverride = null;
    await database.close();
  });

  Future<List<Video?>> resolve(List<Video> videos) =>
      resolveOfflineMusicCollection(
        database: database,
        session: session,
        videos: videos,
        isCurrent: () => true,
      );

  test('pins a verified complete download and keeps duplicate occurrences',
      () async {
    final file = _download();
    final first = _song.copyWith(queueEntryId: 'first-occurrence');
    final duplicate = _song.copyWith(queueEntryId: 'second-occurrence');
    const onlineOnly = Video(videoId: 'online-only', title: 'Online only');
    final occurrences = [first, onlineOnly, duplicate];

    await database.upsertDownload(file.copyWith(downloadComplete: false));
    expect(await resolve(occurrences), [null, null, null]);
    expect(downloadProbes, 0);

    await database.upsertDownload(file);
    final pin = musicDownloadFileFingerprint(file, _fileIdentity);
    expect(pin, isNotNull);
    expect(await resolve(occurrences), [
      first.copyWith(explicitMusicDownload: pin),
      null,
      duplicate.copyWith(explicitMusicDownload: pin),
    ]);
    expect(downloadProbes, 1);
  });

  test('excludes a replaced or revoked pinned file with no cache fallback',
      () async {
    final file = _download();
    await database.upsertDownload(file);
    final pinned = (await resolve([_song])).single!;

    final rendition = 'e' * 64;
    cachedSongs = [
      {
        'videoId': _song.videoId,
        'title': 'Cached title',
        'artist': 'An artist',
        'lengthSeconds': 20,
        'rendition': rendition,
      },
    ];
    fileIdentity = 'c' * 64;
    expect(await resolve([pinned]), [null]);

    fileIdentity = null;
    final result = await resolve([pinned, _song]);
    expect(result.first, isNull);
    expect(CachedMusicPlayback.of(result.last)?.rendition, rendition);
  });

  test('drops a device playlist occurrence after its folder grant is revoked',
      () async {
    final deviceProof = 'd' * 64;
    final device = Video(
      videoId: 'device:playlist:$deviceProof',
      title: 'Playlist title',
      queueEntryId: 'device-occurrence',
    );
    var authorized = true;
    var grantChecks = 0;
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return {'uri': _folder, 'name': 'Music', 'selectionId': 'grant'};
        case 'checkFolderAccess':
          expect(call.arguments['treeUri'], _folder);
          grantChecks++;
          return authorized;
        case 'listTracks':
          expect(call.arguments['treeUri'], _folder);
          return [
            {
              'uri': _uri,
              'title': 'Device title',
              'visibilityKey': deviceProof
            },
          ];
        case 'pendingRenames':
          return [];
      }
      throw MissingPluginException();
    });

    expect(await resolve([device]), [device]);
    authorized = false;
    expect(await resolve([device]), [null]);
    expect(grantChecks, 2);
  });
}
