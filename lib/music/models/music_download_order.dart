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

  /// Uses the same primary value as the visible download order.
  Object? sortValue(DownloadedVideo video) => switch (field) {
        MusicDownloadSortField.defaultOrder => null,
        MusicDownloadSortField.duration => _duration(video),
        _ => _normalizeText(_textValue(video)),
      };

  String? _textValue(DownloadedVideo video) => switch (field) {
        MusicDownloadSortField.title => _title(video),
        MusicDownloadSortField.artist =>
          video.musicMetadata?.artist ?? video.author,
        MusicDownloadSortField.album => video.musicMetadata?.album,
        _ => null,
      };

  static String _title(DownloadedVideo video) =>
      video.musicMetadata?.title ?? video.title;

  static int? _duration(DownloadedVideo video) =>
      video.lengthSeconds > 0 ? video.lengthSeconds : null;

  static String? _normalizeText(String? value) {
    final key = value == null ? '' : normalizeMusicSearchText(value.trim());
    return key.isEmpty ? null : key;
  }

  List<DownloadedVideo> sort(Iterable<DownloadedVideo> source) {
    final rows = source.toList();
    if (field == MusicDownloadSortField.defaultOrder) {
      return descending ? rows.reversed.toList() : rows;
    }

    final normalized = <String?, String?>{};
    String? text(String? value) =>
        normalized.putIfAbsent(value, () => _normalizeText(value));

    rows.sort((first, second) {
      final primary = field == MusicDownloadSortField.duration
          ? _compare<num>(_duration(first), _duration(second), descending)
          : _compare(
              text(_textValue(first)), text(_textValue(second)), descending);
      if (primary != 0) return primary;
      final title = _compare(text(_title(first)), text(_title(second)), false);
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
