import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/song_artwork.dart';
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
  final List<MusicArtistCredit> artistCredits;
  final String? album;
  final String? albumPlaylistId;
  final int? durationSeconds;
  final List<ImageObject> thumbnails;
  final bool usesVideoThumbnails;
  final bool isArtTrack;

  List<ImageObject> get coverThumbnails =>
      kind == MusicLibraryKind.song && !usesVideoThumbnails
          ? songCovers(thumbnails)
          : const [];

  List<ImageObject> get displayThumbnails => kind != MusicLibraryKind.song
      ? thumbnails
      : displaySongThumbnails(
          id, usesVideoThumbnails ? const [] : thumbnails, thumbnails,
          artTrack: isArtTrack);

  const MusicLibraryEntry({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.artistCredits = const [],
    this.album,
    this.albumPlaylistId,
    this.durationSeconds,
    this.thumbnails = const [],
    this.usesVideoThumbnails = false,
    this.isArtTrack = false,
  });

  factory MusicLibraryEntry.song(Video video) {
    final metadata = video.musicMetadata;
    if (metadata == null) throw ArgumentError('A music song is required');
    final instanceUrl =
        (video.playbackConnection ?? video.backendPlayback)?.server.url;
    final covers = songCovers(metadata.thumbnails);
    final frames = stockSongThumbnails(video.videoId, video.videoThumbnails,
        artTrack: metadata.isArtTrack, instanceUrl: instanceUrl);
    final useFrames =
        metadata.thumbnails.isEmpty || (covers.isEmpty && frames.isNotEmpty);
    final List<ImageObject> images;
    if (covers.isNotEmpty && frames.isNotEmpty) {
      // Bookmarks retain eight images. Reserve one slot for a supplied frame
      // in case none of the catalog cover renditions can be loaded later.
      final frame = metadata.isArtTrack
          ? frames.first
          : ImageObject.getBestThumbnail(frames)!;
      images = [...covers.take(7), frame];
    } else if (useFrames) {
      images = instanceUrl == null ? video.videoThumbnails : frames;
    } else {
      images = metadata.thumbnails;
    }
    return MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: video.videoId,
        title: metadata.title,
        subtitle: metadata.artist,
        artistCredits: metadata.artistCredits,
        album: metadata.album,
        albumPlaylistId: metadata.albumPlaylistId,
        durationSeconds: video.lengthSeconds,
        isArtTrack: metadata.isArtTrack,
        usesVideoThumbnails: useFrames,
        thumbnails: images);
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
    final covers = coverThumbnails;
    final frames = covers.isEmpty
        ? const <ImageObject>[]
        : stockSongThumbnails(id, thumbnails, artTrack: isArtTrack);
    return Video(
        videoId: id,
        title: title,
        author: subtitle,
        lengthSeconds: durationSeconds,
        videoThumbnails: frames.isNotEmpty ? frames : thumbnails,
        musicMetadata: MusicMetadata(
            title: title,
            artist: subtitle,
            artistCredits: artistCredits,
            album: album,
            albumPlaylistId: albumPlaylistId,
            thumbnails: covers,
            isArtTrack: isArtTrack));
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'id': id,
        'title': title,
        'subtitle': subtitle,
        if (artistCredits.isNotEmpty && kind == MusicLibraryKind.song)
          'artistCredits':
              artistCredits.map((credit) => credit.toJson()).toList(),
        if (album != null) 'album': album,
        if (kind == MusicLibraryKind.song &&
            validMusicAlbumPlaylistId(albumPlaylistId) != null)
          'albumPlaylistId': albumPlaylistId,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        'thumbnails': thumbnails.map((image) => image.toJson()).toList(),
        if (usesVideoThumbnails) 'usesVideoThumbnails': true,
        if (isArtTrack && kind == MusicLibraryKind.song) 'isArtTrack': true,
      };

  bool get needsSongDetails =>
      kind == MusicLibraryKind.song &&
      _songId.stringMatch(id) == id &&
      (title == id || subtitle.isEmpty || thumbnails.isEmpty);

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _songId = RegExp(r'^[A-Za-z0-9_-]{11}$');

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
    final thumbnails = [
      if (images is List)
        for (final image in images.take(8))
          if (_image(image) case final image?) image,
    ];
    final usesVideoThumbnails = kind == MusicLibraryKind.song &&
        (value['usesVideoThumbnails'] is bool
            ? value['usesVideoThumbnails'] as bool
            : thumbnails.any((image) => isInvidiousThumbnailUrl(image.url)) &&
                songCovers(thumbnails).isEmpty);
    return MusicLibraryEntry(
        kind: kind,
        id: id,
        title: title,
        subtitle: _text(value['subtitle']) ?? '',
        artistCredits: kind == MusicLibraryKind.song
            ? MusicArtistCredit.parseList(value['artistCredits'])
            : const [],
        album: _text(value['album']),
        albumPlaylistId: kind == MusicLibraryKind.song
            ? validMusicAlbumPlaylistId(value['albumPlaylistId'])
            : null,
        durationSeconds: duration is int && duration >= 0 && duration <= 604800
            ? duration
            : null,
        usesVideoThumbnails: usesVideoThumbnails,
        isArtTrack:
            kind == MusicLibraryKind.song && value['isArtTrack'] == true,
        thumbnails: thumbnails);
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return clean.isEmpty ? null : String.fromCharCodes(clean.runes.take(1024));
  }

  static ImageObject? _image(Object? value) {
    if (value is! Map || value['url'] is! String) return null;
    final url = value['url'] as String;
    final uri = Uri.tryParse(url);
    // Invidious catalog artists and playlists also supply instance image
    // paths. Their bookmark kind must not discard otherwise valid artwork.
    final instanceFallback = isInvidiousThumbnailUrl(url) &&
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
