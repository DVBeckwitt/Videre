import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/models/music_artwork_cache.dart';
import 'package:clipious/music/services/music_artwork_cache.dart';
import 'package:clipious/music/services/music_catalog_artwork_cache.dart';
import 'package:clipious/music/services/music_community_cover_cache.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/file_db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

class _TestApp extends AppCubit {
  _TestApp(super.initialState, {super.backgroundDatabase, super.artworkCache});

  @override
  void onReady() {
    intentDataStreamSubscription = const Stream<void>.empty().listen((_) {});
  }
}

class _SessionService extends Service {
  Future<void> Function()? validate;
  Future<void> Function(Server)? revoke;
  final validatedAccounts = <String>[];
  final revokedAccounts = <String>[];

  @override
  Future<void> validateCurrentSessionSafely() async {
    final selected = await db.getCurrentlySelectedServer();
    validatedAccounts.add('${selected.profileId}/${selected.accountId}');
    await validate?.call();
  }

  @override
  Future<void> syncHistory() async {}

  @override
  Future<Server?> logOutProtected(Server account) async {
    revokedAccounts.add('${account.profileId}/${account.accountId}');
    await revoke?.call(account);
    return account;
  }
}

class _FailingMirror extends FileDB {
  String? failingProfile;
  bool failEveryProfile = false;
  int failures = 0;

  @override
  Future<void> insertLogs(AppLog log) async {
    await super.insertLogs(log);
  }

  @override
  Future<void> upsertServer(Server server) async {
    await super.upsertServer(server);
  }

