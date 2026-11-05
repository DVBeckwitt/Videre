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

class DownloadStorage {
  static const _channel = MethodChannel('videre/download_storage');
  static int _nextWrite = 0;

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

  Future<void> writeDocument(
      String source, String uri, CancelToken token) async {
    final id = '${++_nextWrite}';
    if (token.isCancelled) throw token.cancelError!;
    var finished = false;
    final writing = _channel.invokeMethod<void>(
        'writeDocument', {'source': source, 'uri': uri, 'id': id});
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
}
