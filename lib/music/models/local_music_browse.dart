import 'local_music_track.dart';
import 'music_search_text.dart';
import 'on_device_music_entry.dart';

final _leadingArticle = RegExp(r'^(?:a|an|the)\s+(?=\S)');
final _digits = RegExp(r'[0-9]+');
final _paddingZeros = RegExp(r'^0+(?=[0-9])');

/// Uses an embedded sort name as written. English articles are ignored only
/// for the display-name fallback. The display name itself stays unchanged.
String? localMusicSortName(
  String? name, {
  String? sortTag,
  bool ignoreArticles = true,
}) {
  String? normalized(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty || text.toLowerCase() == '<unknown>'
        ? null
        : normalizeMusicSearchText(text);
  }

  final tag = normalized(sortTag);
  if (tag != null) return tag;
  final fallback = normalized(name);
  return ignoreArticles
      ? fallback?.replaceFirst(_leadingArticle, '')
      : fallback;
}

/// Uses the explicit group sort name when its tagged members agree.
String? localMusicGroupSortName(String label, Iterable<String?> sortTags) {
  final names = {
    for (final tag in sortTags)
      if (localMusicSortName(null, sortTag: tag) case final key?) key,
  };
  return names.length == 1 ? names.single : localMusicSortName(label);
}

/// Compares normalized names, including digit runs too large to fit in an int.
int compareLocalMusicSortNames(
  String? first,
  String? second, {
  bool descending = false,
}) =>
    _compareKnown(first, second, _compareNatural, descending);

