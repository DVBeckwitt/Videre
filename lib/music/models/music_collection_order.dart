import '../../videos/models/video.dart';

enum MusicCollectionSortField { source, title, artist, album, duration }

class MusicCollectionOrder {
  const MusicCollectionOrder({
    this.field = MusicCollectionSortField.source,
    this.descending = false,
  });

  factory MusicCollectionOrder.decode(String? value) {
    final parts = value?.split(':');
    if (parts == null || parts.length != 2) {
      return const MusicCollectionOrder();
    }
    final field = MusicCollectionSortField.values.asNameMap()[parts.first];
    if (field == null ||
        (parts.last != 'ascending' && parts.last != 'descending')) {
      return const MusicCollectionOrder();
    }
    return MusicCollectionOrder(
        field: field, descending: parts.last == 'descending');
  }

  final MusicCollectionSortField field;
  final bool descending;

  bool get isSourceOrder =>
      field == MusicCollectionSortField.source && !descending;

  String encode() => '${field.name}:${descending ? 'descending' : 'ascending'}';

  /// Keeps playback and selection keyed to the original occurrences.
  List<int> orderIndices<T>(List<T> items,
      {required Object? Function(T item, MusicCollectionSortField field)
          sortValue}) {
    final indices = [for (var index = 0; index < items.length; index++) index];
    if (field == MusicCollectionSortField.source) {
      return descending ? indices.reversed.toList() : indices;
    }

    final values = [
      for (final item in items) normalizeSortValue(sortValue(item, field)),
    ];
    return indices
      ..sort((first, second) {
        final a = values[first];
        final b = values[second];
        if (a == null) return b == null ? first.compareTo(second) : 1;
        if (b == null) return -1;
        final order = switch ((a, b)) {
          (final String text, final String other) => text.compareTo(other),
          (final num number, final num other) => number.compareTo(other),
          _ => 0,
        };
        return order == 0
            ? first.compareTo(second)
            : (descending ? -order : order);
      });
  }

  static Object? normalizeSortValue(Object? value) {
    if (value is! String) return value;
    final text = value.trim().toLowerCase();
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) =>
      other is MusicCollectionOrder &&
      other.field == field &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(field, descending);
}

Object? musicPlaylistTrackSortValue(
        Video song, MusicCollectionSortField field) =>
    switch (field) {
      MusicCollectionSortField.source => null,
      MusicCollectionSortField.title => song.musicMetadata?.title ?? song.title,
      MusicCollectionSortField.artist =>
        song.musicMetadata?.artist ?? song.author,
      MusicCollectionSortField.album => song.musicMetadata?.album,
      MusicCollectionSortField.duration => switch (song.lengthSeconds) {
          final int seconds when seconds > 0 => seconds,
          _ => null,
        },
    };
