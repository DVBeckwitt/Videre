import 'dart:math';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/music_queue_shuffle.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

const _release = MusicMetadata(
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    albumPlaylistId: 'OLAK5uy_verified');
const _unverifiedRelease = MusicMetadata(
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    albumPlaylistId: 'arbitrary-playlist');

List<String> _order(
  MusicQueueShuffle mode,
  List<IdedVideo> entries, {
  IdedVideo? previous,
  IdedVideo? following,
  List<LocalMusicTrack> deviceTracks = const [],
  int seed = 1,
}) {
  final tracks = {for (final track in deviceTracks) track.playbackId: track};
  return mode.shuffleUpcoming(
    entries: entries,
    previous: previous,
    following: following,
    deviceTrackForId: (id) => tracks[id],
    random: Random(seed),
  );
}

LocalMusicTrack _device(
  int row, {
  String? albumKey,
  int? disc,
  int? track,
  List<LocalMusicFolderLocation> folders = const [],
}) =>
    LocalMusicTrack(
      uri: 'content://media/external/audio/media/$row',
      title: 'Device song $row',
      album: 'Album',
      albumKey: albumKey,
      discNumber: disc,
      trackNumber: track,
      folderLocations: folders,
    );

DownloadedVideo _deviceEntry(LocalMusicTrack track, {int? copy}) =>
    localMusicPlaybackEntry(track, 'default',
        occurrenceId: copy == null ? null : '${track.playbackId}#$copy');

DownloadedVideo _download(String id, {String? occurrence}) => DownloadedVideo(
      videoId: id,
      queueEntryId: occurrence,
      title: id,
      lengthSeconds: 0,
      quality: '',
      audioOnly: true,
      musicMetadata: _release,
    );

void main() {
  test('verified catalog albums keep source order across saved and online rows',
      () {
    const first = Video(videoId: 'first', musicMetadata: _release);
    final second = _download('second');
    const unknownA = Video(videoId: 'a', musicMetadata: _unverifiedRelease);
    const unknownB = Video(videoId: 'b', musicMetadata: _unverifiedRelease);
    final entries = [first, unknownA, second, unknownB];
    const previous = Video(videoId: 'previous', musicMetadata: _release);
    var unverifiedSeparated = false;
    for (var seed = 0; seed < 20; seed++) {
      final order = _order(MusicQueueShuffle.albums, entries,
          previous: previous, seed: seed);
      expect(order, unorderedEquals(entries.map(playbackQueueId)));
      expect(order.first, isNot('first'));
      expect(order.indexOf('second'), order.indexOf('first') + 1);
      unverifiedSeparated |=
          (order.indexOf('a') - order.indexOf('b')).abs() > 1;
    }
    expect(unverifiedSeparated, isTrue);
  });

  test('device album uses disc positions and keeps each duplicate occurrence',
      () {
    final first = _device(1, albumKey: 'album-a', track: 1);
    final second = _device(2, albumKey: 'album-a', disc: 1, track: 2);
    final nextDisc = _device(3, albumKey: 'album-a', disc: 2, track: 1);
    final unknownPosition = _device(4, albumKey: 'album-a');
    final sameTitle = _device(5, albumKey: 'album-b', track: 1);
    final tracks = [first, second, nextDisc, unknownPosition, sameTitle];
    final duplicate = _deviceEntry(first, copy: 1);
    final order = _order(
      MusicQueueShuffle.albums,
      [
        _deviceEntry(unknownPosition),
        _deviceEntry(nextDisc),
        _deviceEntry(sameTitle),
        duplicate,
        _deviceEntry(second),
        _deviceEntry(first),
      ],
      previous: _deviceEntry(first, copy: 2),
      deviceTracks: tracks,
    );
    expect(order, [
      sameTitle.playbackId,
      duplicate.videoId,
      first.playbackId,
      second.playbackId,
      nextDisc.playbackId,
      unknownPosition.playbackId,
    ]);
  });

  test('folders use the exact containing folder and retain source order', () {
    const root = LocalMusicFolderLocation('root', 'Music');
    const firstFolder = LocalMusicFolderLocation('first', 'Music / Album');
    const secondFolder = LocalMusicFolderLocation('second', 'Music / Album');
    final a2 = _device(1, folders: [root, firstFolder], track: 2);
    final a1 = _device(2, folders: [root, firstFolder], track: 1);
    final b2 = _device(3, folders: [root, secondFolder], track: 2);
    final b1 = _device(4, folders: [root, secondFolder], track: 1);
    final tracks = [a2, b2, a1, b1];
    final order = _order(
      MusicQueueShuffle.folders,
      tracks.map(_deviceEntry).toList(),
      previous: _deviceEntry(a1, copy: 1),
      deviceTracks: tracks,
    );
    expect(order, [
      for (final track in [b2, b1, a2, a1]) track.playbackId
    ]);
  });

  test('fewer repeats spaces copies across different playback origins', () {
    final local = _device(1);
    final localA = _deviceEntry(local);
    final localB = _deviceEntry(local, copy: 1);
    const online = Video(videoId: 'same', queueEntryId: 'same#2');
    final download = _download('same', occurrence: 'same#1');
    final entries = [localA, localB, online, download];
    final order = _order(MusicQueueShuffle.fewerRepeats, entries,
        previous: _deviceEntry(local, copy: 2));
    expect(order,
        [playbackQueueId(online), localA.videoId, 'same#1', localB.videoId]);
    expect(order, unorderedEquals(entries.map(playbackQueueId)));
  });

  test('fewer repeats retains all occurrences when repeats are unavoidable',
      () {
    final repeats = [
      const Video(videoId: 'same'),
      for (var i = 1; i <= 4; i++)
        Video(videoId: 'same', queueEntryId: 'same#$i'),
    ];
    const other = Video(videoId: 'other');
    final order = _order(MusicQueueShuffle.fewerRepeats, [...repeats, other],
        previous: const Video(videoId: 'same', queueEntryId: 'same#5'));
    expect(order, ['other', ...repeats.map(playbackQueueId)]);
  });

  test('fewer repeats leaves a separator before a fixed upcoming copy', () {
    const copy = Video(videoId: 'same', queueEntryId: 'same#1');
    const anchor = Video(videoId: 'same', queueEntryId: 'same#2');
    const current = Video(videoId: 'same');
    const other = Video(videoId: 'other');
    const third = Video(videoId: 'third');
    for (var seed = 0; seed < 10; seed++) {
      final trailing = _order(MusicQueueShuffle.fewerRepeats, [other, copy],
          following: anchor, seed: seed);
      expect(trailing, ['same#1', 'other']);
      final both = _order(MusicQueueShuffle.fewerRepeats, [other, copy, third],
          previous: current, following: anchor, seed: seed);
      expect(both, unorderedEquals(['other', 'same#1', 'third']));
      expect(both[1], 'same#1');
    }
  });
}
