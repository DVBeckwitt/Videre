import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:clipious/globals.dart' as globals;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/notifications/models/db/channel_notifications.dart';
import 'package:clipious/notifications/models/db/playlist_notifications.dart';
import 'package:clipious/notifications/models/db/subscription_notifications.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/no_server_selected.dart';
import 'package:clipious/utils/file_db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documentsDirectory;
  late SembastSqfDb database;

  Future<Object?> documentsPath(MethodCall _) async => documentsDirectory.path;

  setUp(() async {
    documentsDirectory =
        await Directory.systemTemp.createTemp('videre-file-db-test-');
    messenger.setMockMethodCallHandler(pathProvider, documentsPath);
    database = await SembastSqfDb.createInMemory();
    globals.db = database;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProvider, null);
    await database.close();
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  ({Future<void> entered, void Function() release}) blockNextDocumentsLookup() {
    final entered = Completer<void>();
    final release = Completer<void>();
    var pending = true;
    messenger.setMockMethodCallHandler(pathProvider, (_) async {
      if (pending) {
        pending = false;
        entered.complete();
        await release.future;
      }
      return documentsDirectory.path;
    });
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    return (entered: entered.future, release: release.complete);
  }

  test('subscription notification file db', () async {
    FileDB db = FileDB();

    var n = await db.getLastSubscriptionNotification();
    expect(n == null, true);

    await db
        .setLastSubscriptionNotification(SubscriptionNotification("abc", 123));
    n = await db.getLastSubscriptionNotification();
    expect(n != null, true);
    expect(n!.lastSeenVideoId, "abc");
    expect(n.timestamp, 123);
  });

  test('test playlist notifications file db', () async {
    FileDB db = FileDB();

    var notifs = await db.getAllPlaylistNotifications();
    expect(notifs.isEmpty, true);

    await db.upsertPlaylistNotification(
        PlaylistNotification("abc", 5, 1234, "My playlist"));
    notifs = await db.getAllPlaylistNotifications();
    expect(notifs.length, 1);

    var n = await db.getPlaylistNotification("abc");
    expect(n != null, true);
    expect(n!.playlistId, "abc");
    expect(n.lastVideoCount, 5);
    expect(n.timestamp, 1234);
    expect(n.playlistName, "My playlist");

    // we shouldn't be able to change the playlistId
    n.lastVideoCount = 6;
    n.timestamp = 1235;
    n.playlistName = "new name";

    await db.upsertPlaylistNotification(n);

    // making sure we're not creating new entries on edit
    notifs = await db.getAllPlaylistNotifications();
    expect(notifs.length, 1);

    n = await db.getPlaylistNotification("abc");
    expect(n != null, true);
    expect(n!.playlistId, "abc");
    expect(n.lastVideoCount, 6);
    expect(n.timestamp, 1235);
    expect(n.playlistName, "new name");

    // testing the method to directly set video count
    await db.setPlaylistNotificationLastViewedVideo("abc", 7);
    n = await db.getPlaylistNotification("abc");
    expect(n != null, true);
    expect(n!.playlistId, "abc");
    expect(n.lastVideoCount, 7);
    // not testing timestamp as it is set by the method
    expect(n.playlistName, "new name");

    // i can have more than one notifications
    var newNotif = PlaylistNotification("123", 123, 123, "another playlist");
    await db.upsertPlaylistNotification(newNotif);

    notifs = await db.getAllPlaylistNotifications();
    expect(notifs.length, 2);

    //we should be able to get notifications separately if there are more than one
    n = await db.getPlaylistNotification("123");
    expect(n != null, true);
    expect(n!.playlistId, "123");

    n = await db.getPlaylistNotification("abc");
    expect(n != null, true);
    expect(n!.playlistId, "abc");

    // we remove everything to test
    await db.deletePlaylistNotification(n);
    await db.deletePlaylistNotification(newNotif);

    notifs = await db.getAllPlaylistNotifications();
    expect(notifs.length, 0);

    // i should be able to try to delete something that doesn't exist without problem
    await db.deletePlaylistNotification(
        PlaylistNotification("anotherid", 123, 123, "oops"));
  });

  test('Channel notifications', () async {
    FileDB db = FileDB();

    var notifs = await db.getAllChannelNotifications();
    expect(notifs.isEmpty, true);

    await db.upsertChannelNotification(
        ChannelNotification("abc", "channel1", "abc", 123));
    notifs = await db.getAllChannelNotifications();
    expect(notifs.length, 1);

    var n = await db.getChannelNotification("abc");
    expect(n != null, true);
    expect(n!.channelId, "abc");
    expect(n.lastSeenVideoId, "abc");
    expect(n.timestamp, 123);
    expect(n.channelName, "channel1");

    // we shouldn't be able to change the playlistId
    n.lastSeenVideoId = "def";
    n.timestamp = 1235;
    n.channelName = "new channel1";

    await db.upsertChannelNotification(n);

    // making sure we're not creating new entries on edit
    notifs = await db.getAllChannelNotifications();
    expect(notifs.length, 1);

    n = await db.getChannelNotification("abc");
    expect(n != null, true);
    expect(n!.channelId, "abc");
    expect(n.lastSeenVideoId, "def");
    expect(n.timestamp, 1235);
    expect(n.channelName, "new channel1");

    // testing the method to directly set video count
    await db.setChannelNotificationLastViewedVideo("abc", "aaa");
    n = await db.getChannelNotification("abc");
    expect(n != null, true);
    expect(n!.channelId, "abc");
    expect(n.lastSeenVideoId, "aaa");
    expect(n.channelName, "new channel1");

    // i can have more than one notifications
    var newNotif = ChannelNotification("abcd", "channel1", "abc", 123);
    await db.upsertChannelNotification(newNotif);

    // i should be able to get all notifs properly if there's more than 1
    n = await db.getChannelNotification("abcd");
    expect(n != null, true);
    expect(n!.channelId, "abcd");

    // we try the first one again
    n = await db.getChannelNotification("abc");
    expect(n != null, true);
    expect(n!.channelId, "abc");

    notifs = await db.getAllChannelNotifications();
    expect(notifs.length, 2);

    // we remove everything to test
    await db.deleteChannelNotification(n);
    await db.deleteChannelNotification(newNotif);

    notifs = await db.getAllChannelNotifications();
    expect(notifs.length, 0);

    // i should be able to try to delete something that doesn't exist without problem
    await db.deleteChannelNotification(
        ChannelNotification("fdafa", "channelNamefdsfas", "fsdfsdf", 1313));
  });

  test('generic settings logs exclude credentials', () async {
    const credential = 'credential-marker-42';
    final previousLevel = Logger.root.level;
    final records = <LogRecord>[];
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await subscription.cancel();
    });

    await FileDB().updateGenericSettings(FileDbGenericSettings()
      ..server = const Server(
        url: 'https://inv.example',
        authToken: credential,
        sidCookie: credential,
        customHeaders: {'Authorization': credential},
      ));

    final messages = records.map((record) => record.message).join('\n');
    expect(messages, contains('Writing json to'));
    expect(messages, isNot(contains(credential)));
  });

  test('concurrent generic settings changes preserve unrelated fields',
      () async {
    const server = Server(url: 'https://inv.example');
    await Future.wait([
      FileDB().setLocale('fr'),
      FileDB().setSubscriptionNotifications(true),
      FileDB().useServer(server),
    ]);

    final settings = await FileDB().getGenericSettings();
    expect(settings.locale, 'fr');
    expect(settings.subscriptionNotifications, isTrue);
    expect(settings.server, server);
  });

  test('profile snapshots survive restart and new people have no account',
      () async {
    final storage = FileDB();
    const original = Server(url: 'https://inv.example', authToken: 'original');
    await storage.useServer(original);
    await storage.setLocale('fr');
    await storage.setSubscriptionNotifications(true);
    await storage.upsertChannelNotification(
        ChannelNotification('channel', 'Original channel', 'first', 1));

    await storage.useProfile('second');
    final restarted = FileDB();
    expect((await restarted.getGenericSettings()).profileId, 'second');
    expect(restarted.profileId, 'second');
    expect(await restarted.getServers(), isEmpty);
    await expectLater(restarted.getCurrentlySelectedServer(),
        throwsA(isA<NoServerSelected>()));
    expect(await restarted.getLocale(), isNull);
    expect(await restarted.getSubscriptionNotifications(), isFalse);
    expect(await restarted.getAllChannelNotifications(), isEmpty);

    const second = Server(
        url: 'https://inv.example',
        profileId: 'second',
        id: 'second-account',
        authToken: 'second');
    await restarted.useServer(second);
    await restarted.setLocale('de');
    await restarted.upsertChannelNotification(
        ChannelNotification('channel', 'Second channel', 'second', 2));
    await restarted.useProfile('default');

    expect(await FileDB().getCurrentlySelectedServer(), original);
    expect(await FileDB().getLocale(), 'fr');
    expect(await FileDB().getSubscriptionNotifications(), isTrue);
    expect((await FileDB().getChannelNotification('channel'))!.channelName,
        'Original channel');
    expect(await restarted.forProfile('second').getCurrentlySelectedServer(),
        second);
    expect(await restarted.forProfile('second').getLocale(), 'de');
  });

  test('fixed profile updates cannot change the active person', () async {
    final storage = FileDB();
    const first = Server(url: 'https://first.example', authToken: 'first');
    const second = Server(
        url: 'https://second.example',
        profileId: 'second',
        id: 'second-account',
        authToken: 'second');
    await storage.useServer(first);
    final captured = storage.forProfile('default');
    await storage.useProfile('second');
    await storage.useServer(second);
    await captured.useServer(first.copyWith(authToken: 'refreshed'));
    await captured.setLocale('es');
    await captured.upsertPlaylistNotification(
        PlaylistNotification('playlist', 3, 1, 'First playlist'));

    expect(await storage.getCurrentlySelectedServer(), second);
    expect(await storage.getLocale(), isNull);
    expect(await storage.getAllPlaylistNotifications(), isEmpty);
    expect(
        (await captured.getCurrentlySelectedServer()).authToken, 'refreshed');
    expect(await captured.getLocale(), 'es');
    expect(() => captured.useServer(second), throwsStateError);
    expect(() => captured.useProfile('second'), throwsStateError);
  });

  test('queued credential refresh cannot reselect a superseded account',
      () async {
    final storage = FileDB();
    const first =
        Server(url: 'https://inv.example', id: 'first', authToken: 'a');
    const second =
        Server(url: 'https://inv.example', id: 'second', authToken: 'b');
    await database.upsertServer(first);
    await database.upsertServer(second);
    await storage.useServer(first);

    final gate = blockNextDocumentsLookup();
    final switching = storage.useServer(second);
    await gate.entered;
    final staleRefresh = storage.forProfile('default').refreshAccount(first);
    await database.useServer(second);
    gate.release();
    await Future.wait([switching, staleRefresh]);

    expect((await storage.getCurrentlySelectedServer()).accountId, 'second');
    expect((await storage.getCurrentlySelectedServer()).authToken, 'b');
  });

  test('queued credential refresh mirrors the latest saved tokens', () async {
    final storage = FileDB();
    const account =
        Server(url: 'https://inv.example', id: 'account', authToken: 'old');
    await database.upsertServer(account);
    await storage.useServer(account);

    final gate = blockNextDocumentsLookup();
    final preceding = storage.setLocale('fr');
    await gate.entered;
    final refresh = storage.refreshAccount(account);
    await database.upsertServer(
        database.getServer('account')!.copyWith(authToken: 'latest'));
    gate.release();
    await Future.wait([preceding, refresh]);

    expect((await storage.getCurrentlySelectedServer()).authToken, 'latest');
    expect(await storage.getLocale(), 'fr');
  });

  test('refresh of a deleted legacy account cannot mirror its URL replacement',
      () async {
    final storage = FileDB();
    const legacy = Server(url: 'https://inv.example', authToken: 'legacy');
    const replacement = Server(
        url: 'https://inv.example', id: 'replacement', authToken: 'other');
    await database.upsertServer(legacy);
    await storage.useServer(legacy);
    await database.upsertServer(replacement);
    await database.deleteServerById(legacy);
    await database.useServer(replacement);

    await storage.refreshAccount(legacy);

    expect((await storage.getCurrentlySelectedServer()).accountId,
        legacy.accountId);
    expect((await storage.getCurrentlySelectedServer()).authToken, 'legacy');
    // Selection synchronization, rather than the stale authentication result,
    // remains responsible for moving the mirror to another saved account.
    await storage.syncWithDb();
    expect((await storage.getCurrentlySelectedServer()).accountId,
        replacement.accountId);
    expect((await storage.getCurrentlySelectedServer()).authToken, 'other');
  });

  test('queued credential refresh cannot change a newly selected person',
      () async {
    final storage = FileDB();
    const account = Server(
        url: 'https://inv.example', id: 'account', authToken: 'original');
    await database.upsertServer(account);
    await storage.useServer(account);
    final person = await database.createProfile('Second person');

    final gate = blockNextDocumentsLookup();
    final switching = storage.useProfile(person.id);
    await gate.entered;
    final staleRefresh = storage.forProfile('default').refreshAccount(account);
    await database.useProfile(person.id);
    gate.release();
    await Future.wait([switching, staleRefresh]);

    final active = await storage.getGenericSettings();
    expect(active.profileId, person.id);
    expect(active.server, isNull);
  });

  test('queued full synchronization resolves the current account and tokens',
      () async {
    final storage = FileDB();
    const first =
        Server(url: 'https://inv.example', id: 'first', authToken: 'a');
    const second =
        Server(url: 'https://inv.example', id: 'second', authToken: 'old-b');
    await database.upsertServer(first);
    await database.upsertServer(second);
    await storage.useServer(first);

    final gate = blockNextDocumentsLookup();
    final preceding = storage.setLocale('fr');
    await gate.entered;
    final syncing = storage.syncWithDb();
    await database.useServer(second);
    await database.upsertServer(
        database.getServer('second')!.copyWith(authToken: 'latest-b'));
    gate.release();
    await Future.wait([preceding, syncing]);

    final selected = await storage.getCurrentlySelectedServer();
    expect(selected.accountId, 'second');
    expect(selected.authToken, 'latest-b');
  });

  test('queued empty-profile synchronization keeps a newly added first account',
      () async {
    final storage = FileDB();
    final gate = blockNextDocumentsLookup();
    final preceding = storage.setLocale('fr');
    await gate.entered;
    final syncing = storage.syncWithDb();
    const account = Server(
        url: 'https://inv.example', id: 'first-account', authToken: 'new');
    await database.upsertServer(account);
    gate.release();
    await Future.wait([preceding, syncing]);

    final selected = await storage.getCurrentlySelectedServer();
    expect(selected.accountId, 'first-account');
    expect(selected.authToken, 'new');
  });

  test('same-person accounts have independent notification cursors', () async {
    final storage = FileDB();
    const first = Server(url: 'https://inv.example', id: 'first');
    const second = Server(url: 'https://inv.example', id: 'second');
    await storage.useServer(first);
    await storage.upsertChannelNotification(
        ChannelNotification('channel', 'Shared channel', 'first-video', 1));
    await storage.upsertPlaylistNotification(
        PlaylistNotification('playlist', 4, 1, 'Shared playlist'));
    await storage.setLastSubscriptionNotification(
        SubscriptionNotification('first-subscription', 1));
    final captured = storage.forAccount(first);

    await storage.useServer(second);
    expect((await storage.getChannelNotification('channel'))!.lastSeenVideoId,
        isEmpty);
    expect(
        (await storage.getPlaylistNotification('playlist'))!.lastVideoCount, 0);
    expect(await storage.getLastSubscriptionNotification(), isNull);
    await storage.setChannelNotificationLastViewedVideo(
        'channel', 'second-video');
    await storage.setPlaylistNotificationLastViewedVideo('playlist', 8);
    await storage.setLastSubscriptionNotification(
        SubscriptionNotification('second-subscription', 2));
    await captured.setChannelNotificationLastViewedVideo(
        'channel', 'late-first-video');
    await captured.setLastSubscriptionNotification(
        SubscriptionNotification('late-first-subscription', 3));

    expect(await captured.getCurrentlySelectedServer(), first);
    expect(await storage.getCurrentlySelectedServer(), second);
    expect((await storage.getChannelNotification('channel'))!.lastSeenVideoId,
        'second-video');
    expect((await captured.getChannelNotification('channel'))!.lastSeenVideoId,
        'late-first-video');
    expect((await captured.getPlaylistNotification('playlist'))!.lastVideoCount,
        4);
    expect((await storage.getLastSubscriptionNotification())!.lastSeenVideoId,
        'second-subscription');
    expect((await captured.getLastSubscriptionNotification())!.lastSeenVideoId,
        'late-first-subscription');
  });

  test('legacy notification cursors belong only to the old selected account',
      () async {
    const legacy = Server(url: 'https://legacy.example', authToken: 'legacy');
    final folder = Directory(p.join(documentsDirectory.path, 'fileDb'));
    await folder.create(recursive: true);
    await File(p.join(folder.path, 'generic_settings.json'))
        .writeAsString(jsonEncode({
      'server': {'url': legacy.url, 'authToken': legacy.authToken},
      'subscriptionNotifications': true,
      'locale': 'en'
    }));
    await File(p.join(folder.path, 'subscription_notifications.json'))
        .writeAsString(jsonEncode(
            SubscriptionNotification('legacy-subscription', 1).toJson()));
    await File(p.join(folder.path, 'channel_notifications.json'))
        .writeAsString(jsonEncode({
      'channel':
          ChannelNotification('channel', 'Legacy channel', 'legacy-video', 1)
              .toJson()
    }));
    await File(p.join(folder.path, 'playlist_notifications.json'))
        .writeAsString(jsonEncode({
      'playlist':
          PlaylistNotification('playlist', 5, 1, 'Legacy playlist').toJson()
    }));

    final storage = FileDB();
    expect((await storage.getLastSubscriptionNotification())!.lastSeenVideoId,
        'legacy-subscription');
    await storage.useServer(
        const Server(url: 'https://legacy.example', id: 'new-account'));
    expect(await FileDB().getLastSubscriptionNotification(), isNull);
    expect((await storage.getChannelNotification('channel'))!.lastSeenVideoId,
        isEmpty);
    expect(
        (await storage.getPlaylistNotification('playlist'))!.lastVideoCount, 0);
    // Editing the configuration for a new account must not replace the old
    // account's legacy cursor when its notification preference is retained.
    await storage.upsertChannelNotification(
        ChannelNotification('channel', 'Renamed channel', 'new-video', 2));
    await storage.useServer(legacy);
    expect((await FileDB().getLastSubscriptionNotification())!.lastSeenVideoId,
        'legacy-subscription');
    expect((await storage.getChannelNotification('channel'))!.lastSeenVideoId,
        'legacy-video');
    expect(
        (await storage.getPlaylistNotification('playlist'))!.lastVideoCount, 5);
  });

  test('clearing one profile leaves other notification files and accounts',
      () async {
    final storage = FileDB();
    const original = Server(url: 'https://original.example');
    await storage.useServer(original);
    await storage.upsertChannelNotification(
        ChannelNotification('channel', 'Original channel', 'first', 1));
    await storage.useProfile('second');
    await storage.useServer(const Server(
        url: 'https://second.example', profileId: 'second', id: 'second'));
    await storage.upsertChannelNotification(
        ChannelNotification('channel', 'Second channel', 'second', 2));
    await storage.clearDb();
    expect(await storage.getAllChannelNotifications(), isEmpty);
    expect(await storage.getServers(), isEmpty);
    await storage.useProfile('default');
    expect(await storage.getCurrentlySelectedServer(), original);
    expect((await storage.getChannelNotification('channel'))!.channelName,
        'Original channel');
  });

  test('concurrent channel notification edits preserve other entries',
      () async {
    final first = ChannelNotification('first', 'First', 'old', 1);
    final second = ChannelNotification('second', 'Second', 'old', 1);
    final third = ChannelNotification('third', 'Third', 'old', 1);
    await Future.wait([
      FileDB().upsertChannelNotification(first),
      FileDB().upsertChannelNotification(second),
    ]);
    expect(
        (await FileDB().getAllChannelNotifications()).map((n) => n.channelId),
        unorderedEquals(['first', 'second']));

    await Future.wait([
      FileDB().deleteChannelNotification(first),
      FileDB().setChannelNotificationLastViewedVideo('second', 'new'),
      FileDB().upsertChannelNotification(third),
    ]);
    final notifications = await FileDB().getAllChannelNotifications();
    expect(notifications.map((n) => n.channelId),
        unorderedEquals(['second', 'third']));
    expect(
        notifications
            .firstWhere((n) => n.channelId == 'second')
            .lastSeenVideoId,
        'new');

    await Future.wait([
      FileDB().deleteChannelNotification(second),
      FileDB().setChannelNotificationLastViewedVideo('second', 'late'),
    ]);
    expect(await FileDB().getChannelNotification('second'), isNull);
  });

  test('concurrent playlist notification edits preserve other entries',
      () async {
    final first = PlaylistNotification('first', 1, 1, 'First');
    final second = PlaylistNotification('second', 1, 1, 'Second');
    final third = PlaylistNotification('third', 1, 1, 'Third');
    await Future.wait([
      FileDB().upsertPlaylistNotification(first),
      FileDB().upsertPlaylistNotification(second),
    ]);
    expect(
        (await FileDB().getAllPlaylistNotifications()).map((n) => n.playlistId),
        unorderedEquals(['first', 'second']));

    await Future.wait([
      FileDB().deletePlaylistNotification(first),
      FileDB().setPlaylistNotificationLastViewedVideo('second', 2),
      FileDB().upsertPlaylistNotification(third),
    ]);
    final notifications = await FileDB().getAllPlaylistNotifications();
    expect(notifications.map((n) => n.playlistId),
        unorderedEquals(['second', 'third']));
    expect(
        notifications
            .firstWhere((n) => n.playlistId == 'second')
            .lastVideoCount,
        2);

    await Future.wait([
      FileDB().deletePlaylistNotification(second),
      FileDB().setPlaylistNotificationLastViewedVideo('second', 3),
    ]);
    expect(await FileDB().getPlaylistNotification('second'), isNull);
  });

  test('a failed file update does not prevent later updates', () async {
    var requests = 0;
    messenger.setMockMethodCallHandler(pathProvider, (_) async {
      if (requests++ == 0) throw PlatformException(code: 'unavailable');
      return documentsDirectory.path;
    });

    final failed = expectLater(
        FileDB().setLocale('fr'), throwsA(isA<PlatformException>()));
    final successful = FileDB().setSubscriptionNotifications(true);
    await Future.wait([failed, successful]);

    expect(await FileDB().getSubscriptionNotifications(), isTrue);
  });

  test('viewing items without notifications does not write notification files',
      () async {
    await FileDB().setChannelNotificationLastViewedVideo('unwatched', 'new');
    await FileDB().setPlaylistNotificationLastViewedVideo('unwatched', 2);

    final files = await Directory(p.join(documentsDirectory.path, 'fileDb'))
        .list()
        .toList();
    expect(files, isEmpty);
  });

  test('clearDb reports deletion failures', () async {
    final invalidFile = Directory(p.join(
      documentsDirectory.path,
      'fileDb',
      'channel_notifications.json',
    ));
    await invalidFile.create(recursive: true);

    await expectLater(FileDB().clearDb(), throwsA(isA<FileSystemException>()));
  });

  test('clearDb ignores missing files', () async {
    await FileDB().clearDb();
  });

  test('storage clients report unavailable app storage', () async {
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    final unavailable = throwsA(isA<PlatformException>()
        .having((error) => error.code, 'code', 'unavailable'));

    await expectLater(FileDB().getGenericSettings(), unavailable);
    await expectLater(SembastSqfDb.create(), unavailable);
  });
}
