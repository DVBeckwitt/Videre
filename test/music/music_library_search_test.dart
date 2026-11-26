import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_lyrics_match.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/local_music_lyrics_authoring.dart';
import 'package:clipious/music/services/music_library_search.dart';
import 'package:clipious/music/services/music_library_search_preferences.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_lyrics_corrections.dart';
import 'package:clipious/music/services/music_offline_lyrics.dart';
import 'package:clipious/music/services/on_device_music_downloads.dart';
import 'package:clipious/music/views/components/music_library_search_results.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import '../test_app_cubit.dart';

class _Storage extends DownloadStorage {
  _Storage(this.probe);

  final Future<List<MusicFileProbe>> Function(
      String profileId, List<DownloadedVideo> files) probe;

  @override
  Future<List<MusicFileProbe>> probeMusicFiles(
          String profileId, Iterable<DownloadedVideo> downloads) =>
      probe(profileId, downloads.toList(growable: false));
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads(super.initialState);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const local = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const tree = 'content://documents/tree/primary%3AMusic';
  const shared = '$tree/document/primary%3AMusic%2Fshared.m4a';
  const copy = '$tree/document/primary%3AMusic%2Fcopy.m4a';
  const saved = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'saved-song1',
    title: 'Canción',
    subtitle: 'Ensemble',
    album: 'Été',
  );
  const downloaded = DownloadedVideo(
    videoId: 'saved-song1',
    title: 'Canción',
    lengthSeconds: 20,
    quality: 'audio',
    musicMetadata: MusicMetadata(title: 'Canción', artist: 'Ensemble'),
    audioOnly: true,
    downloadComplete: true,
  );
  late SembastSqfDb database;
  late Service originalService;
  late int networkCalls;

  MusicFileProbe proof(DownloadedVideo file, String identity) => (
        download: file,
        uri: file.storageUri ?? 'file:///data/app/${file.videoId}.m4a',
        identity: identity,
        byteLength: 777,
      );

  setUp(() async {
    originalService = service;
    networkCalls = 0;
    service = Service(httpClient: MockClient((_) async {
      networkCalls++;
      throw StateError('Library Search must not query the catalog.');
    }));
    database = await SembastSqfDb.createInMemory();
    messenger.setMockMethodCallHandler(local, (_) async => null);
  });

  tearDown(() async {
    expect(networkCalls, 0);
    messenger.setMockMethodCallHandler(local, null);
    service.httpClient.close();
    service = originalService;
    await database.close();
  });

  List<MusicLibrarySearchHit> search(MusicLibrarySearch reader, String query,
          {Set<MusicLibrarySearchType> types =
              MusicLibrarySearchType.categories}) =>
      reader.search(query,
          database: database, profileId: database.profileId, types: types);

  test('matches saved songs and Music playlists within the active profile',
      () async {
    final reader = MusicLibrarySearch(deviceLibrary: LocalMusicLibrary());
    addTearDown(reader.dispose);
    final profile = database.profileId;
    final library = MusicLibraryService.forProfile(database, profile);
    await library.save(saved);
    await library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.playlist,
        id: 'PLrecordings',
        title: 'Canción radio',
        subtitle: 'Dúo'));
    await library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: 'artist', title: 'Ensemble'));
    await library.markLocalPlaylist('local:songs');
    await database.saveSetting(SettingsValue(
        localPlaylistsSetting,
        jsonEncode([
          const Playlist(
                  playlistId: 'local:songs',
                  title: 'Canción offline',
                  author: 'Été',
                  videoCount: 0)
              .toJson(),
          const Playlist(
                  playlistId: 'local:video',
                  title: 'Canción videos',
                  author: 'Ensemble',
                  videoCount: 0)
              .toJson(),
        ])));

    expect(search(reader, 'CANCIÓN été').map((hit) => hit.key),
        ['bookmark:song:saved-song1', 'playlist:local:songs']);
    expect(
        search(reader, 'cancion ete', types: {MusicLibrarySearchType.songs})
            .map((hit) => hit.key),
        ['bookmark:song:saved-song1']);
    expect(
        search(reader, 'cancion', types: {MusicLibrarySearchType.playlists})
            .map((hit) => hit.key),
        ['bookmark:playlist:PLrecordings', 'playlist:local:songs']);
    expect(
        search(reader, 'cancion ete', types: {MusicLibrarySearchType.playlists})
            .single
            .key,
        'playlist:local:songs');
    expect(search(reader, 'duo radio').single.key,
        'bookmark:playlist:PLrecordings');
    expect(search(reader, 'ensemble').single.key, 'bookmark:song:saved-song1');
    expect(search(reader, 'missing cancion'), isEmpty);
    expect(search(reader, '   '), isEmpty);
    final person = await database.createProfile('Other');
    await database.useProfile(person.id);
    expect(search(reader, 'cancion'), isEmpty);
    expect(reader.search('cancion', database: database, profileId: profile),
        isEmpty);
  });

  test('finds distinct saved types offline and reads legacy channel filters',
      () async {
    final reader = MusicLibrarySearch(deviceLibrary: LocalMusicLibrary());
    addTearDown(reader.dispose);
    const title = 'Same title';
    const artistId = 'UC0123456789abcdefghijAB';
    final library =
        MusicLibraryService.forProfile(database, database.profileId);
    for (final (kind, id) in const [
      (MusicLibraryKind.song, 'saved-song1'),
      (MusicLibraryKind.playlist, 'OLAK5uy_shared'),
      (MusicLibraryKind.album, 'MPREunsupported'),
      (MusicLibraryKind.artist, artistId),
      (MusicLibraryKind.playlist, 'PLshared'),
    ]) {
      await library.save(MusicLibraryEntry(kind: kind, id: id, title: title));
    }
    await database.saveSetting(SettingsValue(
        'music-library-search-categories-v1', 'channels,unknown'));
    final preferences =
        MusicLibrarySearchPreferences.forProfile(database, database.profileId);
    expect(preferences.categories, {MusicLibrarySearchType.artists});
    final artist = search(reader, title, types: preferences.categories).single
        as MusicLibrarySearchBookmark;
    expect(artist.entry.id, artistId);
    expect(artist.resultKind, MusicLibraryKind.artist);

    for (final (type, kind, id) in const [
      (MusicLibrarySearchType.songs, MusicLibraryKind.song, 'saved-song1'),
      (MusicLibrarySearchType.albums, MusicLibraryKind.album, 'OLAK5uy_shared'),
      (MusicLibrarySearchType.playlists, MusicLibraryKind.playlist, 'PLshared'),
    ]) {
      final hit = search(reader, title, types: {type}).single
          as MusicLibrarySearchBookmark;
      expect(hit.entry.id, id);
      expect(hit.resultKind, kind);
    }
    expect(search(reader, title), hasLength(4));
    expect(search(reader, 'missing title'), isEmpty);
  });

  test('matches and displays live aliases for distinct saved artist IDs',
      () async {
    const firstId = 'UC0123456789abcdefghijAB';
    const secondId = 'UC0123456789abcdefghijCD';
    const original = 'Original Group';
    final reader = MusicLibrarySearch(deviceLibrary: LocalMusicLibrary());
    addTearDown(reader.dispose);
    final library =
        MusicLibraryService.forProfile(database, database.profileId);
    for (final (songId, title, artistId) in [
      ('one', 'First song', firstId),
      ('two', 'Second song', secondId),
      ('three', 'Unlinked song', null),
    ]) {
      await library.save(MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: songId,
          title: title,
          subtitle: original,
          artistCredits: [MusicArtistCredit(name: original, id: artistId)]));
    }

    // Prime the original text cache before editing the aliases.
    expect(search(reader, 'original group'), hasLength(3));
    final first = MusicArtistIdentity.catalog(firstId);
    final second = MusicArtistIdentity.catalog(secondId);
    await library.setArtistAlias(first, 'Écho Collective',
        isCurrent: () => true);
    expect(
        search(reader, 'original echo first').single.key, 'bookmark:song:one');
    expect(
        search(reader, 'echo collective').single.subtitle, 'Écho Collective');
    await library.setArtistAlias(second, 'Écho Collective',
        isCurrent: () => true);
    expect(search(reader, 'echo collective').map((hit) => hit.key),
        unorderedEquals(['bookmark:song:one', 'bookmark:song:two']));

    await library.setArtistAlias(first, null, isCurrent: () => true);
    expect(search(reader, 'echo collective').single.key, 'bookmark:song:two');
    final restored =
        search(reader, 'original first').single as MusicLibrarySearchBookmark;
    expect(restored.subtitle, original);
    expect(restored.entry.artistCredits.single.id, firstId);
    expect(restored.entry.artistCredits.single.name, original);
  });

  test('matches device and downloaded artist aliases from their own source',
      () async {
    const catalogId = 'UC0123456789abcdefghijAB';
    final file = downloaded.copyWith(
      musicMetadata: const MusicMetadata(
        title: 'Catalog download',
        artist: 'Catalog credit',
        artistCredits: [
          MusicArtistCredit(name: 'Catalog credit', id: catalogId)
        ],
      ),
    );
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => true,
        'listTracks' => [
            {
              'uri': shared,
              'title': 'Device file',
              'artist': 'Device credit',
              'albumArtist': 'Record credit',
            },
          ],
        _ => null,
      };
    });
    final device = LocalMusicLibrary();
    addTearDown(device.dispose);
    final reader = MusicLibrarySearch(
      deviceLibrary: device,
      downloads: OnDeviceMusicDownloads(
          storage: _Storage((_, __) async => [proof(file, 'a' * 64)])),
    );
    addTearDown(reader.dispose);
    await reader.refreshFiles(
        database: database, profileId: database.profileId, downloads: [file]);
    List<MusicLibrarySearchHit> songs(String query) =>
        search(reader, query, types: {MusicLibrarySearchType.songs});
    expect(songs('credit'), hasLength(2));

    final library =
        MusicLibraryService.forProfile(database, database.profileId);
    final deviceArtist = MusicArtistIdentity.device('device credit');
    await library.setArtistAlias(deviceArtist, 'Local Alias',
        isCurrent: () => true);
    await library.setArtistAlias(
        MusicArtistIdentity.device('record credit'), 'Album Alias',
        isCurrent: () => true);
    await library.setArtistAlias(
        MusicArtistIdentity.catalog(catalogId), 'Online Alias',
        isCurrent: () => true);
    expect(songs('device credit local alias').single.subtitle, 'Local Alias');
    expect(songs('album alias').single.title, 'Device file');
    expect(
        songs('catalog credit online alias').single.subtitle, 'Online Alias');
    await library.setArtistAlias(deviceArtist, null, isCurrent: () => true);
    expect(songs('local alias'), isEmpty);
    expect(songs('device credit').single.subtitle, 'Device credit');
    expect(songs('online alias').single.title, 'Catalog download');
  });

  test('searches combinations of actual visible device groups', () async {
    var authorized = true;
    var scans = 0;
    messenger.setMockMethodCallHandler(local, (call) async {
      if (call.method == 'listTracks') {
        scans++;
        return [
          {
            'uri': shared,
            'title': 'First recording',
            'artist': 'Bôssa Duo',
            'album': 'Bôssa Sessions',
            'albumKey': 'a' * 64,
            'genre': 'Bôssa Nova',
            'visibilityKey': 'b' * 64,
          },
          {
            'uri': copy,
            'title': 'Second recording',
            'artist': 'BÔSSA DUO',
            'album': 'Bôssa Sessions',
            'albumKey': 'd' * 64,
            'genre': 'BÔSSA NOVA',
            'visibilityKey': 'c' * 64,
          },
        ];
      }
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => authorized,
        _ => null,
      };
    });
    final device = LocalMusicLibrary(visibilityDatabase: () => database);
    final reader = MusicLibrarySearch(deviceLibrary: device);
    addTearDown(device.dispose);
    addTearDown(reader.dispose);
    await MusicLibraryService.forProfile(database, database.profileId)
        .save(const MusicLibraryEntry(
      kind: MusicLibraryKind.playlist,
      id: 'PLmix',
      title: 'Bôssa mix',
    ));
    await reader.refreshFiles(
        database: database, profileId: database.profileId, downloads: const []);
    final scansAfterRefresh = scans;

    const albumTypes = {MusicLibrarySearchType.albums};
    const artistTypes = {MusicLibrarySearchType.artists};
    const genreTypes = {MusicLibrarySearchType.genres};
    const combinedTypes = {
      MusicLibrarySearchType.albums,
      MusicLibrarySearchType.genres,
      MusicLibrarySearchType.playlists,
    };
    final albums = search(reader, 'BOSSA SESSIONS', types: albumTypes);
    expect(albums, everyElement(isA<MusicLibrarySearchAlbum>()));
    expect(albums.map((hit) => hit.key).toSet(), hasLength(2));
    final artist = search(reader, 'BOSSA DUO', types: artistTypes).single;
    expect(artist, isA<MusicLibrarySearchArtist>());
    final genre = search(reader, 'BOSSA NOVA', types: genreTypes).single;
    expect(genre, isA<MusicLibrarySearchGenre>());
    final songs =
        search(reader, 'BOSSA', types: {MusicLibrarySearchType.songs});
    expect(songs, hasLength(2));
    expect(songs, everyElement(isA<MusicLibrarySearchFile>()));
    final combined = search(reader, 'BOSSA', types: combinedTypes);
    expect(
        combined.map((hit) => hit.key),
        unorderedEquals([
          ...albums.map((hit) => hit.key),
          genre.key,
          'bookmark:playlist:PLmix',
        ]));
    expect(
        search(reader, 'BOSSA').map((hit) => hit.key),
        unorderedEquals([
          ...combined.map((hit) => hit.key),
          artist.key,
          ...songs.map((hit) => hit.key),
        ]));
    expect(search(reader, 'sessions', types: genreTypes), isEmpty);
    expect(scans, scansAfterRefresh);

    final hidden = await device.hideTrack(
        device.visibleTracks.singleWhere((track) => track.uri == copy));
    expect(hidden, isNotNull);
    final remainingAlbum = search(reader, 'bossa', types: albumTypes).single;
    expect(albums.map((hit) => hit.key), contains(remainingAlbum.key));
    expect(search(reader, 'bossa', types: artistTypes).single.key, artist.key);
    expect(search(reader, 'bossa', types: genreTypes).single.key, genre.key);

    authorized = false;
    await device.revalidate();
    expect(search(reader, 'BOSSA', types: combinedTypes).map((hit) => hit.key),
        ['bookmark:playlist:PLmix']);
    expect(search(reader, 'BOSSA', types: artistTypes), isEmpty);
  });

  test('finds explicitly kept recordings by words on one lyric line', () async {
    final device = LocalMusicLibrary();
    final reader = MusicLibrarySearch(deviceLibrary: device);
    addTearDown(device.dispose);
    addTearDown(reader.dispose);
    const types = {MusicLibrarySearchType.lyrics};
    const id = 'loose-song1';
    const metadata = MusicMetadata(title: 'Night Train', artist: 'Ensemble');
    final offline = MusicOfflineLyrics(database);
    await offline.save(
      id,
      const MusicLyrics.plain('À la rivière, je chante.\nSous le ciel pâle.'),
      track: metadata,
      durationSeconds: 40,
    );

    final hit = search(reader, 'RIVIERE CHANTE', types: types).single
        as MusicLibrarySearchRecording;
    expect(hit.video.videoId, id);
    expect(hit.title, metadata.title);
    expect(hit.subtitle, metadata.artist);
    expect(hit.lyricLine, 'À la rivière, je chante.');
    expect(search(reader, 'riviere ciel', types: types), isEmpty);
    expect(search(reader, metadata.title, types: types), isEmpty);
    expect(search(reader, 'riviere chante'), isEmpty);
    expect(
        search(reader, 'riviere chante', types: {MusicLibrarySearchType.songs}),
        isEmpty);

    final initial = database.profileId;
    final other = await database.createProfile('Other');
    await database.useProfile(other.id);
    expect(search(reader, 'riviere chante', types: types), isEmpty);
    expect(
        reader.search('riviere chante',
            database: database, profileId: initial, types: types),
        isEmpty);
    await database.useProfile(initial);
    expect(search(reader, 'riviere chante', types: types).single.key, hit.key);
    await offline.remove(id);
    expect(search(reader, 'riviere chante', types: types), isEmpty);
  });

  test('a saved song uses its recording metadata and explicit correction',
      () async {
    final device = LocalMusicLibrary();
    final reader = MusicLibrarySearch(deviceLibrary: device);
    addTearDown(device.dispose);
    addTearDown(reader.dispose);
    const types = {MusicLibrarySearchType.lyrics};
    final owner = database.forProfile(database.profileId);
    final library =
        MusicLibraryService.forProfile(database, database.profileId);
    final metadata = saved.toVideo().musicMetadata!;
    final offline = MusicOfflineLyrics(owner);
    await offline.save(
      saved.id,
      const MusicLyrics.synced([
        (start: Duration(seconds: 3), text: 'Bright morning'),
      ]),
      track: metadata,
      durationSeconds: saved.durationSeconds,
    );
    await library.save(saved);
    await library.setSavedSongTitle(saved.id, 'My favorite recording',
        isCurrent: () => true);

    final hit = search(reader, 'bright morning', types: types).single;
    expect(hit, isA<MusicLibrarySearchBookmark>());
    expect(hit.title, 'My favorite recording');
    expect(hit.lyricLine, 'Bright morning');
    final corrections = MusicLyricsCorrections(owner);
    await corrections.save(
      saved.id,
      const MusicLyricsCorrection(MusicLyrics.plain('Cloudy evening')),
    );
    expect(search(reader, 'bright morning', types: types), isEmpty);
    expect(search(reader, 'cloudy evening', types: types).single.key, hit.key);
    await corrections.save(
      saved.id,
      const MusicLyricsCorrection(MusicLyrics.unavailable()),
    );
    expect(search(reader, 'bright morning', types: types), isEmpty);
    expect(search(reader, 'cloudy evening', types: types), isEmpty);
    await corrections.clear(saved.id);
    expect(search(reader, 'bright morning', types: types).single.key, hit.key);
  });

  test('a local lyric match expires on sidecar removal and lost grant',
      () async {
    var authorized = true;
    var sidecarPresent = true;
    var readCalls = 0;
    messenger.setMockMethodCallHandler(local, (call) async {
      if (call.method == 'readTrackLyrics') {
        readCalls++;
        expect(call.arguments['trackUri'], shared);
        if (!authorized) return null;
        return {
          if (sidecarPresent) 'sidecar': '[ti:Metadata]\n[00:01.00]Nuit en été',
          'embedded': 'Morning bells',
        };
      }
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => authorized,
        'listTracks' => [
            {'uri': shared, 'title': 'Local song', 'durationMs': 20000},
          ],
        _ => null,
      };
    });
    final device = LocalMusicLibrary(visibilityDatabase: () => database);
    final reader = MusicLibrarySearch(deviceLibrary: device);
    addTearDown(device.dispose);
    addTearDown(reader.dispose);
    const query = 'NUIT ETE';
    final profile = database.profileId;
    await reader.refreshFiles(
        database: database, profileId: profile, downloads: const []);
    expect(search(reader, 'Local song').single.lyricLine, isNull);
    expect(readCalls, 0);

    final matches = await reader
        .findDeviceLyricMatches(query,
            database: database, profileId: profile, isCurrent: () => true)
        .toList();
    final match = matches.single;
    expect(match.line, 'Nuit en été');
    expect(match.track.uri, shared);
    List<MusicLibrarySearchHit> results() => reader.search(query,
        database: database,
        profileId: profile,
        types: {MusicLibrarySearchType.lyrics},
        deviceLyricMatches: {match.track: match.line});
    expect(results().single, isA<MusicLibrarySearchFile>());

    sidecarPresent = false;
    expect(
        await reader.recheckDeviceLyric(query, match.track,
            database: database, profileId: profile, isCurrent: () => true),
        isNull);
    expect(
        await reader.recheckDeviceLyric('morning bells', match.track,
            database: database, profileId: profile, isCurrent: () => true),
        'Morning bells');

    authorized = false;
    await device.revalidate();
    expect(results(), isEmpty);
    expect(
        await reader.recheckDeviceLyric(query, match.track,
            database: database, profileId: profile, isCurrent: () => true),
        isNull);
    expect(readCalls, 3);
  });

  test(
      'lyric search uses a provider row’s local draft without opening its file',
      () async {
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => {
            'uri': tree,
            'name': 'Documents',
            'selectionId': 'provider-grant',
            'isDocumentProvider': true,
          },
        'checkFolderAccess' => true,
        'listTracks' => [
            {'uri': shared, 'title': 'Provider song', 'durationMs': 20000},
          ],
        'readTrackLyrics' => fail('A lyric search opened a provider file'),
        _ => null,
      };
    });
    final device = LocalMusicLibrary(visibilityDatabase: () => database);
    final reader = MusicLibrarySearch(deviceLibrary: device);
    addTearDown(device.dispose);
    addTearDown(reader.dispose);
    final profile = database.profileId;
    await reader.refreshFiles(
        database: database, profileId: profile, downloads: const []);
    final track = device.visibleTracks.single;
    expect(track.isDocumentProvider, isTrue);
    final lyrics = LocalMusicLyricsAuthoring.forTrack(
        database: database, track: track, isCurrent: () => true)!;
    expect(
        await lyrics.savePlain('A saved verse', previousDraft: null), isTrue);
    final matches = await reader
        .findDeviceLyricMatches('saved verse',
            database: database, profileId: profile, isCurrent: () => true)
        .toList();
    expect(matches.single, (track: track, line: 'A saved verse'));
    expect(
        await reader.recheckDeviceLyric('saved verse', track,
            database: database, profileId: profile, isCurrent: () => true),
        'A saved verse');
  });

  test('an in-flight device lyric read cannot publish to another profile',
      () async {
    final started = Completer<void>();
    final pendingLyrics = Completer<Map<String, String>>();
    messenger.setMockMethodCallHandler(local, (call) async {
      if (call.method == 'readTrackLyrics') {
        started.complete();
        return pendingLyrics.future;
      }
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => true,
        'listTracks' => [
            {'uri': shared, 'title': 'Local song'},
          ],
        _ => null,
      };
    });
    final device = LocalMusicLibrary(visibilityDatabase: () => database);
    final reader = MusicLibrarySearch(deviceLibrary: device);
    addTearDown(device.dispose);
    addTearDown(reader.dispose);
    final initial = database.profileId;
    final other = await database.createProfile('Other');
    await reader.refreshFiles(
        database: database, profileId: initial, downloads: const []);
    final matches = reader
        .findDeviceLyricMatches('private line',
            database: database, profileId: initial, isCurrent: () => true)
        .toList();
    await started.future;
    await database.useProfile(other.id);
    pendingLyrics.complete({'embedded': 'Private line'});
    expect(await matches, isEmpty);
  });

  test(
      'keeps separate readable copies and reacts to visibility and lost access',
      () async {
    var authorized = true;
    var pickCalls = 0;
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => authorized,
        'listTracks' => [
            {
              'uri': shared,
              'title': 'Canción',
              'artist': 'Ensemble',
              'visibilityKey': 'b' * 64,
            },
            {
              'uri': copy,
              'title': 'Canción',
              'artist': 'Ensemble',
              'visibilityKey': 'c' * 64,
            },
          ],
        'matchDownloadTracks' => {
            'shared': [shared],
          },
        'pickFolder' => ++pickCalls,
        _ => null,
      };
    });
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    final sharedRecord = downloaded.copyWith(
        videoId: 'shared', storageUri: shared, folderUri: tree);
    final missing = downloaded.copyWith(videoId: 'missing');
    final queued =
        downloaded.copyWith(videoId: 'pending', downloadComplete: false);
    final storage = _Storage((profile, files) async {
      expect(files, [sharedRecord, downloaded, missing]);
      return [
        if (authorized) proof(sharedRecord, 'a' * 64),
        proof(downloaded, 'd' * 64),
      ];
    });
    final reader = MusicLibrarySearch(
        deviceLibrary: library,
        downloads: OnDeviceMusicDownloads(storage: storage));
    addTearDown(reader.dispose);
    await MusicLibraryService.forProfile(database, database.profileId)
        .save(saved);
    Future<void> refresh() => reader.refreshFiles(
        database: database,
        profileId: database.profileId,
        downloads: [sharedRecord, downloaded, missing, queued],
        force: true);
    List<MusicLibrarySearchFile> files() => search(reader, 'Ensemble canción')
        .whereType<MusicLibrarySearchFile>()
        .toList();

    await refresh();
    expect(search(reader, 'cancion').whereType<MusicLibrarySearchBookmark>(),
        hasLength(1));
    expect(files().map((hit) => hit.entry.deviceTrack?.uri),
        unorderedEquals([shared, copy, null]));
    expect(files().map((hit) => hit.key).toSet(), hasLength(3));
    expect(
        search(reader, 'Ensemble canción',
            types: {MusicLibrarySearchType.songs}).map((hit) => hit.key),
        search(reader, 'Ensemble canción').map((hit) => hit.key));
    expect(
        search(reader, 'Ensemble canción',
            types: {MusicLibrarySearchType.playlists}),
        isEmpty);
    expect(
        files()
            .singleWhere((hit) => hit.entry.download != null)
            .entry
            .downloadFileProof,
        'd' * 64);
    await library.hideTrack(
        library.visibleTracks.singleWhere((track) => track.uri == copy));
    expect(files().map((hit) => hit.entry.deviceTrack?.uri),
        unorderedEquals([shared, null]));

    authorized = false;
    await refresh();
    expect(files().single.entry.download, downloaded);
    expect(pickCalls, 0);
  });

  test('matches embedded sort aliases and displays the original labels',
      () async {
    const title = '星の歌';
    const artist = '月楽団';
    const titleAlias = 'Hoshi no Uta';
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => true,
        'listTracks' => [
            {
              'uri': shared,
              'title': title,
              'artist': artist,
              'album': '夜明け',
              'albumArtist': '空合唱団',
              'titleSort': titleAlias,
              'artistSort': 'Tsuki Gakudan',
              'albumSort': 'Yoake',
              'albumArtistSort': 'Sora Gasshodan',
              'fileName': 'track01.mp3',
            },
          ],
        _ => null,
      };
    });
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    final reader = MusicLibrarySearch(deviceLibrary: library);
    addTearDown(reader.dispose);
    await reader.refreshFiles(
        database: database, profileId: database.profileId, downloads: []);

    final original = search(reader, title).single;
    expect(original, isA<MusicLibrarySearchFile>());
    for (final query in [
      titleAlias.toUpperCase(),
      'tsuki gakudan',
      'yoake',
      'sora gasshodan',
      '$title $titleAlias',
      'track01.mp3',
    ]) {
      final hits = search(reader, query);
      expect(hits, hasLength(1), reason: query);
      expect(hits.single.key, original.key, reason: query);
      expect(hits.single.title, title, reason: query);
      expect(hits.single.subtitle, artist, reason: query);
    }
  });

  test('Library Search only hides files with a known explicit advisory',
      () async {
    const untagged = '$tree/document/primary%3AMusic%2Funtagged.m4a';
    messenger.setMockMethodCallHandler(local, (call) async {
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => true,
        'listTracks' => [
            {'uri': shared, 'title': 'Canción (Edit A)', 'contentAdvisory': 1},
            {'uri': copy, 'title': 'Canción (Edit B)', 'contentAdvisory': 2},
            {'uri': untagged, 'title': 'Canción (Explicit Mix)'},
          ],
        _ => null,
      };
    });
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    final reader = MusicLibrarySearch(
        deviceLibrary: library,
        downloads:
            OnDeviceMusicDownloads(storage: _Storage((_, __) async => [])));
    addTearDown(reader.dispose);
    await MusicLibraryService.forProfile(database, database.profileId)
        .save(saved);
    await reader.refreshFiles(
        database: database, profileId: database.profileId, downloads: []);

    final allTitles = [
      'Canción',
      'Canción (Edit A)',
      'Canción (Edit B)',
      'Canción (Explicit Mix)',
    ];
    final visibleTitles = [
      'Canción',
      'Canción (Edit B)',
      'Canción (Explicit Mix)',
    ];
    Iterable<String> titles() =>
        search(reader, 'cancion').map((hit) => hit.title);
    expect(titles(), unorderedEquals(allTitles));
    await library.setHideExplicitTracks(true);
    expect(titles(), unorderedEquals(visibleTitles));
    await library.setHideExplicitTracks(false);
    expect(titles(), unorderedEquals(allTitles));
  });

  test('a pending earlier profile probe cannot publish after a switch',
      () async {
    final firstEntered = Completer<void>();
    final firstProof = Completer<List<MusicFileProbe>>();
    final initialProfile = database.profileId;
    final other = await database.createProfile('Other');
    final newDownload =
        downloaded.copyWith(profileId: other.id, videoId: 'new-copy');
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    final storage = _Storage((profile, files) {
      if (profile == initialProfile) {
        firstEntered.complete();
        return firstProof.future;
      }
      return Future.value([proof(newDownload, 'f' * 64)]);
    });
    final reader = MusicLibrarySearch(
        deviceLibrary: library,
        downloads: OnDeviceMusicDownloads(storage: storage));
    addTearDown(reader.dispose);
    final stale = reader.refreshFiles(
        database: database, profileId: initialProfile, downloads: [downloaded]);
    await firstEntered.future;
    await database.useProfile(other.id);
    expect(search(reader, 'cancion'), isEmpty);
    await reader.refreshFiles(
        database: database,
        profileId: other.id,
        downloads: [downloaded, newDownload]);
    firstProof.complete([proof(downloaded, 'e' * 64)]);
    await stale;
    final hit = search(reader, 'cancion').single as MusicLibrarySearchFile;
    expect(hit.entry.download, newDownload);
    expect(hit.entry.downloadFileProof, 'f' * 64);
  });

  test('retiring Search during alias lookup leaves the hidden proof unchanged',
      () async {
    final started = Completer<void>();
    final matched = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(local, (call) async {
      if (call.method == 'matchDownloadTracks') {
        if (!started.isCompleted) started.complete();
        return matched.future;
      }
      return switch (call.method) {
        'getFolder' => {'uri': tree, 'name': 'Music', 'selectionId': 'music'},
        'checkFolderAccess' => true,
        'listTracks' => [
            {'uri': shared, 'title': 'Canción', 'visibilityKey': 'b' * 64},
          ],
        _ => null,
      };
    });
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    addTearDown(library.dispose);
    await library.refresh();
    final hidden = await library.hideTrack(library.visibleTracks.single);
    expect(hidden, isNotNull);
    final sharedRecord =
        downloaded.copyWith(storageUri: shared, folderUri: tree);
    final identity = 'a' * 64;
    final storage = _Storage((_, __) async => [proof(sharedRecord, identity)]);
    final reader = MusicLibrarySearch(
        deviceLibrary: library,
        downloads: OnDeviceMusicDownloads(storage: storage));
    addTearDown(reader.dispose);

    var current = true;
    Future<void> refresh() => reader.refreshFiles(
        database: database,
        profileId: database.profileId,
        downloads: [sharedRecord],
        isCurrent: () => current);
    final retired = refresh();
    await started.future;
    current = false;
    matched.complete({
      sharedRecord.videoId: [shared],
    });
    await retired;
    expect(library.hiddenDownloadProofs, isEmpty);
    expect(search(reader, 'cancion'), isEmpty);

    current = true;
    await refresh();
    expect(library.hiddenDownloadProofs, {identity});
    expect(search(reader, 'cancion'), isEmpty);
  });

  testWidgets('resuming Library cannot publish the earlier shared file proof',
      (tester) async {
    const channel = MethodChannel('videre/download_storage');
    db = database;
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    final file = downloaded.copyWith(storageUri: shared, folderUri: tree);
    final manager = _Downloads(DownloadManagerState(videos: [file]));
    addTearDown(app.close);
    addTearDown(manager.close);
    final earlier = Completer<Map<String, Object>>();
    var probes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'probeMusicFiles') return null;
      probes++;
      // The older call captured availability before the grant was revoked.
      return probes == 1 ? earlier.future : <String, Object>{};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<DownloadManagerCubit>.value(value: manager),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: MusicLibrarySearchResults(query: 'cancion', active: true),
        ),
      ),
    ));
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    expect(probes, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    earlier.complete({
      file.videoId: {'identity': 'a' * 64, 'byteLength': 777},
    });
    await tester.pumpAndSettle();
    expect(probes, 2);
    expect(find.text(file.title), findsNothing);
    expect(find.text('No results found.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
