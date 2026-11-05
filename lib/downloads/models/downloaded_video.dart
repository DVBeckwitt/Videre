import 'dart:io';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'downloaded_video.freezed.dart';

part 'downloaded_video.g.dart';

const String _downloadFolder = 'downloads';

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
      @Default(false) bool downloadComplete,
      @Default(false) bool downloadFailed,
      @Default(false) bool authenticationRequired,
      @Default(false) bool storageFailed,
      String? folderUri,
      String? storageUri,
      @Default(false) bool audioOnly,
      DownloadContainer? container,
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

  String get extension =>
      (container ?? DownloadContainer.webm).extension(audioOnly);

  String get mimeType =>
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
    final shortened = String.fromCharCodes(name.runes.take(50));
    return '${shortened.isEmpty ? id : shortened}_$id.$extension';
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  Future<String> get thumbnailPath => _privatePath('jpg');

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
