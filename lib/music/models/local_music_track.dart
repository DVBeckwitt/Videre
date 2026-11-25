import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'replay_gain.dart';

/// One exact folder or verified ancestor in the authorized device source.
class LocalMusicFolderLocation {
  final String key;
  final String label;

  const LocalMusicFolderLocation(this.key, this.label);
}

/// Metadata for a track from the selected Android music source.
class LocalMusicTrack {
  static final systemSource = Uri.parse('content://media/external/audio/media');
  static final _identityPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _volumePattern = RegExp(r'^[a-zA-Z0-9_-]+$');
  static final _rowPattern = RegExp(r'^[0-9]+$');
  static final _metadataControls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  final String uri;
  final Uri? sourceUri;

  /// The provider and its verified document ID for a SAF track.
  final (String, String)? documentIdentity;
  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? titleSort;
  final String? artistSort;
  final String? albumSort;
  final String? albumArtistSort;
  final String? genre;
  final ReplayGain? replayGain;

  /// Identifies an album grouping only within the authorized device catalog.
  final String? albumKey;
  final int? discNumber;
  final int? trackNumber;

  /// Embedded music date at its original precision (year, month, or day).
  final String? releaseDate;
  final String? originalReleaseDate;
  final int durationMs;
  final int? sizeBytes;

  /// Absolute offset into the backing document of a virtual CUE track.
  final int? cueStartUs;

  /// Absolute end of the CUE track. The final track may play to EOF.
  final int? cueEndUs;

  final String? artPath;

  /// Private cached image from the same permitted folder as this track.
  final String? adjacentArtPath;
  final String? fileName;
  final int? sizeBytes;
  final DateTime? dateAdded;
  final DateTime? dateModified;
  final bool firstSeen;
  final bool canRename;

  /// Android positively identified this track as a recording.
  final bool isRecording;

  /// Verified ancestors in order, ending with the exact containing folder.
  final List<LocalMusicFolderLocation> folderLocations;
  final String? visibilityKey;
  final String? documentVisibilityKey;
  final String? _identityUri;
  final String? _identityKey;

  const LocalMusicTrack({
    required this.uri,
    required this.title,
    this.sourceUri,
    this.documentIdentity,
    this.artist,
    this.album,
    this.albumArtist,
    this.titleSort,
    this.artistSort,
    this.albumSort,
    this.albumArtistSort,
    this.genre,
    this.replayGain,
    this.albumKey,
    this.discNumber,
    this.trackNumber,
    this.releaseDate,
    this.originalReleaseDate,
    this.durationMs = 0,
    this.sizeBytes,
    this.cueStartUs,
    this.cueEndUs,
    this.artPath,
    this.adjacentArtPath,
    this.fileName,
    this.sizeBytes,
    this.dateAdded,
    this.dateModified,
    this.firstSeen = false,
    this.canRename = false,
    this.isRecording = false,
    this.folderLocations = const [],
    this.visibilityKey,
    this.documentVisibilityKey,
    String? identityUri,
    String? identityKey,
  })  : _identityUri = identityUri,
        _identityKey = identityKey;

  String get playbackId =>
      'device:${_identityKey ?? sha256.convert(utf8.encode(_identityUri ?? uri))}';

  bool get isCueTrack => cueStartUs != null;

