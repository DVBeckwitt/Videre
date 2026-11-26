import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fs;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../globals.dart';
import '../music/models/music_artwork_cache.dart';
import '../music/services/music_catalog_artwork_cache.dart';

final notificationArtworkCache = NotificationArtworkCache(
  profileId: () => db.profileId,
);

/// Temporary files for remote artwork shown by Android's media notification.
class NotificationArtworkCache {
  NotificationArtworkCache({
    required this.profileId,
    this.limitBytes = 32 * 1024 * 1024,
    Config Function(String namespace)? configFactory,
  }) {
    _files = ArtworkFileCache(
      'notification-artwork',
      onStored: _scheduleTrim,
      configFactory: configFactory,
    )..stagingBudget = MusicArtworkStagingBudget(
        () => limitBytes,
        onPressure: _scheduleTrim,
      );
  }

  final String Function() profileId;
  final int limitBytes;
  late final ArtworkFileCache _files;
  late final BaseCacheManager manager = _NotificationArtworkManager(this);
  bool _trimScheduled = false;
  Future<void> _work = Future.value();

  Future<({int usedBytes, int limitBytes, bool canClear})> read() =>
      _run(_trim);

  Future<T> _run<T>(Future<T> Function() work) {
    final operation = _work.then((_) => work());
    _work = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<({int usedBytes, int limitBytes, bool canClear})> clear() async {
    // Android keeps a decoded bitmap for the active media item. Only its
    // temporary disk files and pending downloads belong to this store.
    await _files.clear();
    return read();
  }

  void _scheduleTrim() {
    if (_trimScheduled) return;
    _trimScheduled = true;
    unawaited(
      _run(() async {
        _trimScheduled = false;
        await _trim();
      }).catchError((Object _) {
        // The next explicit read reports a storage error to Settings.
      }),
    );
  }

  Future<({int usedBytes, int limitBytes, bool canClear})> _trim() async {
    for (var attempt = 0;; attempt++) {
      final inventory = await _files.inventory();
      final indexedBytes = inventory.entries.fold(
        0,
        (bytes, entry) => bytes + entry.bytes,
      );
      _files.stagingBudget.measureIndexed(indexedBytes);
      var usedBytes = indexedBytes + inventory.stagedBytes;
      if (usedBytes <= limitBytes || attempt == 2) {
        return (
          usedBytes: usedBytes,
          limitBytes: limitBytes,
          canClear: inventory.entries.isNotEmpty || inventory.hasTransfers,
        );
      }

      // An entry touched or replaced during trimming can decline eviction.
      inventory.entries.sort((a, b) => a.touched.compareTo(b.touched));
      for (final entry in inventory.entries) {
        if (usedBytes <= limitBytes) break;
        await entry.remove();
        usedBytes -= entry.bytes;
      }
    }
  }

  String _key(String key, [Map<String, String>? headers]) {
    final names = headers?.keys.toList() ?? <String>[];
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              profileId(),
              key,
              for (final name in names) [name.toLowerCase(), headers![name]],
            ]),
          ),
        )
        .toString();
  }
}

// AudioService keeps this adapter for its lifetime. Each operation uses the
// current file manager so clearing the cache does not require a media restart.
class _NotificationArtworkManager implements BaseCacheManager {
  _NotificationArtworkManager(this.cache);

  final NotificationArtworkCache cache;

  BaseCacheManager get _current => cache._files.manager;

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String> headers = const {},
  }) async {
    final manager = _current;
    final file = await manager.getSingleFile(
      url,
      key: cache._key(key ?? url, headers),
      headers: headers,
    );
    if (!identical(manager, _current)) {
      throw const HttpException('Notification artwork request was cleared.');
    }
    return file;
  }

  @override
  Future<FileInfo?> getFileFromMemory(String key) async {
    // AudioService's fast lookup supplies only the URL. A matching URL can
    // return different images under different instance or profile credentials.
    return null;
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) =>
      _current.getFileFromCache(
        cache._key(key),
        ignoreMemCache: ignoreMemCache,
      );

  @override
  Stream<FileInfo> getFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) =>
      getFileStream(
        url,
        key: key,
        headers: headers,
      ).where((response) => response is FileInfo).cast<FileInfo>();

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      _current.getFileStream(
        url,
        key: cache._key(key ?? url, headers),
        headers: headers,
        withProgress: withProgress,
      );

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) =>
      _current.downloadFile(
        url,
        key: cache._key(key ?? url, authHeaders),
        authHeaders: authHeaders,
        force: force,
      );

  @override
  Future<fs.File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) =>
      _current.putFile(
        url,
        fileBytes,
        key: cache._key(key ?? url),
        eTag: eTag,
        maxAge: maxAge,
        fileExtension: fileExtension,
      );

  @override
  Future<fs.File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) =>
      _current.putFileStream(
        url,
        source,
        key: cache._key(key ?? url),
        eTag: eTag,
        maxAge: maxAge,
        fileExtension: fileExtension,
      );

  @override
  Future<void> removeFile(String key) => _current.removeFile(cache._key(key));

  @override
  Future<void> emptyCache() async => cache.clear();

  @override
  Future<void> dispose() async {
    await cache._work;
    await cache._files.dispose();
  }
}
