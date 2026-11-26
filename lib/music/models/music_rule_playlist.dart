import 'music_library_entry.dart';
import 'music_recording_rating.dart';
import 'music_search_text.dart';

const musicRulePlaylistTextLimit = 120;
const musicRulePlaylistMaximumDuration = 604800;

enum MusicRulePlaylistSort { saved, title, artist, album, duration }

/// A saved query over the current profile's bookmarked songs.
class MusicRulePlaylist {
  const MusicRulePlaylist({
    required this.id,
    required this.name,
    this.titleContains = '',
    this.artistContains = '',
    this.albumContains = '',
    this.minimumDurationSeconds,
    this.maximumDurationSeconds,
    this.minimumRating,
    this.sort = MusicRulePlaylistSort.saved,
    this.descending = false,
    this.limit,
  });

  final String id;
  final String name;
  final String titleContains;
  final String artistContains;
  final String albumContains;
  final int? minimumDurationSeconds;
  final int? maximumDurationSeconds;
  final int? minimumRating;
  final MusicRulePlaylistSort sort;
  final bool descending;
  final int? limit;

  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _controls = RegExp(r'[\x00-\x1f\x7f]');

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        if (titleContains.isNotEmpty) 'titleContains': titleContains,
        if (artistContains.isNotEmpty) 'artistContains': artistContains,
        if (albumContains.isNotEmpty) 'albumContains': albumContains,
        if (minimumDurationSeconds != null)
          'minimumDurationSeconds': minimumDurationSeconds,
        if (maximumDurationSeconds != null)
          'maximumDurationSeconds': maximumDurationSeconds,
        if (minimumRating != null) 'minimumRating': minimumRating,
        'sort': sort.name,
        'descending': descending,
        if (limit != null) 'limit': limit,
      };

  static MusicRulePlaylist? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = _cleanText(value['name']);
    final title = _cleanText(value['titleContains'] ?? '');
    final artist = _cleanText(value['artistContains'] ?? '');
    final album = _cleanText(value['albumContains'] ?? '');
    final minimum = value['minimumDurationSeconds'];
    final maximum = value['maximumDurationSeconds'];
    final minimumRating = value['minimumRating'];
    final limit = value['limit'];
    final sort = MusicRulePlaylistSort.values
        .asNameMap()[value['sort'] ?? MusicRulePlaylistSort.saved.name];
    final descending = value['descending'] ?? false;
    if (id is! String ||
        _idPattern.stringMatch(id) != id ||
        name == null ||
        name.isEmpty ||
        title == null ||
        artist == null ||
        album == null ||
        (minimum != null &&
            !_inRange(minimum, 0, musicRulePlaylistMaximumDuration)) ||
        (maximum != null &&
            !_inRange(maximum, 0, musicRulePlaylistMaximumDuration)) ||
        (minimum is int && maximum is int && minimum > maximum) ||
        (minimumRating != null &&
            !isValidMusicRecordingRating(minimumRating)) ||
        (limit != null && !_inRange(limit, 1, musicLibraryMaximumEntries)) ||
        sort == null ||
        descending is! bool) {
      return null;
    }
    return MusicRulePlaylist(
      id: id,
      name: name,
      titleContains: title,
      artistContains: artist,
      albumContains: album,
      minimumDurationSeconds: minimum as int?,
      maximumDurationSeconds: maximum as int?,
      minimumRating: minimumRating as int?,
      sort: sort,
      descending: descending,
      limit: limit as int?,
    );
  }

  static String? _cleanText(Object? value) {
    if (value is! String || _controls.hasMatch(value)) return null;
    final trimmed = value.trim();
    return trimmed.runes.length > musicRulePlaylistTextLimit ? null : trimmed;
  }

  static bool _inRange(Object value, int min, int max) =>
      value is int && value >= min && value <= max;

  /// All supplied conditions must match. Saved order is the input order.
  /// An unknown value fails its filter and sorts after known values.
  List<MusicLibraryEntry> resolve(Iterable<MusicLibraryEntry> entries,
      {Map<String, int> ratings = const {}}) {
    final titleFilter = _normalized(titleContains);
    final artistFilter = _normalized(artistContains);
    final albumFilter = _normalized(albumContains);
    final minimum = minimumDurationSeconds;
    final maximum = maximumDurationSeconds;
    final ratingThreshold = minimumRating;
    final rows =
        <({MusicLibraryEntry entry, int index, String? text, num? duration})>[];
    for (final (index, entry) in entries.indexed) {
      if (entry.kind != MusicLibraryKind.song) continue;
      final rating = ratings[entry.id];
      if (ratingThreshold != null &&
          (rating == null || rating < ratingThreshold)) {
        continue;
      }
      final title =
          entry.title.trim() == entry.id ? null : _normalized(entry.title);
      if (!_matches(title, titleFilter)) continue;
      final artists = [
        for (final credit in entry.artistCredits)
          if (_normalized(credit.name) case final name?) name,
      ];
      final artist =
          artists.isEmpty ? _normalized(entry.subtitle) : artists.first;
      if (artistFilter != null &&
          !(artists.isEmpty
              ? _matches(artist, artistFilter)
              : artists.join(', ').contains(artistFilter))) {
        continue;
      }
      final album = _normalized(entry.album);
      if (!_matches(album, albumFilter)) continue;
      final duration = entry.durationSeconds;
      final knownDuration = duration != null && duration > 0 ? duration : null;
      if ((minimum != null &&
              (knownDuration == null || knownDuration < minimum)) ||
          (maximum != null &&
              (knownDuration == null || knownDuration > maximum))) {
        continue;
      }

      final textKey = switch (sort) {
        MusicRulePlaylistSort.title => title,
        MusicRulePlaylistSort.artist => artist,
        MusicRulePlaylistSort.album => album,
        _ => null,
      };
      rows.add(
          (entry: entry, index: index, text: textKey, duration: knownDuration));
    }

    if (sort == MusicRulePlaylistSort.saved) {
      return _take((descending ? rows.reversed : rows).map((row) => row.entry));
    }
    rows.sort((first, second) {
      final order = sort == MusicRulePlaylistSort.duration
          ? _compare(first.duration, second.duration)
          : _compare(first.text, second.text);
      return order != 0 ? order : first.index.compareTo(second.index);
    });
    return _take(rows.map((row) => row.entry));
  }

  List<MusicLibraryEntry> _take(Iterable<MusicLibraryEntry> entries) {
    final count = limit;
    return (count == null ? entries : entries.take(count)).toList();
  }

  static String? _normalized(String? text) {
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final normalized = normalizeMusicSearchText(trimmed);
    return normalized.isEmpty ? null : normalized;
  }

  static bool _matches(String? value, String? filter) =>
      filter == null || value?.contains(filter) == true;

  int _compare<T extends Comparable<T>>(T? first, T? second) {
    if (first == null) return second == null ? 0 : 1;
    if (second == null) return -1;
    return descending ? second.compareTo(first) : first.compareTo(second);
  }
}
