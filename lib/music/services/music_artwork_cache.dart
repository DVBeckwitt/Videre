import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../../globals.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_artwork_cache.dart';
import 'music_catalog_artwork_cache.dart';
import 'music_community_cover_cache.dart';

final musicArtworkCache = MusicArtworkCache();

/// The two stores serve on-screen online Music artwork for one profile.
class MusicArtworkCache {
  MusicArtworkCache({
    MusicCommunityCoverCache? community,
    MusicCatalogArtworkCache Function(String, void Function())? catalog,
    IDbClient Function(String)? database,
  })  : _community = community ?? communityMusicCoverCache,
        _catalog = catalog ??
            ((profile, onStored) =>
                MusicCatalogArtworkCache(profile, onStored: onStored)),
        _database = database ?? ((profile) => db.forProfile(profile));

  final MusicCommunityCoverCache _community;
  final MusicCatalogArtworkCache Function(String, void Function()) _catalog;
  final IDbClient Function(String) _database;
  final _profiles = <String, _ProfileArtworkCache>{};
  bool _listening = false;

  _ProfileArtworkCache _profile(String profile) {
    if (!_listening) {
      _community.savedCover.addListener(_coverStored);
      _listening = true;
    }
    return _profiles.putIfAbsent(profile, () {
      final budget = MusicArtworkStagingBudget(
        () => _limitMiB(_database(profile)) * 1024 * 1024,
        onPressure: () => _scheduleTrim(profile),
      );
      final catalog = _catalog(profile, () => _scheduleTrim(profile))
        ..stagingBudget = budget;
      _community.setStagingBudget(profile, budget);
      return _ProfileArtworkCache(catalog, budget);
    });
  }

  BaseCacheManager catalogManager(String profile) {
    final state = _profile(profile);
    if (state.removal != null) {
      throw StateError('The active Music profile changed.');
    }
    trackProfile(profile);
    return state.catalog.manager;
  }

  void trackProfile(String profile) {
    final state = _profile(profile);
    if (state.removal == null && !state.started) {
      state.started = true;
      _scheduleTrim(profile);
    }
  }

  Future<MusicArtworkCacheStatus> read(IDbClient owner) =>
      _withProfile(owner, (state) => _status(owner, state));

  Future<MusicArtworkCacheStatus> configure(IDbClient owner, int limitMiB,
      {bool Function()? isCurrent}) {
    if (!musicArtworkCacheLimitsMiB.contains(limitMiB)) {
      throw ArgumentError.value(limitMiB, 'limitMiB');
    }
    return _withProfile(owner, (state) async {
      await owner.saveSetting(
          SettingsValue(musicArtworkCacheLimitSettingName, '$limitMiB'));
      await state.catalog.applyStagingLimit();
      return _trim(owner, state);
    }, isCurrent: isCurrent);
  }

  Future<MusicArtworkCacheStatus> clear(IDbClient owner,
          {bool Function()? isCurrent}) =>
      _withProfile(owner, (state) async {
        await Future.wait([
          state.catalog.clear(),
          _community.clear(owner.profileId),
        ]);
        return _status(owner, state);
      }, isCurrent: isCurrent);

  Future<T> _withProfile<T>(
      IDbClient owner, Future<T> Function(_ProfileArtworkCache state) action,
      {bool Function()? isCurrent}) {
    final state = _profile(owner.profileId);
    if (state.removal != null) {
      return Future.error(StateError('The active Music profile changed.'));
    }
    return state.run(() {
      if (state.removal != null || isCurrent?.call() == false) {
        throw StateError('The active Music profile changed.');
      }
      return action(state);
    });
  }

  void _coverStored() {
    final cover = _community.savedCover.value;
    if (cover != null) _scheduleTrim(cover.$1);
  }

  void _scheduleTrim(String profile) {
    // Community-only users may never have opened a catalog thumbnail.
    final state = _profile(profile);
    if (state.removal != null || state.trimQueued) return;
    state.trimQueued = true;
    unawaited(state.run(() async {
      state.trimQueued = false;
      if (state.removal == null) await _trim(_database(profile), state);
    }).catchError((Object _) {
      // An unavailable cache is reported by the settings view on its next read.
    }));
  }

  int _limitMiB(IDbClient owner) =>
      parseMusicArtworkCacheLimit(
          owner.getSettings(musicArtworkCacheLimitSettingName)?.value) ??
      musicArtworkCacheDefaultLimitMiB;

  Future<
      ({
        List<MusicArtworkCacheEntry> entries,
        MusicArtworkCacheStatus status,
      })> _snapshot(IDbClient owner, _ProfileArtworkCache state) async {
    final (catalog, community) = await (
      state.catalog.inventory(),
      _community.entries(owner.profileId)
    ).wait;
    final entries = [...catalog.entries, ...community];
    final indexedBytes = entries.fold(0, (bytes, entry) => bytes + entry.bytes);
    state.budget.measureIndexed(indexedBytes);
    return (
      entries: entries,
      status: (
        usedBytes: indexedBytes + catalog.stagedBytes,
        limitMiB: _limitMiB(owner),
        hasTransfers: catalog.hasTransfers,
      ),
    );
  }

  Future<MusicArtworkCacheStatus> _status(
          IDbClient owner, _ProfileArtworkCache state) async =>
      (await _snapshot(owner, state)).status;

  Future<MusicArtworkCacheStatus> _trim(
      IDbClient owner, _ProfileArtworkCache state) async {
    final limitMiB = _limitMiB(owner);
    final limit = limitMiB * 1024 * 1024;
    // A file touched or replaced after the snapshot may refuse eviction.
    // Recheck against the newer access order before reporting the result.
    // A stalled response can put pressure on finished files without adding
    // an index row. Evict the oldest finished files to make room for it.
    for (var attempt = 0; attempt < 2; attempt++) {
      final snapshot = await _snapshot(owner, state);
      final entries = snapshot.entries;
      var usedBytes = snapshot.status.usedBytes;
      if (usedBytes <= limit) return snapshot.status;
      entries.sort((a, b) => a.touched.compareTo(b.touched));
      for (final entry in entries) {
        if (usedBytes <= limit) break;
        await entry.remove();
        usedBytes -= entry.bytes;
      }
    }
    return _status(owner, state);
  }

  Future<void> removeProfile(String profile) {
    final state = _profile(profile);
    final removal = state.removal;
    if (removal != null) return removal;

    // Invalidate requests before waiting for a queued settings operation.
    state.catalog.invalidate();
    _community.invalidate(profile);
    return state.removal = state.run(() async {
      try {
        await _withCatalogStorage(state.catalog.clear);
        await _community.removeProfile(profile);
        try {
          await _withCatalogStorage(state.catalog.dispose);
        } finally {
          // Disposal can close the index before it reports an error.
          _profiles.remove(profile);
          _community.setStagingBudget(profile, null);
        }
      } finally {
        state.removal = null;
      }
    });
  }

  Future<void> _withCatalogStorage(Future<void> Function() operation) async {
    try {
      await operation();
    } on MissingPlatformDirectoryException {
      // This platform has no persistent catalog image files to remove.
    } on MissingPluginException {
      // The app can also retire profiles without a file-cache plugin.
    }
  }
}

class _ProfileArtworkCache {
  final MusicCatalogArtworkCache catalog;
  final MusicArtworkStagingBudget budget;
  Future<void> _tail = Future.value();
  bool started = false;
  bool trimQueued = false;
  Future<void>? removal;

  _ProfileArtworkCache(this.catalog, this.budget);

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
