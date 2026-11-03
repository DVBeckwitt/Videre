import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/person_profile.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/settings/models/errors/no_server_selected.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';

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
      await client.saveProgress(Progress(0.45, videoId));
      await client.upsertHistoryVideo(
          HistoryVideoCache(videoId, 'Existing video', 'Author', ''));
      await client.saveSetting(SettingsValue('local-playlists', '[]'));

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
