import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../utils/interfaces/db.dart';
import '../models/downloaded_video.dart';

final _downloadHash = RegExp(r'^[a-f0-9]{64}$');
final _fileFingerprint = RegExp(r'^v2:([a-f0-9]{64}):([a-f0-9]{64})$');

/// Pin the file's owner and rendition without putting storage locations or
/// connection details in a playback session.
String musicDownloadFingerprint(DownloadedVideo file) => sha256
    .convert(utf8.encode(jsonEncode([
      file.profileId,
      file.accountId,
      file.videoId,
      file.folderUri,
      file.storageUri,
      file.audioOnly,
      file.musicFormat?.name,
      file.container?.name,
      file.quality,
      file.audioTrackId,
      file.playbackProvenance?.toJson(),
    ])))
    .toString();

/// The device browser also pins the native proof for the file it listed.
String? musicDownloadFileFingerprint(DownloadedVideo file, String proof) =>
    _downloadHash.stringMatch(proof) == proof
        ? 'v2:${musicDownloadFingerprint(file)}:$proof'
        : null;

RegExpMatch? _matchFileFingerprint(String value) {
  final match = _fileFingerprint.firstMatch(value);
  return match?.group(0) == value ? match : null;
}

String? _downloadMetadataFingerprint(String value) =>
    _downloadHash.stringMatch(value) == value
        ? value
        : _matchFileFingerprint(value)?.group(1);

bool isValidOfflineMusicFingerprint(Object? value) =>
    value is String && _downloadMetadataFingerprint(value) != null;

String? pinnedMusicDownloadFileProof(String value) =>
    _matchFileFingerprint(value)?.group(2);

DownloadedVideo? readyMusicDownload(IDbClient database, String id,
    {String? fingerprint}) {
  if (!DownloadedVideo.isSafeFileId(id)) return null;
  final DownloadedVideo? file;
  try {
    file = database.getDownloadByVideoId(id);
  } catch (_) {
    return null;
  }
  if (file == null ||
      file.videoId != id ||
      file.profileId != database.profileId ||
      !file.audioOnly ||
      file.musicMetadata?.title.trim().isNotEmpty != true ||
      !file.downloadComplete ||
      file.downloadFailed ||
      file.storageFailed ||
      file.authenticationRequired ||
      (fingerprint != null &&
          musicDownloadFingerprint(file) !=
              _downloadMetadataFingerprint(fingerprint))) {
    return null;
  }
  return file;
}
