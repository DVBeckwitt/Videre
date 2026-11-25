import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/music/models/music_download_order.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadedVideo song(
        String id, String title, String artist, String? album, int seconds,
        {bool complete = true}) =>
    DownloadedVideo(
      videoId: id,
      title: id,
      audioOnly: true,
      downloadComplete: complete,
      musicMetadata: MusicMetadata(title: title, artist: artist, album: album),
      lengthSeconds: seconds,
      quality: 'audio',
    );

void main() {
  final rows = [
    song('z', 'Écho', 'Ártist', 'Édition', 90, complete: false),
    song('x', ' ', '', null, -1),
    song('c', 'Beta', 'artist', 'edition', 90),
    song('a', 'echo', 'ARTIST', 'EDITION', 90),
    song('m', ' Alpine ', 'Bard', 'Album', 180),
  ];
  List<String> ids(Iterable<DownloadedVideo> videos) =>
      [for (final video in videos) video.videoId];

  test('all stored field and direction pairs round-trip with value equality',
      () {
    for (final field in MusicDownloadSortField.values) {
      for (final descending in [false, true]) {
        final order = MusicDownloadOrder(field: field, descending: descending);
        final encoded =
            '${field.name}:${descending ? 'descending' : 'ascending'}';
        expect(order.encode(), encoded);
        final restored = MusicDownloadOrder.fromStorage(encoded);
        expect(restored, order);
        expect(restored.hashCode, order.hashCode);
      }
    }
    expect(const MusicDownloadOrder(),
        isNot(const MusicDownloadOrder(descending: true)));
    for (final value in [
      null,
      '',
      'title',
      'title:',
      'Title:ascending',
      'title:up',
      ':descending',
      'artist:descending:extra',
      'title:ascending '
    ]) {
      expect(MusicDownloadOrder.fromStorage(value), isNull, reason: value);
    }
  });

  test('default order copies the source and optionally reverses every row', () {
    final expected = ids(rows);
    final ascending = const MusicDownloadOrder().sort(rows);
    final descending = const MusicDownloadOrder(descending: true).sort(rows);
    expect(ids(ascending), expected);
    expect(ids(descending), expected.reversed.toList());
    ascending[0] = rows[1];
    expect(ids(rows), expected);
  });

  test('named sorts keep missing values last and break ties by title then ID',
      () {
    final orders = {
      MusicDownloadSortField.title: (
        ['m', 'c', 'a', 'z', 'x'],
        ['a', 'z', 'c', 'm', 'x']
      ),
      MusicDownloadSortField.artist: (
        ['c', 'a', 'z', 'm', 'x'],
        ['m', 'c', 'a', 'z', 'x']
      ),
      MusicDownloadSortField.album: (
        ['m', 'c', 'a', 'z', 'x'],
        ['c', 'a', 'z', 'm', 'x']
      ),
      MusicDownloadSortField.duration: (
        ['c', 'a', 'z', 'm', 'x'],
        ['m', 'c', 'a', 'z', 'x']
      ),
    };
    for (final entry in orders.entries) {
      expect(
          ids(MusicDownloadOrder(field: entry.key).sort(rows)), entry.value.$1);
      expect(
          ids(MusicDownloadOrder(field: entry.key, descending: true)
              .sort(rows)),
          entry.value.$2);
    }
    expect(ids(rows), ['z', 'x', 'c', 'a', 'm']);
  });

  test('zero and negative lengths use the same unknown-duration group', () {
    final zero = song('zero', 'Alpha', 'Artist', null, 0);
    final negative = song('negative', 'Zulu', 'Artist', null, -20);
    for (final descending in [false, true]) {
      final order = MusicDownloadOrder(
          field: MusicDownloadSortField.duration, descending: descending);
      expect(ids(order.sort([negative, zero, rows.first])),
          ['z', 'zero', 'negative']);
    }
  });
}
