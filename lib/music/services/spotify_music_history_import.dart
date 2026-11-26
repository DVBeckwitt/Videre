import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../utils/backup.dart';
import '../../videos/models/db/history_video_cache.dart';
import '../models/music_listening_event.dart';
import 'music_history_transfer.dart';

typedef SpotifyMusicHistoryInput = ({
  String text,
  List<SpotifyMusicHistoryCandidate> candidates,
  Set<String> existingEventIds,
});

enum SpotifyMusicHistoryStatus {
  matched,
  ambiguous,
  unmatched,
  duplicate,
  skipped,
  invalid,
}

class SpotifyMusicHistoryCandidate {
  const SpotifyMusicHistoryCandidate(this.entry, this.source);

  final HistoryVideoCache entry;
  final MusicListeningSource source;
}

class SpotifyMusicHistoryRow {
  const SpotifyMusicHistoryRow._({
    required this.number,
    required this.status,
    this.title,
    this.artist,
    this.album,
    this.playedAt,
    this.matches = const [],
  });

  final int number;
  final SpotifyMusicHistoryStatus status;
  final String? title;
  final String? artist;
  final String? album;
  final DateTime? playedAt;
  final List<SpotifyMusicHistoryCandidate> matches;
}

class SpotifyMusicHistoryPreview {
  SpotifyMusicHistoryPreview._(
    List<SpotifyMusicHistoryRow> rows,
    List<MusicListeningEvent> events,
  )   : rows = List.unmodifiable(rows),
        events = List.unmodifiable(events);

  final List<SpotifyMusicHistoryRow> rows;
  final List<MusicListeningEvent> events;
}

final _whitespace = RegExp(r'\s+');
final _timestamp = RegExp(
  r'^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'
  r'T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,6})?'
  r'(?:Z|[+-](?:[01][0-9]|2[0-3]):?[0-5][0-9])$',
);
final _spotifyTrackUri = RegExp(r'^spotify:track:[A-Za-z0-9]+$');
final _versionFiveId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Spotify imports use UUID v5. Native dated listening events use UUID v4.
bool isSpotifyMusicHistoryEventId(String id) =>
    _versionFiveId.stringMatch(id) == id;

/// Reads the audio files in Spotify's Extended Streaming History export.
class SpotifyMusicHistoryImport {
  static const _title = 'master_metadata_track_name';
  static const _artist = 'master_metadata_album_artist_name';
  static const _album = 'master_metadata_album_album_name';
  static const _trackUri = 'spotify_track_uri';
  static const _nonMusic = [
    'spotify_episode_uri',
    'episode_name',
    'episode_show_name',
    'audiobook_uri',
    'audiobook_chapter_uri',
    'audiobook_title',
  ];

  static SpotifyMusicHistoryPreview preview(SpotifyMusicHistoryInput input) {
    final data = _decode(input.text);
    final byLabels = <(String, String), List<SpotifyMusicHistoryCandidate>>{};
    for (final candidate in input.candidates) {
      final entry = candidate.entry;
      final metadata = entry.musicMetadata;
      final title = _label(metadata?.title) ?? _label(entry.title);
      final artist = _label(metadata?.artist) ?? _label(entry.author);
      if (title != null && artist != null) {
        final key = (_normalized(title), _normalized(artist));
        (byLabels[key] ??= []).add(candidate);
      }
    }

    final seen = <String>{...input.existingEventIds};
    final rows = <SpotifyMusicHistoryRow>[];
    final events = <MusicListeningEvent>[];
    for (final (index, dataRow) in data.indexed) {
      rows.add(_reviewRow(index + 1, dataRow, byLabels, seen, events));
    }
    return SpotifyMusicHistoryPreview._(rows, events);
  }

  static List<dynamic> _decode(String text) {
    if (text.length > UserBackup.maxBytes ||
        utf8.encode(text).length > UserBackup.maxBytes) {
      throw const MusicHistoryFileTooLarge();
    }
    const invalid = FormatException('Invalid Spotify listening history.');
    final Object? data;
    try {
      data = jsonDecode(text.startsWith('\ufeff') ? text.substring(1) : text);
    } on FormatException {
      // The decoder's exception can contain source text from the export.
      throw invalid;
    }
    if (data is! List ||
        (data.isNotEmpty &&
            !data.any((row) =>
                row is Map<String, dynamic> &&
                (row.containsKey(_title) ||
                    row.containsKey(_trackUri) ||
                    _nonMusic.any(row.containsKey))))) {
      throw invalid;
    }
    return data;
  }

