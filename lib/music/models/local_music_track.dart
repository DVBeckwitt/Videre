import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Metadata for a track from the selected Android music source.
class LocalMusicTrack {
  static final systemSource = Uri.parse('content://media/external/audio/media');
  static final _identityPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _volumePattern = RegExp(r'^[a-zA-Z0-9_-]+$');
  static final _rowPattern = RegExp(r'^[0-9]+$');

  final String uri;
  final String title;
  final String? artist;
  final String? album;
  final int durationMs;
  final String? artPath;
  final String? fileName;
  final DateTime? dateAdded;
  final DateTime? dateModified;
  final bool firstSeen;
  final bool canRename;
  final String? _identityUri;
  final String? _identityKey;

  const LocalMusicTrack({
    required this.uri,
    required this.title,
    this.artist,
    this.album,
    this.durationMs = 0,
    this.artPath,
    this.fileName,
    this.dateAdded,
    this.dateModified,
    this.firstSeen = false,
    this.canRename = false,
    String? identityUri,
    String? identityKey,
  })  : _identityUri = identityUri,
        _identityKey = identityKey;

  String get playbackId =>
      'device:${_identityKey ?? sha256.convert(utf8.encode(_identityUri ?? uri))}';

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
    final duration = value['durationMs'];
    final art = value['artPath'];
    final name = value['fileName'];
    return LocalMusicTrack(
      uri: uri,
      title: title,
      artist: value['artist'] is String ? value['artist'] as String : null,
      album: value['album'] is String ? value['album'] as String : null,
      durationMs: duration is int && duration > 0 ? duration : 0,
      artPath: art is String && art.startsWith('/') ? art : null,
      fileName: name is String && name.isNotEmpty ? name : null,
      dateAdded: _date(value['addedMs']),
      dateModified: _date(value['modifiedMs']),
      firstSeen: value['firstSeen'] == true,
      canRename: value['canRename'] == true,
      identityUri: identityUri as String?,
      identityKey: identityKey as String?,
    );
  }

  static DateTime? _date(Object? value) =>
      value is int && value > 0 && value <= 8640000000000000
          ? DateTime.fromMillisecondsSinceEpoch(value)
          : null;

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
