import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/music/models/local_music_browse.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

LocalMusicTrack _track(
  String id,
  String title, {
  String? artist,
  String? album,
  String? titleSort,
  String? artistSort,
  String? albumSort,
  int durationMs = 0,
  int? sizeBytes,
}) =>
    LocalMusicTrack(
      uri: 'content://media/external/audio/media/$id',
      title: title,
      artist: artist,
      album: album,
      titleSort: titleSort,
      artistSort: artistSort,
      albumSort: albumSort,
      durationMs: durationMs,
      sizeBytes: sizeBytes,
      identityKey: id.padLeft(64, '0'),
    );

void main() {
  test('sort names use a usable embedded tag before the article rule', () {
    expect(localMusicSortName(' The Écho 2 '), 'echo 2');
    expect(localMusicSortName('An Overture'), 'overture');
    expect(localMusicSortName('A  Song'), 'song');
    expect(localMusicSortName('Theatre 2'), 'theatre 2');
    expect(localMusicSortName('The'), 'the');
    expect(
      localMusicSortName('The Écho 2', ignoreArticles: false),
      'the echo 2',
    );
    expect(
      localMusicSortName('The Écho 2', sortTag: ' The Zéta 1 '),
      'the zeta 1',
    );
    expect(localMusicSortName('The Écho 2', sortTag: '<UNKNOWN>'), 'echo 2');
    expect(localMusicSortName('The Écho 2', sortTag: '   '), 'echo 2');
    expect(localMusicSortName(' <unknown> '), isNull);
  });

  test('natural comparison handles multiple, padded and large digit runs', () {
    expect(
      compareLocalMusicSortNames('disc 2 track 9', 'disc 2 track 10'),
      lessThan(0),
    );
    expect(compareLocalMusicSortNames('disc 002 track 9', 'disc 2 track 9'), 0);
    expect(
      compareLocalMusicSortNames(
        'track 9999999999999999999999',
        'track 10000000000000000000000',
      ),
      lessThan(0),
    );
    expect(
      compareLocalMusicSortNames('track 2', 'track 10', descending: true),
      greaterThan(0),
    );
  });

  test('track name sorts use tags and break normalized ties by stable ID', () {
    final laterId = _track(
      '2',
      'The Écho 02',
      artist: 'Artist 2',
      album: 'Album 2',
    );
    final earlierId = _track(
      '1',
      'echo 2',
      artist: 'artist 02',
      album: 'album 02',
    );
    final naturalLater = _track(
      '3',
      'Echo 10',
      artist: 'Artist 10',
      album: 'Album 10',
    );
    final preferred = _track(
      '4',
      'Zebra',
      artist: 'Zulu',
      album: 'Zenith',
      titleSort: 'Alpha',
      artistSort: 'Aardvark',
      albumSort: 'Aardvark',
    );
    final missing = _track(
      '5',
      'Unknown tags',
      artist: ' ',
      album: '<unknown>',
    );
    final input = [
      laterId,
      naturalLater,
      preferred,
      missing,
      earlierId,
    ].map(OnDeviceMusicEntry.device).toList();

    for (final field in [
      LocalMusicTrackSortField.title,
      LocalMusicTrackSortField.artist,
      LocalMusicTrackSortField.album,
    ]) {
      List<LocalMusicTrack?> inOrder(bool descending) => LocalMusicTrackSort(
            field,
            descending,
          ).order(input).map((row) => row.deviceTrack).toList();
      expect(inOrder(false), [
        preferred,
        earlierId,
        laterId,
        naturalLater,
        missing,
      ]);
      expect(inOrder(true), [
        if (field == LocalMusicTrackSortField.title) missing,
        naturalLater,
        earlierId,
        laterId,
        preferred,
        if (field != LocalMusicTrackSortField.title) missing,
      ]);
    }
    expect(input.map((row) => row.deviceTrack), [
      laterId,
      naturalLater,
      preferred,
      missing,
      earlierId,
    ]);
  });

  test(
    'duration and size sorts retain missing values last in both directions',
    () {
      final short = OnDeviceMusicEntry.device(
        _track('1', 'Short', durationMs: 500, sizeBytes: 0),
      );
      final downloaded = OnDeviceMusicEntry.download(
        DownloadedVideo(
          videoId: 'downloaded',
          title: 'Downloaded',
          quality: 'audio',
          lengthSeconds: 3,
          downloadComplete: true,
          audioOnly: true,
          musicMetadata:
              const MusicMetadata(title: 'Downloaded', artist: 'Artist'),
        ),
        'proof',
        sizeBytes: 4096,
      );
      final unknown = OnDeviceMusicEntry.device(_track('2', 'Absent'));
      final invalid = OnDeviceMusicEntry.device(
        _track('3', 'Invalid', durationMs: -10, sizeBytes: -5),
      );
      final input = [invalid, downloaded, unknown, short];

      for (final field in [
        LocalMusicTrackSortField.duration,
        LocalMusicTrackSortField.size,
      ]) {
        expect(LocalMusicTrackSort(field, false).order(input), [
          short,
          downloaded,
          unknown,
          invalid,
        ]);
        expect(LocalMusicTrackSort(field, true).order(input), [
          downloaded,
          short,
          unknown,
          invalid,
        ]);
      }
      final totals = LocalMusicTotals.fromEntries(input);
      expect(totals.trackCount, 4);
      expect(totals.durationMs, 3500);
      expect(totals.sizeBytes, 4096);
      expect(totals.durationComplete, isFalse);
      expect(totals.sizeComplete, isFalse);
    },
  );

  test('totals sum positive millisecond durations before rounding', () {
    final short = _track('1', 'Short', durationMs: 650, sizeBytes: 0);
    final next = _track('2', 'Next', durationMs: 550, sizeBytes: 24);
    final missingSize = _track('3', 'Missing size', durationMs: 200);

    final subsecond = LocalMusicTotals.fromTracks([short]);
    expect(subsecond.durationMs, 650);
    expect(subsecond.sizeBytes, 0);
    expect(subsecond.durationComplete, isTrue);
    expect(subsecond.sizeComplete, isTrue);

    final exact = LocalMusicTotals.fromTracks([short, next]);
    expect(exact.trackCount, 2);
    expect(exact.durationMs, 1200);
    expect(exact.sizeBytes, 24);
    expect(exact.durationComplete, isTrue);
    expect(exact.sizeComplete, isTrue);

    final missing = LocalMusicTotals.fromTracks([short, next, missingSize]);
    expect(missing.trackCount, 3);
    expect(missing.durationMs, 1400);
    expect(missing.sizeBytes, 24);
    expect(missing.durationComplete, isTrue);
    expect(missing.sizeComplete, isFalse);

    final partial = LocalMusicTotals.fromTracks([short, next], complete: false);
    expect(partial.durationMs, 1200);
    expect(partial.sizeBytes, 24);
    expect(partial.durationComplete, isFalse);
    expect(partial.sizeComplete, isFalse);

    final unknown = LocalMusicTotals.fromTracks([_track('4', 'Unknown')]);
    expect(unknown.trackCount, 1);
    expect(unknown.durationMs, isNull);
    expect(unknown.sizeBytes, isNull);
    expect(unknown.durationComplete, isFalse);
    expect(unknown.sizeComplete, isFalse);
  });

  test('category order compares measurements and breaks ties consistently', () {
    final short = _track('1', 'Short', durationMs: 550, sizeBytes: 20);
    final longer = _track('2', 'Longer', durationMs: 850, sizeBytes: 30);
    final unknown = _track('3', 'Unknown');
    final groups = [
      (
        key: 'b',
        name: 'The Set 02',
        totals: LocalMusicTotals.fromTracks([short]),
      ),
      (key: 'a', name: 'Set 2', totals: LocalMusicTotals.fromTracks([short])),
      (
        key: 'c',
        name: 'Set 10',
        totals: LocalMusicTotals.fromTracks([short, longer]),
      ),
      (
        key: 'u',
        name: 'Unknown',
        totals: LocalMusicTotals.fromTracks([unknown]),
      ),
    ];

    List<String> ordered(LocalMusicCategorySort choice, bool descending) {
      final sorted = [...groups]..sort(
          (a, b) => choice.compare(
            a.totals,
            b.totals,
            firstName: localMusicSortName(a.name),
            secondName: localMusicSortName(b.name),
            firstKey: a.key,
            secondKey: b.key,
            descending: descending,
          ),
        );
      return sorted.map((group) => group.key).toList();
    }

    for (final choice in LocalMusicCategorySort.values) {
      expect(
        ordered(choice, false),
        choice == LocalMusicCategorySort.trackCount
            ? ['a', 'b', 'u', 'c']
            : ['a', 'b', 'c', 'u'],
      );
      expect(
        ordered(choice, true),
        choice == LocalMusicCategorySort.name
            ? ['u', 'c', 'a', 'b']
            : ['c', 'a', 'b', 'u'],
      );
    }
  });

  group('local track channel metadata', () {
    LocalMusicTrack parse([Map<String, Object?> metadata = const {}]) =>
        LocalMusicTrack.fromDocument({
          'uri': 'content://media/external/audio/media/1',
          'title': 'The Display Title',
          ...metadata,
        }, LocalMusicTrack.systemSource)!;

    test('keeps display name, valid sort tags and measured zero bytes', () {
      final track = parse({
        'titleSort': '  Display Title  ',
        'artistSort': 'Écho',
        'albumSort': 'Album 10',
        'albumArtistSort': 'Artist, The',
        'durationMs': 900,
        'sizeBytes': 0,
      });
      expect(track.title, 'The Display Title');
      expect(track.titleSort, 'Display Title');
      expect(track.artistSort, 'Écho');
      expect(track.albumSort, 'Album 10');
      expect(track.albumArtistSort, 'Artist, The');
      expect(track.durationMs, 900);
      expect(track.sizeBytes, 0);
      expect(parse({'sizeBytes': 4500000000}).sizeBytes, 4500000000);
    });

    test('ignores malformed optional metadata and accepts legacy rows', () {
      final invalid = parse({
        'titleSort': '   ',
        'artistSort': '<UNKNOWN>',
        'albumSort': 'Album\u0000title',
        'albumArtistSort': 'x' * 1025,
        'sizeBytes': -5,
      });
      final wrongTypes = parse({'albumSort': 123, 'sizeBytes': '200'});
      final legacy = parse();

      for (final track in [invalid, wrongTypes, legacy]) {
        expect(track.title, 'The Display Title');
        expect(track.titleSort, isNull);
        expect(track.artistSort, isNull);
        expect(track.albumSort, isNull);
        expect(track.albumArtistSort, isNull);
        expect(track.sizeBytes, isNull);
      }
    });
  });
}