int _compareNatural(String first, String second) {
  var a = 0;
  var b = 0;
  while (a < first.length && b < second.length) {
    final firstUnit = first.codeUnitAt(a);
    final secondUnit = second.codeUnitAt(b);
    if (_isDigit(firstUnit) && _isDigit(secondUnit)) {
      final firstRun = _digits.matchAsPrefix(first, a)!;
      final secondRun = _digits.matchAsPrefix(second, b)!;
      final firstNumber = firstRun.group(0)!.replaceFirst(_paddingZeros, '');
      final secondNumber = secondRun.group(0)!.replaceFirst(_paddingZeros, '');
      final length = firstNumber.length.compareTo(secondNumber.length);
      if (length != 0) return length;
      final number = firstNumber.compareTo(secondNumber);
      if (number != 0) return number;
      a = firstRun.end;
      b = secondRun.end;
    } else {
      if (firstUnit != secondUnit) return firstUnit.compareTo(secondUnit);
      a++;
      b++;
    }
  }
  return (first.length - a).compareTo(second.length - b);
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

int _compareKnown<T>(
  T? first,
  T? second,
  int Function(T, T) compare,
  bool descending,
) {
  if (first == null) return second == null ? 0 : 1;
  if (second == null) return -1;
  return descending ? compare(second, first) : compare(first, second);
}

int _compareNumbers(int? first, int? second, bool descending) =>
    _compareKnown(first, second, (a, b) => a.compareTo(b), descending);

enum LocalMusicTrackSortField {
  title,
  artist,
  album,
  dateAdded,
  dateModified,
  duration,
  size,
}

class LocalMusicTrackSort {
  const LocalMusicTrackSort(this.field, this.descending);

  factory LocalMusicTrackSort.fromValue(String? value) {
    final parts = value?.split(':');
    final field = LocalMusicTrackSortField.values.firstWhere(
      (field) => field.name == parts?.first,
      orElse: () => LocalMusicTrackSortField.title,
    );
    return LocalMusicTrackSort(field, parts?.last == 'descending');
  }

  final LocalMusicTrackSortField field;
  final bool descending;

  String get value =>
      '${field.name}:${descending ? 'descending' : 'ascending'}';

  /// The active primary key. Text keys are normalized, dates are [DateTime],
  /// and duration and size are [int] in milliseconds and bytes, respectively.
  /// Unknown values are null and sort last in either direction.
  Object? sortValueFor(OnDeviceMusicEntry row) => switch (field) {
        LocalMusicTrackSortField.title => _titleSortName(row),
        LocalMusicTrackSortField.artist => localMusicSortName(
            row.artist,
            sortTag: row.deviceTrack?.artistSort,
          ),
        LocalMusicTrackSortField.album => localMusicSortName(
            row.album,
            sortTag: row.deviceTrack?.albumSort,
          ),
        LocalMusicTrackSortField.dateAdded => row.dateAdded,
        LocalMusicTrackSortField.dateModified => row.dateModified,
        LocalMusicTrackSortField.duration => _duration(row.durationMs),
        LocalMusicTrackSortField.size => _size(row.sizeBytes),
      };

  String? _titleSortName(OnDeviceMusicEntry row) =>
      localMusicSortName(row.title, sortTag: row.deviceTrack?.titleSort);

  List<OnDeviceMusicEntry> order(List<OnDeviceMusicEntry> tracks) {
    final titles = {for (final row in tracks) row: _titleSortName(row)};
    final values = field == LocalMusicTrackSortField.title
        ? titles
        : {for (final row in tracks) row: sortValueFor(row)};
    return [...tracks]..sort((a, b) {
        final comparison = _compareKnown(
          values[a],
          values[b],
          _compareSortValues,
          descending,
        );
        if (comparison != 0) return comparison;
        final title = compareLocalMusicSortNames(titles[a], titles[b]);
        return title != 0 ? title : a.id.compareTo(b.id);
      });
  }
}

int _compareSortValues(Object a, Object b) => switch (a) {
      String() => _compareNatural(a, b as String),
      DateTime() => a.compareTo(b as DateTime),
      _ => (a as int).compareTo(b as int),
    };

int? _duration(int value) => value > 0 ? value : null;
int? _size(int? value) => value != null && value >= 0 ? value : null;

/// Count and measured subtotals for the browse rows in one scope.
class LocalMusicTotals {
  const LocalMusicTotals._(
    this.trackCount,
    this.durationMs,
    this.sizeBytes,
    this.durationComplete,
    this.sizeComplete,
  );

  factory LocalMusicTotals.fromTracks(
    Iterable<LocalMusicTrack> tracks, {
    bool complete = true,
  }) =>
      LocalMusicTotals._sum(
        tracks.map((track) => (track.durationMs, track.sizeBytes)),
        complete,
      );

  factory LocalMusicTotals.fromEntries(
    Iterable<OnDeviceMusicEntry> entries, {
    bool complete = true,
  }) =>
      LocalMusicTotals._sum(
        entries.map((entry) => (entry.durationMs, entry.sizeBytes)),
        complete,
      );

  factory LocalMusicTotals._sum(
    Iterable<(int, int?)> measurements,
    bool complete,
  ) {
    var count = 0;
    int? duration;
    int? size;
    var allDurations = complete;
    var allSizes = complete;
    for (final (durationMs, sizeBytes) in measurements) {
      count++;
      if (_duration(durationMs) case final known?) {
        duration = (duration ?? 0) + known;
      } else {
        allDurations = false;
      }
      if (_size(sizeBytes) case final known?) {
        size = (size ?? 0) + known;
      } else {
        allSizes = false;
      }
    }
    return LocalMusicTotals._(count, duration, size, allDurations, allSizes);
  }

  final int trackCount;
  final int? durationMs;
  final int? sizeBytes;
  final bool durationComplete;
  final bool sizeComplete;
}

enum LocalMusicCategorySort {
  name,
  trackCount,
  duration,
  size;

  /// Breaks ties by name and a stable group key so refreshes cannot reshuffle
  /// groups with the same measurements.
  int compare(
    LocalMusicTotals a,
    LocalMusicTotals b, {
    required String? firstName,
    required String? secondName,
    required String firstKey,
    required String secondKey,
    bool descending = false,
  }) {
    final comparison = switch (this) {
      name => compareLocalMusicSortNames(
          firstName,
          secondName,
          descending: descending,
        ),
      trackCount => _compareNumbers(a.trackCount, b.trackCount, descending),
      duration => _compareNumbers(a.durationMs, b.durationMs, descending),
      size => _compareNumbers(a.sizeBytes, b.sizeBytes, descending),
    };
    if (comparison != 0) return comparison;
    final names = compareLocalMusicSortNames(firstName, secondName);
    return names != 0 ? names : firstKey.compareTo(secondKey);
  }
}
