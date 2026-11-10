import 'dart:convert';

import '../../utils/invidious_image.dart';
import '../../utils/models/image_object.dart';
import '../../videos/models/video.dart';
import 'playlist.dart';
import 'playlist_reference.dart';

const playlistLibraryMaximumEntries = 10000;
const playlistLibraryMaximumBytes = 5 * 1024 * 1024;

/// A bookmark of an existing playlist, never an editable copy or media cache.
class SavedPlaylist {
  final PlaylistReference reference;
  final String title;
  final String author;
  final int videoCount;
  final List<Video> previews;

  const SavedPlaylist({
    required this.reference,
    required this.title,
    this.author = '',
    required this.videoCount,
    this.previews = const [],
  });

  factory SavedPlaylist.fromPlaylist(
      Playlist playlist, PlaylistReference reference) {
    if (playlist.playlistId != reference.playlistId) {
      throw ArgumentError('The playlist does not match its source');
    }
    final saved = tryParse(SavedPlaylist(
            reference: reference,
            title: playlist.title,
            author: playlist.author,
            videoCount: playlist.videoCount,
            previews: playlist.videos
                .where((video) => !video.filtered)
                .take(4)
                .toList())
        .toJson());
    if (saved == null) throw ArgumentError('Invalid playlist bookmark');
    return saved;
  }

  Playlist toPlaylist() => Playlist(
        playlistId: reference.playlistId,
        type: reference.kind == PlaylistSourceKind.account
            ? invidiousPlaylist
            : youtubePlaylist,
        title: title,
        author: author,
        videoCount: videoCount,
        videos: previews,
      );

  Map<String, dynamic> toJson() => {
        'reference': reference.toJson(),
        'title': title,
        'author': author,
        'videoCount': videoCount,
        'previews': previews
            .map((video) => {
                  'videoId': video.videoId,
                  'title': video.title,
                  'author': video.author,
                  'lengthSeconds': video.lengthSeconds,
                  'videoThumbnails': video.videoThumbnails
                      .map((image) => image.toJson())
                      .toList(),
                })
            .toList(),
      };

  /// Storage and backups use the same bounded, profile-owned view. A later
  /// duplicate updates metadata without moving the original entry's position.
  static List<SavedPlaylist> decodeLibrary(String? value, String profileId) {
    if (value == null ||
        utf8.encode(value).length > playlistLibraryMaximumBytes) {
      return const [];
    }
    try {
      final data = jsonDecode(value);
      if (data is! Map || data['version'] != 1 || data['entries'] is! List) {
        return const [];
      }
      final unique = <String, SavedPlaylist>{};
      for (final row
          in (data['entries'] as List).take(playlistLibraryMaximumEntries)) {
        final entry = tryParse(row);
        if (entry != null && entry.reference.profileId == profileId) {
          unique[entry.reference.key] = entry;
        }
      }
      return List.unmodifiable(unique.values);
    } on FormatException {
      return const [];
    }
  }

  /// Damaged rows are ignored individually. Only display metadata is retained.
  static SavedPlaylist? tryParse(Object? value) {
    if (value is! Map) return null;
    final reference = PlaylistReference.tryParse(value['reference']);
    final title = _text(value['title']);
    final count = value['videoCount'];
    if (reference == null ||
        reference.kind == PlaylistSourceKind.local ||
        title == null ||
        count is! int ||
        count < 0 ||
        count > 1000000) {
      return null;
    }
    final previews = value['previews'];
    return SavedPlaylist(
      reference: reference,
      title: title,
      author: _text(value['author']) ?? '',
      videoCount: count,
      previews: [
        if (previews is List)
          for (final entry in previews.take(4))
            if (_video(entry) case final video?) video,
      ],
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final text = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return text.isEmpty ? null : String.fromCharCodes(text.runes.take(1024));
  }

  static Video? _video(Object? value) {
    if (value is! Map) return null;
    final id = value['videoId'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      return null;
    }
    final duration = value['lengthSeconds'];
    final images = value['videoThumbnails'];
    return Video(
      videoId: id,
      title: _text(value['title']) ?? '',
      author: _text(value['author']) ?? '',
      lengthSeconds: duration is int && duration >= 0 && duration <= 604800
          ? duration
          : null,
      videoThumbnails: [
        if (images is List)
          for (final entry in images.take(4))
            if (_image(entry) case final image?) image,
      ],
    );
  }

  static ImageObject? _image(Object? value) {
    if (value is! Map || value['url'] is! String) return null;
    final url = value['url'] as String;
    final uri = Uri.tryParse(url);
    if (url.length > 2048 ||
        uri == null ||
        uri.userInfo.isNotEmpty ||
        (!isInvidiousThumbnailUrl(url) &&
            (uri.scheme != 'https' || uri.host.isEmpty)) ||
        (uri.hasScheme && !['http', 'https'].contains(uri.scheme))) {
      return null;
    }
    int size(Object? value) =>
        value is int && value >= 0 && value <= 16384 ? value : 0;
    return ImageObject(
        null,
        Uri(
                scheme: uri.hasScheme ? uri.scheme : null,
                host: uri.hasAuthority ? uri.host : null,
                port: uri.hasPort ? uri.port : null,
                path: uri.path)
            .toString(),
        size(value['width']),
        size(value['height']));
  }
}
