import 'package:clipious/music/models/local_music_album.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tree = 'content://provider/tree/music';
  final firstKey = 'a' * 64;
  final secondKey = 'b' * 64;

  LocalMusicTrack track(String title,
          {String? key,
          String? artist,
          String? albumArtist,
          int? disc,
          int? position,
          String? date,
          String? original}) =>
      LocalMusicTrack(
          uri: '$tree/document/$title',
          title: title,
          album: 'Live',
          albumKey: key,
          artist: artist,
          albumArtist: albumArtist,
          discNumber: disc,
          trackNumber: position,
          releaseDate: date,
          originalReleaseDate: original);

  test('groups verified editions while retaining compilation performers', () {
    final albums = groupLocalMusicAlbums([
      track('Guest one', key: firstKey, artist: 'One', albumArtist: 'Various'),
      track('Different edition', key: secondKey, albumArtist: 'Various'),
      track('Unverified', albumArtist: 'Various'),
      track('Guest two', key: firstKey, artist: 'Two', albumArtist: 'Various'),
    ]);

    expect(albums.map((album) => album.key), [firstKey, secondKey]);
    expect(albums.first.albumArtist, 'Various');
    expect(albums.first.tracks.map((track) => track.artist), ['One', 'Two']);
    expect(albums.last.tracks.single.title, 'Different edition');
  });

  test('orders discs and tracks with stable ties and unchanged occurrences',
      () {
    final duplicate = track('First', disc: 1, position: 2);
    final ordered = orderLocalMusicAlbumTracks([
      track('Unknown first'),
      track('Disc two', disc: 2, position: 1),
      track('Tenth', disc: 1, position: 10),
      duplicate,
      track('Same position', position: 2),
      duplicate,
      track('Unknown second'),
      track('Numbered disc', disc: 2),
    ]);

    expect(ordered.map((track) => track.title), [
      'First',
      'Same position',
      'First',
      'Tenth',
      'Disc two',
      'Numbered disc',
      'Unknown first',
      'Unknown second',
    ]);
    expect(identical(ordered[0], ordered[2]), isTrue);
  });

  test('keeps matching date precision and suppresses conflicting dates', () {
    final tracks = [
      track('One', key: firstKey, date: '2020', original: '1989-02'),
      track('Two', key: firstKey, date: '2020-06-21', original: '1989'),
      track('Three', key: firstKey, date: '2020-06'),
    ];
    final album = findLocalMusicAlbum(tracks, firstKey)!;
    expect(album.releaseDate, '2020-06-21');
    expect(album.originalReleaseDate, '1989-02');
    expect(
        findLocalMusicAlbum([
          ...tracks,
          track('Conflict', key: firstKey, date: '2020-06-22')
        ], firstKey)!
            .releaseDate,
        isNull);
  });

  test('reads validated nullable order and dates from the device channel', () {
    final source = Uri.parse(tree);
    const row = {'uri': '$tree/document/1', 'title': 'Song'};
    final track = LocalMusicTrack.fromDocument({
      ...row,
      'discNumber': 2,
      'trackNumber': 19,
      'releaseDate': '2024-02-29',
      'originalReleaseDate': '1988',
    }, source)!;
    expect(track.discNumber, 2);
    expect(track.trackNumber, 19);
    expect(track.releaseDate, '2024-02-29');
    expect(track.originalReleaseDate, '1988');

    final invalid = LocalMusicTrack.fromDocument({
      ...row,
      'discNumber': 0,
      'trackNumber': '3',
      'releaseDate': '2023-02-29',
      'originalReleaseDate': '0000',
    }, source)!;
    expect(invalid.discNumber, isNull);
    expect(invalid.trackNumber, isNull);
    expect(invalid.releaseDate, isNull);
    expect(invalid.originalReleaseDate, isNull);
  });
}
