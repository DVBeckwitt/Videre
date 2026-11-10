import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

class _LiveNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

// Explicitly opt in; the canonical offline suite must never require YouTube.
// flutter test --dart-define=VIDERE_LIVE_MUSIC_TEST=true test/music/catalog_live_test.dart
// Add VIDERE_LIVE_MUSIC_SOCKS_PORT=9050 (and optionally
// VIDERE_LIVE_MUSIC_SOCKS_HOST) to test the app's actual SOCKS transport.
// VIDERE_LIVE_MUSIC_VERIFY_TOR=true additionally requires IsTor=true.
void main() {
  _LiveNetworkBinding();
  const enabled = bool.fromEnvironment('VIDERE_LIVE_MUSIC_TEST');
  const port = int.fromEnvironment('VIDERE_LIVE_MUSIC_SOCKS_PORT');
  const verifyTor = bool.fromEnvironment('VIDERE_LIVE_MUSIC_VERIFY_TOR');
  final previousOverrides = HttpOverrides.current;

  setUpAll(() async {
    if (!enabled) return;
    db = await SembastSqfDb.createInMemory();
    HttpOverrides.global = MyHttpOverrides();
    final config = SocksProxyConfig(
        enabled: port != 0,
        host: const String.fromEnvironment('VIDERE_LIVE_MUSIC_SOCKS_HOST',
            defaultValue: '127.0.0.1'),
        port: port == 0 ? 9050 : port);
    await NetworkProxy.instance
        .initialize(saved: jsonEncode(config.toJson()), configureNative: false);
    service = Service();
    if (verifyTor) {
      expect(config.enabled, isTrue,
          reason: 'Tor verification requires an explicit SOCKS endpoint.');
      final response = await service.httpClient
          .get(Uri.parse('https://check.torproject.org/api/ip'))
          .timeout(const Duration(seconds: 40));
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body)['IsTor'], isTrue);
    }
  });

  tearDownAll(() async {
    if (!enabled) return;
    service.httpClient.close();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    HttpOverrides.global = previousOverrides;
    await db.close();
  });

  // The Invidious media setting must not disable catalog or artwork requests,
  // whether the application uses SOCKS or the ordinary network connection.
  for (final useMediaProxy in [false, true]) {
    group('Proxy videos=$useMediaProxy', () {
      setUp(() => db.saveSetting(
          SettingsValue(useProxySettingName, useMediaProxy.toString())));
      test('public anonymous discovery feeds smoke check', () async {
        final catalog = MusicCatalogService();
        final releases = await catalog.getNewReleases();
        expect(releases, isNotEmpty);
        expect(releases.every((album) => album.id.startsWith('MPRE')), isTrue);
        final global = await catalog.getCharts();
        final us = await catalog.getCharts(country: 'US');
        expect(global.country, 'ZZ');
        expect(us.country, 'US');
        expect(global.playlists, isNotEmpty);
        expect(us.playlists, isNotEmpty);
        expect(global.artists, isNotEmpty);
        expect(us.countries.any((country) => country.code == 'ZZ'), isTrue);
        final moods = await catalog.getMoodCategories();
        expect(moods, isNotEmpty);
        expect(moods.any((category) => category.group == 'For you'), isFalse);
        final playlists = await catalog.getMoodPlaylists(moods.first.params);
        expect(playlists, isNotEmpty);
        // Public counts only; no request configuration or transport details.
        // ignore: avoid_print
        print('Live discovery: ${releases.length} new releases; '
            'global ${global.playlists.length} chart playlists, '
            '${global.artists.length} artist cards; '
            'US ${us.playlists.length} chart playlists, '
            '${us.artists.length} artist cards; '
            '${us.countries.length} countries; ${moods.length} mood/genre categories; '
            '${playlists.length} ${moods.first.title} playlists.');
      }, skip: !enabled, timeout: const Timeout(Duration(minutes: 3)));

      test('public catalog search, album, song and playlist smoke check',
          () async {
        final catalog = MusicCatalogService();
        final songs = await catalog.searchSongs('Daft Punk Get Lucky');
        expect(songs, isNotEmpty);
        expect(songs.first.artists, contains('Daft Punk'));
        final artwork = await service.httpClient
            .get(Uri.parse(songs.first.thumbnails.first.url))
            .timeout(const Duration(seconds: 30));
        expect(artwork.statusCode, 200);
        expect(artwork.bodyBytes, isNotEmpty);
        final albums =
            await catalog.searchAlbums('Daft Punk Random Access Memories');
        expect(albums, isNotEmpty);
        final album = await catalog.getAlbum(albums.first.id);
        expect(album.title, contains('Random Access Memories'));
        expect(album.tracks, hasLength(13));
        expect(album.tracks.first.title, 'Give Life Back to Music');
        expect(album.tracks.last.title, 'Contact');
        final song = await catalog.getSong(songs.first.videoId);
        expect(song.title, contains('Get Lucky'));
        final albumPlaylist = await catalog
            .getPlaylist('OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c');
        expect(albumPlaylist.title, album.title);
        expect(albumPlaylist.tracks, hasLength(13));
        final playlist =
            await catalog.getPlaylist('PLwO8Yaz8URbq0HdSG3VFeCIUSGpsjbCtH');
        expect(playlist.title, 'Every Daft Punk Song');
        expect(playlist.tracks, isNotEmpty);
        final artists = await catalog.searchArtists('Daft Punk');
        expect(artists.first.name, 'Daft Punk');
        final artist = await catalog.getArtist(artists.first.id);
        expect(artist.songs, isNotEmpty);
        expect(artist.albums.length, greaterThan(10));
        expect(artist.singles.length, greaterThan(10));
        final playlists = await catalog.searchPlaylists('Daft Punk');
        expect(playlists, isNotEmpty);
        final largeArtist = await catalog.getArtist('UCuA3IbLtd-mMVPH5gm16tWQ');
        expect(largeArtist.artist.name, 'Buckethead');
        expect(largeArtist.albums.length, greaterThan(100));
        // Public metadata only; never log transport headers or configuration.
        // ignore: avoid_print
        print('Live music: ${songs.length} songs, ${albums.length} albums; '
            '${album.title}: ${album.tracks.length} ordered tracks; '
            'song ${song.videoId}; album playlist ${albumPlaylist.tracks.length}; '
            'public playlist ${playlist.tracks.length} tracks; '
            'artist ${artist.artist.name}: ${artist.songs.length} top songs, '
            '${artist.albums.length} albums, ${artist.singles.length} singles; '
            '${playlists.length} public playlists; '
            '${largeArtist.artist.name}: ${largeArtist.albums.length} albums.');
      }, skip: !enabled, timeout: const Timeout(Duration(minutes: 3)));
    });
  }
}
