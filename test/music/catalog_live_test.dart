import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// Explicitly opt in; the canonical offline suite must never require YouTube.
// flutter test --dart-define=VIDERE_LIVE_MUSIC_TEST=true test/music/catalog_live_test.dart
void main() {
  test('public catalog search, album, song and playlist smoke check', () async {
    final client = http.Client();
    addTearDown(client.close);
    final catalog = MusicCatalogService(httpClient: client);
    final songs = await catalog.searchSongs('Daft Punk Get Lucky');
    expect(songs, isNotEmpty);
    expect(songs.first.artists, contains('Daft Punk'));
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
    final albumPlaylist =
        await catalog.getPlaylist('OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c');
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
  },
      skip: !const bool.fromEnvironment('VIDERE_LIVE_MUSIC_TEST'),
      timeout: const Timeout(Duration(minutes: 3)));
}
