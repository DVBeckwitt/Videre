import '../../content_filter/community_models.dart' show normalizeChannelId;
import '../../playlists/models/playlist_reference.dart';
import '../../videos/models/music_metadata.dart';
import 'local_date_interval.dart';
import 'music_listening_event.dart';

enum MusicListeningPeriod {
  last7Days(Duration(days: 7)),
  last30Days(Duration(days: 30)),
  last90Days(Duration(days: 90)),
  last180Days(Duration(days: 180)),
  last365Days(Duration(days: 365)),
  allTime(null);

  const MusicListeningPeriod(this.duration);

  final Duration? duration;
}

enum MusicListeningRankBy { song, artist, album, playlist }

typedef MusicListeningRank = ({
  String? title,
  String? subtitle,
  int plays,
  MusicListeningTarget? target,
});

sealed class MusicListeningTarget {
  const MusicListeningTarget();
}

class ListeningRecording extends MusicListeningTarget {
  const ListeningRecording(this.event);

  final MusicListeningEvent event;
}

class ListeningArtist extends MusicListeningTarget {
  const ListeningArtist(this.channelId);

  final String channelId;
}

class ListeningAlbum extends MusicListeningTarget {
  const ListeningAlbum(this.playlistId);

  final String playlistId;
}

class ListeningPlaylist extends MusicListeningTarget {
  const ListeningPlaylist(this.reference);

  final PlaylistReference reference;
}

class MusicListeningRankings {
  MusicListeningRankings._(this.plays, this._ranks);

  final int plays;
  final Map<MusicListeningRankBy, List<MusicListeningRank>> _ranks;

  List<MusicListeningRank> rankedBy(MusicListeningRankBy dimension) =>
      _ranks[dimension]!;

  factory MusicListeningRankings.fromEvents(
      Iterable<MusicListeningEvent> events, MusicListeningPeriod period,
      {required DateTime now}) {
    final start =
        period.duration == null ? null : now.subtract(period.duration!);
    return MusicListeningRankings._tally(
        events, now, (at) => start == null || !at.isBefore(start));
  }

  factory MusicListeningRankings.fromDateInterval(
      Iterable<MusicListeningEvent> events, LocalDateInterval interval,
      {required DateTime now}) {
    return MusicListeningRankings._tally(events, now, interval.contains);
  }

  factory MusicListeningRankings._tally(Iterable<MusicListeningEvent> events,
      DateTime now, bool Function(DateTime) includes) {
    final songs = <Object, _ListeningTally>{};
    final artists = <Object, _ListeningTally>{};
    final albums = <Object, _ListeningTally>{};
    final playlists = <Object, _ListeningTally>{};
    var plays = 0;
    for (final event in events) {
      if (event.isLegacy ||
          event.playedAt.isAfter(now) ||
          !includes(event.playedAt)) {
        continue;
      }
      final entry = event.entry;
      final music = entry.musicMetadata;
      final artist = _label(music?.artist) ?? _label(entry.author);
      final playlist = event.playlist;
      final releaseId = playlist?.kind == PlaylistSourceKind.public
          ? validMusicAlbumPlaylistId(playlist?.playlistId)
          : null;
      final album = _label(music?.album) ??
          (releaseId == null ? null : playlist?.displayTitle);
      final albumId = music?.albumPlaylistId ?? releaseId;
      plays++;

      (songs[event.trackId] ??= _ListeningTally()).add(
        event.playedAt,
        _label(music?.title) ?? _label(entry.title),
        artist,
        ListeningRecording(event),
      );

      final credited = <Object>{};
      for (final credit in music?.artistCredits ?? const []) {
        final name = _label(credit.name);
        if (name == null) continue;
        final key = credit.id == null ? (name.toLowerCase(),) : credit.id!;
        if (credited.add(key)) {
          final id = normalizeChannelId(credit.id);
          (artists[key] ??= _ListeningTally()).add(event.playedAt, name, null,
              id == null ? null : ListeningArtist(id));
        }
      }
      if (credited.isEmpty && artist != null) {
        final key = artist == _label(entry.author) && entry.authorId != null
            ? entry.authorId!
            : (artist.toLowerCase(),);
        final id = key is String ? normalizeChannelId(key) : null;
        (artists[key] ??= _ListeningTally()).add(event.playedAt, artist, null,
            id == null ? null : ListeningArtist(id));
      }

      if (album != null || albumId != null) {
        // Title-only releases are scoped by the credited artist so unrelated
        // records with the same title do not share a total.
        final key = albumId ?? (album!.toLowerCase(), artist?.toLowerCase());
        (albums[key] ??= _ListeningTally()).add(event.playedAt, album, artist,
            albumId == null ? null : ListeningAlbum(albumId));
      }

      // Catalog releases use a public playlist for playback, too.
      if (playlist != null && releaseId == null) {
        (playlists[playlist.key] ??= _ListeningTally()).add(event.playedAt,
            playlist.displayTitle, null, ListeningPlaylist(playlist));
      }
    }
    return MusicListeningRankings._(plays, {
      MusicListeningRankBy.song: _ranked(songs),
      MusicListeningRankBy.artist: _ranked(artists),
      MusicListeningRankBy.album: _ranked(albums),
      MusicListeningRankBy.playlist: _ranked(playlists),
    });
  }

  static List<MusicListeningRank> _ranked(Map<Object, _ListeningTally> totals) {
    final ordered = totals.entries.toList()
      ..sort((a, b) {
        final byPlays = b.value.plays.compareTo(a.value.plays);
        if (byPlays != 0) return byPlays;
        final byTitle = (a.value.title?.toLowerCase() ?? '')
            .compareTo(b.value.title?.toLowerCase() ?? '');
        if (byTitle != 0) return byTitle;
        final bySubtitle = (a.value.subtitle?.toLowerCase() ?? '')
            .compareTo(b.value.subtitle?.toLowerCase() ?? '');
        if (bySubtitle != 0) return bySubtitle;
        return a.key.toString().compareTo(b.key.toString());
      });
    return List.unmodifiable(ordered.map((entry) => (
          title: entry.value.title,
          subtitle: entry.value.subtitle,
          plays: entry.value.plays,
          target: entry.value.target,
        )));
  }
}

String? _label(String? value) {
  final label = value?.trim();
  return label == null || label.isEmpty ? null : label;
}

class _ListeningTally {
  int plays = 0;
  String? title;
  String? subtitle;
  DateTime? _titleAt;
  DateTime? _subtitleAt;
  MusicListeningTarget? target;
  DateTime? _targetAt;

  void add(DateTime playedAt, String? title,
      [String? subtitle, MusicListeningTarget? target]) {
    plays++;
    if (target != null && (_targetAt?.isBefore(playedAt) ?? true)) {
      this.target = target;
      _targetAt = playedAt;
    }
    if (title != null && (_titleAt?.isBefore(playedAt) ?? true)) {
      this.title = title;
      _titleAt = playedAt;
    }
    if (subtitle != null && (_subtitleAt?.isBefore(playedAt) ?? true)) {
      this.subtitle = subtitle;
      _subtitleAt = playedAt;
    }
  }
}
