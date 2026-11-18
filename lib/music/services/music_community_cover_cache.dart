import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../videos/models/music_metadata.dart';
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

  final Future<Directory> Function() _supportDirectory;
  final CommunityCoverLoader _loader;
  final ValueNotifier<(String, String)?> _savedCover = ValueNotifier(null);
  final _misses = <(String, String, String, String, String?, int?), DateTime>{};
  final _checked = <(String, String), (DateTime, int, bool)>{};
  int _active = 0;
  Completer<void>? _slotChanged;

  MusicCommunityCoverCache({
    Future<Directory> Function()? supportDirectory,
    CommunityCoverLoader? loader,
  })  : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _loader = loader ?? fetchCommunityMusicCover;

  ValueListenable<(String, String)?> get savedCover => _savedCover;

  Future<Directory> _profileFolder(String profile) async {
    final support = await _supportDirectory();
    final folder = sha256.convert(utf8.encode(profile)).toString();
    return Directory(p.join(support.path, 'community-music-covers-v1', folder));
  }

  Future<File> _file(String profile, String videoId) async =>
      File(p.join((await _profileFolder(profile)).path, '$videoId.png'));

  Future<void> removeProfile(String profile) async {
    _misses.removeWhere((key, _) => key.$1 == profile);
    _checked.removeWhere((key, _) => key.$1 == profile);
    try {
      final folder = await _profileFolder(profile);
      if (await folder.exists()) await folder.delete(recursive: true);
    } on MissingPlatformDirectoryException {
      // No platform cache directory exists.
    } on MissingPluginException {
      // No platform cache directory exists.
    }
  }

  Future<File?> read(String profile, String videoId,
      {required bool Function() isCurrent}) async {
    if (!isCurrent() || !_youtubeId.hasMatch(videoId)) return null;
    try {
      final file = await _file(profile, videoId);
      final stat = await file.stat();
      if (!isCurrent() ||
          stat.type != FileSystemEntityType.file ||
          stat.size <= 0 ||
          stat.size > _maxBytes) {
        return null;
      }
      final key = (profile, videoId);
      final checked = _checked[key];
      if (checked != null &&
          checked.$1 == stat.modified &&
          checked.$2 == stat.size) {
        return checked.$3 ? file : null;
      }
      final valid = await _canDecode(file);
      if (!isCurrent()) return null;
      _checked[key] = (stat.modified, stat.size, valid);
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
    if (!_youtubeId.hasMatch(videoId) || !isCurrent()) return null;
    final cached = await read(profile, videoId, isCurrent: isCurrent);
    if (cached != null || !isCurrent()) return cached;
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
    if (!await _takeSlot(isCurrent)) return null;
    try {
      final local = await read(profile, videoId, isCurrent: isCurrent);
      if (local != null || !isCurrent()) return local;
      if (_misses[lookup]?.isAfter(DateTime.now()) == true) return null;
      final bytes = await _loader(track, durationSeconds, isCurrent: isCurrent);
      if (!isCurrent()) return null;
      if (bytes == null) {
        _rememberMiss(lookup, now.add(const Duration(hours: 6)));
        return null;
      }
      if (bytes.isEmpty || bytes.length > _maxBytes) return null;
      final file = await _file(profile, videoId);
      if (!isCurrent()) return null;
      final folder = await file.parent.create(recursive: true);
      // createTemp gives simultaneous requests distinct staging files.
      final staging = await folder.createTemp('.pending-');
      final partial = File(p.join(staging.path, 'cover.png'));
      try {
        await partial.writeAsBytes(bytes, flush: true);
        if (!isCurrent()) return null;
        final existing = await read(profile, videoId, isCurrent: isCurrent);
        if (!isCurrent()) return null;
        if (existing == null) {
          await partial.rename(file.path);
          _checked.remove((profile, videoId));
          if (_savedCover.value == (profile, videoId)) {
            _savedCover.value = null;
          }
          _savedCover.value = (profile, videoId);
        }
      } finally {
        try {
          if (await partial.exists()) await partial.delete();
          await staging.delete();
        } on FileSystemException {
          // A failed cleanup does not invalidate an already stored cover.
        }
      }
      await _trim(folder);
      return isCurrent() ? file : null;
    } on MusicCommunityCoverException {
      if (isCurrent()) {
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
      final changed = _slotChanged;
      _slotChanged = null;
      changed?.complete();
    }
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

  Future<void> _trim(Directory folder) async {
    try {
      final files = await folder
          .list(followLinks: false)
          .where((entry) => entry is File && p.extension(entry.path) == '.png')
          .cast<File>()
          .toList();
      if (files.length <= _capacity) return;
      final entries = await Future.wait(files.map((file) async {
        final stat = await file.stat();
        return (file, stat.modified);
      }));
      entries.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (file, _) in entries.take(files.length - _capacity)) {
        await file.delete();
      }
    } on FileSystemException {
      // A concurrent eviction or storage error leaves the saved image usable.
    }
  }
}
