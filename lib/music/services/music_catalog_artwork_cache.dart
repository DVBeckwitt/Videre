import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fs;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/music_artwork_cache.dart';

/// An independent disk cache for the catalog artwork viewed by one profile.
class MusicCatalogArtworkCache {
  MusicCatalogArtworkCache(this.profileId, {this.onStored, this.configFactory});

  final String profileId;
  final void Function()? onStored;
  final Config Function(String namespace)? configFactory;

  late final String _namespace =
      'music-catalog-art-${sha256.convert(utf8.encode(profileId))}';
  Config? _config;
  Config get _base => _config ??= configFactory?.call(_namespace) ??
      Config(_namespace, repo: _TemporaryIndex(_namespace));
  Future<bool>? _opening;
  Future<bool> get _opened => _opening ??= Future.microtask(_open);
  Future<void> _work = Future.value();
  int _generation = 0;
  bool _disposed = false;
  final _requests = <Completer<void>>{};
  final _writes = <String, _CatalogWrite>{};
  MusicArtworkStagingBudget stagingBudget = MusicArtworkStagingBudget(
      () => musicArtworkCacheDefaultLimitMiB * 1024 * 1024);
  CacheManager? _manager;

  bool get hasTransfers => _requests.isNotEmpty || _writes.isNotEmpty;

  Future<({List<MusicArtworkCacheEntry> entries, int stagedBytes, bool hasTransfers})>
      inventory() => _local(() async {
            final entries = await _entries();
            final stagedBytes =
                _writes.values.fold(0, (bytes, w) => bytes + w.bytes);
            return (
              entries: entries,
              stagedBytes: stagedBytes,
              hasTransfers: hasTransfers
            );
          });

  Future<bool> _open() async {
    try {
      final opened = await _base.repo.open();
      await _sweepUnindexed();
      return opened;
    } catch (_) {
      // Both the repository and IOFileSystem can retain a failed open future.
      // A later settings read gets a fresh pair if cache storage recovers.
      _resetOpen();
      rethrow;
    }
  }

  void _resetOpen() {
    _opening = null;
    _config = null;
    invalidate();
  }

  BaseCacheManager get manager {
    if (_disposed) throw StateError('Artwork cache has been disposed.');
    return _manager ??= _CatalogManager(
        this,
        _generation,
        Config(_namespace,
            repo: _CatalogRepository(this, _generation),
            fileSystem: _CatalogFiles(this, _generation, _base.fileSystem),
            fileService:
                _CatalogFileService(this, _generation, _base.fileService),
            maxNrOfCacheObjects: _base.maxNrOfCacheObjects,
            stalePeriod: _base.stalePeriod));
  }

  // Only local metadata commits, eviction and clear share this queue. A pending
  // HTTP request can never hold a settings operation or a fresh request open.
  Future<T> _local<T>(Future<T> Function() action) {
    final result = _work.then((_) async {
      await _opened;
      return action();
    });
    _work = result.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return result;
  }

  Future<void> _unlink(String relativePath) async {
    if (!_cacheFilename.hasMatch(relativePath)) return;
    final file = await _base.fileSystem.createFile(relativePath);
    try {
      await file.delete();
    } on PathNotFoundException {
      // Android may already have reclaimed this cache file.
    }
  }

  Future<void> _remove(CacheObject object) async {
    await _unlink(object.relativePath);
    await _base.repo.delete(object.id!);
  }

  Future<void> _sweepUnindexed() async {
    final rows = await _base.repo.getAllObjects();
    await _removeAbandonedFiles({for (final row in rows) row.relativePath});
  }

