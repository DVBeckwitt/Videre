import 'package:clipious/music/models/music_playlist_selection.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const first = Video(
      videoId: 'shared',
      indexId: 'first',
      musicMetadata: MusicMetadata(title: 'First', artist: 'Singer'));
  const second = Video(
      videoId: 'shared',
      indexId: 'second',
      musicMetadata: MusicMetadata(title: 'Second', artist: 'Singer'));
  const other = Video(
      videoId: 'other',
      musicMetadata: MusicMetadata(title: 'Other', artist: 'Singer'));
  const hidden = Video(videoId: 'shared', title: 'Untagged');
  List<String> ids(List<Video> source) => assignPlaylistEntryIds(source)
      .map((video) => video.queueEntryId!)
      .toList();

  test('distinct playlist occurrences survive reordering and prune removals',
      () {
    final source = [first, other, second];
    final keys = ids(source);
    final selection = MusicPlaylistSelection()
      ..reconcile(source)
      ..toggle(keys.last)
      ..toggle(keys.first)
      ..toggle(keys[1]);
    expect(selection.selected.toList(), [keys.last, keys.first, keys[1]]);
    selection.reconcile([other, hidden, second]);
    expect(selection.selected.toList(), [keys.last, keys[1]]);
    selection.reconcile([second.copyWith(musicMetadata: null), other]);
    expect(selection.selected.toList(), [keys[1]]);
  });

  for (final collision in [false, true]) {
    test(
        'a renumbered copy never inherits a check (explicit collision: $collision)',
        () {
      final sourceId = collision ? 'duplicate' : null;
      final source = [
        hidden.copyWith(indexId: sourceId),
        first.copyWith(indexId: sourceId),
        second.copyWith(indexId: sourceId),
        other,
      ];
      final keys = ids(source);
      final selection = MusicPlaylistSelection()
        ..reconcile(source)
        ..toggle(keys[1])
        ..toggle(keys.last);
      // Removing the hidden first copy hands the selected key to the next
      // song. A key intersection alone would keep the wrong row checked.
      final changed = source.skip(1).toList();
      expect(ids(changed)[1], keys[1]);
      selection.reconcile(changed);
      expect(selection.selected.toList(), [keys.last]);
    });
  }

  test('ambiguous selections survive equivalent source reloads, not a swap',
      () {
    final a = first.copyWith(indexId: null), b = second.copyWith(indexId: null);
    final source = [a, b];
    final id = ids(source).first;
    final selection = MusicPlaylistSelection()
      ..reconcile(source)
      ..toggle(id);
    final reloaded = [
      for (final song in source)
        song.copyWith(
            musicMetadata:
                MusicMetadata.fromJson(song.musicMetadata!.toJson())),
    ];
    selection.reconcile(reloaded);
    expect(selection.selected, {id});
    selection.reconcile(reloaded.reversed.toList());
    expect(selection.selected, isEmpty);
  });

  test(
      'moving indistinguishable copies past another row invalidates their keys',
      () {
    final copy = first.copyWith(indexId: null);
    final source = [copy, other, copy];
    final keys = ids(source);
    final selection = MusicPlaylistSelection()
      ..reconcile(source)
      ..toggle(keys.first)
      ..toggle(keys[1]);
    selection.reconcile([other, copy, copy]);
    expect(selection.selected, {keys[1]});
  });

  test('select all applies only to matching Music rows in their supplied order',
      () {
    final source = [first, other, hidden, second];
    final keys = ids(source);
    final selection = MusicPlaylistSelection()
      ..reconcile(source)
      ..toggle(keys[2])
      ..toggle('stale');
    expect(selection.selected, isEmpty);
    selection
      ..toggle(keys[1])
      ..toggleAll([keys.last, keys[2], keys.first, keys.last, 'stale']);
    expect(selection.selected.toList(), [keys.last, keys.first]);
    selection.toggleAll([keys.first, keys.last]);
    expect(selection.selected, isEmpty);
    selection
      ..toggle(keys[1])
      ..clear();
    expect(selection.selected, isEmpty);
  });
}
