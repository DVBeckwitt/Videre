import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_library_service.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/person_profile.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/settings/models/errors/no_server_selected.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/service.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart' show newDatabaseFactoryMemory;

void main() {
  const videoId = 'abcdefghijk';
  const channelId = 'UC1234567890123456789012';
  const endpoint = 'https://instance.example';
  late SembastSqfDb database;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
  });

  tearDown(() => database.close());

  test('legacy stores become one Default library without rewriting accounts',
      () async {
    final directory = await Directory.systemTemp.createTemp('videre-profiles-');
    final path = '${directory.path}/legacy.db';
    var raw = await databaseFactoryIo.openDatabase(path);
    var client = SembastSqfDb(raw);
    try {
      // This is the pre-profile record format, including URL account keys.
      await client.serversStore.record(endpoint).put(raw, {
        'url': endpoint,
        'authToken': 'legacy-token',
        'customHeaders': {'X-Private': 'legacy-header'},
        'inUse': true,
      });
      await client.serversStore.record('https://second.example').put(raw, {
        'url': 'https://second.example',
        'sidCookie': 'SID=second-account',
        'inUse': false,
      });
      await client.progressStore
          .record(videoId)
          .put(raw, Progress(0.45, videoId).toJson());
      await client.historyVideoCacheStore.record(videoId).put(raw,
          HistoryVideoCache(videoId, 'Existing video', 'Author', '').toJson());
      await client.settingsStore
          .record('local-playlists')
          .put(raw, SettingsValue('local-playlists', '[]').toJson());

      expect(await client.getProfiles(), [PersonProfile.defaultProfile]);
      expect(await client.getProfiles(), [PersonProfile.defaultProfile]);
      expect(client.getServer(endpoint)?.accountId, endpoint);
      expect(client.getServer(endpoint)?.authToken, 'legacy-token');
      expect(await client.getServers(), hasLength(2));
      expect(client.getVideoProgress(videoId), 0.45);

      final second = await client.createProfile('Second person');
      await client.useProfile(second.id);
      expect(await client.getServers(), isEmpty);
      expect(client.getLocalHistory(), isEmpty);
      await client.close();
      raw = await databaseFactoryIo.openDatabase(path);
      client = SembastSqfDb(raw);

      expect(client.profileId, second.id);
      expect(await client.getProfiles(), hasLength(2));
      expect(client.getServer(endpoint), isNull);
      final original = client.forProfile(PersonProfile.defaultId);
      expect(original.getServer(endpoint)?.authToken, 'legacy-token');
      expect(await original.getServers(), hasLength(2));
      expect(original.getServer('https://second.example')?.sidCookie,
          'SID=second-account');
      expect(original.getServer(endpoint)?.customHeaders,
          {'X-Private': 'legacy-header'});
      expect(original.getLocalHistory().single.videoId, videoId);
      expect(original.getVideoProgress(videoId), 0.45);
    } finally {
      await client.close();
      await directory.delete(recursive: true);
    }
  });

  test('each person owns an empty library and fixed views retain their owner',
      () async {
    final original = database.forProfile(database.profileId);
    await original.saveProgress(Progress(1, videoId));
    await original.upsertHistoryVideo(
        HistoryVideoCache(videoId, 'Private video', 'Author', ''));
    await original.addOfflineSubscription(const OfflineSubscription(
        channelId: channelId, channelName: 'Private channel'));
    await original.addToSearchHistory(SearchHistoryItem('private search', 0));
    await original.saveFilter(VideoFilter(value: 'private filter'));
    await original.upsertHomeLayout(HomeLayout()..showBigSource = false);
    await original.saveSetting(SettingsValue('local-playlists', '[1]'));
    await original
        .saveSetting(SettingsValue('playback-session', 'private queue'));
    await original.upsertDownload(const DownloadedVideo(
        videoId: videoId,
        title: 'Private download',
        lengthSeconds: 60,
        quality: '720p',
        downloadComplete: true));

    final person = await database.createProfile('  Second person  ');
    expect(person.name, 'Second person');
    await database.useProfile(person.id);
    expect(database.getLocalHistory(), isEmpty);
    expect(database.getAllProgress(), isEmpty);
    expect(await database.getOfflineSubscriptions(), isEmpty);
    expect(database.getSearchHistory(), isEmpty);
    expect(database.getAllFilters(), isEmpty);
    expect(database.getHomeLayout().showBigSource, isTrue);
    expect(database.getAllDownloads(), isEmpty);
    expect(database.getSettings('local-playlists'), isNull);
    expect(database.getSettings('playback-session'), isNull);
    await expectLater(database.getCurrentlySelectedServer(),
        throwsA(isA<NoServerSelected>()));

    await original.saveProgress(Progress(0.6, videoId));
    await database.saveProgress(Progress(0.2, videoId));
    expect(original.getVideoProgress(videoId), 0.6);
    expect(database.getVideoProgress(videoId), 0.2);
    expect(original.getAllDownloads().single.title, 'Private download');
    await original.close(); // Closing a view must not close its owner's DB.
    expect(database.getVideoProgress(videoId), 0.2);
  });

  test('same endpoint supports independent accounts and selections per person',
      () async {
    const first = Server(url: endpoint, id: 'account-a', authToken: 'token-a');
    const second = Server(url: endpoint, id: 'account-b', authToken: 'token-b');
    await database.upsertServer(first);
    await database.upsertServer(second);
    await database.useServer(second);
    expect(await database.getServers(), hasLength(2));
    expect(database.getServer(first.accountId)?.authToken, 'token-a');
    expect(database.getServer(second.accountId)?.authToken, 'token-b');
    expect(database.getServer(endpoint)?.accountId, second.accountId);

    final person = await database.createProfile('Another person');
    await database.useProfile(person.id);
    final third = Server(
        url: endpoint,
        id: 'account-c',
        profileId: person.id,
        authToken: 'token-c');
    await database.upsertServer(third);
    expect(database.getServer(first.accountId), isNull);
    expect(database.getServer(endpoint)?.authToken, 'token-c');
    await expectLater(database.upsertServer(first), throwsStateError);
    final original = database.forProfile('default');
    expect(
        (await original.getCurrentlySelectedServer()).accountId, 'account-b');
    await original.deleteServer(first);
    expect(database.getServer('account-c')?.authToken, 'token-c');
  });

  test('selection preserves credential refresh queued before its transaction',
      () async {
    const account =
        Server(url: endpoint, id: 'account', authToken: 'old-token');
    await database.upsertServer(account);
    final entered = Completer<void>();
    final release = Completer<void>();
    final blocking = database.db.transaction((txn) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final refresh = database.serversStore
        .record(account.accountId)
        .update(database.db, {'authToken': 'refreshed-token'});
    final select = database.useServer(account);
    release.complete();
    await Future.wait([blocking, refresh, select]);
    expect((await database.getCurrentlySelectedServer()).authToken,
        'refreshed-token');
  });

  test('exact account lookup never substitutes a same-URL replacement',
      () async {
    const legacy = Server(url: endpoint, authToken: 'legacy-token');
    const replacement = Server(
        url: endpoint, id: 'replacement', authToken: 'replacement-token');
    await database.upsertServer(legacy);
    await database.upsertServer(replacement);
    expect(database.getAccount(legacy.accountId)?.authToken, 'legacy-token');
    await database.deleteServerById(legacy);

    // URL lookups remain compatible, while identity-bound operations fail.
    expect(database.getServer(endpoint)?.accountId, replacement.accountId);
    expect(database.getAccount(legacy.accountId), isNull);
    expect(database.getAccount(replacement.accountId)?.authToken,
        'replacement-token');

    final original = database.forProfile(database.profileId);
    final second = await database.createProfile('Second person');
    await database.useProfile(second.id);
    await database.upsertServer(
        legacy.copyWith(profileId: second.id, authToken: 'second-token'));
    expect(database.getAccount(endpoint)?.profileId, second.id);
    expect(original.getAccount(endpoint), isNull);
    expect(original.getAccount(replacement.accountId)?.authToken,
        'replacement-token');
  });

  test('device network/storage settings stay shared; personal settings do not',
      () async {
    await database.saveSetting(
        SettingsValue(networkSocksProxySettingName, '{"enabled":true}'));
    await database
        .saveSetting(SettingsValue('download-folder', 'device grant'));
    await database.saveSetting(SettingsValue(themeModeSettingName, 'dark'));
    final person = await database.createProfile('Second person');
    await database.useProfile(person.id);
    expect(database.getSettings(networkSocksProxySettingName)?.value,
        '{"enabled":true}');
    expect(database.getSettings('download-folder')?.value, 'device grant');
    expect(database.getSettings(themeModeSettingName), isNull);
    await database.saveSetting(SettingsValue('download-folder', 'new grant'));
    expect(database.forProfile('default').getSettings('download-folder')?.value,
        'new grant');
  });

  test('backup restore targets one person and never carries saved accounts',
      () async {
    final first = database.forProfile('default');
    await first.saveProgress(Progress(0.8, videoId));
    await first.upsertHistoryVideo(
        HistoryVideoCache(videoId, 'Original title', 'Author', ''));
    await first.upsertServer(const Server(url: endpoint, authToken: 'secret'));
    final backup = await first.exportBackup();
    expect(backup.encode(), isNot(contains('secret')));
    final person = await database.createProfile('Restore target');
    await database.useProfile(person.id);
    final target = Server(
        url: endpoint,
        profileId: person.id,
        id: 'target-account',
        authToken: 'preserve-target');
    await database.upsertServer(target);
    await database.restoreBackup(backup, replace: true);
    expect(database.getVideoProgress(videoId), 0.8);
    expect((await database.getServers()).single.authToken, 'preserve-target');
    await database.clearLocalHistory();
    expect(first.getVideoProgress(videoId), 0.8);
    expect(first.getLocalHistory().single.title, 'Original title');
  });

  test('portable watched restore cancels superseded sync without exporting it',
      () async {
    final watched = stringMapStoreFactory.store('watchState:default');
    final outbox = stringMapStoreFactory.store('watchOutbox:default');
    final memberships = stringMapStoreFactory.store('watchMembership:default');
    await watched.record(videoId).put(database.db, {
      'manualWatched': true,
      'localPlayback': false,
      'completed': false,
      'revision': 7,
    });
    await outbox.record('pending').put(database.db,
        {'videoId': videoId, 'accountId': 'private-account', 'revision': 7});
    await memberships
        .record('observation')
        .put(database.db, {'videoId': videoId, 'accountId': 'private-account'});
    final encoded = (await database.exportBackup()).encode();
    expect(encoded, isNot(contains('private-account')));
    expect(encoded, isNot(contains('revision')));
    await database.restoreBackup(UserBackup.parse(encoded), replace: true);
    expect((await watched.record(videoId).get(database.db))?['revision'], 8);
    expect(await outbox.count(database.db), 0);
    expect(await memberships.count(database.db), 1);

    final oldFormat = jsonDecode(encoded) as Map<String, dynamic>;
    oldFormat.remove('watchState');
    expect(UserBackup.parse(jsonEncode(oldFormat)).sections['watchState'],
        isEmpty);
  });

  test('profile names and invalid selections cannot damage existing state',
      () async {
    await expectLater(database.createProfile('  '), throwsFormatException);
    await expectLater(database.useProfile('missing'), throwsStateError);
    expect(database.profileId, 'default');
    await database.renameProfile('default', 'Owner');
    expect((await database.getProfiles()).single.name, 'Owner');
    await expectLater(
        database.renameProfile('missing', 'Name'), throwsStateError);
    expect(() => database.forProfile('missing'), throwsStateError);
    final person = await database.createProfile('Second');
    await expectLater(
        database.forProfile('default').useProfile(person.id), throwsStateError);
    expect(database.profileId, 'default');
  });

  test('profile deletion rejects the active, missing and last profiles',
      () async {
    await expectLater(database.deleteProfile('default'), throwsStateError);
    await expectLater(database.deleteProfile('missing'), throwsStateError);
    final second = await database.createProfile('Second');
    await expectLater(database.deleteProfile('default'), throwsStateError);
    await database.useProfile(second.id);
    await expectLater(database.deleteProfile(second.id), throwsStateError);
    await database.deleteProfile('default');
    expect((await database.getProfiles()).map((profile) => profile.id),
        [second.id]);
    await expectLater(database.deleteProfile(second.id), throwsStateError);
    await expectLater(database.useProfile('default'), throwsStateError);
    expect(database.profileId, second.id);
  });

  for (final deleteDefault in [false, true]) {
    test('deletion removes only its complete library (default=$deleteDefault)',
        () async {
      final second = await database.createProfile('Second');
      final deleted = deleteDefault ? 'default' : second.id;
      final retained = deleteDefault ? second.id : 'default';
      const stores = [
        'downloadedVideo',
        'searchHistory',
        'serviers',
        'videoFilters',
        'historyVideoCache',
        'progress',
        'offline_subscriptions',
        'settings',
      ];
      String storeName(String id, String name) =>
          id == 'default' ? name : 'profile:$id:$name';
      for (final id in ['default', second.id]) {
        for (final name in stores) {
          await stringMapStoreFactory
              .store(storeName(id, name))
              .record('private')
              .put(database.db, {'owner': id});
        }
        await intMapStoreFactory
            .store(storeName(id, 'homeLayout'))
            .record(1)
            .put(database.db, {'owner': id});
        for (final name in [
          'watchState',
          'watchMembership',
          'watchOutbox',
          'watchSync',
        ]) {
          await stringMapStoreFactory
              .store('$name:$id')
              .record('private')
              .put(database.db, {'owner': id});
        }
      }
      for (final key in [
        networkSocksProxySettingName,
        skipSslVerificationSettingName,
        'download-folder',
        forceTvUiSettingName,
      ]) {
        await database.saveSetting(SettingsValue(key, 'device value'));
      }
      for (final name in ['appLogs', 'dearrow']) {
        await stringMapStoreFactory
            .store(name)
            .record('shared')
            .put(database.db, {'value': 'shared'});
      }
      await database.useProfile(retained);
      await database.deleteProfile(deleted);
      for (final name in stores) {
        expect(
            await stringMapStoreFactory
                .store(storeName(deleted, name))
                .record('private')
                .get(database.db),
            isNull);
        expect(
            await stringMapStoreFactory
                .store(storeName(retained, name))
                .record('private')
                .get(database.db),
            {'owner': retained});
      }
      expect(
          await intMapStoreFactory
              .store(storeName(deleted, 'homeLayout'))
              .count(database.db),
          0);
      expect(
          await intMapStoreFactory
              .store(storeName(retained, 'homeLayout'))
              .count(database.db),
          1);
      for (final name in [
        'watchState',
        'watchMembership',
        'watchOutbox',
        'watchSync',
      ]) {
        expect(
            await stringMapStoreFactory
                .store('$name:$deleted')
                .count(database.db),
            0);
        expect(
            await stringMapStoreFactory
                .store('$name:$retained')
                .count(database.db),
            1);
      }
      for (final key in [
        networkSocksProxySettingName,
        skipSslVerificationSettingName,
        'download-folder',
        forceTvUiSettingName,
      ]) {
        expect(database.getSettings(key)?.value, 'device value');
      }
      for (final name in ['appLogs', 'dearrow']) {
        expect(await stringMapStoreFactory.store(name).count(database.db), 1);
      }
    });
  }

  test('deleted default stays deleted across initialization and a reopen',
      () async {
    final factory = newDatabaseFactoryMemory();
    var client = SembastSqfDb(await factory.openDatabase('deleted-default'));
    try {
      await client.getProfiles();
      final second = await client.createProfile('Second');
      await client.useProfile(second.id);
      await client.deleteProfile('default');
      expect(() => client.forProfile('default'), throwsStateError);
      await client.close();
      client = SembastSqfDb(await factory.openDatabase('deleted-default'));
      expect((await client.getProfiles()).map((profile) => profile.id),
          [second.id]);
      expect(client.profileId, second.id);
      await client.renameProfile(second.id, 'Renamed');
      final third = await client.createProfile('Third');
      expect((await client.getProfiles()).map((profile) => profile.id),
          unorderedEquals([second.id, third.id]));
      // Repair a stale persisted selection using an existing person.
      await stringMapStoreFactory
          .store('personProfileState')
          .record('active')
          .put(client.db, {'id': 'default'});
      await client.getProfiles();
      expect([second.id, third.id], contains(client.profileId));
      expect(() => client.forProfile('default'), throwsStateError);
    } finally {
      await client.close();
    }
  });

  test('deleted captured views cannot read, write or recreate their person',
      () async {
    final second = await database.createProfile('Second');
    final owner = database.forProfile('default');
    final watch = WatchRepository(owner);
    await watch.beginPlayback(videoId); // Initialize its cached store handles.
    await database.useProfile(second.id);
    await database.deleteProfile('default');
    expect(() => owner.db, throwsStateError);
    expect(() => owner.profileId, throwsStateError);
    expect(() => owner.settingsStore, throwsStateError);
    expect(() => owner.getSettings('download-folder'), throwsStateError);
    expect(() => owner.getVideoProgress(videoId), throwsStateError);
    expect(() => watch.status(videoId), throwsStateError);
    await expectLater(owner.getProfiles(), throwsStateError);
    await expectLater(owner.useProfile('default'), throwsStateError);
    await expectLater(owner.saveSetting(SettingsValue('local-playlists', '[]')),
        throwsStateError);
    await expectLater(
        owner.saveProgress(Progress(1, videoId)), throwsStateError);
    expect((await database.getProfiles()).map((profile) => profile.id),
        [second.id]);
    await owner.close();
    expect(database.profileId, second.id);
  });

  test('writes queued behind deletion cannot recreate private stores',
      () async {
    final person = await database.createProfile('Remove');
    final owner = database.forProfile(person.id);
    final watch = WatchRepository(owner);
    final library = PlaylistLibraryService.forProfile(owner, person.id);
    final checkpoints = PlaylistProgressService.forProfile(owner, person.id);
    await watch.beginPlayback(videoId);
    final entered = Completer<void>();
    final release = Completer<void>();
    final blocking = database.db.transaction((txn) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final deletion = database.deleteProfile(person.id);
    final failures = [
      expectLater(owner.saveSetting(SettingsValue('local-playlists', '[]')),
          throwsStateError),
      expectLater(owner.saveProgress(Progress(1, videoId)), throwsStateError),
      expectLater(
          owner.upsertHistoryVideo(
              HistoryVideoCache(videoId, 'Late history', 'Author', '')),
          throwsStateError),
      expectLater(watch.beginPlayback(videoId), throwsStateError),
      expectLater(watch.mergeRemote('account', {videoId}, complete: true),
          throwsStateError),
      expectLater(watch.setSyncStatus('account', 'synced'), throwsStateError),
      expectLater(
          library.remove(PlaylistReference(
              kind: PlaylistSourceKind.public,
              playlistId: 'PLremoved',
              profileId: person.id)),
          throwsStateError),
      expectLater(checkpoints.clear(), throwsStateError),
    ];
    release.complete();
    await blocking;
    await deletion;
    await Future.wait(failures);
    for (final name in ['settings', 'progress', 'historyVideoCache']) {
      expect(
          await stringMapStoreFactory
              .store('profile:${person.id}:$name')
              .count(database.db),
          0);
    }
    for (final name in [
      'watchState',
      'watchMembership',
      'watchOutbox',
      'watchSync'
    ]) {
      expect(
          await stringMapStoreFactory
              .store('$name:${person.id}')
              .count(database.db),
          0);
    }
    expect((await database.getProfiles()).single.id, 'default');
  });

  test('a history reply after profile deletion cancels without reviving data',
      () async {
    final person = await database.createProfile('Remove');
    final owner = database.forProfile(person.id);
    final account = Server(
        url: endpoint,
        id: 'account',
        profileId: person.id,
        authToken: 'test-token');
    await owner.upsertServer(account);
    final entered = Completer<void>();
    final response = Completer<List<String>>();
    final worker = WatchHistorySync(
        repository: WatchRepository(owner),
        readPage: (_, __, ___) {
          entered.complete();
          return response.future;
        },
        changeHistory: (_, __, ___) async => fail('Unexpected history write'),
        accountIsCurrent: (_) async => (await owner.getServers()).isNotEmpty);
    final running = worker.run(account);
    await entered.future;
    await database.saveProgress(Progress(0.35, videoId));
    await database.deleteProfile(person.id);
    response.complete([videoId]);
    await running;
    await worker.run(account, force: true);
    // A late unawaited request must also stop before constructing a new worker.
    await Service().syncAccountHistory(account, database: owner);
    expect(database.getVideoProgress(videoId), 0.35);
    for (final name in [
      'watchState',
      'watchMembership',
      'watchOutbox',
      'watchSync'
    ]) {
      expect(
          await stringMapStoreFactory
              .store('$name:${person.id}')
              .count(database.db),
          0);
    }
  });

  test(
      'local history deletion removes watched state and pending intent only here',
      () async {
    final second = await database.createProfile('Second');
    for (final id in ['default', second.id]) {
      final view = database.forProfile(id);
      await view.saveProgress(Progress(1, videoId));
      await view.upsertHistoryVideo(
          HistoryVideoCache(videoId, 'Watched video', 'Author', ''));
      await stringMapStoreFactory
          .store('watchState:$id')
          .record(videoId)
          .put(database.db, {'completed': true, 'revision': 1});
      for (final name in ['watchMembership', 'watchOutbox']) {
        await stringMapStoreFactory
            .store('$name:$id')
            .record('entry')
            .put(database.db, {'videoId': videoId, 'accountId': 'account'});
      }
    }
    await database.deleteLocalHistory(videoId);
    expect(database.getVideoProgress(videoId), 0);
    for (final name in ['watchState', 'watchMembership', 'watchOutbox']) {
      expect(
          await stringMapStoreFactory.store('$name:default').count(database.db),
          0);
      expect(
          await stringMapStoreFactory
              .store('$name:${second.id}')
              .count(database.db),
          1);
    }
    final other = database.forProfile(second.id);
    expect(other.getVideoProgress(videoId), 1);
    await other.clearLocalHistory();
    for (final name in ['watchState', 'watchMembership', 'watchOutbox']) {
      expect(
          await stringMapStoreFactory
              .store('$name:${second.id}')
              .count(database.db),
          0);
    }
  });
}