  // The library writes a download before recording it in the index. Sweep only
  // before transfers or when clearing the current generation.
  Future<void> _removeAbandonedFiles(Set<String> retained) async {
    final folder = (await _base.fileSystem.createFile('index.json')).parent;
    if (!await folder.exists()) return;
    await for (final entry in folder.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is File &&
          _cacheFilename.hasMatch(name) &&
          !retained.contains(name)) {
        await _unlink(name);
      }
    }
  }

  Future<List<MusicArtworkCacheEntry>> entries() => _local(_entries);

  Future<List<MusicArtworkCacheEntry>> _entries() async {
    final entries = <MusicArtworkCacheEntry>[];
    for (final object in await _base.repo.getAllObjects()) {
      if (!_cacheFilename.hasMatch(object.relativePath)) continue;
      final file = await _base.fileSystem.createFile(object.relativePath);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        await _base.repo.delete(object.id!);
        continue;
      }
      if (stat.type != FileSystemEntityType.file) continue;
      entries.add((
        bytes: stat.size,
        touched: object.touched ?? stat.modified,
        remove: () => _local(() async {
              final current = await _base.repo.get(object.key);
              // A trim snapshot must never remove a newer response.
              if (current?.id == object.id &&
                  current?.relativePath == object.relativePath &&
                  current?.touched == object.touched) {
                await _remove(object);
              }
            }),
      ));
    }
    return entries;
  }

  /// Stop accepting bytes from the old manager before queued local work.
  void invalidate() {
    ++_generation;
    _manager = null;
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
    for (final write in _writes.values) {
      write.cancel();
    }
  }

  Future<void> _reclaimStaleWrites() async {
    await Future.wait([
      for (final write in _writes.values)
        if (!write.current) write.reclaim(),
    ]);
  }

  Future<void> applyStagingLimit() => _local(() async {
        var excess = stagingBudget.excess;
        for (final write in _writes.values.toList().reversed) {
          if (excess <= 0) break;
          if (write._reserved == 0) continue;
          write.cancel(_oversizedArtwork);
          excess -= write._reserved;
        }
        await _reclaimStaleWrites();
      });

  Future<void> clear() {
    invalidate();
    return _local(() async {
      await _reclaimStaleWrites();
      for (final object in await _base.repo.getAllObjects()) {
        await _remove(object);
      }
      await _removeAbandonedFiles({});
      // The JSON index normally delays writes. Forget cleared URLs on disk
      // before reporting completion, even if the process stops immediately.
      if (_base.repo is JsonCacheInfoRepository) {
        try {
          await _base.repo.close();
          await _base.repo.open();
        } catch (_) {
          _resetOpen();
          rethrow;
        }
      }
    });
  }

  Future<void> dispose() {
    if (_disposed) return _work;
    _disposed = true;
    invalidate();
    return _local(() async {
      await _reclaimStaleWrites();
      await _base.repo.close();
    });
  }
}