  static SpotifyMusicHistoryRow _reviewRow(
    int number,
    Object? data,
    Map<(String, String), List<SpotifyMusicHistoryCandidate>> byLabels,
    Set<String> seen,
    List<MusicListeningEvent> events,
  ) {
    if (data is! Map<String, dynamic>) {
      return SpotifyMusicHistoryRow._(
        number: number,
        status: SpotifyMusicHistoryStatus.invalid,
      );
    }
    final privateSession = data['incognito_mode'];
    if (privateSession != null && privateSession != false) {
      return SpotifyMusicHistoryRow._(
        number: number,
        status: privateSession == true
            ? SpotifyMusicHistoryStatus.skipped
            : SpotifyMusicHistoryStatus.invalid,
      );
    }

    final title = _label(data[_title]);
    final artist = _label(data[_artist]);
    final album = _label(data[_album]);
    final playedAt = _playedAt(data['ts']);
    final msPlayed = data['ms_played'];
    var matches = const <SpotifyMusicHistoryCandidate>[];
    final SpotifyMusicHistoryStatus status;
    if (_nonMusic.any((key) => _label(data[key]) != null) || msPlayed == 0) {
      status = SpotifyMusicHistoryStatus.skipped;
    } else if (title == null ||
        artist == null ||
        playedAt == null ||
        msPlayed is! int ||
        msPlayed < 0) {
      status = SpotifyMusicHistoryStatus.invalid;
    } else {
      final labels = (_normalized(title), _normalized(artist));
      final normalizedAlbum = album == null ? null : _normalized(album);
      final trackUri = _label(data[_trackUri]);
      final id = const Uuid().v5(
        Namespace.url.value,
        jsonEncode([
          'videre-music-history:spotify',
          playedAt.microsecondsSinceEpoch,
          if (trackUri != null &&
              _spotifyTrackUri.stringMatch(trackUri) == trackUri)
            trackUri
          else
            [labels.$1, labels.$2, normalizedAlbum],
          msPlayed,
        ]),
      );
      if (!seen.add(id)) {
        status = SpotifyMusicHistoryStatus.duplicate;
      } else {
        matches = _match(byLabels[labels] ?? const [], normalizedAlbum);
        status = switch (matches.length) {
          0 => SpotifyMusicHistoryStatus.unmatched,
          1 => SpotifyMusicHistoryStatus.matched,
          _ => SpotifyMusicHistoryStatus.ambiguous,
        };
        if (matches.length == 1) {
          events.add(_event(id, playedAt, matches.single));
        }
      }
    }

    return SpotifyMusicHistoryRow._(
      number: number,
      status: status,
      title: title,
      artist: artist,
      album: album,
      playedAt: playedAt,
      matches: matches,
    );
  }

  static List<SpotifyMusicHistoryCandidate> _match(
    List<SpotifyMusicHistoryCandidate> candidates,
    String? album,
  ) {
    final exact = <SpotifyMusicHistoryCandidate>[];
    final unknown = <SpotifyMusicHistoryCandidate>[];
    for (final candidate in candidates) {
      final knownAlbum = _label(candidate.entry.musicMetadata?.album);
      if (album == null || knownAlbum == null) {
        unknown.add(candidate);
      } else if (_normalized(knownAlbum) == album) {
        exact.add(candidate);
      }
    }
    final seen = <String>{};
    return List.unmodifiable([
      for (final candidate in exact.isEmpty ? unknown : exact)
        if (seen.add(candidate.entry.videoId)) candidate,
    ]);
  }

  static MusicListeningEvent _event(
    String id,
    DateTime playedAt,
    SpotifyMusicHistoryCandidate candidate,
  ) {
    final sourceEntry = candidate.entry;
    final entry = HistoryVideoCache(
      sourceEntry.videoId,
      sourceEntry.title,
      sourceEntry.author,
      sourceEntry.thumbnail,
      authorId: sourceEntry.authorId,
      lengthSeconds: sourceEntry.lengthSeconds,
      musicMetadata: sourceEntry.musicMetadata,
      playedFromDownload: sourceEntry.playedFromDownload,
      downloadAccountId: sourceEntry.downloadAccountId,
    )..created = playedAt;
    return MusicListeningEvent(id: id, entry: entry, source: candidate.source);
  }

  static String? _label(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String _normalized(String value) =>
      value.trim().toLowerCase().replaceAll(_whitespace, ' ');

  static DateTime? _playedAt(Object? value) {
    if (value is! String) return null;
    final parts = _timestamp.firstMatch(value);
    if (parts == null || parts.end != value.length) return null;
    final year = int.parse(parts[1]!);
    final month = int.parse(parts[2]!);
    final day = int.parse(parts[3]!);
    // DateTime.parse normalizes invalid calendar dates into the next month.
    if (DateTime.utc(year, month, day).day != day) return null;
    return DateTime.tryParse(value)?.toUtc();
  }
}
