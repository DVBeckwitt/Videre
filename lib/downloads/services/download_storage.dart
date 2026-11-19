import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

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

  bool get supportsSharedMusic => Platform.isAndroid;

  /// Android 10+ can publish app-owned songs with no storage permission.
  /// Earlier versions need a folder grant through the system picker.
  Future<String?> sharedMusicFolder() =>
      _channel.invokeMethod<String>('sharedMusicFolder');

  Future<DownloadFolder?> pickFolder(String? initialUri) async =>
      DownloadFolder.fromJson(await _channel
          .invokeMethod<dynamic>('pickFolder', {'initialUri': initialUri}));

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
