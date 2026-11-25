import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../videos/models/music_metadata.dart';
import '../models/music_artwork_cache.dart';
import 'music_community_cover_service.dart';

typedef CommunityCoverLoader = Future<Uint8List?> Function(
    MusicMetadata track, int? durationSeconds,
    {required bool Function() isCurrent});

final communityMusicCoverCache = MusicCommunityCoverCache();

/// Stores only locally decoded provider output. File paths derived from a
/// profile and video ID never contain a provider URL or a user's song query.
class MusicCommunityCoverCache {
  static const _capacity = 250;
  static const _maxBytes = 2 * 1024 * 1024;
  static const _maxLookups = 5;
  static final _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _stagingName = RegExp(r'^\.pending-[A-Za-z0-9_-]+$');
  static final _diskWork = <String, Future<void>>{};

  final Future<Directory> Function() _supportDirectory;
  final CommunityCoverLoader _loader;
  final ValueNotifier<(String, String)?> _savedCover = ValueNotifier(null);
  final ValueNotifier<(String, String?)?> _invalidated = ValueNotifier(null);
  final _epochs = <String, Object>{};
  final _stagingBudgets = <String, MusicArtworkStagingBudget>{};
  final _misses = <(String, String, String, String, String?, int?), DateTime>{};
  final _checked = <(String, String), (DateTime, int, bool, int)>{};
  int _access = 0;
  int _active = 0;
  Completer<void>? _slotChanged;

  MusicCommunityCoverCache({
    Future<Directory> Function()? supportDirectory,
    CommunityCoverLoader? loader,
  })  : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _loader = loader ?? fetchCommunityMusicCover;

  ValueListenable<(String, String)?> get savedCover => _savedCover;
  ValueListenable<(String, String?)?> get invalidated => _invalidated;

  void setStagingBudget(String profile, MusicArtworkStagingBudget? budget) {
    if (budget == null) {
      _stagingBudgets.remove(profile);
    } else {
      _stagingBudgets[profile] = budget;
    }
  }

  // Provider lookups run concurrently. Only work on the same profile's disk
  // files (including publishing a staged cover) is serialized.
  Future<T> _disk<T>(String profile, Future<T> Function() action) {
    final work =
        (_diskWork[profile] ?? Future<void>.value()).then((_) => action());
    final tail = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _diskWork[profile] = tail;
    tail.then((_) {
      if (identical(_diskWork[profile], tail)) _diskWork.remove(profile);
    });
    return work;
  }

  void _notify<T>(ValueNotifier<T?> event, T change) {
    if (event.value == change) event.value = null;
    event.value = change;
  }

  Future<Directory> _profileFolder(String profile) async {
    final support = await _supportDirectory();
    final folder = sha256.convert(utf8.encode(profile)).toString();
    var directory = support;
    for (final part in ['community-music-covers-v1', folder]) {
      directory = Directory(p.join(directory.path, part));
      final type =
          await FileSystemEntity.type(directory.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw FileSystemException(
            'Unexpected artwork cache directory', directory.path);
      }
    }
    return directory;
  }

  Future<File> _file(String profile, String videoId) async =>
      File(p.join((await _profileFolder(profile)).path, '$videoId.png'));

  Future<void> clear(String profile) => _clear(profile, removeFolder: false);
  Future<void> removeProfile(String profile) =>
      _clear(profile, removeFolder: true);

  /// Prevent existing cover lookups from publishing to this profile.
  void invalidate(String profile) {
    _epochs.remove(profile);
    _wakeSlotWaiters();
  }

  Future<void> _clear(String profile, {required bool removeFolder}) {
    invalidate(profile);
    final finished = _disk(profile, () async {
      _misses.removeWhere((key, _) => key.$1 == profile);
      _checked.removeWhere((key, _) => key.$1 == profile);
      try {
        final folder = await _profileFolder(profile);
        await for (final item in folder.list(followLinks: false)) {
          try {
            if (_isCover(item)) {
              final file = item as File;
              await FileImage(file).evict();
              await file.delete();
            } else {
              await _removeStaging(item);
            }
          } on PathNotFoundException {
            // Continue with the other covers if this one was already removed.
          }
        }
        if (removeFolder) await folder.delete(recursive: true);
      } on PathNotFoundException {
        // The profile has no community cache.
      } on MissingPlatformDirectoryException {
        // No platform cache directory exists.
      } on MissingPluginException {
        // No platform cache directory exists.
      }
    });
    // Reads scheduled by mounted listeners must wait behind the clear.
    _notify(_invalidated, (profile, null));
    return finished;
  }

