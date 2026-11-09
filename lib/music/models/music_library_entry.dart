import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';

enum MusicLibraryKind { song, album, artist, playlist }

const musicLibraryMaximumBytes = 5 * 1024 * 1024;
const musicLibraryMaximumEntries = 10000;

/// Display metadata and public catalog identities, never playback responses.
class MusicLibraryEntry {
  final MusicLibraryKind kind;
  final String id;
  final String title;
  final String subtitle;
  final String? album;
  final int? durationSeconds;
  final List<ImageObject> thumbnails;
  final bool usesVideoThumbnails;

  const MusicLibraryEntry({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.album,
    this.durationSeconds,
    this.thumbnails = const [],
    this.usesVideoThumbnails = false,
  });

  factory MusicLibraryEntry.song(Video video) {
    final metadata = video.musicMetadata;
    if (metadata == null) throw ArgumentError('A music song is required');
    return MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: video.videoId,
        title: metadata.title,
        subtitle: metadata.artist,
        album: metadata.album,
        durationSeconds: video.lengthSeconds,
        usesVideoThumbnails: metadata.thumbnails.isEmpty,
        thumbnails: metadata.thumbnails.isEmpty
            ? video.videoThumbnails
            : metadata.thumbnails);
  }

  factory MusicLibraryEntry.collection(MusicCollection collection,
          {required bool album}) =>
      MusicLibraryEntry(
          kind: album ? MusicLibraryKind.album : MusicLibraryKind.playlist,
          id: collection.id,
          title: collection.title,
          subtitle: collection.artists.join(', '),
          thumbnails: collection.thumbnails);

  factory MusicLibraryEntry.artist(MusicArtist artist) => MusicLibraryEntry(
      kind: MusicLibraryKind.artist,
      id: artist.id,
      title: artist.name,
      thumbnails: artist.thumbnails);

  Video toVideo() {
    if (kind != MusicLibraryKind.song) {
      throw StateError('Only songs can be played directly');
    }
    return Video(
        videoId: id,
        title: title,
        author: subtitle,
        lengthSeconds: durationSeconds,
        videoThumbnails: thumbnails,
        musicMetadata: MusicMetadata(
            title: title,
            artist: subtitle,
            album: album,
            thumbnails: usesVideoThumbnails ? const [] : thumbnails));
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'id': id,
        'title': title,
        'subtitle': subtitle,
        if (album != null) 'album': album,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        'thumbnails': thumbnails.map((image) => image.toJson()).toList(),
        if (usesVideoThumbnails) 'usesVideoThumbnails': true,
      };

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Skip malformed rows individually so one damaged bookmark cannot hide the
  /// rest of a person's library. Copy only the explicitly supported fields.
  static MusicLibraryEntry? tryParse(Object? value) {
    if (value is! Map) return null;
    final kind = MusicLibraryKind.values
        .where((kind) => kind.name == value['kind'])
        .firstOrNull;
    final id = value['id'];
    final title = _text(value['title']);
    if (kind == null ||
        id is! String ||
        _id.stringMatch(id) != id ||
        title == null) {
      return null;
    }
    final duration = value['durationSeconds'];
    final images = value['thumbnails'];
    final usesVideoThumbnails = kind == MusicLibraryKind.song &&
        (value['usesVideoThumbnails'] is bool
            ? value['usesVideoThumbnails'] as bool
            : images is List &&
                images.take(8).whereType<Map>().any((image) =>
                    image['url'] is String &&
                    isInvidiousThumbnailUrl(image['url'] as String)));
    return MusicLibraryEntry(
        kind: kind,
        id: id,
        title: title,
        subtitle: _text(value['subtitle']) ?? '',
        album: _text(value['album']),
        durationSeconds: duration is int && duration >= 0 && duration <= 604800
            ? duration
            : null,
        usesVideoThumbnails: usesVideoThumbnails,
        thumbnails: [
          if (images is List)
            for (final image in images.take(8))
              if (_image(image, usesVideoThumbnails: usesVideoThumbnails)
                  case final image?)
                image,
        ]);
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return clean.isEmpty ? null : String.fromCharCodes(clean.runes.take(1024));
  }

  static ImageObject? _image(Object? value,
      {required bool usesVideoThumbnails}) {
    if (value is! Map || value['url'] is! String) return null;
    final url = value['url'] as String;
    final uri = Uri.tryParse(url);
    final instanceFallback = usesVideoThumbnails &&
        isInvidiousThumbnailUrl(url) &&
        uri != null &&
        ((!uri.hasScheme && !uri.hasAuthority) ||
            (uri.scheme == 'http' && uri.host.isNotEmpty));
    if (url.length > 2048 ||
        uri == null ||
        (!instanceFallback && (uri.scheme != 'https' || uri.host.isEmpty)) ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    // Art does not need request credentials, signed query strings, or fragments.
    final clean = Uri(
            scheme: uri.hasScheme ? uri.scheme : null,
            host: uri.hasAuthority ? uri.host : null,
            port: uri.hasPort ? uri.port : null,
            path: uri.path)
        .toString();
    int size(Object? value) =>
        value is int && value >= 0 && value <= 16384 ? value : 0;
    return ImageObject(
        null, clean, size(value['width']), size(value['height']));
  }
}
