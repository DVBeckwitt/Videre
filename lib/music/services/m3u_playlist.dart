import 'dart:convert';

import '../models/local_music_track.dart';

const _maxPathLength = 4096;
final _pathControls = RegExp(r'[\x00-\x1f\x7f]');
final _drive = RegExp(r'^[a-zA-Z]:/');
final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

final _windowsInvalidCharacter = RegExp(r'[<>:"/\\|?*]');
final _windowsDeviceName = RegExp(
  r'^(?:CON|PRN|AUX|NUL|(?:COM|LPT)[1-9¹²³]) *(?:\.|$)',
  caseSensitive: false,
);

bool _isWindowsPathComponent(String component) =>
    !component.startsWith(' ') &&
    !component.endsWith(' ') &&
    !component.endsWith('.') &&
    !_windowsInvalidCharacter.hasMatch(component) &&
    !_windowsDeviceName.hasMatch(component);

/// A file coordinate reported by the Android document picker or Music index.
/// It is used only for matching and writing playlist text.
typedef M3uLocation = ({String volume, String path});

M3uLocation? m3uLocation(Object? value) {
  if (value is! Map || value['volume'] is! String || value['path'] is! String) {
    return null;
  }
  final volume = value['volume'] as String;
  final path = value['path'] as String;
  if (volume.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      _normalizePath(path) != path) {
    return null;
  }
  return (volume: volume, path: path);
}

String? _normalizePath(String value, [Iterable<String> base = const []]) {
  if (value.isEmpty ||
      value.length > _maxPathLength ||
      _pathControls.hasMatch(value)) {
    return null;
  }
  final parts = base.toList();
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(segment);
    }
  }
  return parts.isEmpty ? null : parts.join('/');
}

class M3uDocument {
  static const maxEntries = 10000;
  final List<String> entries;

  M3uDocument._(this.entries);

  factory M3uDocument.parse(String text) {
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final entries = <String>[];
    for (final line in LineSplitter.split(text)) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#EXT-X-')) {
        throw const FormatException('HLS playlist');
      }
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (entries.length == maxEntries || line.length > _maxPathLength) {
        throw const FormatException('Playlist exceeds size limits');
      }
      entries.add(line);
    }
    if (entries.isEmpty) throw const FormatException('Empty playlist');
    return M3uDocument._(List.unmodifiable(entries));
  }
}

typedef M3uIndexedTrack = ({LocalMusicTrack track, M3uLocation location});
typedef M3uMatch = ({
  String reference,
  M3uIndexedTrack? exact,
  M3uIndexedTrack? suggestion,
  bool canRelink,
});

typedef M3uIndexSnapshot = ({
  M3uTrackIndex index,
  bool Function() isCurrent,
});

enum M3uExportPathStyle { automatic, relative, absolute, windows }

class M3uTrackIndex {
  final _locations = <M3uLocation, List<M3uIndexedTrack>>{};
  final _names = <String, List<M3uIndexedTrack>>{};
  final _ids = <String, M3uIndexedTrack>{};
  final _documents = <(String, String), M3uIndexedTrack>{};
  final Map<String, String> volumeRoots;

  M3uTrackIndex(Iterable<M3uIndexedTrack> tracks, this.volumeRoots) {
    for (final track in tracks) {
      _ids.putIfAbsent(track.track.playbackId, () => track);
      if (track.track.documentIdentity case final document?) {
        _documents.putIfAbsent(document, () => track);
      }
      final location = track.location;
      (_locations[location] ??= []).add(track);
      (_names[location.path.split('/').last] ??= []).add(track);
    }
  }

  M3uIndexedTrack? byTrack(LocalMusicTrack track) =>
      _ids[track.playbackId] ?? _documents[track.documentIdentity];

  Iterable<M3uIndexedTrack> get tracks => _ids.values;

  bool contains(M3uIndexedTrack row) {
    final current = _ids[row.track.playbackId];
    return current?.track.uri == row.track.uri &&
        current?.location == row.location;
  }

  List<M3uMatch> match(M3uDocument document, M3uLocation? playlist) =>
      [for (final reference in document.entries) _match(reference, playlist)];

