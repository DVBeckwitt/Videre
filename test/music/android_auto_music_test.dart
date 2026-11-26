import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/android_auto_music.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

class _Catalog extends MusicCatalogService {
  final queries = <String>[];
  Future<List<MusicTrack>> Function(String) results = (_) async => [];

  @override
  Future<List<MusicTrack>> searchSongs(String query) {
    queries.add(query);
    return results(query);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const saved = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'saved-song1',
    title: 'Saved Song',
    subtitle: 'Beacon Artist',
    album: 'Saved Album',
  );
  const deviceTrack = LocalMusicTrack(
    uri: 'content://media/external/audio/media/14',
    title: 'Offline Song',
    artist: 'Device Artist',
    artPath: '/private/cache/cover.jpg',
    durationMs: 42000,
  );
  const remote = MusicTrack(videoId: 'remote00001', title: 'Remote Song');
  const anotherRemote =
      MusicTrack(videoId: 'remote00002', title: 'Another Result');

  late SembastSqfDb database;
  late Object? session;
  late _Catalog catalog;
  late AndroidAutoMusic browser;
  late List<OnDeviceMusicEntry> device;
  late Future<List<OnDeviceMusicEntry>> Function() loadDevice;
  late List<Playlist> Function(IDbClient) playlists;
  late List<
      ({
        List<Video> entries,
        int index,
        String? title,
        bool Function() current
      })> remotePlays;
  late List<({List<OnDeviceMusicEntry> entries, int index})> devicePlays;

  MusicLibraryService library() =>
      MusicLibraryService.forProfile(database, database.profileId);

