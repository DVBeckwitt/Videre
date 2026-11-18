import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Metadata for an audio document found under the user's selected Android tree.
class LocalMusicTrack {
  final String uri;
  final String title;
  final String? artist;
  final String? album;
  final int durationMs;
  final String? artPath;

  const LocalMusicTrack({
    required this.uri,
    required this.title,
    this.artist,
    this.album,
    this.durationMs = 0,
    this.artPath,
  });

  String get playbackId => 'device:${sha256.convert(utf8.encode(uri))}';

  static LocalMusicTrack? fromDocument(dynamic value, Uri tree) {
    if (value is! Map) return null;
    final uri = value['uri'];
    final title = value['title'];
    if (uri is! String || title is! String || title.trim().isEmpty) return null;
    final document = Uri.tryParse(uri);
    if (document == null ||
        document.scheme != 'content' ||
        document.authority != tree.authority ||
        document.hasQuery ||
        document.hasFragment) {
      return null;
    }
    final parts = document.pathSegments;
    if (parts.length != 4 ||
        parts[0] != 'tree' ||
        parts[1] != tree.pathSegments[1] ||
        parts[2] != 'document' ||
        parts[3].isEmpty) {
      return null;
    }
    final duration = value['durationMs'];
    final art = value['artPath'];
    return LocalMusicTrack(
      uri: uri,
      title: title,
      artist: value['artist'] is String ? value['artist'] as String : null,
      album: value['album'] is String ? value['album'] as String : null,
      durationMs: duration is int && duration > 0 ? duration : 0,
      artPath: art is String && art.startsWith('/') ? art : null,
    );
  }
}
