import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_listening_event.dart';
import 'package:clipious/music/models/music_listening_rankings.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 11, 25, 14);

MusicListeningEvent _play({
  required String id,
  required String song,
  required DateTime at,
  MusicMetadata? metadata,
  String? author,
  String? authorId,
  bool legacy = false,
  MusicListeningSource source = MusicListeningSource.catalog,
  PlaylistReference? playlist,
}) {
  return MusicListeningEvent(
    id: id,
    entry: HistoryVideoCache(song, song, author, '',
        authorId: authorId, musicMetadata: metadata)
      ..created = at,
    source: source,
    isLegacy: legacy,
    playlist: playlist,
  );
}

void main() {
  test('periods include their lower boundary and only confirmed past starts',
      () {
    final events = [
      _play(id: 'now', song: 'played', at: _now),
      for (final days in [7, 30, 365, 366])
        _play(
            id: 'day-$days',
            song: 'played',
            at: _now.subtract(Duration(days: days))),
      _play(id: 'legacy', song: 'old history', at: _now, legacy: true),
      _play(
          id: 'future',
          song: 'future play',
          at: _now.add(const Duration(milliseconds: 1))),
    ];

    for (final (period, count) in [
      (MusicListeningPeriod.last7Days, 2),
      (MusicListeningPeriod.last30Days, 3),
      (MusicListeningPeriod.last365Days, 4),
      (MusicListeningPeriod.allTime, 5),
    ]) {
      final rankings =
          MusicListeningRankings.fromEvents(events, period, now: _now);
      expect(rankings.plays, count);
      expect(rankings.rankedBy(MusicListeningRankBy.song),
          [(title: 'played', subtitle: null, plays: count)]);
    }
  });

  test('songs and artist credits aggregate by identity across renditions', () {
    const twoArtists =
        MusicMetadata(title: 'Duet', artist: 'Baker, Amber', artistCredits: [
      MusicArtistCredit(name: 'Baker', id: 'baker-1'),
      MusicArtistCredit(name: 'Baker', id: 'baker-1'),
      MusicArtistCredit(name: 'Amber', id: 'amber'),
    ]);
    final rankings = MusicListeningRankings.fromEvents([
      _play(id: 'stream', song: 'A', at: _now, metadata: twoArtists),
      _play(
          id: 'saved',
          song: 'A',
          at: _now.subtract(const Duration(days: 1)),
          metadata: twoArtists,
          source: MusicListeningSource.download),
      _play(
          id: 'other',
          song: 'B',
          at: _now,
          author: 'Baker',
          authorId: 'baker-2'),
      _play(
          id: 'device',
          song: 'device:file',
          at: _now,
          source: MusicListeningSource.device,
          metadata: const MusicMetadata(title: 'Duet', artist: 'Cora')),
    ], MusicListeningPeriod.last7Days, now: _now);

    expect(rankings.rankedBy(MusicListeningRankBy.song), [
      (title: 'Duet', subtitle: 'Baker, Amber', plays: 2),
      (title: 'B', subtitle: 'Baker', plays: 1),
      (title: 'Duet', subtitle: 'Cora', plays: 1),
    ]);
    expect(rankings.rankedBy(MusicListeningRankBy.artist), [
      (title: 'Amber', subtitle: null, plays: 2),
      (title: 'Baker', subtitle: null, plays: 2),
      (title: 'Baker', subtitle: null, plays: 1),
      (title: 'Cora', subtitle: null, plays: 1),
    ]);
  });

  test('release IDs survive label changes and album names stay scoped', () {
    const release = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'OLAK5uy_Release',
        profileId: 'profile',
        displayTitle: 'Album');
    final rankings = MusicListeningRankings.fromEvents([
      _play(
          id: 'older',
          song: 'A',
          at: _now.subtract(const Duration(days: 1)),
          metadata: const MusicMetadata(
              title: 'One',
              artist: 'Alice',
              album: 'Earlier title',
              albumPlaylistId: 'OLAK5uy_Release')),
      _play(
          id: 'newer',
          song: 'B',
          at: _now,
          playlist: release,
          metadata: const MusicMetadata(
              title: 'Two',
              artist: 'Bob',
              album: 'Latest title',
              albumPlaylistId: 'OLAK5uy_Release')),
      for (final artist in ['Alice', 'Bob'])
        _play(
            id: artist,
            song: artist,
            at: _now,
            metadata: MusicMetadata(
                title: 'Three', artist: artist, album: 'Greatest Hits')),
    ], MusicListeningPeriod.allTime, now: _now);

    expect(rankings.rankedBy(MusicListeningRankBy.album), [
      (title: 'Latest title', subtitle: 'Bob', plays: 2),
      (title: 'Greatest Hits', subtitle: 'Alice', plays: 1),
      (title: 'Greatest Hits', subtitle: 'Bob', plays: 1),
    ]);
    expect(rankings.rankedBy(MusicListeningRankBy.playlist), isEmpty);
  });

  test('playlists count only attributed plays and stay distinct by account',
      () {
    PlaylistReference playlist(String account, String? title) =>
        PlaylistReference(
          kind: PlaylistSourceKind.account,
          playlistId: 'IVPfixture',
          profileId: 'profile',
          accountId: account,
          origin: 'https://instance.test',
          displayTitle: title,
        );

    final rankings = MusicListeningRankings.fromEvents([
      _play(id: 'standalone', song: 'A', at: _now),
      _play(
          id: 'current',
          song: 'A',
          at: _now,
          playlist: playlist('one', 'Road trip')),
      _play(
          id: 'older',
          song: 'A',
          at: _now.subtract(const Duration(days: 2)),
          playlist: playlist('one', 'Old name')),
      _play(
          id: 'unlabeled',
          song: 'B',
          at: _now.add(const Duration(minutes: 1)),
          playlist: playlist('one', null)),
      _play(
          id: 'second owner',
          song: 'A',
          at: _now,
          playlist: playlist('two', 'Road trip')),
    ], MusicListeningPeriod.allTime, now: _now.add(const Duration(minutes: 2)));

    expect(rankings.plays, 5);
    expect(rankings.rankedBy(MusicListeningRankBy.playlist), [
      (title: 'Road trip', subtitle: null, plays: 3),
      (title: 'Road trip', subtitle: null, plays: 1),
    ]);
  });
}
