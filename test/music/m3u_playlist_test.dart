import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/m3u_playlist.dart';
import 'package:flutter_test/flutter_test.dart';

const _playlist = (volume: 'primary', path: 'Music/Lists/Set.m3u8');
const _volumeRoots = {
  'primary': '/storage/emulated/0',
  'card': '/storage/card'
};

M3uIndexedTrack _track(int id, String path, {String volume = 'primary'}) => (
      track: LocalMusicTrack(
        uri: 'content://media/external/audio/media/$id',
        title: path.split('/').last,
      ),
      location: (volume: volume, path: path),
    );

void main() {
  test('reads a UTF-8 BOM and ignores metadata while preserving repeats', () {
    final document = M3uDocument.parse('\uFEFF#EXTM3U\r\n'
        '#EXTINF:120,Café\r\n'
        '  # a comment\r\n'
        '../Albums/Café.mp3\r\n'
        '\r\n'
        './Second.mp3\n'
        '../Albums/Café.mp3');

    expect(document.entries,
        ['../Albums/Café.mp3', './Second.mp3', '../Albums/Café.mp3']);
  });

  test('rejects HLS and playlists with no file references', () {
    expect(
        () => M3uDocument.parse('#EXTM3U\n'
            'first.mp3\n'
            '  #EXT-X-TARGETDURATION:10\n'
            'segment.ts'),
        throwsFormatException);
    expect(() => M3uDocument.parse('#EXTM3U\n  # comment\n'),
        throwsFormatException);
  });

  test('resolves relative, Android absolute and escaped file URI references',
      () {
    final first = _track(1, 'Music/Albums/Café 100%.mp3');
    final second = _track(2, 'Music/Lists/Second.mp3');
    final index = M3uTrackIndex([first, second], _volumeRoots);
    final document = M3uDocument.parse('../Albums/Café 100%.mp3\n'
        './Second.mp3\n'
        '/sdcard/Music/Albums/Café 100%.mp3\n'
        'file:///storage/emulated/0/Music/Albums/Caf%C3%A9%20100%25.mp3\n'
        '${r'..\Albums\Café 100%.mp3'}');

    expect(index.match(document, _playlist).map((match) => match.exact),
        [first, second, first, first, first]);
    expect(index.match(document, null).map((match) => match.exact),
        [null, null, first, first, null]);
  });

  test('only resolves files in the supplied granted index', () {
    final visible = _track(1, 'Music/Albums/Visible.mp3');
    final index = M3uTrackIndex([visible], _volumeRoots);
    final document = M3uDocument.parse('../Albums/Hidden.mp3\n'
        '/storage/emulated/0/Outside/Unindexed.mp3\n'
        '../../../Visible.mp3\n'
        'https://example.com/Visible.mp3\n'
        'content://media/external/audio/media/1\n'
        'file://other-host/storage/emulated/0/Music/Albums/Visible.mp3');

    final matches = index.match(document, _playlist);
    expect(matches.map((match) => match.exact), everyElement(isNull));
    expect(matches.map((match) => match.suggestion), everyElement(isNull));
    expect(
        matches.skip(2).map((match) => match.canRelink), everyElement(isFalse));
  });

  test('suggests a unique moved file and leaves ambiguous paths unresolved',
      () {
    final moved = _track(1, 'Music/New/Moved.mp3');
    final copyA = _track(2, 'Music/Albums/Copy.mp3');
    final copyB = _track(3, 'Music/Other/Copy.mp3');
    final collisionA = _track(4, 'Music/Lists/Collision.mp3');
    final collisionB = _track(5, 'Music/Lists/Collision.mp3');
    final index = M3uTrackIndex(
        [moved, copyA, copyB, collisionA, collisionB], _volumeRoots);
    final document = M3uDocument.parse('../Old/Moved.mp3\n'
        '../Old/Copy.mp3\n'
        './Collision.mp3\n'
        '../Albums/Copy.mp3');

    final matches = index.match(document, _playlist);
    expect(matches.map((match) => match.exact), [null, null, null, copyA]);
    expect(matches.map((match) => match.suggestion), [moved, null, null, null]);
  });

  test('exports relative paths and falls back to known absolute roots', () {
    final first = _track(1, 'Music/Albums/Café.mp3');
    final second = _track(2, 'Music/Lists/#Opener.mp3');
    final third = _track(3, 'Backup/Encore.mp3', volume: 'card');
    final unknown = _track(4, 'Other.mp3', volume: 'opaque');
    final tracks = [first, second, third, first];
    final index = M3uTrackIndex([...tracks, unknown], _volumeRoots);
    final lines = [
      for (final track in tracks) index.exportPath(track.location, _playlist)!,
    ];

    expect(lines, [
      '../Albums/Café.mp3',
      './#Opener.mp3',
      '/storage/card/Backup/Encore.mp3',
      '../Albums/Café.mp3',
    ]);
    expect(index.exportPath(first.location, null),
        '/storage/emulated/0/Music/Albums/Café.mp3');
    expect(index.exportPath(unknown.location, _playlist), isNull);
    final document = M3uDocument.parse('#EXTM3U\n${lines.join('\n')}\n');
    expect(
        index.match(document, _playlist).map((match) => match.exact), tracks);
  });

  test(
      'exports relative and portable paths that reimport after moving the tree',
      () {
    final song = _track(1, 'Music/Albums/Café 100%.mp3');
    final opener = _track(2, 'Music/Lists/#Opener.mp3');
    final tracks = [song, opener, song];
    final index = M3uTrackIndex([song, opener], _volumeRoots);
    final movedSong = _track(1, 'Archive/${song.location.path}');
    final movedOpener = _track(2, 'Archive/${opener.location.path}');
    final movedPlaylist =
        (volume: 'primary', path: 'Archive/${_playlist.path}');
    final movedIndex = M3uTrackIndex([movedSong, movedOpener], _volumeRoots);

    for (final (style, expected) in [
      (
        M3uExportPathStyle.relative,
        ['../Albums/Café 100%.mp3', './#Opener.mp3']
      ),
      (
        M3uExportPathStyle.windows,
        [r'..\Albums\Café 100%.mp3', r'.\#Opener.mp3']
      ),
    ]) {
      final paths = [
        for (final row in tracks)
          index.exportPath(row.location, _playlist, style: style)!,
      ];
      expect(paths, [...expected, expected.first]);
      final document = M3uDocument.parse('#EXTM3U\n${paths.join('\n')}\n');
      expect(
        movedIndex.match(document, movedPlaylist).map((match) => match.exact),
        [movedSong, movedOpener, movedSong],
      );
    }
  });

  test('explicit formats use the available destination and volume information',
      () {
    final song = _track(1, 'Music/Albums/First.mp3');
    final card = _track(2, 'Music/Albums/Second.mp3', volume: 'card');
    final unknown = _track(3, 'Third.mp3', volume: 'opaque');
    final index = M3uTrackIndex([song, card, unknown], _volumeRoots);

    const absolute = M3uExportPathStyle.absolute;
    expect(index.exportPath(song.location, _playlist, style: absolute),
        '/storage/emulated/0/Music/Albums/First.mp3');
    expect(index.exportPath(song.location, null, style: absolute),
        '/storage/emulated/0/Music/Albums/First.mp3');
    expect(index.exportPath(card.location, _playlist, style: absolute),
        '/storage/card/Music/Albums/Second.mp3');
    expect(
        index.exportPath(unknown.location, _playlist, style: absolute), isNull);

    for (final style in [
      M3uExportPathStyle.relative,
      M3uExportPathStyle.windows
    ]) {
      expect(index.exportPath(card.location, _playlist, style: style), isNull);
      expect(index.exportPath(song.location, null, style: style), isNull);
    }
  });

  test('portable export skips components Windows cannot preserve', () {
    const invalidPaths = [
      'Music/Albums/What?.mp3',
      'Music/Lists/Track: Intro.mp3',
      'Music/Lists/Song*.mp3',
      'Music/Lists/AuX.flac',
      'Music/Com¹/Track.mp3',
      'Music/lPt9.album/Track.mp3',
      'Music/Album./Track.mp3',
      'Music/Album /Track.mp3',
      'Music/Lists/ Intro.mp3',
    ];
    final index = M3uTrackIndex([], _volumeRoots);
    for (final path in invalidPaths) {
      final location = (volume: 'primary', path: path);
      expect(
          index.exportPath(location, _playlist,
              style: M3uExportPathStyle.windows),
          isNull,
          reason: path);
      expect(
          index.exportPath(location, _playlist,
              style: M3uExportPathStyle.relative),
          isNotNull,
          reason: path);
    }
  });

  test('skips exported lines that exceed the playlist parser limit', () {
    final track = _track(1, List.filled(17, 'a' * 240).join('/'));
    final index = M3uTrackIndex([track], _volumeRoots);
    const rootPlaylist = (volume: 'primary', path: 'Set.m3u8');

    expect(index.exportPath(track.location, rootPlaylist), track.location.path);
    expect(index.exportPath(track.location, _playlist), isNull);
    expect(
        index.exportPath(track.location, rootPlaylist,
            style: M3uExportPathStyle.absolute),
        isNull);
  });
}
