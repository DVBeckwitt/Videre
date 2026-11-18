import 'package:clipious/music/services/music_cover_match.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

const _albumTrack = MusicMetadata(
    title: 'The Band - First Light (Live) (Official Video)',
    artist: 'The Band - Topic',
    album: 'Night Sky');
const _noAlbum = MusicMetadata(title: 'First Light (Live)', artist: 'The Band');
const _recording = '11111111-1111-4111-8111-111111111111';
const _group = '22222222-2222-4222-8222-222222222222';
const _alternative = '33333333-3333-4333-8333-333333333333';

Map<String, Object?> release(
        {String group = _group,
        String title = 'Night Sky',
        String status = 'Official',
        List<String> secondary = const []}) =>
    {
      'title': title,
      'status': status,
      'release-group': {
        'id': group,
        'primary-type': 'Album',
        'secondary-types': secondary,
      },
    };

Map<String, Object?> recording({Map<String, Object?> changes = const {}}) => {
      'id': _recording,
      'title': 'First Light (Live)',
      'artist-credit': [
        {
          'artist': {'name': 'The Band'}
        }
      ],
      'length': 180000,
      'releases': [release()],
      ...changes,
    };

Map<String, Object?> page(List<Map<String, Object?>> recordings) => {
      'recordings': recordings,
      'count': recordings.length,
      'offset': 0,
    };

void main() {
  test('builds a literal recording query and preserves performance labels', () {
    final uri = musicCoverSearchUri(_albumTrack, 180)!;
    expect(uri.origin, 'https://musicbrainz.org');
    expect(uri.path, '/ws/2/recording');
    expect(uri.queryParameters['query'],
        'recording:"First Light (Live)" AND artist:"The Band" AND release:"Night Sky" AND dur:[178000 TO 182000] AND status:official');
    expect(uri.queryParameters['fmt'], 'json');
    expect(uri.queryParameters['limit'], '5');
    final quoted = musicCoverSearchUri(
        const MusicMetadata(
            title: r'A "B" \ C (Remix)', artist: 'TheBandVEVO', album: 'D'),
        180)!;
    expect(quoted.queryParameters['query'],
        contains(r'recording:"A \"B\" \\ C (Remix)"'));
    final vevo = musicCoverSearchUri(
        const MusicMetadata(
            title: 'The Band – First Light (Official Music Video)',
            artist: 'TheBandVEVO'),
        180)!;
    expect(vevo.queryParameters['query'],
        startsWith('recording:"First Light" AND artist:"The Band"'));
    expect(vevo.queryParameters['query'], isNot(contains('release:')));
  });

  test('official lyric video titles match the song and keep its version', () {
    const track = MusicMetadata(
        title: 'Adele - Love Is A Game (Official Lyric Video)',
        artist: 'Adele');
    final uri = musicCoverSearchUri(track, 404)!;
    expect(uri.queryParameters['query'],
        startsWith('recording:"Love Is A Game" AND artist:"Adele"'));
    final row = recording(changes: {
      'title': 'Love Is a Game',
      'artist-credit': [
        {
          'artist': {'name': 'Adele'}
        }
      ],
      'length': 403500,
      'releases': [release(title: '30')],
    });
    expect(musicCoverReleaseGroupId(track, 404, page([row])), _group);

    const live = MusicMetadata(
        title: 'Adele - Love Is A Game (Live) (Official Lyrics Video)',
        artist: 'Adele');
    expect(musicCoverSearchUri(live, 404)!.queryParameters['query'],
        startsWith('recording:"Love Is A Game (Live)"'));
    expect(musicCoverReleaseGroupId(live, 404, page([row])), isNull);
  });

  test('requires usable title, artist and either album or duration', () {
    expect(musicCoverSearchUri(_noAlbum, null), isNull);
    expect(musicCoverSearchUri(_noAlbum, 0), isNull);
    expect(
        musicCoverSearchUri(
            const MusicMetadata(title: '', artist: 'Artist'), 180),
        isNull);
    expect(
        musicCoverSearchUri(
            const MusicMetadata(title: 'Song', artist: '\nArtist'), 180),
        isNull);
    expect(musicCoverSearchUri(_albumTrack, null)!.queryParameters['query'],
        isNot(contains('dur:')));
    expect(
        musicCoverReleaseGroupId(_noAlbum, null, page([recording()])), isNull);
  });

  test('accepts equivalent official editions with exact recording and album',
      () {
    final releases = [
      release(),
      release(),
      release(group: _alternative, title: 'Box Set')
    ];
    final result = page([
      recording(changes: {'length': 182000, 'releases': releases})
    ]);
    expect(musicCoverReleaseGroupId(_albumTrack, 180, result), _group);
    expect(musicCoverReleaseGroupId(_albumTrack, null, result), _group);
  });

  test('keeps the complete credited artist including join phrases', () {
    const duet = MusicMetadata(
        title: 'First Light (Live)', artist: 'Artist A feat. Artist B');
    final row = recording(changes: {
      'artist-credit': [
        {
          'name': 'Artist A',
          'artist': {'name': 'Legal name'},
          'joinphrase': ' feat. '
        },
        {'name': 'Artist B'}
      ]
    });
    expect(musicCoverReleaseGroupId(duet, 180, page([row])), _group);
    const solo = MusicMetadata(title: 'First Light (Live)', artist: 'Artist A');
    expect(musicCoverReleaseGroupId(solo, 180, page([row])), isNull);
  });

  test('rejects version, label, duration and artist mismatches', () {
    for (final changes in <Map<String, Object?>>[
      {'title': 'First Light'},
      {'disambiguation': '2019 studio version'},
      {'disambiguation': '2019 studio version ' * 18},
      {'length': 182001},
      {'length': null},
      {
        'artist-credit': [
          {'name': 'Cover Band'}
        ]
      },
      {
        'releases': [release(title: 'Night Sky (Deluxe)')]
      },
      {
        'releases': [release(status: 'Bootleg')]
      },
    ]) {
      expect(
          musicCoverReleaseGroupId(
              _albumTrack, 180, page([recording(changes: changes)])),
          isNull);
    }
  });

  test('uses albumless matches only for one plausible original release group',
      () {
    final compilation = release(
        group: _alternative,
        title: 'Greatest Hits',
        secondary: ['Compilation']);
    expect(
        musicCoverReleaseGroupId(
            _noAlbum,
            180,
            page([
              recording(changes: {
                'releases': [compilation, release()]
              })
            ])),
        _group);
    for (final releases in [
      [compilation],
      [release(), release(group: _alternative)],
      [release(group: '../other')],
    ]) {
      expect(
          musicCoverReleaseGroupId(
              _noAlbum,
              180,
              page([
                recording(changes: {'releases': releases})
              ])),
          isNull);
    }
  });

  test(
      'rejects partial pages, ambiguous recordings, and ambiguous named albums',
      () {
    final first = recording();
    final second = recording(changes: {'id': _alternative});
    final conflicting = recording(changes: {
      'releases': [release(), release(group: _alternative)]
    });
    for (final result in [
      {
        ...page([first]),
        'count': 9
      },
      {
        ...page([first]),
        'offset': 5
      },
      page([first, second]),
      page([
        recording(changes: {'release-count': 21})
      ]),
      page([
        recording(changes: {'release-offset': 20})
      ]),
      page([conflicting]),
    ]) {
      expect(musicCoverReleaseGroupId(_albumTrack, 180, result), isNull);
    }
  });
}
