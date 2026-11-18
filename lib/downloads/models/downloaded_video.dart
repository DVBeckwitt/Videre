import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' show sha256;

part 'downloaded_video.freezed.dart';

part 'downloaded_video.g.dart';

const String _downloadFolder = 'downloads';

class _PlaybackProvenanceConverter
    implements JsonConverter<DownloadPlaybackProvenance?, Object?> {
  const _PlaybackProvenanceConverter();

  @override
  DownloadPlaybackProvenance? fromJson(Object? json) =>
      DownloadPlaybackProvenance.tryFromJson(json);

  @override
  Object? toJson(DownloadPlaybackProvenance? value) => value?.toJson();
}

class _MusicMetadataConverter
    implements JsonConverter<MusicMetadata?, Map<String, dynamic>?> {
  const _MusicMetadataConverter();

  @override
  MusicMetadata? fromJson(Map<String, dynamic>? json) =>
      json == null ? null : MusicMetadata.fromJson(json);

  @override
  Map<String, dynamic>? toJson(MusicMetadata? metadata) => metadata?.toJson();
}

class _SponsorSegmentConverter
    implements JsonConverter<SponsorSegment, Map<String, dynamic>> {
  const _SponsorSegmentConverter();

  @override
  SponsorSegment fromJson(Map<String, dynamic> json) =>
      SponsorSegment.fromJson(json);

  @override
  Map<String, dynamic> toJson(SponsorSegment segment) => segment.toJson();
}

/// Remembers the owned destination across retries. A finished exported copy
/// belongs to the user independently of the original Videre download.
@JsonSerializable()
class ExportedMusicCopy {
  final String folder;
  final String uri;
  final MusicDownloadFormat format;
  final bool complete;
  const ExportedMusicCopy(this.folder, this.uri, this.format,
      {this.complete = false});
  factory ExportedMusicCopy.fromJson(Map<String, dynamic> json) =>
      _$ExportedMusicCopyFromJson(json);
  Map<String, dynamic> toJson() => _$ExportedMusicCopyToJson(this);

  @override
  bool operator ==(Object other) =>
      other is ExportedMusicCopy &&
      folder == other.folder &&
      uri == other.uri &&
      format == other.format &&
      complete == other.complete;

  @override
  int get hashCode => Object.hash(folder, uri, format, complete);
}

class _MusicCopyConverter
    implements JsonConverter<ExportedMusicCopy?, Map<String, dynamic>?> {
  const _MusicCopyConverter();
  @override
  ExportedMusicCopy? fromJson(Map<String, dynamic>? value) =>
      value == null ? null : ExportedMusicCopy.fromJson(value);
  @override
  Map<String, dynamic>? toJson(ExportedMusicCopy? copy) => copy?.toJson();
}

@freezed
sealed class DownloadedVideo with _$DownloadedVideo implements IdedVideo {
  @Implements<IdedVideo>()
  const factory DownloadedVideo(
      {required String videoId,
      required String title,
      @Default('default') String profileId,
      String? accountId,
      String? author,
      String? authorUrl,
      @_MusicMetadataConverter() MusicMetadata? musicMetadata,
      @_SponsorSegmentConverter()
      @Default([])
      List<SponsorSegment> sponsorSegments,
      @Default(false) bool downloadComplete,
      @Default(false) bool downloadFailed,
      @Default(false) bool authenticationRequired,
      @Default(false) bool storageFailed,
      String? folderUri,
      String? storageUri,
      @_PlaybackProvenanceConverter()
      DownloadPlaybackProvenance? playbackProvenance,
      @Default(false) bool audioOnly,
      MusicDownloadFormat? musicFormat,
      @_MusicCopyConverter() ExportedMusicCopy? exportedMusic,
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel,
      required int lengthSeconds,
      required String quality}) = _DownloadedVideo;

  const DownloadedVideo._();

  factory DownloadedVideo.fromJson(Map<String, Object?> json) =>
      _$DownloadedVideoFromJson(json);

  static final _fileIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Remote identifiers must remain a single bounded filesystem component.
  static bool isSafeFileId(String value) =>
      _fileIdPattern.stringMatch(value) == value;