  static LocalMusicTrack? fromDocument(dynamic value, Uri source) {
    if (value is! Map) return null;
    final uri = value['uri'];
    final title = value['title'];
    if (uri is! String || title is! String || title.trim().isEmpty) return null;
    if (!_isSourceTrack(uri, source)) return null;
    final identityUri = value['identityUri'];
    if (identityUri != null &&
        (identityUri is! String || !_isSourceTrack(identityUri, source))) {
      return null;
    }
    final identityKey = value['identityKey'];
    if (identityKey != null &&
        (identityKey is! String || !_identityPattern.hasMatch(identityKey))) {
      return null;
    }
    final cueStart = value['cueStartUs'];
    final cueEnd = value['cueEndUs'];
    if (cueStart != null || cueEnd != null) {
      if (source == systemSource ||
          identityKey == null ||
          cueStart is! int ||
          cueStart < 0 ||
          (cueEnd != null && (cueEnd is! int || cueEnd <= cueStart))) {
        return null;
      }
    }
    final duration = value['durationMs'];
    final size = value['sizeBytes'];
    final art = value['artPath'];
    final adjacentArt = value['adjacentArtPath'];
    final name = value['fileName'];
    final size = value['sizeBytes'];
    final albumKey = value['albumKey'];
    final genre = value['genre'];
    final visibilityKey = value['visibilityKey'];
    final validVisibilityKey =
        visibilityKey is String && _identityPattern.hasMatch(visibilityKey)
            ? visibilityKey
            : null;
    final documentIdentity = source == systemSource || cueStart != null
        ? null
        : (source.authority, Uri.parse(uri).pathSegments.last);
    return LocalMusicTrack(
      uri: uri,
      sourceUri: source,
      documentIdentity: documentIdentity,
      title: title,
      artist: value['artist'] is String ? value['artist'] as String : null,
      album: value['album'] is String ? value['album'] as String : null,
      albumArtist: value['albumArtist'] is String
          ? value['albumArtist'] as String
          : null,
      titleSort: _sortTag(value['titleSort']),
      artistSort: _sortTag(value['artistSort']),
      albumSort: _sortTag(value['albumSort']),
      albumArtistSort: _sortTag(value['albumArtistSort']),
      genre: genre is String &&
              genre.trim().isNotEmpty &&
              genre.trim().toLowerCase() != '<unknown>'
          ? genre.trim()
          : null,
      replayGain: _parseReplayGain(value['replayGain']),
      albumKey: albumKey is String && _identityPattern.hasMatch(albumKey)
          ? albumKey
          : null,
      discNumber: _albumPosition(value['discNumber']),
      trackNumber: _albumPosition(value['trackNumber']),
      releaseDate: _releaseDate(value['releaseDate']),
      originalReleaseDate: _releaseDate(value['originalReleaseDate']),
      durationMs: duration is int && duration > 0 ? duration : 0,
      sizeBytes: cueStart == null && size is int && size >= 0 ? size : null,
      cueStartUs: cueStart as int?,
      cueEndUs: cueEnd as int?,
      artPath: art is String && art.startsWith('/') ? art : null,
      adjacentArtPath: adjacentArt is String &&
              adjacentArt.startsWith('/') &&
              !adjacentArt.startsWith('//')
          ? adjacentArt
          : null,
      fileName: name is String && name.isNotEmpty ? name : null,
      sizeBytes: size is int && size > 0 ? size : null,
      dateAdded: _date(value['addedMs']),
      dateModified: _date(value['modifiedMs']),
      firstSeen: value['firstSeen'] == true,
      canRename: cueStart == null && value['canRename'] == true,
      isRecording: source == systemSource && value['isRecording'] == true,
      folderLocations: _parseFolderLocations(value['folderLocations']),
      visibilityKey: validVisibilityKey,
      documentVisibilityKey: documentIdentity == null
          ? null
          : _documentVisibilityKey(uri, documentIdentity, value['modifiedMs'],
              value['sizeBytes'], validVisibilityKey),
      identityUri: identityUri as String?,
      identityKey: identityKey as String?,
    );
  }

  static String? _documentVisibilityKey(String uri, (String, String) identity,
      Object? modified, Object? size, String? key) {
    if (key == null ||
        modified is! int ||
        modified <= 0 ||
        size is! int ||
        size <= 0) {
      return null;
    }
    String fingerprint(List<String> parts) => sha256
        .convert(
            utf8.encode(parts.map((part) => '${part.length}:$part').join()))
        .toString();
    // A rename alias or protected reused URI has stronger native verification
    // than directory metadata alone. Keep its original scoped proof.
    if (key != fingerprint(['document', uri, '$modified', '$size'])) {
      return null;
    }
    return fingerprint([
      'document-across-music-locations',
      identity.$1,
      identity.$2,
      '$modified',
      '$size',
    ]);
  }

