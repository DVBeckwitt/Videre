import '../../videos/models/music_metadata.dart';

const _limit = 5;
const _toleranceMs = 2000;
final _mbid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    caseSensitive: false);
final _spaces = RegExp(r'\s+');
final _controls = RegExp(r'[\x00-\x1f\x7f]');
final _uploadLabel = RegExp(
    r'\s*\((?:official (?:music video|video|audio)|(?:official )?lyrics? video)\)\s*$',
    caseSensitive: false);
final _uploaderLabel = RegExp(r'(?:\s+-\s+Topic|VEVO)$');
final _artistSeparator = RegExp(r'\s+[-–—]\s+');

String? _id(Object? value) =>
    value is String && value.length == 36 && _mbid.hasMatch(value)
        ? value.toLowerCase()
        : null;

String _label(Object? value) =>
    value is String && value.length <= 320 && !_controls.hasMatch(value)
        ? value.trim().replaceAll(_spaces, ' ')
        : '';

String _key(String text) => text.toLowerCase().replaceAll('’', "'");

typedef _Signature = ({String title, String artist, String album});

_Signature? _signature(MusicMetadata track, int? seconds) {
  var title = _label(track.title);
  final uploader = _label(track.artist);
  var artist = uploader.replaceFirst(_uploaderLabel, '').trimRight();
  final album = _label(track.album);
  if ((track.album?.trim().isNotEmpty == true && album.isEmpty) ||
      (seconds == null && album.isEmpty) ||
      (seconds != null && (seconds <= 0 || seconds > 86400))) {
    return null;
  }
  final separator = _artistSeparator.firstMatch(title);
  if (separator != null) {
    final prefix = title.substring(0, separator.start);
    // A VEVO channel name can omit the spaces in its credited artist's name.
    if (_key(prefix) == _key(artist) ||
        (uploader.endsWith('VEVO') &&
            _key(prefix).replaceAll(' ', '') ==
                _key(artist).replaceAll(' ', ''))) {
      title = title.substring(separator.end);
      artist = prefix;
    }
  }
  title = title.replaceFirst(_uploadLabel, '').trim();
  if (title.isEmpty || artist.isEmpty) return null;
  return (title: title, artist: artist, album: album);
}

/// MusicBrainz accepts Lucene syntax. Quote labels as literal phrases before
/// enclosing the query as a single URI parameter.
String _phrase(String text) =>
    '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

Uri? musicCoverSearchUri(MusicMetadata track, int? durationSeconds) {
  final signature = _signature(track, durationSeconds);
  if (signature == null) return null;
  final query = [
    'recording:${_phrase(signature.title)}',
    'artist:${_phrase(signature.artist)}',
    if (signature.album.isNotEmpty) 'release:${_phrase(signature.album)}',
    if (durationSeconds != null)
      'dur:[${(durationSeconds * 1000 - _toleranceMs).clamp(1, 86400000)} TO ${durationSeconds * 1000 + _toleranceMs}]',
    'status:official',
  ].join(' AND ');
  return Uri.https('musicbrainz.org', '/ws/2/recording',
      {'query': query, 'limit': '$_limit', 'fmt': 'json'});
}

String _artistCredit(Object? entries) {
  if (entries is! List || entries.isEmpty) return '';
  final result = StringBuffer();
  for (final (index, entry) in entries.indexed) {
    if (entry is! Map) return '';
    final artist = entry['artist'];
    final name =
        _label(entry['name'] ?? (artist is Map ? artist['name'] : null));
    final join = entry['joinphrase'] ?? '';
    if (name.isEmpty ||
        join is! String ||
        (index + 1 < entries.length && join.isEmpty)) {
      return '';
    }
    result.write(name);
    result.write(join);
  }
  return _key(_label(result.toString()));
}

/// Use the group's representative CAA front. Editions can have different
/// covers, and list order is not evidence of which edition a listener has.
String? musicCoverReleaseGroupId(
    MusicMetadata track, int? durationSeconds, Object? json) {
  final signature = _signature(track, durationSeconds);
  if (signature == null || json is! Map) return null;
  final rows = json['recordings'];
  // A truncated search page could hide a second plausible recording.
  if (rows is! List ||
      rows.length > _limit ||
      json['offset'] != 0 ||
      json['count'] != rows.length) {
    return null;
  }
  final title = _key(signature.title);
  final artist = _key(signature.artist);
  final album = _key(signature.album);
  String? recordingId;
  String? groupId;
  for (final row in rows) {
    if (row is! Map ||
        _key(_label(row['title'])) != title ||
        _artistCredit(row['artist-credit']) != artist) {
      continue;
    }
    final length = row['length'];
    if (durationSeconds != null &&
        (length is! int ||
            length <= 0 ||
            (length - durationSeconds * 1000).abs() > _toleranceMs)) {
      continue;
    }
    final comment = row['disambiguation'];
    final version = _key(_label(comment));
    if (comment != null &&
        (comment is! String ||
            (comment.trim().isNotEmpty && version.isEmpty))) {
      continue;
    }
    if (version.isNotEmpty &&
        !title.contains('($version)') &&
        !title.contains('[$version]') &&
        !title.endsWith(' - $version')) {
      continue;
    }
    final id = _id(row['id']);
    final releases = row['releases'];
    if (id == null ||
        releases is! List ||
        (row.containsKey('release-count') &&
            row['release-count'] != releases.length) ||
        (row.containsKey('release-offset') && row['release-offset'] != 0)) {
      return null;
    }
    for (final release in releases) {
      if (release is! Map || release['status'] != 'Official') continue;
      final releaseTitle = _label(release['title']);
      if (releaseTitle.isEmpty ||
          (album.isNotEmpty && _key(releaseTitle) != album)) {
        continue;
      }
      final group = release['release-group'];
      if (group is! Map) return null;
      if (album.isEmpty) {
        // Compilations and other secondary release types cannot identify the
        // originating cover when the song has no album label.
        final kinds = group['secondary-types'];
        if (!const {'Album', 'Single', 'EP'}.contains(group['primary-type']) ||
            (kinds != null && (kinds is! List || kinds.isNotEmpty)) ||
            (release['artist-credit'] != null &&
                _artistCredit(release['artist-credit']) != artist)) {
          continue;
        }
      }
      final candidate = _id(group['id']);
      if (candidate == null ||
          (groupId != null && groupId != candidate) ||
          (recordingId != null && recordingId != id)) {
        return null;
      }
      groupId = candidate;
      recordingId = id;
    }
  }
  return groupId;
}
