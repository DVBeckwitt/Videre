import '../../downloads/models/downloaded_video.dart';
import 'music_search_text.dart';

enum MusicDownloadSortField { defaultOrder, title, artist, album, duration }

class MusicDownloadOrder {
  final MusicDownloadSortField field;
  final bool descending;

  const MusicDownloadOrder({
    this.field = MusicDownloadSortField.defaultOrder,
    this.descending = false,
  });

  static MusicDownloadOrder? fromStorage(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final field = MusicDownloadSortField.values.asNameMap()[parts.first];
    if (field == null) return null;
    return switch (parts.last) {
      'ascending' => MusicDownloadOrder(field: field),
      'descending' => MusicDownloadOrder(field: field, descending: true),
      _ => null,
    };
  }

  String encode() => '${field.name}:${descending ? 'descending' : 'ascending'}';

  List<DownloadedVideo> sort(Iterable<DownloadedVideo> source) {
    final rows = source.toList();
    if (field == MusicDownloadSortField.defaultOrder) {
      return descending ? rows.reversed.toList() : rows;
    }

    final normalized = <String, String>{};
    String? text(String? value) {
      if (value == null) return null;
      final key = normalized.putIfAbsent(
          value, () => normalizeMusicSearchText(value.trim()));
      return key.isEmpty ? null : key;
    }

    rows.sort((first, second) {
      final firstTitle = text(first.musicMetadata?.title ?? first.title);
      final secondTitle = text(second.musicMetadata?.title ?? second.title);
      final primary = switch (field) {
        MusicDownloadSortField.title =>
          _compare(firstTitle, secondTitle, descending),
        MusicDownloadSortField.artist => _compare(
            text(first.musicMetadata?.artist ?? first.author),
            text(second.musicMetadata?.artist ?? second.author),
            descending),
        MusicDownloadSortField.album => _compare(
            text(first.musicMetadata?.album),
            text(second.musicMetadata?.album),
            descending),
        MusicDownloadSortField.duration => _compare<num>(
            first.lengthSeconds > 0 ? first.lengthSeconds : null,
            second.lengthSeconds > 0 ? second.lengthSeconds : null,
            descending),
        MusicDownloadSortField.defaultOrder => 0,
      };
      if (primary != 0) return primary;
      final title = _compare(firstTitle, secondTitle, false);
      return title != 0 ? title : first.videoId.compareTo(second.videoId);
    });
    return rows;
  }

  static int _compare<T extends Comparable<T>>(
      T? first, T? second, bool descending) {
    if (first == null) return second == null ? 0 : 1;
    if (second == null) return -1;
    return descending ? second.compareTo(first) : first.compareTo(second);
  }

  @override
  bool operator ==(Object other) =>
      other is MusicDownloadOrder &&
      other.field == field &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(field, descending);
}
