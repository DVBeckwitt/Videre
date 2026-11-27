import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../music/models/music_file_audio_format.dart';
import '../models/downloaded_video.dart';

const downloadFolderSetting = 'download-folder';

/// Android's persisted document-tree grant, stored only on this device.
class DownloadFolder {
  final String uri;
  final String name;

  const DownloadFolder(this.uri, this.name);

  static DownloadFolder? fromJson(dynamic value) {
    if (value is! Map || value['uri'] is! String || value['name'] is! String) {
      return null;
    }
    final uri = Uri.tryParse(value['uri'] as String);
    return uri?.scheme == 'content' && uri!.hasAuthority
        ? DownloadFolder(value['uri'] as String, value['name'] as String)
        : null;
  }

  Map<String, String> toJson() => {'uri': uri, 'name': name};
}

typedef DownloadDestination = ({DownloadFolder? folder, bool usePrivate});
typedef DownloadCapacity = ({String volume, int availableBytes});
typedef MusicFileProbe = ({
  DownloadedVideo download,
  String uri,
  String identity,
  int byteLength,
});

const defaultDownloadDestination = (folder: null, usePrivate: false);
const privateDownloadDestination = (folder: null, usePrivate: true);

/// Device-local choices for new jobs. Each queued job retains its own URI.
class DownloadFolderPreferences {
  final DownloadDestination video;
  final DownloadDestination audio;
  final DownloadFolder? legacyMusicFolder;

  const DownloadFolderPreferences({
    this.video = defaultDownloadDestination,
    this.audio = defaultDownloadDestination,
    this.legacyMusicFolder,
  });

  factory DownloadFolderPreferences.decode(String? raw) {
    try {
      final saved = raw == null ? null : jsonDecode(raw);
      final music =
          saved is Map ? DownloadFolder.fromJson(saved['musicFolder']) : null;
      if (saved is Map &&
          (saved.containsKey('video') || saved.containsKey('audio'))) {
        return DownloadFolderPreferences(
            video: _destination(saved['video']),
            audio: _destination(saved['audio']),
            legacyMusicFolder: music);
      }
      // A single older destination applied to every download. The optional
      // pre-Android-10 Music tree was only a fallback for public song exports.
      final shared = music != null && DownloadFolder.fromJson(saved) == null
          ? defaultDownloadDestination
          : _destination(saved);
      return DownloadFolderPreferences(
          video: shared, audio: shared, legacyMusicFolder: music);
    } on FormatException {
      return const DownloadFolderPreferences(
          video: privateDownloadDestination, audio: privateDownloadDestination);
    }
  }

  static DownloadDestination _destination(dynamic value) {
    if (value == null) return defaultDownloadDestination;
    final folder = DownloadFolder.fromJson(value);
    // A malformed custom preference must never publish a file unintentionally.
    return folder == null
        ? privateDownloadDestination
        : (folder: folder, usePrivate: false);
  }

  String? encode() {
    Object? value(DownloadDestination destination) =>
        destination.folder?.toJson() ??
        (destination.usePrivate ? 'private' : null);
    if (video == defaultDownloadDestination &&
        audio == defaultDownloadDestination &&
        legacyMusicFolder == null) {
      return null;
    }
    return jsonEncode({
      'video': value(video),
      'audio': value(audio),
      if (legacyMusicFolder != null) 'musicFolder': legacyMusicFolder!.toJson(),
    });
  }
}

class DownloadStorage {
  static const _channel = MethodChannel('videre/download_storage');
  static int _nextWrite = 0;
  static final _fileProof = RegExp(r'^[a-f0-9]{64}$');

  static bool _readyMusicFile(DownloadedVideo file, String profileId) =>
      file.profileId == profileId &&
      file.downloadComplete &&
      !file.downloadFailed &&
      !file.storageFailed &&
      !file.authenticationRequired &&
      file.audioOnly &&
      file.musicMetadata?.title.trim().isNotEmpty == true &&
      DownloadedVideo.isSafeFileId(file.videoId);