  M3uMatch _match(String reference, M3uLocation? playlist) {
    final path = _localPath(reference);
    if (path == null || path.endsWith('/') || path == '.' || path == '..') {
      return (
        reference: reference,
        exact: null,
        suggestion: null,
        canRelink: false,
      );
    }
    final absolute = path.startsWith('/') || _drive.hasMatch(path);
    final M3uLocation? location;
    if (absolute) {
      location = _fromAbsolute(path);
    } else if (playlist != null) {
      final parts = playlist.path.split('/')..removeLast();
      final normalized = _normalizePath(path, parts);
      location = normalized == null
          ? null
          : (volume: playlist.volume, path: normalized);
    } else {
      location = null;
    }
    final rows = _locations[location];
    final exact = _uniqueTrack(rows);
    // Multiple exact candidates or an invalid relative path need review as
    // missing. A same-name file elsewhere cannot disambiguate either.
    final name = path.split('/').last;
    final canRelink = absolute
        ? _normalizePath(path) != null
        : location != null || playlist == null;
    final suggestion = exact == null && rows == null && canRelink
        ? _uniqueTrack(_names[name])
        : null;
    return (
      reference: reference,
      exact: exact,
      suggestion: suggestion,
      canRelink: canRelink,
    );
  }

  static M3uIndexedTrack? _uniqueTrack(List<M3uIndexedTrack>? candidates) {
    if (candidates == null) return null;
    final first = candidates.first;
    return candidates.every(
      (candidate) => candidate.track.playbackId == first.track.playbackId,
    )
        ? first
        : null;
  }

  M3uLocation? _fromAbsolute(String path) {
    for (final MapEntry(key: volume, value: root) in volumeRoots.entries) {
      final prefixes = {
        root,
        if (volume == 'primary') ...[
          '/sdcard',
          '/mnt/sdcard',
          '/storage/self/primary',
        ],
      };
      for (final prefix in prefixes) {
        if (path.startsWith('$prefix/')) {
          final relative = _normalizePath(path.substring(prefix.length + 1));
          return relative == null ? null : (volume: volume, path: relative);
        }
      }
    }
    return null;
  }

  static String? _localPath(String value) {
    if (value.isEmpty ||
        value.length > _maxPathLength ||
        _pathControls.hasMatch(value)) {
      return null;
    }
    final path = value.replaceAll('\\', '/');
    if (path.startsWith('//')) return null;
    if (!_scheme.hasMatch(path) || _drive.hasMatch(path)) return path;
    final uri = Uri.tryParse(path);
    if (uri == null ||
        uri.scheme != 'file' ||
        (uri.host.isNotEmpty && uri.host != 'localhost') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final parts = uri.pathSegments;
    if (parts.any((part) =>
        part.contains('/') ||
        part.contains('\\') ||
        _pathControls.hasMatch(part))) {
      return null;
    }
    final decoded = parts.join('/');
    return uri.path.startsWith('/') ? '/$decoded' : null;
  }

  /// Returns a path in [style], or null when the track cannot use it.
  String? exportPath(
    M3uLocation track,
    M3uLocation? destination, {
    M3uExportPathStyle style = M3uExportPathStyle.automatic,
  }) {
    final sameVolume = track.volume == destination?.volume;
    if (style == M3uExportPathStyle.absolute ||
        (style == M3uExportPathStyle.automatic && !sameVolume)) {
      final root = volumeRoots[track.volume];
      if (root == null) return null;
      final path = '$root/${track.path}';
      return path.length <= _maxPathLength ? path : null;
    }
    if (!sameVolume) return null;
    final from = destination!.path.split('/')..removeLast();
    final to = track.path.split('/');
    var common = 0;
    while (common < from.length &&
        common < to.length - 1 &&
        from[common] == to[common]) {
      common++;
    }
    final components = to.skip(common);
    final windows = style == M3uExportPathStyle.windows;
    if (windows && !components.every(_isWindowsPathComponent)) return null;
    final relative = [
      for (var i = common; i < from.length; i++) '..',
      ...components,
    ].join('/');
    final path =
        relative.trimLeft().startsWith('#') || _scheme.hasMatch(relative)
            ? './$relative'
            : relative;
    if (path.length > _maxPathLength) return null;
    return windows ? path.replaceAll('/', r'\') : path;
  }
}