  Future<File?> read(String profile, String videoId,
      {required bool Function() isCurrent}) {
    final epoch = _epochs.putIfAbsent(profile, Object.new);
    return _disk(
        profile,
        () => _read(profile, videoId,
            () => identical(epoch, _epochs[profile]) && isCurrent()));
  }

  Future<File?> _read(
      String profile, String videoId, bool Function() current) async {
    if (!current() || _youtubeId.stringMatch(videoId) != videoId) return null;
    try {
      final file = await _file(profile, videoId);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final stat = await file.stat();
      if (!current() ||
          stat.type != FileSystemEntityType.file ||
          stat.size <= 0 ||
          stat.size > _maxBytes) {
        return null;
      }
      final key = (profile, videoId);
      final checked = _checked[key];
      final valid = checked != null &&
              checked.$1 == stat.modified &&
              checked.$2 == stat.size
          ? checked.$3
          : await _canDecode(file);
      if (!current()) return null;
      var touched = stat.modified;
      if (valid) {
        touched = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch);
        await file.setLastModified(touched);
        if (!current()) return null;
      }
      _checked.remove(key);
      _checked[key] = (touched, stat.size, valid, ++_access);
      if (_checked.length > _capacity) _checked.remove(_checked.keys.first);
      return valid ? file : null;
    } on FileSystemException {
      return null;
    } on MissingPlatformDirectoryException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  // The provider normalizes covers to a single PNG. A damaged cache entry
  // must yield to the stock artwork and allow the next lookup to replace it.
  Future<bool> _canDecode(File file) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width > 1024 || descriptor.height > 1024) return false;
      codec =
          await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
      if (codec.frameCount != 1) return false;
      (await codec.getNextFrame()).image.dispose();
      return true;
    } on Exception {
      return false;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<File?> load(
      String profile, String videoId, MusicMetadata track, int? durationSeconds,
      {required bool Function() isCurrent}) async {
    if (_youtubeId.stringMatch(videoId) != videoId || !isCurrent()) return null;
    final epoch = _epochs.putIfAbsent(profile, Object.new);
    bool current() => identical(epoch, _epochs[profile]) && isCurrent();
    final cached = await read(profile, videoId, isCurrent: current);
    if (!current()) return null;
    if (cached != null) return cached;
    final lookup = (
      profile,
      videoId,
      track.title,
      track.artist,
      track.album,
      durationSeconds
    );
    final now = DateTime.now();
    if (_misses[lookup]?.isAfter(now) == true) return null;
    if (!await _takeSlot(current)) return null;
    try {
      final local = await read(profile, videoId, isCurrent: current);
      if (!current()) return null;
      if (local != null) return local;
      if (_misses[lookup]?.isAfter(DateTime.now()) == true) return null;
      final bytes = await _loader(track, durationSeconds, isCurrent: current);
      if (!current()) return null;
      if (bytes == null) {
        _rememberMiss(lookup, now.add(const Duration(hours: 6)));
        return null;
      }
      if (bytes.isEmpty || bytes.length > _maxBytes) return null;
      return await _disk(profile, () async {
        final existing = await _read(profile, videoId, current);
        if (!current()) return null;
        if (existing != null) return existing;
        final file = await _file(profile, videoId);
        final folder = await file.parent.create(recursive: true);
        final staging = await folder.createTemp('.pending-');
        final partial = File(p.join(staging.path, 'cover.png'));
        final budget = _stagingBudgets[profile];
        var reserved = false;
        try {
          if (!current()) return null;
          reserved = budget?.reserve(bytes.length) ?? true;
          if (!reserved) return null;
          await partial.writeAsBytes(bytes, flush: true);
          if (!current()) return null;
          await partial.rename(file.path);
          await FileImage(file).evict();
          if (!current()) return null;
          _checked.remove((profile, videoId));
          await _trim(profile, folder);
          if (!current()) return null;
          _notify(_savedCover, (profile, videoId));
          return file;
        } finally {
          try {
            await _removeStaging(staging);
          } on FileSystemException {
            // The next inventory can reclaim interrupted staging.
          } finally {
            if (reserved) budget?.release(bytes.length);
          }
        }
      });
    } on MusicCommunityCoverException {
      if (current()) {
        _rememberMiss(lookup, now.add(const Duration(minutes: 1)));
      }
      return null;
    } on FileSystemException {
      return null;
    } on MissingPlatformDirectoryException {
      return null;
    } on MissingPluginException {
      return null;
    } finally {
      _active--;
      _wakeSlotWaiters();
    }
  }

  void _wakeSlotWaiters() {
    final changed = _slotChanged;
    _slotChanged = null;
    changed?.complete();
  }

  Future<bool> _takeSlot(bool Function() isCurrent) async {
    while (isCurrent() && _active >= _maxLookups) {
      await (_slotChanged ??= Completer<void>()).future;
    }
    if (!isCurrent()) return false;
    _active++;
    return true;
  }

  void _rememberMiss(
      (String, String, String, String, String?, int?) lookup, DateTime expiry) {
    _misses.remove(lookup);
    _misses[lookup] = expiry;
    if (_misses.length > _capacity) _misses.remove(_misses.keys.first);
  }

  static bool _isCover(FileSystemEntity item) =>
      item is File &&
      p.extension(item.path) == '.png' &&
      _youtubeId.stringMatch(p.basenameWithoutExtension(item.path)) ==
          p.basenameWithoutExtension(item.path);

  static Future<void> _removeStaging(FileSystemEntity item) async {
    if (item is! Directory) return;
    final name = p.basename(item.path);
    if (_stagingName.stringMatch(name) != name) return;
    if (await FileSystemEntity.type(item.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final partial = File(p.join(item.path, 'cover.png'));
    if (await FileSystemEntity.type(partial.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await partial.delete();
    }
    if (await item.list(followLinks: false).isEmpty) await item.delete();
  }

  Future<List<File>> _covers(Directory folder,
      {bool reclaimStaging = false}) async {
    final covers = <File>[];
    await for (final item in folder.list(followLinks: false)) {
      if (_isCover(item)) {
        covers.add(item as File);
      } else if (reclaimStaging) {
        try {
          await _removeStaging(item);
        } on PathNotFoundException {
          // An already-removed partial needs no further cleanup.
        }
      }
    }
    return covers;
  }

  Future<List<(File, FileStat)>> _stats(List<File> covers) async {
    final files = <(File, FileStat)>[];
    for (final file in covers) {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file) files.add((file, stat));
    }
    return files;
  }

  /// Enumerate owned covers without decoding or touching their LRU state.
  Future<List<MusicArtworkCacheEntry>> entries(String profile) {
    final epoch = _epochs.putIfAbsent(profile, Object.new);
    return _disk(profile, () async {
      try {
        final files = await _stats(
            await _covers(await _profileFolder(profile), reclaimStaging: true));
        if (!identical(_epochs[profile], epoch)) return [];
        return [
          for (final (file, stat) in files) _entry(profile, epoch, file, stat),
        ];
      } on PathNotFoundException {
        return [];
      } on MissingPlatformDirectoryException {
        return [];
      } on MissingPluginException {
        return [];
      }
    });
  }

  MusicArtworkCacheEntry _entry(
      String profile, Object epoch, File file, FileStat stat) {
    final key = (profile, p.basenameWithoutExtension(file.path));
    final access = _checked[key]?.$4;
    return (
      bytes: stat.size,
      touched: stat.modified,
      remove: () => _disk(profile, () async {
            if (!identical(_epochs[profile], epoch) ||
                _checked[key]?.$4 != access) {
              return;
            }
            final folder = await _profileFolder(profile);
            if (folder.path != file.parent.path ||
                await FileSystemEntity.type(file.path, followLinks: false) !=
                    FileSystemEntityType.file) {
              return;
            }
            final live = await file.stat();
            if (live.type != FileSystemEntityType.file ||
                live.size != stat.size ||
                live.modified != stat.modified) {
              return;
            }
            try {
              await _remove(profile, file);
            } on PathNotFoundException {
              // The measured entry has already been removed.
            }
          })
    );
  }

  Future<void> _remove(String profile, File file) async {
    await file.delete();
    await FileImage(file).evict();
    final id = p.basenameWithoutExtension(file.path);
    _checked.remove((profile, id));
    _notify(_invalidated, (profile, id));
  }

  Future<void> _trim(String profile, Directory folder) async {
    try {
      final covers = await _covers(folder);
      if (covers.length <= _capacity) return;
      final files = await _stats(covers);
      if (files.length <= _capacity) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, _) in files.take(files.length - _capacity)) {
        await _remove(profile, file);
      }
    } on FileSystemException {
      // A concurrent eviction or storage error leaves the saved image usable.
    }
  }
}