  static Future<String> _privateMusicFolder(String profileId) async =>
      p.joinAll([
        (await getApplicationDocumentsDirectory()).path,
        ...privateDownloadFolderSegments(profileId),
      ]);

  static String _privateMusicUri(String folder, DownloadedVideo file) =>
      Uri.file(p.join(folder, '${file.videoId}.${file.extension}')).toString();

  Future<String?> musicFileProof(DownloadedVideo file,
          {bool verifyCompletion = false}) async =>
      (await _probeMusicFiles(file.profileId, [file],
              expectedSha256:
                  verifyCompletion ? file.playbackProvenance?.sha256 : null))
          .firstOrNull
          ?.identity;

  /// Checks that completed owned files are still readable and captures an
  /// opaque native descriptor identity without reading their audio bytes.
  Future<List<MusicFileProbe>> probeMusicFiles(
          String profileId, Iterable<DownloadedVideo> downloads) =>
      _probeMusicFiles(profileId, downloads);

  /// Reads audio properties from the verified file for a single inspector.
  Future<({String uri, int byteLength, MusicFileAudioFormat? audioFormat})?>
      inspectMusicFile(DownloadedVideo file, {String? expectedIdentity}) async {
    final profileId = file.profileId;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !_readyMusicFile(file, profileId) ||
        !DownloadedVideo.isSafeFileId(profileId) ||
        (file.storageUri == null) != (file.folderUri == null) ||
        (expectedIdentity != null &&
            _fileProof.stringMatch(expectedIdentity) != expectedIdentity)) {
      return null;
    }

