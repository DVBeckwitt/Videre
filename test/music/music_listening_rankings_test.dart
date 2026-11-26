import 'package:clipious/music/models/local_date_interval.dart';
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

Iterable<({String? title, String? subtitle, int plays})> _display(
        List<MusicListeningRank> ranks) =>
    ranks.map((rank) => (
          title: rank.title,
          subtitle: rank.subtitle,
          plays: rank.plays,
        ));

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
      expect(_display(rankings.rankedBy(MusicListeningRankBy.song)),
          [(title: 'played', subtitle: null, plays: count)]);
    }
  });

  for (final (period, days) in [
    (MusicListeningPeriod.last90Days, 90),
    (MusicListeningPeriod.last180Days, 180),
  ]) {
    test('$days-day cutoff applies to all ranking categories', () {
      final start = _now.subtract(Duration(days: days));
      const tick = Duration(microseconds: 1);
      const metadata =
          MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
      const playlist = PlaylistReference(
          kind: PlaylistSourceKind.local,
          playlistId: 'local:charts',
          profileId: 'profile',
          displayTitle: 'Playlist');

      for (final (id, at, legacy, included) in [
        ('before cutoff', start.subtract(tick), false, false),
        ('at cutoff', start, false, true),
        ('after cutoff', start.add(tick), false, true),
        ('at now', _now, false, true),
        ('in future', _now.add(tick), false, false),
        ('legacy entry', start, true, false),
      ]) {
        final rankings = MusicListeningRankings.fromEvents([
          _play(
            id: id,
            song: 'song',
            at: at,
            legacy: legacy,
            metadata: metadata,
            playlist: playlist,
          ),
        ], period, now: _now);

        expect(rankings.plays, included ? 1 : 0, reason: id);
        for (final (group, title, subtitle) in [
          (MusicListeningRankBy.song, 'Song', 'Artist'),
          (MusicListeningRankBy.artist, 'Artist', null),
          (MusicListeningRankBy.album, 'Album', 'Artist'),
          (MusicListeningRankBy.playlist, 'Playlist', null),
        ]) {
          expect(
              rankings.rankedBy(group),
              [
                if (included) (title: title, subtitle: subtitle, plays: 1),
              ],
              reason: '$id in ${group.name}');
        }
      }
    });
  }

  for (final (month, day) in [(3, 8), (11, 1)]) {
    test('custom dates use local midnight across the $month/$day clock change',
        () {
      final start = DateTime(2026, month, day);
      final end = DateTime(2026, month, day + 1);
      final date = DateTime(2026, month, day, 12);
      final interval = LocalDateInterval.inclusive(date, date);
      expect(interval.start, start);
      expect(interval.endExclusive, end);

      const tick = Duration(microseconds: 1);
      const metadata =
          MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album');
      const playlist = PlaylistReference(
        kind: PlaylistSourceKind.local,
        playlistId: 'local:charts',
        profileId: 'profile',
        displayTitle: 'Playlist',
      );
      final rankings = MusicListeningRankings.fromDateInterval([
        for (final (id, at, legacy) in [
          ('before', start.subtract(tick), false),
          ('start', start, false),
          ('end minus one tick', end.subtract(tick), false),
          ('end', end, false),
          ('next day', end.add(const Duration(minutes: 30)), false),
          ('legacy', date, true),
        ])
          _play(
            id: id,
            song: 'song',
            at: at,
            legacy: legacy,
            metadata: metadata,
            playlist: playlist,
          ),
      ], interval, now: end.add(const Duration(days: 1)));

      expect(rankings.plays, 2);
      for (final (group, title, subtitle) in [
        (MusicListeningRankBy.song, 'Song', 'Artist'),
        (MusicListeningRankBy.artist, 'Artist', null),
        (MusicListeningRankBy.album, 'Album', 'Artist'),
        (MusicListeningRankBy.playlist, 'Playlist', null),
      ]) {
        expect(rankings.rankedBy(group), [
          (title: title, subtitle: subtitle, plays: 2),
        ]);
      }
    });
  }

  test('songs and artist credits aggregate by identity across renditions', () {
    const twoArtists =
        MusicMetadata(title: 'Duet', artist: 'Baker, Amber', artistCredits: [
      MusicArtistCredit(name: 'Baker', id: 'UC0000000000000000000001'),
      MusicArtistCredit(name: 'Baker', id: 'UC0000000000000000000001'),
      MusicArtistCredit(name: 'Amber', id: 'UC0000000000000000000003'),
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
          authorId: 'UC0000000000000000000002'),
      _play(
          id: 'device',
          song: 'device:file',
          at: _now,
          source: MusicListeningSource.device,
          metadata: const MusicMetadata(title: 'Duet', artist: 'Cora')),
    ], MusicListeningPeriod.last7Days, now: _now);

    expect(_display(rankings.rankedBy(MusicListeningRankBy.song)), [
      (title: 'Duet', subtitle: 'Baker, Amber', plays: 2),
      (title: 'B', subtitle: 'Baker', plays: 1),
      (title: 'Duet', subtitle: 'Cora', plays: 1),
    ]);
    expect(_display(rankings.rankedBy(MusicListeningRankBy.artist)), [
      (title: 'Amber', subtitle: null, plays: 2),
      (title: 'Baker', subtitle: null, plays: 2),
      (title: 'Baker', subtitle: null, plays: 1),
      (title: 'Cora', subtitle: null, plays: 1),
    ]);
    final recordings = rankings
        .rankedBy(MusicListeningRankBy.song)
        .map((rank) => (rank.target as ListeningRecording).event);
    expect(recordings.map((event) => (event.trackId, event.id)),
        [('A', 'stream'), ('B', 'other'), ('device:file', 'device')]);
    final artists = rankings.rankedBy(MusicListeningRankBy.artist);
    expect(
        artists
            .take(3)
            .map((rank) => (rank.target as ListeningArtist).channelId),
        [
          'UC0000000000000000000003',
          'UC0000000000000000000001',
          'UC0000000000000000000002'
        ]);
    expect(artists.last.target, isNull);
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

    expect(_display(rankings.rankedBy(MusicListeningRankBy.album)), [
      (title: 'Latest title', subtitle: 'Bob', plays: 2),
      (title: 'Greatest Hits', subtitle: 'Alice', plays: 1),
      (title: 'Greatest Hits', subtitle: 'Bob', plays: 1),
    ]);
    final albums = rankings.rankedBy(MusicListeningRankBy.album);
    expect(
        (albums.first.target as ListeningAlbum).playlistId, release.playlistId);
    expect(albums.skip(1).map((rank) => rank.target), everyElement(isNull));
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
    expect(_display(rankings.rankedBy(MusicListeningRankBy.playlist)), [
      (title: 'Road trip', subtitle: null, plays: 3),
      (title: 'Road trip', subtitle: null, plays: 1),
    ]);
    final sources = rankings
        .rankedBy(MusicListeningRankBy.playlist)
        .map((rank) => (rank.target as ListeningPlaylist).reference);
    expect(
        sources, [playlist('one', 'Road trip'), playlist('two', 'Road trip')]);
  });
}