  static ReplayGain? _parseReplayGain(Object? value) {
    if (value is! Map) return null;
    double? number(Object? field, {bool peak = false}) {
      if (field is! num || !field.isFinite || (peak && field <= 0)) return null;
      return field.toDouble();
    }

    final trackGain = number(value['trackGainDb']);
    final albumGain = number(value['albumGainDb']);
    final trackPeak = number(value['trackPeak'], peak: true);
    final albumPeak = number(value['albumPeak'], peak: true);
    if (trackGain == null &&
        albumGain == null &&
        trackPeak == null &&
        albumPeak == null) {
      return null;
    }
    return ReplayGain(
      trackGainDb: trackGain,
      albumGainDb: albumGain,
      trackPeak: trackPeak,
      albumPeak: albumPeak,
    );
  }

  static DateTime? _date(Object? value) =>
      value is int && value > 0 && value <= 8640000000000000
          ? DateTime.fromMillisecondsSinceEpoch(value)
          : null;

  static int? _albumPosition(Object? value) =>
      value is int && value > 0 && value <= 0xffff ? value : null;

  static final _releaseDatePattern = RegExp(r'^\d{4}(?:-\d{2}(?:-\d{2})?)?$');

  static String? _releaseDate(Object? value) {
    if (value is! String || _releaseDatePattern.stringMatch(value) != value) {
      return null;
    }
    final parts = value.split('-').map(int.parse).toList();
    final year = parts[0];
    final month = parts.length > 1 ? parts[1] : 1;
    final day = parts.length > 2 ? parts[2] : 1;
    if (year == 0 || month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    return DateTime.utc(year, month, day).month == month ? value : null;
  }

  static String? _sortTag(Object? value) {
    if (value is! String ||
        value.length > 1024 ||
        _metadataControls.hasMatch(value)) {
      return null;
    }
    final tag = value.trim();
    return tag.isEmpty || tag.toLowerCase() == '<unknown>' ? null : tag;
  }

  static List<LocalMusicFolderLocation> _parseFolderLocations(Object? value) {
    if (value is! List || value.isEmpty || value.length > 64) return const [];
    final folders = <LocalMusicFolderLocation>[];
    final seen = <String>{};
    for (final item in value) {
      if (item is! Map || item['key'] is! String || item['label'] is! String) {
        return const [];
      }
      final key = item['key'] as String;
      final label = item['label'] as String;
      if (_identityPattern.stringMatch(key) != key ||
          !seen.add(key) ||
          label.isEmpty ||
          label.length > 1024 ||
          _metadataControls.hasMatch(label) ||
          !label.split(' / ').every(_validFolderLabelPart)) {
        return const [];
      }
      folders.add(LocalMusicFolderLocation(key, label));
    }
    return List.unmodifiable(folders);
  }

  static bool _validFolderLabelPart(String part) =>
      part.isNotEmpty &&
      part.trim() == part &&
      part != '.' &&
      part != '..' &&
      part.toLowerCase() != '<unknown>' &&
      !part.contains('/') &&
      !part.contains(r'\');

  static bool _isSourceTrack(String uri, Uri source) {
    final document = Uri.tryParse(uri);
    if (document == null ||
        document.scheme != 'content' ||
        document.hasQuery ||
        document.hasFragment) {
      return false;
    }
    final parts = document.pathSegments;
    if (source == systemSource) {
      return document.authority == 'media' &&
          parts.length == 4 &&
          parts[0] != 'internal' &&
          _volumePattern.hasMatch(parts[0]) &&
          parts[1] == 'audio' &&
          parts[2] == 'media' &&
          _rowPattern.hasMatch(parts[3]);
    }
    return document.authority == source.authority &&
        source.pathSegments.length == 2 &&
        parts.length == 4 &&
        parts[0] == 'tree' &&
        parts[1] == source.pathSegments[1] &&
        parts[2] == 'document' &&
        parts[3].isNotEmpty;
  }
}