  Future<MediaItem> folder(String title) async {
    final root = await browser.getChildren(AudioService.browsableRootId);
    return root.singleWhere((item) => item.title == title);
  }

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    session = Object();
    catalog = _Catalog();
    device = [];
    loadDevice = () async => device;
    playlists = (_) => [];
    remotePlays = [];
    devicePlays = [];
    browser = AndroidAutoMusic(
      session: () => session,
      database: () => database,
      catalog: catalog,
      playVideos: (entries, index, title, current) async => remotePlays.add((
        entries: entries,
        index: index,
        title: title,
        current: current,
      )),
      playDevice: (entries, index, _, __) async =>
          devicePlays.add((entries: entries, index: index)),
      loadDevice: () => loadDevice(),
      loadPlaylists: (owner) => playlists(owner),
    );
  });

  tearDown(() => database.close());

  test('browses saved songs for the current profile and rejects retired IDs',
      () async {
    await library().save(saved);
    final firstFolder = await folder('Saved songs');
    expect(firstFolder.playable, isFalse);
    final firstSong = (await browser.getChildren(firstFolder.id)).single;
    expect(firstSong.playable, isTrue);
    expect(firstSong.title, saved.title);
    expect((await browser.getMediaItem(firstSong.id))?.title, saved.title);

    final other = await database.createProfile('Other');
    await database.useProfile(other.id);
    session = Object();
    await library().save(const MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'saved-song1',
      title: 'Other metadata for the same song',
    ));

    await browser.playFromMediaId(firstSong.id);
    expect(await browser.getMediaItem(firstSong.id), isNull);
    expect(await browser.getChildren(firstFolder.id), isEmpty);
    expect(remotePlays, isEmpty);

    final currentFolder = await folder('Saved songs');
    final newSong = (await browser.getChildren(currentFolder.id)).single;
    expect(newSong.title, 'Other metadata for the same song');
    await browser.playFromMediaId(newSong.id);
    expect(remotePlays.single.entries.single.title, newSong.title);
    expect(remotePlays.single.current(), isTrue);
    browser.invalidate();
    expect(remotePlays.single.current(), isFalse);
    expect(await browser.getMediaItem(newSong.id), isNull);
  });

  test('rechecks bookmark visibility when opening a later browse page',
      () async {
    final entries = List.generate(
      102,
      (index) => MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'page${index.toString().padLeft(7, '0')}',
        title: 'Song $index',
      ),
    );
    expect(await library().importSongs(entries), entries.length);
    final savedFolder = await folder('Saved songs');
    final firstPage = await browser.getChildren(savedFolder.id);
    final nextPage = firstPage.singleWhere((item) => item.playable == false);
    final earlier = (await browser.getChildren(nextPage.id)).first;
    final removed =
        entries.singleWhere((entry) => entry.title == earlier.title);

    await library().remove(removed.kind, removed.id);

    final refreshed = await browser.getChildren(nextPage.id);
    expect(refreshed.map((item) => item.title), isNot(contains(removed.title)));
    expect(refreshed, hasLength(1));
    expect(await browser.getMediaItem(earlier.id), isNull);
  });

  test(
    'a queue addition cannot resolve on-device media from a retired scope',
    () async {
      device = [OnDeviceMusicEntry.device(deviceTrack)];
      final deviceFolder = await folder('On device');
      final row = (await browser.getChildren(deviceFolder.id)).single;
      expect(browser.isOnDeviceSong(deviceFolder.id), isNull);
      expect(browser.isOnDeviceSong(row.id), isTrue);
      expect(
        (await browser.resolveQueueSong(row.id))?.device?.deviceTrack,
        deviceTrack,
      );

      final held = Completer<List<OnDeviceMusicEntry>>();
      loadDevice = () => held.future;
      final pending = browser.resolveQueueSong(row.id);
      session = Object();
      held.complete(device);
      expect(await pending, isNull);
      expect(browser.isOnDeviceSong(row.id), isNull);
    },
  );

  test('plays the selected occurrence in a local Music playlist', () async {
    await library().markLocalPlaylist('local:music');
    const song = Video(
      videoId: 'playlist001',
      title: 'Repeated Song',
      musicMetadata: MusicMetadata(title: 'Repeated Song', artist: 'Artist'),
    );
    const another = Video(
      videoId: 'playlist002',
      title: 'Another Song',
      musicMetadata: MusicMetadata(title: 'Another Song', artist: 'Artist'),
    );
    const videoOnly = Video(videoId: 'videoplay01', title: 'Video only');
    final profileId = database.profileId;
    playlists = (owner) {
      expect(owner.profileId, profileId);
      return const [
        Playlist(
          title: 'Repeat mix',
          playlistId: 'local:music',
          author: '',
          videoCount: 3,
          videos: [song, another, song],
        ),
        Playlist(
          title: 'Watch later',
          playlistId: 'local:videos',
          author: '',
          videoCount: 1,
          videos: [videoOnly],
        ),
      ];
    };

    final playlistFolder = await folder('Playlists');
    final playlist = (await browser.getChildren(playlistFolder.id)).single;
    expect(playlist.title, 'Repeat mix');
    final songs = await browser.getChildren(playlist.id);
    expect(songs.map((item) => item.title), [
      'Repeated Song',
      'Another Song',
      'Repeated Song',
    ]);
    expect(songs.first.id, isNot(songs.last.id));

    await browser.playFromMediaId(songs.last.id);
    final selection = remotePlays.single;
    expect(selection.index, 2);
    expect(selection.title, 'Repeat mix');
    expect(selection.entries.map((entry) => entry.videoId), [
      song.videoId,
      another.videoId,
      song.videoId,
    ]);
  });

  test('browses authorized device tracks without exporting a document URI',
      () async {
    device = [
      OnDeviceMusicEntry.device(deviceTrack),
      OnDeviceMusicEntry.download(
        const DownloadedVideo(
          videoId: 'download001',
          title: 'Another profile download',
          lengthSeconds: 180,
          quality: '',
          profileId: 'another-profile',
          musicMetadata:
              MusicMetadata(title: 'Another profile download', artist: ''),
        ),
        'file-proof',
      ),
    ];
    final deviceFolder = await folder('On device');
    final item = (await browser.getChildren(deviceFolder.id)).single;
    expect(item.title, deviceTrack.title);
    expect(item.id, isNot(contains(deviceTrack.uri)));
    expect(
        item.artUri?.toString() ?? '', isNot(contains(deviceTrack.artPath!)));
    expect(item.extras?.toString() ?? '', isNot(contains(deviceTrack.uri)));

    await browser.playFromMediaId(item.id);
    expect(devicePlays.single.entries.single.deviceTrack, same(deviceTrack));
    expect(devicePlays.single.index, 0);

    device = [];
    await browser.playFromMediaId(item.id);
    expect(await browser.getMediaItem(item.id), isNull);
    expect(devicePlays, hasLength(1));
  });

  test('voice playback prefers the active library and supports an empty query',
      () async {
    await library().save(saved);
    device = [OnDeviceMusicEntry.device(deviceTrack)];

    await browser.playFromSearch('  beacon artist  ');
    expect(remotePlays.single.entries.single.videoId, saved.id);
    expect(catalog.queries, isEmpty);

    await browser.playFromSearch('   ');
    expect(remotePlays.last.entries.single.videoId, saved.id);
    expect(catalog.queries, isEmpty);

    await browser.playFromSearch('Device Artist');
    expect(devicePlays.single.entries.single.deviceTrack, same(deviceTrack));
    expect(catalog.queries, isEmpty);

    await browser
        .playFromSearch('', {'android.intent.extra.artist': 'Device Artist'});
    expect(devicePlays.last.entries.single.deviceTrack, same(deviceTrack));
    expect(devicePlays, hasLength(2));
    expect(catalog.queries, isEmpty);
  });

  test('a removed bookmark retires its local search result', () async {
    await library().save(saved);
    final hits = await browser.search(saved.title);
    final id = hits.single.id;
    expect(hits.single.title, saved.title);

    await library().remove(saved.kind, saved.id);

    expect(await browser.getMediaItem(id), isNull);
    await browser.playFromMediaId(id);
    expect(remotePlays, isEmpty);
    expect(catalog.queries, isEmpty);
  });

  test('catalog results can be browsed and preserve their playback order',
      () async {
    catalog.results = (_) async => [remote, anotherRemote];

    final hits = await browser.search('  Remote Song  ');
    expect(catalog.queries, ['Remote Song']);
    expect(hits.map((item) => item.title), [remote.title, anotherRemote.title]);
    expect(
        (await browser.getMediaItem(hits.last.id))?.title, anotherRemote.title);

    await browser.playFromMediaId(hits.last.id);
    final selection = remotePlays.single;
    expect(selection.index, 1);
    expect(selection.entries.map((entry) => entry.videoId),
        [remote.videoId, anotherRemote.videoId]);

    await browser.playFromSearch('Remote Song');
    expect(catalog.queries, ['Remote Song', 'Remote Song']);
    expect(remotePlays.last.index, 0);
    expect(remotePlays.last.entries.map((entry) => entry.videoId),
        [remote.videoId, anotherRemote.videoId]);
  });

  test('discards catalog results across an account change in the same profile',
      () async {
    final waiting = Completer<List<MusicTrack>>();
    final requested = Completer<void>();
    catalog.results = (_) {
      requested.complete();
      return waiting.future;
    };

    final pending = browser.playFromSearch('Pending query');
    await requested.future;
    session = Object();
    waiting.complete([remote]);
    await pending;
    expect(remotePlays, isEmpty);

    catalog.results = (_) async => [remote];
    final fresh = await browser.search('Fresh query');
    expect(fresh.single.title, remote.title);
    session = null;
    expect(await browser.getChildren(AudioService.browsableRootId), isEmpty);
    expect(await browser.getMediaItem(fresh.single.id), isNull);
    await browser.playFromMediaId(fresh.single.id);
    await browser.playFromSearch('Another query');
    expect(remotePlays, isEmpty);
    expect(catalog.queries, ['Pending query', 'Fresh query']);
  });
}