// Names generated by the pinned cache library for both HTTP and manual writes.
final _cacheFilename = RegExp(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?:\.[A-Za-z0-9!#$%&'*+.^_`|~-]*)?$");

class _TemporaryIndex extends JsonCacheInfoRepository {
  _TemporaryIndex(this.namespace);
  final String namespace;

  @override
  Future<bool> open() async {
    path =
        p.join((await getTemporaryDirectory()).path, namespace, 'index.json');
    return super.open();
  }
}

class _CatalogFiles implements FileSystem {
  _CatalogFiles(this.cache, this.generation, this.files);
  final MusicCatalogArtworkCache cache;
  final int generation;
  final FileSystem files;

  @override
  Future<fs.File> createFile(String name) async =>
      _CatalogFile(cache, generation, await files.createFile(name));
}

class _CatalogFile extends fs.ForwardingFileSystemEntity<fs.File, File>
    with fs.ForwardingFile {
  _CatalogFile(this.cache, this.generation, this.delegate);
  final MusicCatalogArtworkCache cache;
  final int generation;
  @override
  final fs.File delegate;

  @override
  IOSink openWrite(
          {FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      IOSink(_CatalogWrite(cache, generation, delegate, mode),
          encoding: encoding);

  @override
  Future<fs.File> delete({bool recursive = false}) => cache._local(() async {
        // WebHelper may request deletion when the response extension changes,
        // before the replacement body is accepted. The index owns that file
        // until a replacement commits.
        if (generation == cache._generation &&
            !(await cache._base.repo.getAllObjects())
                .any((row) => row.relativePath == basename)) {
          try {
            await delegate.delete(recursive: recursive);
          } on PathNotFoundException {
            // The repository may already have reclaimed the replaced file.
          }
        }
        return this;
      });

  @override
  fs.FileSystem get fileSystem => delegate.fileSystem;
  @override
  String get basename => delegate.basename;
  @override
  String get dirname => delegate.dirname;
  @override
  fs.File wrapFile(File file) =>
      _CatalogFile(cache, generation, fileSystem.file(file.path));
  @override
  fs.Directory wrapDirectory(Directory directory) =>
      fileSystem.directory(directory.path);
  @override
  fs.Link wrapLink(Link link) => fileSystem.link(link.path);
}

const _staleArtwork = HttpException('Artwork request was cleared.');
const _oversizedArtwork = HttpException('Artwork exceeds the storage limit.');

class _CatalogFileService extends FileService {
  _CatalogFileService(this.cache, this.generation, this.delegate) {
    concurrentFetches = delegate.concurrentFetches;
  }

  final MusicCatalogArtworkCache cache;
  final int generation;
  final FileService delegate;

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    if (generation != cache._generation) throw _staleArtwork;
    final cleared = Completer<void>();
    cache._requests.add(cleared);
    try {
      return await Future.any([
        cleared.future.then<FileServiceResponse>((_) => throw _staleArtwork),
        delegate.get(url, headers: headers).then((response) {
          final stale = generation != cache._generation;
          final hasBody = response.statusCode == HttpStatus.ok ||
              response.statusCode == HttpStatus.accepted;
          if (stale ||
              (hasBody &&
                  (response.contentLength ?? 0) >
                      cache.stagingBudget.limitBytes())) {
            _discardBody(response.content);
            throw stale ? _staleArtwork : _oversizedArtwork;
          }
          return response;
        }),
      ]);
    } finally {
      cache._requests.remove(cleared);
    }
  }
}

void _cancelStream(Future<dynamic> cancellation) {
  // The HTTP producer may delay its cancellation acknowledgement. No local
  // file operation needs to wait for it.
  unawaited(
      cancellation.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
}

void _discardBody(Stream<List<int>> body) =>
    _cancelStream(body.listen(null, onError: (Object _) {}).cancel());

/// The cache manager pipes HTTP bodies into this sink before indexing them.
/// Charge each chunk before writing it and close the file even when pipe fails.
class _CatalogWrite implements StreamConsumer<List<int>> {
  _CatalogWrite(this.cache, this.generation, this.file, this.mode);

  final MusicCatalogArtworkCache cache;
  final int generation;
  final fs.File file;
  final FileMode mode;
  late final MusicArtworkStagingBudget _budget = cache.stagingBudget;
  StreamIterator<List<int>>? _source;
  Future<void>? _writing;
  int _reserved = 0;
  int bytes = 0;
  HttpException? _cancelled;

  bool get current => _cancelled == null && generation == cache._generation;
  HttpException get _cancellationError => _cancelled ?? _staleArtwork;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (!current) {
      _discardBody(stream);
      throw _staleArtwork;
    }
    cache._writes[file.basename] = this;
    final source = _source = StreamIterator(stream);
    await (_writing = _write(source));
  }

  Future<void> _write(StreamIterator<List<int>> source) async {
    try {
      RandomAccessFile? destination;
      try {
        while (current && await source.moveNext()) {
          if (!current) throw _cancellationError;
          final chunk = source.current;
          if (!_budget.reserve(chunk.length)) throw _oversizedArtwork;
          _reserved += chunk.length;
          destination ??= await file.open(mode: mode);
          if (!current) throw _cancellationError;
          await destination.writeFrom(chunk);
          bytes += chunk.length;
          if (current) _budget.wroteBytes();
        }
        if (!current) throw _cancellationError;
        destination ??= await file.open(mode: mode);
      } finally {
        await destination?.close();
      }
      if (!current) throw _cancellationError;
    } catch (_) {
      await _discard();
      rethrow;
    } finally {
      _stopReading();
    }
  }

  void cancel([HttpException reason = _staleArtwork]) {
    _cancelled ??= reason;
    _stopReading();
  }

  void _stopReading() {
    final source = _source;
    _source = null;
    if (source != null) _cancelStream(source.cancel());
  }

  @override
  Future<void> close() async {
    if (!current) throw _cancellationError;
  }

  Future<void> reclaim() async {
    try {
      await _writing;
    } catch (_) {
      // If the failed write could not unlink its file, retry now.
    }
    await _discard();
  }

  Future<void> _discard() async {
    if (cache._writes[file.basename] != this) return;
    try {
      await file.delete();
    } on PathNotFoundException {
      // Android may already have reclaimed the file.
    }
    indexed();
  }

  void indexed() {
    cache._writes.remove(file.basename);
    _budget.release(_reserved);
    _reserved = 0;
  }
}

class _CatalogManager extends CacheManager {
  _CatalogManager(this.cache, this.generation, super.config);
  final MusicCatalogArtworkCache cache;
  final int generation;

  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) =>
      // CacheStore refreshes its persisted last-use time only on an index read.
      super.getFileFromCache(key, ignoreMemCache: true);

  @override
  Future<FileInfo> downloadFile(String url,
      {String? key,
      Map<String, String>? authHeaders,
      bool force = false}) async {
    final result = await super
        .downloadFile(url, key: key, authHeaders: authHeaders, force: force);
    // WebHelper schedules the index commit before emitting FileInfo.
    await cache._work;
    if (generation != cache._generation) throw _staleArtwork;
    return result;
  }
}

/// WebHelper writes files before asynchronously committing their metadata.
/// Each manager has its own generation so a delayed response can never replace
/// a later download of the same URL after a clear.
class _CatalogRepository implements CacheInfoRepository {
  _CatalogRepository(this.cache, this.generation);

  final MusicCatalogArtworkCache cache;
  final int generation;
  final _reads = Expando<bool>();
  bool get current => generation == cache._generation;
  CacheInfoRepository get repo => cache._base.repo;

  @override
  Future<bool> open() => cache._opened;
  @override
  Future<bool> close() async => false;
  @override
  Future<bool> exists() => repo.exists();
  @override
  Future<void> deleteDataFile() => cache.clear();

  @override
  Future<CacheObject?> get(String key) => cache._local(() async {
        if (!current) return null;
        final record = await repo.get(key);
        if (record == null || !_cacheFilename.hasMatch(record.relativePath)) {
          return null;
        }
        _reads[record] = true;
        await repo.update(record);
        return record;
      });

  @override
  Future<dynamic> updateOrInsert(CacheObject object) => cache._local(() async {
        // CacheStore also calls this with the identical object it just read.
        // Its touch was committed in get; replaying it could undo a refresh.
        if (_reads[object] == true) return null;
        final write = cache._writes[object.relativePath];
        if (!current) {
          await write?.reclaim();
          return null;
        }
        final previous = await repo.get(object.key);
        // Pressure can evict a stale cover during its own refresh. A completed
        // replacement still belongs in this generation, with a new index ID.
        final reinsert = previous == null && object.id != null && write != null;
        if (!current ||
            write?.current == false ||
            (!reinsert && object.id != null && object.id != previous?.id)) {
          await write?.reclaim();
          return null;
        }
        final changed = previous?.relativePath != object.relativePath;
        final saved = await repo.updateOrInsert(reinsert
            ? CacheObject(object.url,
                key: object.key,
                relativePath: object.relativePath,
                validTill: object.validTill,
                eTag: object.eTag,
                length: object.length)
            : object);
        write?.indexed();
        if (changed && previous != null) {
          await cache._unlink(previous.relativePath);
        }
        if (changed && current) cache.onStored?.call();
        return saved;
      });

  @override
  Future<List<CacheObject>> getAllObjects() => cache._local(
      () async => current ? await repo.getAllObjects() : <CacheObject>[]);

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) =>
      cache._local(() async => current
          ? await repo.getObjectsOverCapacity(capacity)
          : <CacheObject>[]);

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) => cache._local(
      () async => current ? await repo.getOldObjects(maxAge) : <CacheObject>[]);

  @override
  Future<int> delete(int id) => deleteAll([id]);

  @override
  Future<int> deleteAll(Iterable<int> ids) => cache._local(() async {
        final selected = ids.toSet();
        if (!current || selected.isEmpty) return 0;
        var count = 0;
        for (final object in await repo.getAllObjects()) {
          if (selected.contains(object.id)) {
            await cache._remove(object);
            count++;
          }
        }
        return count;
      });

  @override
  Future<CacheObject> insert(CacheObject object,
          {bool setTouchedToNow = true}) =>
      cache._local(() {
        if (!current) throw StateError('Artwork cache has been cleared.');
        return repo.insert(object, setTouchedToNow: setTouchedToNow);
      });

  @override
  Future<int> update(CacheObject object, {bool setTouchedToNow = true}) =>
      cache._local(() async => current
          ? await repo.update(object, setTouchedToNow: setTouchedToNow)
          : 0);
}
