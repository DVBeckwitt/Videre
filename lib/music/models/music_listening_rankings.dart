import '../../playlists/models/playlist_reference.dart';
import '../../videos/models/music_metadata.dart';
import 'music_listening_event.dart';

enum MusicListeningPeriod {
  last7Days(Duration(days: 7)),
  last30Days(Duration(days: 30)),
  last365Days(Duration(days: 365)),
  allTime(null);

  const MusicListeningPeriod(this.duration);

  final Duration? duration;
}

enum MusicListeningRankBy { song, artist, album, playlist }

typedef MusicListeningRank = ({String? title, String? subtitle, int plays});

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
    final songs = <Object, _ListeningTally>{};
    final artists = <Object, _ListeningTally>{};
    final albums = <Object, _ListeningTally>{};
    final playlists = <Object, _ListeningTally>{};
    var plays = 0;
    for (final event in events) {
      if (event.isLegacy ||
          event.playedAt.isAfter(now) ||
          (start != null && event.playedAt.isBefore(start))) {
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
          event.playedAt, _label(music?.title) ?? _label(entry.title), artist);

      final credited = <Object>{};
      for (final credit in music?.artistCredits ?? const []) {
        final name = _label(credit.name);
        if (name == null) continue;
        final key = credit.id == null ? (name.toLowerCase(),) : credit.id!;
        if (credited.add(key)) {
          (artists[key] ??= _ListeningTally()).add(event.playedAt, name);
        }
      }
      if (credited.isEmpty && artist != null) {
        final key = artist == _label(entry.author) && entry.authorId != null
            ? entry.authorId!
            : (artist.toLowerCase(),);
        (artists[key] ??= _ListeningTally()).add(event.playedAt, artist);
      }

      if (album != null || albumId != null) {
        // Title-only releases are scoped by the credited artist so unrelated
        // records with the same title do not share a total.
        final key = albumId ?? (album!.toLowerCase(), artist?.toLowerCase());
        (albums[key] ??= _ListeningTally()).add(event.playedAt, album, artist);
      }

      // Catalog releases use a public playlist for playback, too.
      if (playlist != null && releaseId == null) {
        (playlists[playlist.key] ??= _ListeningTally())
            .add(event.playedAt, playlist.displayTitle);
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

  void add(DateTime playedAt, String? title, [String? subtitle]) {
    plays++;
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