  @override
  Future<void> syncWithDb() async {
    await super.syncWithDb();
    // Fail after writing to model a partial disk/mirror transition.
    if (failures > 0 && (failEveryProfile || db.profileId == failingProfile)) {
      failures--;
      throw StateError('Injected background snapshot failure');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const first = Server(
      url: 'https://same.example', id: 'first', authToken: 'first-token');
  late Server second;
  late _TestApp app;
  late _SessionService sessionService;
  late _FailingMirror mirror;
  late Service originalService;
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('videre-session-switch-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(first);
    final person = await db.createProfile('Second');
    second = Server(
        url: first.url,
        id: 'second',
        profileId: person.id,
        authToken: 'second-token');
    await db.forProfile(person.id).upsertServer(second);
    originalService = service;
    sessionService = _SessionService();
    service = sessionService;
    mirror = _FailingMirror();
    await mirror.syncWithDb();
    app =
        _TestApp(AppState(0, first, HomeLayout()), backgroundDatabase: mirror);
    await app.initState();
  });

  tearDown(() async {
    if (!app.isClosed) await app.close();
    service = originalService;
    await db.close();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  Future<void> expectSelected(Server expected) async {
    expect(db.profileId, expected.profileId);
    final selected = await db.getCurrentlySelectedServer();
    expect(selected.accountId, expected.accountId);
    expect(selected.authToken, expected.authToken);
    expect(app.state.profileId, expected.profileId);
    expect(app.state.server?.accountId, expected.accountId);
    expect(app.state.server?.authToken, expected.authToken);
    final background = await mirror.getCurrentlySelectedServer();
    expect(background.profileId, expected.profileId);
    expect(background.accountId, expected.accountId);
    expect(background.authToken, expected.authToken);
    expect(app.state.globalLoading, isFalse);
    expect(app.state.sessionRecoveryRequired, isFalse);
  }

  test('deleting an inactive profile preserves the active runtime and account',
      () async {
    var stopped = false;
    app.beforeAccountSwitch = () async => stopped = true;
    await app.deleteProfile(second.profileId);
    expect(stopped, isFalse);
    expect(sessionService.revokedAccounts,
        ['${second.profileId}/${second.accountId}']);
    expect((await db.getProfiles()).single.id, first.profileId);
    expect(() => db.forProfile(second.profileId), throwsStateError);
    await expectSelected(first);
  });

  test('deleting the active Default profile safely selects a surviving person',
      () async {
    final lifecycle = <String>[];
    app.beforeAccountSwitch = () async => lifecycle.add('stop:${db.profileId}');
    app.afterAccountSwitch =
        () async => lifecycle.add('reload:${db.profileId}');
    app.resetNavigation =
        (_) async => lifecycle.add('navigate:${db.profileId}');
    sessionService.revoke = (account) async {
      expect(account.profileId, first.profileId);
      expect(db.profileId, second.profileId);
      expect(db.forProfile(first.profileId).getAccount(first.accountId),
          isNotNull);
      lifecycle.add('revoke:${account.profileId}');
    };
    await app.deleteProfile(first.profileId);
    expect(lifecycle, [
      'stop:default',
      'reload:${second.profileId}',
      'navigate:${second.profileId}',
      'revoke:default'
    ]);
    expect((await db.getProfiles()).single.id, second.profileId);
    await expectSelected(second);
  });

  test('the last profile is protected before any credentials are revoked',
      () async {
    await app.deleteProfile(second.profileId);
    sessionService.revokedAccounts.clear();
    await expectLater(app.deleteProfile(first.profileId), throwsStateError);
    expect(sessionService.revokedAccounts, isEmpty);
    expect((await db.getProfiles()).single.id, first.profileId);
    await expectSelected(first);
  });

  test('failed native cleanup retains the profile for a later deletion retry',
      () async {
    sessionService.revoke = (_) async => throw StateError('Cleanup failed');
    await expectLater(app.deleteProfile(first.profileId), throwsStateError);
    expect(await db.getProfiles(), hasLength(2));
    expect(
        db.forProfile(first.profileId).getAccount(first.accountId), isNotNull);
    await expectSelected(second);
    sessionService.revoke = null;
    await app.deleteProfile(first.profileId);
    expect((await db.getProfiles()).single.id, second.profileId);
    await expectSelected(second);
  });

  for (final failingStore in ['catalog', 'Community']) {
    test('a $failingStore artwork failure leaves the profile usable for retry',
        () async {
      const videoId = 'ABCDEFGHIJK';
      const pendingVideoId = 'BCDEFGHIJKL';
      const coverUrl = 'https://example.test/catalog.png';
      const pendingUrl = '$coverUrl?pending';
      const track = MusicMetadata(title: 'Song', artist: 'Artist');
      const pendingTrack = MusicMetadata(title: 'Older song', artist: 'Artist');
      final coverBytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=');
      final catalogStarted = Completer<void>();
      final communityStarted = Completer<void>();
      final releaseResponses = Completer<void>();
      final fileService =
          HttpFileService(httpClient: MockClient((request) async {
        if (request.url.toString() == pendingUrl &&
            !catalogStarted.isCompleted) {
          catalogStarted.complete();
          await releaseResponses.future;
          return http.Response.bytes([1, 2, 3], 200,
              headers: {'content-type': 'image/png'});
        }
        return http.Response.bytes(coverBytes, 200,
            headers: {'content-type': 'image/png'});
      }));
      final communityCache = MusicCommunityCoverCache(
        supportDirectory: () async => documents,
        loader: (track, _, {required isCurrent}) async {
          if (track == pendingTrack) {
            communityStarted.complete();
            await releaseResponses.future;
          }
          return coverBytes;
        },
      );
      final catalogs = <MusicCatalogArtworkCache>[];
      final cache = MusicArtworkCache(
        community: communityCache,
        catalog: (profile, onStored) {
          final catalog = MusicCatalogArtworkCache(profile,
              onStored: onStored,
              configFactory: (name) => Config(name,
                  repo: JsonCacheInfoRepository.withFile(
                      File(p.join(documents.path, name, 'index.json'))),
                  fileService: fileService));
          catalogs.add(catalog);
          return catalog;
        },
        database: db.forProfile,
      );
      addTearDown(() async {
        if (!releaseResponses.isCompleted) releaseResponses.complete();
        for (final catalog in catalogs) {
          await catalog.dispose();
        }
      });
      await app.close();
      app = _TestApp(AppState(0, first, HomeLayout()),
          backgroundDatabase: mirror, artworkCache: cache);
      await app.initState();

      final profileId = second.profileId;
      final owner = db.forProfile(profileId);
      final other = db.forProfile(first.profileId);
      final manager = cache.catalogManager(owner.profileId);
      final original = await manager.putFile(coverUrl, coverBytes);
      final community = (await communityCache
          .load(owner.profileId, videoId, track, 180, isCurrent: () => true))!;
      final otherCatalog = await cache
          .catalogManager(other.profileId)
          .putFile(coverUrl, coverBytes);
      final otherCommunity = (await communityCache
          .load(other.profileId, videoId, track, 180, isCurrent: () => true))!;
      await owner
          .saveSetting(SettingsValue(musicArtworkCacheLimitSettingName, '16'));
      expect(await cache.read(owner), (
        usedBytes: 2 * coverBytes.length,
        limitMiB: 16,
        hasTransfers: false,
      ));
      await app.switchProfile(owner.profileId);
      await expectSelected(second);

      final oldCatalog = expectLater(
          manager.getSingleFile(pendingUrl), throwsA(isA<HttpException>()));
      final oldCommunity = communityCache.load(
          owner.profileId, pendingVideoId, pendingTrack, 180,
          isCurrent: () => true);
      await Future.wait([catalogStarted.future, communityStarted.future]);

      // A conflicting filesystem entry makes the store fail at its real I/O boundary.
      final obstruction =
          failingStore == 'catalog' ? original.path : community.parent.path;
      if (failingStore == 'catalog') {
        await original.rename('$obstruction.saved');
        final directory = await Directory(obstruction).create();
        await File(p.join(directory.path, 'obstruction')).create();
      } else {
        await community.parent.rename('$obstruction.saved');
        await File(obstruction).create();
      }

      await expectLater(app.deleteProfile(owner.profileId),
          throwsA(isA<FileSystemException>()));
      await oldCatalog;
      if (failingStore == 'catalog') {
        await Directory(obstruction).delete(recursive: true);
        await File('$obstruction.saved').rename(obstruction);
      } else {
        await File(obstruction).delete();
        await Directory('$obstruction.saved').rename(obstruction);
      }
      expect((await db.getProfiles()).map((p) => p.id),
          unorderedEquals([owner.profileId, other.profileId]));
      await expectSelected(first);
      expect((await cache.read(owner)).limitMiB, 16);
      expect(sessionService.revokedAccounts, isEmpty);
      expect((await owner.getCurrentlySelectedServer()).authToken,
          second.authToken);
      expect(
          (await mirror
                  .forProfile(owner.profileId)
                  .getCurrentlySelectedServer())
              .authToken,
          second.authToken);

      await app.switchProfile(owner.profileId);
      await expectSelected(second);
      final freshManager = cache.catalogManager(owner.profileId);
      final replacement = await freshManager.getSingleFile(pendingUrl);
      expect(await replacement.readAsBytes(), coverBytes);
      final freshCommunity = await communityCache.load(
          owner.profileId, videoId, track, 180,
          isCurrent: () => db.profileId == owner.profileId);
      expect(await freshCommunity!.readAsBytes(), coverBytes);
      expect((await cache.configure(owner, 32)).limitMiB, 32);

      releaseResponses.complete();
      expect(await oldCommunity, isNull);
      expect((await freshManager.getFileFromCache(pendingUrl))?.file.path,
          replacement.path);
      expect(
          await communityCache.read(owner.profileId, pendingVideoId,
              isCurrent: () => true),
          isNull);

      await app.deleteProfile(owner.profileId);
      expect((await db.getProfiles()).single.id, other.profileId);
      expect(() => db.forProfile(profileId), throwsStateError);
      expect(sessionService.revokedAccounts,
          ['${second.profileId}/${second.accountId}']);
      await expectLater(
          mirror.forProfile(profileId).getCurrentlySelectedServer(),
          throwsStateError);
      expect(await replacement.exists(), isFalse);
      expect(await original.exists(), isFalse);
      expect(await community.parent.exists(), isFalse);
      expect(await otherCatalog.readAsBytes(), coverBytes);
      expect(await otherCommunity.readAsBytes(), coverBytes);
      await expectSelected(first);
    });
  }

  test('queued switching cannot reopen a profile while it is being deleted',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    sessionService.revoke = (_) async {
      started.complete();
      await release.future;
    };
    final deletion = app.deleteProfile(first.profileId);
    await started.future;
    final switching =
        expectLater(app.switchProfile(first.profileId), throwsStateError);
    release.complete();
    await deletion;
    await switching;
    expect((await db.getProfiles()).single.id, second.profileId);
    await expectSelected(second);
  });

  test('failed active-profile switching prevents deletion and sign-out',
      () async {
    app.beforeAccountSwitch =
        () async => throw StateError('Cannot stop playback');
    await expectLater(app.deleteProfile(first.profileId), throwsStateError);
    expect(sessionService.revokedAccounts, isEmpty);
    expect(await db.getProfiles(), hasLength(2));
    await expectSelected(first);
  });

  for (final stage in [
    'before',
    'validation',
    'mirror',
    'reload',
    'navigation'
  ]) {
    test('$stage failure restores the previous person, account and runtime',
        () async {
      var failed = false;
      final reloaded = <String>[];
      final navigated = <String>[];
      app.beforeAccountSwitch = () async {
        if (stage == 'before' && !failed) {
          failed = true;
          throw StateError('Injected preparation failure');
        }
      };
      sessionService.validate = () async {
        if (stage == 'validation' && !failed) {
          failed = true;
          throw StateError('Injected session check failure');
        }
      };
      app.afterAccountSwitch = () async {
        reloaded.add(db.profileId);
        if (stage == 'reload' && !failed) {
          failed = true;
          throw StateError('Injected runtime reload failure');
        }
      };
      app.resetNavigation = (_) async {
        navigated.add(db.profileId);
        if (stage == 'navigation' && !failed) {
          failed = true;
          throw StateError('Injected navigation failure');
        }
      };
      if (stage == 'mirror') {
        mirror.failingProfile = second.profileId;
        mirror.failures = 1;
      }
      await expectLater(app.switchServer(second), throwsStateError);
      await expectSelected(first);
      expect(reloaded.last, first.profileId);
      expect(navigated.last, first.profileId);
      // A failed transition must not poison the serialized queue.
      await app.switchServer(second);
      await expectSelected(second);
    });
  }

  test(
      'rollback reloads the latest saved credentials instead of the old snapshot',
      () async {
    final refreshed = first.copyWith(
        authToken: 'refreshed-token',
        customHeaders: {'X-Connection': 'refreshed'});
    var firstReload = true;
    app.afterAccountSwitch = () async {
      if (firstReload) {
        firstReload = false;
        await db.forProfile(first.profileId).upsertServer(refreshed);
        throw StateError('Reload failed after another login completed');
      }
    };
    await expectLater(app.switchServer(second), throwsStateError);
    await expectSelected(refreshed);
    expect(app.state.server?.customHeaders, refreshed.customHeaders);
    expect((await mirror.getCurrentlySelectedServer()).customHeaders,
        refreshed.customHeaders);
  });

  test('switching a deleted legacy account cannot select its URL replacement',
      () async {
    final legacy = Server(url: first.url, authToken: 'legacy-token');
    await db.upsertServer(legacy);
    await db.deleteServerById(legacy);
    var preparations = 0;
    app.beforeAccountSwitch = () async => preparations++;

    expect(await app.switchServer(legacy), isNull);

    expect(preparations, 0);
    expect(sessionService.validatedAccounts, isEmpty);
    await expectSelected(first);
  });

  test('rollback never substitutes a deleted legacy account with a URL match',
      () async {
    final legacy = Server(url: first.url, authToken: 'legacy-token');
    const retained = Server(
        url: 'https://retained.example',
        id: 'retained',
        authToken: 'retained-token');
    await db.upsertServer(legacy);
    await db.upsertServer(retained);
    await db.useServer(legacy);
    await mirror.syncWithDb();
    await app.initState();
    var firstReload = true;
    app.afterAccountSwitch = () async {
      if (!firstReload) return;
      firstReload = false;
      final owner = db.forProfile(first.profileId);
      await owner.deleteServerById(legacy);
      await owner.useServer(retained);
      throw StateError(
          'Target reload failed after the old account was removed');
    };

    await expectLater(app.switchServer(second), throwsStateError);

    await expectSelected(retained);
  });

  for (final rollback in [false, true]) {
    test(
        'notifications published before the mirror changes are retired '
        '(rollback=$rollback)', () async {
      final visible = <String>{'Existing notification'};
      final clearedFor = <String>[];
      final titlesAtNavigation = <List<String>>[];
      app.beforeAccountSwitch = () async => visible.clear();
      app.clearSessionNotifications = () async {
        clearedFor.add((await mirror.getGenericSettings()).profileId);
        visible.clear();
      };
      sessionService.validate = () async {
        // A worker reads FileDB in another isolate. Until publication it can
        // finish both ownership checks against the previous person's mirror.
        expect((await mirror.getCurrentlySelectedServer()).profileId,
            first.profileId);
        visible.add('Previous person private title');
        if (rollback) throw StateError('Target session validation failed');
      };
      app.resetNavigation = (_) async {
        titlesAtNavigation.add(visible.toList());
      };

      if (rollback) {
        await expectLater(app.switchServer(second), throwsStateError);
      } else {
        await app.switchServer(second);
      }

      expect(visible, isEmpty);
      expect(titlesAtNavigation, isNotEmpty);
      expect(titlesAtNavigation.every((titles) => titles.isEmpty), isTrue);
      expect(clearedFor, isNotEmpty);
      expect(
          clearedFor.every(
              (id) => id == (rollback ? first.profileId : second.profileId)),
          isTrue);
    });
  }

  test('notification cleanup covers a partially failed mirror publication',
      () async {
    final visible = <String>{};
    final clearedFor = <String>[];
    app.clearSessionNotifications = () async {
      clearedFor.add((await mirror.getGenericSettings()).profileId);
      visible.clear();
    };
    sessionService.validate = () async {
      visible.add('Previous person private title');
    };
    mirror.failingProfile = second.profileId;
    mirror.failures = 1;

    await expectLater(app.switchServer(second), throwsStateError);

    expect(visible, isEmpty);
    expect(clearedFor.first, second.profileId);
    expect(clearedFor.last, first.profileId);
    await expectSelected(first);
  });

  test('failed notification cleanup keeps recovery blocked until retry',
      () async {
    var failing = true;
    app.clearSessionNotifications = () async {
      if (failing) throw StateError('Notification service unavailable');
    };

    await expectLater(
        app.switchServer(second), throwsA(isA<SessionRecoveryRequired>()));
    expect(app.state.sessionRecoveryRequired, isTrue);
    expect(app.state.globalLoading, isFalse);

    failing = false;
    await app.retrySessionRecovery();
    await expectSelected(first);
  });

  for (final logout in [false, true]) {
    test(
        'credentials changed during runtime reload are published (logout=$logout)',
        () async {
      final updated = second.copyWith(authToken: logout ? null : 'new-token');
      app.afterAccountSwitch = () async {
        await db.forProfile(second.profileId).upsertServer(updated);
        // Normal callbacks deliberately cannot publish over a transition.
        app.setServer(updated);
      };
      await app.switchServer(second);
      await expectSelected(updated);
      expect(app.isLoggedIn, !logout);
    });
  }

  test('rollback reload publishes a refresh that finishes during recovery',
      () async {
    var calls = 0;
    final updated = first.copyWith(authToken: 'recovery-refresh');
    app.afterAccountSwitch = () async {
      if (++calls == 1) throw StateError('Target reload failed');
      await db.forProfile(first.profileId).upsertServer(updated);
      app.setServer(updated);
    };
    await expectLater(app.switchServer(second), throwsStateError);
    await expectSelected(updated);
  });

  test('unrecoverable reload remains blocked until explicit recovery succeeds',
      () async {
    app.afterAccountSwitch =
        () async => throw StateError('Runtime unavailable');
    await expectLater(
        app.switchServer(second), throwsA(isA<SessionRecoveryRequired>()));
    expect(app.state.sessionRecoveryRequired, isTrue);
    expect(app.state.globalLoading, isFalse);
    await expectLater(app.switchServer(second), throwsStateError);
    expect(app.state.sessionRecoveryRequired, isTrue);
    await expectLater(
        app.retrySessionRecovery(), throwsA(isA<SessionRecoveryRequired>()));
    expect(app.state.sessionRecoveryRequired, isTrue);
    expect(app.state.globalLoading, isFalse);
    app.afterAccountSwitch = () async {};
    await app.retrySessionRecovery();
    await expectSelected(first);
  });

  test('mirror recovery failure never unblocks the previous screen', () async {
    mirror.failEveryProfile = true;
    mirror.failures = 2;
    await expectLater(
        app.switchServer(second), throwsA(isA<SessionRecoveryRequired>()));
    expect(app.state.sessionRecoveryRequired, isTrue);
    expect(app.state.globalLoading, isFalse);
    await app.retrySessionRecovery();
    await expectSelected(first);
  });

  test('rapid profile and same-URL account switches remain serialized',
      () async {
    final third = second.copyWith(id: 'third', authToken: 'third-token');
    await db.forProfile(second.profileId).upsertServer(third);
    final started = Completer<void>();
    final finish = Completer<void>();
    sessionService.validate = () async {
      if (!started.isCompleted) {
        started.complete();
        await finish.future;
      }
    };
    final toSecond = app.switchProfile(second.profileId);
    await started.future;
    final toThird = app.switchServer(third);
    final toFirst = app.switchServer(first);
    expect(db.profileId, second.profileId);
    expect(app.state.globalLoading, isTrue);
    finish.complete();
    await Future.wait([toSecond, toThird, toFirst]);
    expect(sessionService.validatedAccounts, [
      '${second.profileId}/${second.accountId}',
      '${third.profileId}/${third.accountId}',
      '${first.profileId}/${first.accountId}',
    ]);
    await expectSelected(first);
    expect(
        (await db.forProfile(second.profileId).getCurrentlySelectedServer())
            .accountId,
        third.accountId);
  });

  test('closing during preparation cancels active and queued switches',
      () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var preparations = 0;
    var reloads = 0;
    app.beforeAccountSwitch = () async {
      preparations++;
      started.complete();
      await finish.future;
    };
    app.afterAccountSwitch = () async {
      reloads++;
    };
    final switching = app.switchServer(second);
    await started.future;
    final queued = app.switchServer(first);
    final closing = app.close();
    finish.complete();
    expect(await switching, isNull);
    expect(await queued, isNull);
    await closing;
    expect(preparations, 1);
    expect(reloads, 0);
    expect(db.profileId, first.profileId);
    expect(
        (await mirror.getCurrentlySelectedServer()).accountId, first.accountId);
  });

  test(
      'closing after selection restores persistence without invoking disposed hooks',
      () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var reloads = 0;
    var navigations = 0;
    sessionService.validate = () async {
      started.complete();
      await finish.future;
    };
    app.afterAccountSwitch = () async {
      reloads++;
    };
    app.resetNavigation = (_) async {
      navigations++;
    };
    final switching = app.switchServer(second);
    await started.future;
    expect(db.profileId, second.profileId);
    final closing = app.close();
    finish.complete();
    expect(await switching, isNull);
    await closing;
    expect(reloads, 0);
    expect(navigations, 0);
    expect(db.profileId, first.profileId);
    expect((await db.getCurrentlySelectedServer()).accountId, first.accountId);
    expect(
        (await mirror.getCurrentlySelectedServer()).accountId, first.accountId);
    expect(await app.switchServer(second), isNull);
    expect(db.profileId, first.profileId);
  });
}