    try {
      final uri = file.storageUri ??
          _privateMusicUri(await _privateMusicFolder(profileId), file);
      final expectedLength = file.playbackProvenance?.byteLength;
      final available = await _channel.invokeMapMethod<String, Object?>(
        'probeMusicFiles',
        {
          'profileId': profileId,
          'includeAudioFormat': true,
          'files': [
            {
              'key': file.videoId,
              'videoId': file.videoId,
              'uri': uri,
              'folderUri': file.folderUri,
              if (expectedIdentity != null)
                'expectedIdentity': expectedIdentity,
              if (expectedLength != null) 'expectedByteLength': expectedLength,
            },
          ],
        },
      );
      final value = available?[file.videoId];
      if (value is! Map<Object?, Object?>) return null;
      final proof = _musicProbe(file, uri, value);
      if (proof == null ||
          (expectedIdentity != null && proof.identity != expectedIdentity)) {
        return null;
      }
      return (
        uri: proof.uri,
        byteLength: proof.byteLength,
        audioFormat: MusicFileAudioFormat.fromChannel(value['audioFormat']),
      );
    } on Exception {
      return null;
    }
  }

  static MusicFileProbe? _musicProbe(
    DownloadedVideo file,
    String uri,
    Object? value,
  ) {
    if (value
        case {
          'identity': final String id,
          'byteLength': final int n,
        } when _fileProof.stringMatch(id) == id && n > 0) {
      final expectedLength = file.playbackProvenance?.byteLength;
      if (expectedLength == null || expectedLength == n) {
        return (download: file, uri: uri, identity: id, byteLength: n);
      }
    }
    return null;
  }

  Future<List<MusicFileProbe>> _probeMusicFiles(
      String profileId, Iterable<DownloadedVideo> downloads,
      {String? expectedSha256}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];

    final files = downloads
        .where((file) => _readyMusicFile(file, profileId))
        .toList(growable: false);
    final result = <MusicFileProbe>[];
    String? privateFolder;
    for (var start = 0; start < files.length; start += 64) {
      final batch = <String, ({DownloadedVideo file, String uri})>{};
      for (final file in files.skip(start).take(64)) {
        try {
          var uri = file.storageUri;
          if (uri == null) {
            privateFolder ??= await _privateMusicFolder(profileId);
            uri = _privateMusicUri(privateFolder, file);
          } else if (file.folderUri == null) {
            continue;
          }
          batch[file.videoId] = (file: file, uri: uri);
        } on Exception {
          // A missing private destination does not affect other downloads.
        }
      }
      if (batch.isEmpty) continue;
      try {
        final available =
            await _channel.invokeMapMethod<String, dynamic>('probeMusicFiles', {
          'profileId': profileId,
          'files': [
            for (final entry in batch.entries)
              {
                'key': entry.key,
                'videoId': entry.key,
                'uri': entry.value.uri,
                'folderUri': entry.value.file.folderUri,
                if (expectedSha256 != null) 'expectedSha256': expectedSha256,
              },
          ],
        });
        for (final entry in batch.entries) {
          final proof = _musicProbe(
            entry.value.file,
            entry.value.uri,
            available?[entry.key],
          );
          if (proof != null) result.add(proof);
        }
      } on PlatformException {
        // Storage or a provider may become unavailable between reads.
      } on MissingPluginException {
        return [];
      }
    }
    return result;
  }

  /// Opens Android sharing for one current, completed audible rendition.
  Future<bool> shareMusicFile(DownloadedVideo file,
          {String? expectedIdentity,
          required bool Function() isCurrent}) async =>
      await _musicFileAction<bool>('shareMusicFile', file,
          expectedIdentity: expectedIdentity, isCurrent: isCurrent) ??
      false;

  Future<bool> canSetMusicRingtone(DownloadedVideo file,
          {String? expectedIdentity,
          required bool Function() isCurrent}) async =>
      await _musicFileAction<bool>('canSetMusicRingtone', file,
          expectedIdentity: expectedIdentity, isCurrent: isCurrent) ??
      false;

  Future<String?> setMusicRingtone(DownloadedVideo file,
          {String? expectedIdentity, required bool Function() isCurrent}) =>
      _musicFileAction<String>('setMusicRingtone', file,
          expectedIdentity: expectedIdentity, isCurrent: isCurrent);

  Future<T?> _musicFileAction<T>(String method, DownloadedVideo file,
      {String? expectedIdentity, required bool Function() isCurrent}) async {
    final arguments = await musicFileShareArguments(file,
        expectedIdentity: expectedIdentity, isCurrent: isCurrent);
    if (arguments == null || !isCurrent()) return null;
    try {
      return await _channel.invokeMethod<T>(method, {
        ...arguments,
        if (method != 'shareMusicFile') 'title': file.title,
      });
    } on Exception {
      return null;
    }
  }

  /// Serializes a current downloaded rendition for Android's attachment checks.
  Future<Map<String, Object?>?> musicFileShareArguments(DownloadedVideo file,
      {String? expectedIdentity, required bool Function() isCurrent}) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !_readyMusicFile(file, file.profileId) ||
        !DownloadedVideo.isSafeFileId(file.profileId) ||
        (file.storageUri == null) != (file.folderUri == null) ||
        (expectedIdentity != null &&
            _fileProof.stringMatch(expectedIdentity) != expectedIdentity) ||
        !isCurrent()) {
      return null;
    }
    try {
      final uri = file.storageUri ??
          _privateMusicUri(await _privateMusicFolder(file.profileId), file);
      if (!isCurrent()) return null;
      return {
        'profileId': file.profileId,
        'videoId': file.videoId,
        'uri': uri,
        'folderUri': file.folderUri,
        'mime': file.mimeType,
        'expectedIdentity': expectedIdentity,
        'expectedSha256': file.playbackProvenance?.sha256,
        'byteLength': file.playbackProvenance?.byteLength,
      };
    } on Exception {
      return null;
    }
  }

  bool get supportsSharedMusic => Platform.isAndroid;

  /// Android 10+ can publish app-owned songs with no storage permission.
  /// Earlier versions need a folder grant through the system picker.
  Future<String?> sharedMusicFolder() =>
      _channel.invokeMethod<String>('sharedMusicFolder');

  Future<DownloadFolder?> pickFolder(String? initialUri) async =>
      DownloadFolder.fromJson(await _channel
          .invokeMethod<dynamic>('pickFolder', {'initialUri': initialUri}));

  /// Returns the free bytes and backing volume for a local path or a
  /// destination Android can identify. A provider may leave capacity unknown.
  Future<DownloadCapacity?> capacityFor(String pathOrUri) async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
          'downloadCapacity', {'pathOrUri': pathOrUri});
      if (value
          case {
            'volume': final String volume,
            'availableBytes': final int bytes,
          } when volume.isNotEmpty && bytes >= 0) {
        return (volume: volume, availableBytes: bytes);
      }
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    return null;
  }

  Future<void> checkFolder(String uri) =>
      _channel.invokeMethod<void>('checkFolder', {'uri': uri});

  Future<String> prepareDocument(
      String folder, String? existing, String name, String mimeType) async {
    final uri = await _channel.invokeMethod<String>('prepareDocument', {
      'folder': folder,
      'existing': existing,
      'name': name,
      'mime': mimeType,
    });
    if (uri == null || Uri.tryParse(uri)?.scheme != 'content') {
      throw PlatformException(code: 'DOWNLOAD_STORAGE');
    }
    return uri;
  }

  Future<void> writeDocument(String source, String uri, CancelToken token) =>
      _copy('writeDocument', {'source': source, 'uri': uri}, token);

  Future<void> readDocument(
          String uri, String folder, String destination, CancelToken token) =>
      _copy('readDocument',
          {'uri': uri, 'folderUri': folder, 'destination': destination}, token);

  Future<void> _copy(
      String method, Map<String, String> arguments, CancelToken token) async {
    final id = '${++_nextWrite}';
    if (token.isCancelled) throw token.cancelError!;
    var finished = false;
    final writing =
        _channel.invokeMethod<void>(method, {...arguments, 'id': id});
    // Native copying stays off the UI thread and can be stopped by pause/delete.
    token.whenCancel.then((_) async {
      if (finished) return;
      try {
        await _channel.invokeMethod<void>('cancelWrite', {'id': id});
      } on PlatformException {
        // The write reports its own outcome; cancellation must not mask it.
      } on MissingPluginException {
        // The engine may already be shutting down.
      }
    });
    try {
      await writing;
      if (token.isCancelled) throw token.cancelError!;
    } finally {
      finished = true;
    }
  }

  Future<void> deleteDocument(String uri) =>
      _channel.invokeMethod<void>('deleteDocument', {'uri': uri});

  /// Metadata only. Zero includes confirmed absence. An inaccessible document
  /// or a provider without a size is unknown.
  Future<int?> documentSize(String uri, String folderUri) async {
    final size = await _channel.invokeMethod<Object?>(
        'documentSize', {'uri': uri, 'folderUri': folderUri});
    return size is int && size >= 0 ? size : null;
  }

  /// False only when the exported file is confirmed absent from this destination.
  Future<bool> exportExists(String uri, String folderUri) async {
    final exists = await _channel.invokeMethod<bool>(
        'exportExists', {'uri': uri, 'folderUri': folderUri});
    if (exists == null) throw PlatformException(code: 'DOWNLOAD_STORAGE');
    return exists;
  }

  /// Fingerprints the completed owned document, never a path supplied by media.
  Future<({int byteLength, String sha256})?> inspectDocument(
      String uri, String folderUri) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
        'inspectDocument', {'uri': uri, 'folderUri': folderUri});
    if (value == null ||
        value['byteLength'] is! int ||
        value['sha256'] is! String) {
      return null;
    }
    return (
      byteLength: value['byteLength'] as int,
      sha256: value['sha256'] as String
    );
  }
}
