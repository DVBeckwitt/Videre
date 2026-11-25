import 'dart:async';

import 'package:clipious/music/models/music_artwork_cache.dart';
import 'package:clipious/music/services/music_artwork_cache.dart';
import 'package:clipious/music/services/music_catalog_artwork_cache.dart';
import 'package:clipious/music/services/music_community_cover_cache.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const mib = 1024 * 1024;

class _Files {
  final files = <String, (int, DateTime)>{};

  void add(String name, int mib, int age) {
    files[name] = (mib * 1024 * 1024, DateTime.utc(2026, 1, age));
  }

  List<MusicArtworkCacheEntry> get entries => [
        for (final entry in files.entries)
          (
            bytes: entry.value.$1,
            touched: entry.value.$2,
            remove: () async {
              files.remove(entry.key);
            }
          ),
      ];
}

class _Catalog implements MusicCatalogArtworkCache {
  final files = _Files();
  Completer<void>? measuring;
  Completer<void>? release;
  StateError? disposalError;
  bool disposed = false;

  @override
  Future<List<MusicArtworkCacheEntry>> entries() async {
    if (disposed) throw StateError('Catalog has been disposed.');
    if (measuring != null && !measuring!.isCompleted) measuring!.complete();
    await release?.future;
    return files.entries;
  }

  @override
  Future<
          ({
            List<MusicArtworkCacheEntry> entries,
            int stagedBytes,
            bool hasTransfers
          })>
      inventory() async =>
          (entries: await entries(), stagedBytes: 0, hasTransfers: false);

  @override
  set stagingBudget(MusicArtworkStagingBudget value) {}

  @override
  Future<void> applyStagingLimit() async {}

  @override
  Future<void> clear() async => files.files.clear();

  @override
  void invalidate() {}

  @override
  Future<void> dispose() async {
    disposed = true;
    final error = disposalError;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Community implements MusicCommunityCoverCache {
  final profiles = <String, _Files>{};

  _Files files(String profile) => profiles.putIfAbsent(profile, _Files.new);

  @override
  final ValueNotifier<(String, String)?> savedCover = ValueNotifier(null);

  @override
  void setStagingBudget(String profile, MusicArtworkStagingBudget? budget) {}

  @override
  Future<List<MusicArtworkCacheEntry>> entries(String profile) async =>
      files(profile).entries;

  @override
  Future<void> clear(String profile) async => files(profile).files.clear();

  @override
  void invalidate(String profile) {}

  @override
  Future<void> removeProfile(String profile) async {
    profiles.remove(profile);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late _Community community;
  late Map<String, _Catalog> catalogs;
  late MusicArtworkCache cache;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    community = _Community();
    catalogs = {};
    cache = MusicArtworkCache(
      community: community,
      catalog: (profile, _) {
        final catalog = catalogs[profile];
        if (catalog != null && !catalog.disposed) return catalog;
        return catalogs[profile] = _Catalog();
      },
      database: database.forProfile,
    );
  });

  tearDown(() async {
    community.savedCover.dispose();
    await database.close();
  });

  test('usage is read-only and one profile budget trims both artwork stores',
      () async {
    final primary = database.forProfile(database.profileId);
    final otherProfile = await database.createProfile('Other');
    final other = database.forProfile(otherProfile.id);
    final catalog = catalogs.putIfAbsent(primary.profileId, _Catalog.new);
    catalog.files
      ..add('old catalog cover', 8, 1)
      ..add('new catalog cover', 6, 3);
    community.files(primary.profileId).add('community cover', 12, 2);
    community.files(other.profileId).add('other profile cover', 10, 1);
    await primary
        .saveSetting(SettingsValue(musicArtworkCacheLimitSettingName, '16'));

    expect(await cache.read(primary),
        (usedBytes: 26 * mib, limitMiB: 16, hasTransfers: false));
    expect(catalog.files.files, contains('old catalog cover'));
    expect(await cache.configure(primary, 16),
        (usedBytes: 6 * mib, limitMiB: 16, hasTransfers: false));
    expect(catalog.files.files.keys, ['new catalog cover']);
    expect(community.files(primary.profileId).files, isEmpty);
    expect(await cache.clear(primary),
        (usedBytes: 0, limitMiB: 16, hasTransfers: false));
    expect(await cache.read(other), (
      usedBytes: 10 * mib,
      limitMiB: musicArtworkCacheDefaultLimitMiB,
      hasTransfers: false
    ));
  });

  test('an artwork action rechecks its profile when earlier work completes',
      () async {
    final owner = database.forProfile(database.profileId);
    final catalog = catalogs.putIfAbsent(owner.profileId, _Catalog.new)
      ..measuring = Completer<void>()
      ..release = Completer<void>();
    catalog.files.add('retained cover', 1, 1);
    final reading = cache.read(owner);
    await catalog.measuring!.future;
    var current = true;
    final clearing = expectLater(
        cache.clear(owner, isCurrent: () => current), throwsStateError);
    current = false;
    catalog.release!.complete();
    await reading;
    await clearing;
    expect((await cache.read(owner)).usedBytes, mib);
  });

  test('concurrent removal shares one attempt and recovers a failed disposal',
      () async {
    final owner = database.forProfile(database.profileId);
    final catalog = catalogs.putIfAbsent(owner.profileId, _Catalog.new)
      ..measuring = Completer<void>()
      ..release = Completer<void>()
      ..disposalError = StateError('Closing the catalog failed.');
    final reading = cache.read(owner);
    await catalog.measuring!.future;
    final queued = expectLater(cache.configure(owner, 16), throwsStateError);
    final removal = cache.removeProfile(owner.profileId);
    final failed = expectLater(removal, throwsA(same(catalog.disposalError)));
    expect(cache.removeProfile(owner.profileId), same(removal));
    await expectLater(cache.read(owner), throwsStateError);
    catalog.release!.complete();
    await reading;
    await queued;
    await failed;

    expect(catalog.disposed, isTrue);
    expect(await cache.read(owner), (
      usedBytes: 0,
      limitMiB: musicArtworkCacheDefaultLimitMiB,
      hasTransfers: false
    ));
    expect(catalogs[owner.profileId], isNot(same(catalog)));
    await cache.removeProfile(owner.profileId);
  });
}
