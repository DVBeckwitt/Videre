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
          String? discSubtitle,
          int? position,
          String? date,
          String? original,
          LocalMusicReleaseKind? releaseKind}) =>
      LocalMusicTrack(
          uri: '$tree/document/$title',
          title: title,
          album: 'Live',
          albumKey: key,
          artist: artist,
          albumArtist: albumArtist,
          discNumber: disc,
          discSubtitle: discSubtitle,
          trackNumber: position,
          releaseDate: date,
          originalReleaseDate: original,
          releaseKind: releaseKind);

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

  test('shows a subtitle only when every track on that disc agrees', () {
    final tracks = [
      track('Rarities two',
          key: firstKey, disc: 2, position: 2, discSubtitle: 'Rarities'),
      track('Rarities one',
          key: firstKey, disc: 2, position: 1, discSubtitle: 'Rarities'),
      track('Main', key: firstKey, position: 1, discSubtitle: 'Main'),
      track('Main without tag', key: firstKey, disc: 1, position: 2),
      track('Live', key: firstKey, disc: 3, discSubtitle: 'Live'),
      track('Studio', key: firstKey, disc: 3, discSubtitle: 'Studio'),
      track('Unnumbered', key: firstKey, discSubtitle: 'Unnumbered'),
    ];
    expect(findLocalMusicAlbum(tracks, firstKey)!.discHeadings, {
      0: (number: 1, subtitle: null),
      2: (number: 2, subtitle: 'Rarities'),
      4: (number: 3, subtitle: null),
    });
    expect(
        findLocalMusicAlbum(tracks.take(2), firstKey)!.discHeadings, isEmpty);
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

  test('uses a consistent embedded kind for each exact release key', () {
    final tracks = [
      track('Tagged', key: firstKey, releaseKind: LocalMusicReleaseKind.ep),
      track('Missing tag', key: firstKey),
      track('Same title', key: secondKey),
    ];
    final albums = groupLocalMusicAlbums(tracks);
    expect(albums.map((album) => album.releaseKind),
        [LocalMusicReleaseKind.ep, null]);
    expect(
        findLocalMusicAlbum([
          ...tracks,
          track('Conflicting tag',
              key: firstKey, releaseKind: LocalMusicReleaseKind.live)
        ], firstKey)!
            .releaseKind,
        isNull);
  });

  test('reads validated release metadata from the device channel', () {
    final source = Uri.parse(tree);
    const row = {'uri': '$tree/document/1', 'title': 'Song'};
    final track = LocalMusicTrack.fromDocument({
      ...row,
      'discNumber': 2,
      'discSubtitle': ' Rarities ',
      'trackNumber': 19,
      'releaseDate': '2024-02-29',
      'originalReleaseDate': '1988',
      'releaseKind': 'dj-mix',
    }, source)!;
    expect(track.discNumber, 2);
    expect(track.discSubtitle, 'Rarities');
    expect(track.trackNumber, 19);
    expect(track.releaseDate, '2024-02-29');
    expect(track.originalReleaseDate, '1988');
    expect(track.releaseKind, LocalMusicReleaseKind.djMix);

    final invalid = LocalMusicTrack.fromDocument({
      ...row,
      'discNumber': 0,
      'discSubtitle': 'Disc\nTwo',
      'trackNumber': '3',
      'releaseDate': '2023-02-29',
      'originalReleaseDate': '0000',
      'releaseKind': 'live sessions',
    }, source)!;
    expect(invalid.discNumber, isNull);
    expect(invalid.discSubtitle, isNull);
    expect(invalid.trackNumber, isNull);
    expect(invalid.releaseDate, isNull);
    expect(invalid.originalReleaseDate, isNull);
    expect(invalid.releaseKind, isNull);
  });
}