  String get _fileId {
    if (!isSafeFileId(videoId)) {
      throw const FormatException('Invalid download video ID');
    }
    return videoId;
  }

  Future<String> _privatePath(String extension) async {
    final id = _fileId;
    final dir = await _getDownloadFolder();
    return p.join(dir.path, '$id.$extension');
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  Future<String> get downloadPath => _privatePath(extension);

  // Keep the existing prefix so interrupted jobs can resume after upgrading.
  Future<String> get stagingPath => _privatePath('webm');

  bool get storeAsMusic => audioOnly && musicFormat != null;

  String get extension =>
      (audioOnly ? musicFormat?.extension : null) ??
      (container ?? DownloadContainer.webm).extension(audioOnly);

  String get mimeType =>
      (audioOnly ? musicFormat?.mimeType : null) ??
      (container ?? DownloadContainer.webm).mimeType(audioOnly);

  /// Older video downloads can have an MP4 file without a saved container.
  @JsonKey(includeFromJson: false, includeToJson: false)
  Future<String> get effectivePath async {
    if (storageUri != null) return storageUri!;
    final path = await downloadPath;
    if (container == null && !audioOnly && !await File(path).exists()) {
      return _privatePath('mp4');
    }
    return path;
  }

  String get fileName {
    final id = _fileId;
    final name = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    // Android omits dotfiles from its audio index, including in SAF folders.
    final visibleName =
        storeAsMusic ? name.replaceFirst(RegExp(r'^[.\s]+'), '') : name;
    final shortened = String.fromCharCodes(visibleName.runes.take(50));
    return '${shortened.isEmpty ? id : shortened}_$id.$extension';
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  Future<String> get thumbnailPath => _privatePath('jpg');

  /// Music artwork is private to the download. A stock poster uses a separate
  /// filename so it can never satisfy a verified catalog cover lookup.
  Future<Directory> get songCoverDirectory async =>
      Directory(await _privatePath('song-covers'));

  String? get songCoverUrl => ImageObject.getBestThumbnail(
          songCovers(musicMetadata?.thumbnails ?? const []))
      ?.url;

  Future<File?> get songCoverFile async {
    final cover = songCoverUrl;
    if (cover == null || accountId == null) return null;
    final key = sha256.convert(utf8.encode(jsonEncode([accountId, cover])));
    final directory = await songCoverDirectory;
    return File(p.join(directory.path, '$key.jpg'));
  }

  Future<File?> get stockSongPosterFile async {
    if (musicMetadata == null || accountId == null) return null;
    final key = sha256.convert(utf8.encode(accountId!));
    final directory = await songCoverDirectory;
    return File(p.join(directory.path, 'stock-$key.jpg'));
  }

  Future<File?> get existingSongCover =>
      _existingSongArtwork(allowPoster: false);

  Future<File?> get existingSongArtwork =>
      _existingSongArtwork(allowPoster: true);

  Future<File?> _existingSongArtwork({required bool allowPoster}) async {
    if (!downloadComplete ||
        downloadFailed ||
        storageFailed ||
        authenticationRequired) {
      return null;
    }
    try {
      final cover = await songCoverFile;
      if (cover != null && await cover.exists()) return cover;
      if (!allowPoster) return null;
      final poster = await stockSongPosterFile;
      return poster != null && await poster.exists() ? poster : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Retained captions let the Flutter player show subtitles while offline.
  @JsonKey(includeFromJson: false, includeToJson: false)
  Future<String> get subtitlePath => _privatePath('vtt');

  Future<Directory> _getDownloadFolder() async {
    Directory dir = await getApplicationDocumentsDirectory();
    if (!isSafeFileId(profileId)) {
      throw const FormatException('Invalid download profile ID');
    }
    // The original person's files retain their historical locations. Other
    // people get private staging and media paths even for the same video ID.
    dir = Directory(profileId == 'default'
        ? p.join(dir.path, _downloadFolder)
        : p.join(dir.path, _downloadFolder, 'profiles', profileId));
    if (!(await dir.exists())) {
      await dir.create(recursive: true);
    }

    return dir;
  }
}
