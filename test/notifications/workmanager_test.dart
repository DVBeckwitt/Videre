import 'dart:async';
import 'dart:io';

import 'package:awesome_notifications/awesome_notifications_method_channel.dart';
import 'package:awesome_notifications/awesome_notifications_platform_interface.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/notifications/models/db/playlist_notifications.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/workmanager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _NotificationService extends Service {
  UserFeed feed = UserFeed([], []);
  int playlistCount = 7;
  Future<void> Function()? beforeFeed;
  Future<void> Function()? beforePlaylist;
  final requestedServers = <Server?>[];

  @override
  Future<UserFeed> getUserFeed(
      {int? maxResults,
      int? page,
      bool saveLastSeen = true,
      Server? serverOverride}) async {
    expect(saveLastSeen, isFalse);
    requestedServers.add(serverOverride);
    await beforeFeed?.call();
    return feed;
  }

  @override
  Future<Playlist> getPublicPlaylists(String playlistId,
      {int? page, bool saveLastSeen = true, Server? serverOverride}) async {
    expect(saveLastSeen, isFalse);
    requestedServers.add(serverOverride);
    await beforePlaylist?.call();
    return Playlist(
        title: 'A playlist',
        playlistId: playlistId,
        author: 'Author',
        videoCount: playlistCount,
        videos: const [Video(videoId: 'latest')]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const notifications = MethodChannel('awesome_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documentsDirectory;
  late _NotificationService notificationService;
  late AwesomeNotificationsPlatform originalNotifications;
  final sent = <Map<Object?, Object?>>[];
  final cancelled = <int>[];
  Completer<bool>? pendingNotification;

  setUp(() async {
    documentsDirectory =
        await Directory.systemTemp.createTemp('videre-notification-test-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documentsDirectory.path);
    originalNotifications = AwesomeNotificationsPlatform.instance;
    AwesomeNotificationsPlatform.instance = MethodChannelAwesomeNotifications();
    messenger.setMockMethodCallHandler(notifications, (call) async {
      if (call.method == 'cancelNotification') {
        cancelled.add(call.arguments as int);
        return true;
      }
      expect(call.method, 'createNewNotification');
      final arguments = call.arguments as Map<Object?, Object?>;
      sent.add(arguments['content']! as Map<Object?, Object?>);
      return pendingNotification?.future ?? true;
    });
    sent.clear();
    cancelled.clear();
    pendingNotification = null;
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(const Server(
        url: 'https://instance.example', inUse: true, authToken: 'test-token'));
    await fileDb.useServer(await db.getCurrentlySelectedServer());
    notificationService = _NotificationService();
    service = notificationService;
    await fileDb.setLocale('en');
  });

  tearDown(() async {
    AwesomeNotificationsPlatform.instance = originalNotifications;
    messenger.setMockMethodCallHandler(notifications, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    await db.close();
    await documentsDirectory.delete(recursive: true);
  });

  test('playlist additions report the positive number of new videos', () async {
    await fileDb.upsertPlaylistNotification(
        PlaylistNotification('playlist', 5, 123, 'A playlist'));

    await checkForNewVideos();

    expect(sent, hasLength(1));
    expect(sent.single['body'], contains('2 new videos'));
    expect(sent.single['payload'], {
      'playlistId': 'playlist',
      'profileId': 'default',
      'accountId': 'https://instance.example',
    });
  });

  for (final count in [5, 3]) {
    test('playlist count $count does not report new videos after count 5',
        () async {
      await fileDb.upsertPlaylistNotification(
          PlaylistNotification('playlist', 5, 123, 'A playlist'));
      notificationService.playlistCount = count;

      await checkForNewVideos();

      expect(sent, isEmpty);
    });
  }

  test('an initially empty playlist reports its first video', () async {
    await fileDb.upsertPlaylistNotification(
        PlaylistNotification('playlist', 0, 123, 'A playlist'));
    notificationService.playlistCount = 1;

    await checkForNewVideos();

    expect(sent, hasLength(1));
    expect(sent.single['body'], contains('1 new video'));
  });

  test(
      'first subscription check records newest video without reporting old ones',
      () async {
    await fileDb.setSubscriptionNotifications(true);
    notificationService.feed = UserFeed([], const [
      Video(videoId: 'newest'),
      Video(videoId: 'older'),
      Video(videoId: 'oldest'),
    ]);

    await checkForNewVideos();

    expect((await fileDb.getLastSubscriptionNotification())!.lastSeenVideoId,
        'newest');
    expect(sent, isEmpty);

    await checkForNewVideos();
    expect(sent, isEmpty);

    notificationService.feed = UserFeed([], const [
      Video(videoId: 'new-upload'),
      Video(videoId: 'newest'),
      Video(videoId: 'older'),
    ]);
    await checkForNewVideos();

    expect(sent, hasLength(1));
    expect(sent.single['body'], contains('1 new video'));
    expect(sent.single['payload'], {
      'lastSeenVideo': 'new-upload',
      'profileId': 'default',
      'accountId': 'https://instance.example',
    });
  });

  test(
      'a delayed subscription response cannot initialize another account cursor',
      () async {
    await fileDb.setSubscriptionNotifications(true);
    final original = await db.getCurrentlySelectedServer();
    final started = Completer<void>();
    final release = Completer<void>();
    notificationService.feed =
        UserFeed([], const [Video(videoId: 'original-private-video')]);
    notificationService.beforeFeed = () {
      started.complete();
      return release.future;
    };

    final checking = checkForNewVideos();
    await started.future;
    final next = original.copyWith(id: 'second-account', authToken: 'second');
    await db.upsertServer(next);
    await db.useServer(next);
    await fileDb.useServer(next);
    release.complete();
    await checking;

    expect(notificationService.requestedServers, [original]);
    expect(sent, isEmpty);
    expect(await fileDb.forAccount(original).getLastSubscriptionNotification(),
        isNull);
    expect(await fileDb.forAccount(next).getLastSubscriptionNotification(),
        isNull);
  });

  test('a delayed playlist response cannot notify after a person switch',
      () async {
    await fileDb.upsertPlaylistNotification(
        PlaylistNotification('playlist', 5, 123, 'Private playlist'));
    final original = await db.getCurrentlySelectedServer();
    final started = Completer<void>();
    final release = Completer<void>();
    notificationService.beforePlaylist = () {
      started.complete();
      return release.future;
    };

    final checking = checkForNewVideos();
    await started.future;
    final person = await db.createProfile('Another person');
    await db.useProfile(person.id);
    final next = original.copyWith(
        profileId: person.id, id: 'another-account', authToken: 'another');
    await db.upsertServer(next);
    await db.useServer(next);
    await fileDb.useProfile(person.id);
    await fileDb.useServer(next);
    release.complete();
    await checking;

    expect(notificationService.requestedServers, [original]);
    expect(sent, isEmpty);
    expect(await fileDb.getAllPlaylistNotifications(), isEmpty);
    expect(
        (await fileDb.forAccount(original).getAllPlaylistNotifications())
            .single
            .lastVideoCount,
        5);
  });

  for (final changeGateway in [false, true]) {
    test(
        'account security changes invalidate pending notifications '
        '(gateway: $changeGateway)', () async {
      await fileDb.upsertPlaylistNotification(
          PlaylistNotification('playlist', 5, 123, 'A playlist'));
      final original = await db.getCurrentlySelectedServer();
      final started = Completer<void>();
      final release = Completer<void>();
      notificationService.beforePlaylist = () {
        started.complete();
        return release.future;
      };

      final checking = checkForNewVideos();
      await started.future;
      await db.upsertServer(changeGateway
          ? original.copyWith(gatewayEnabled: !original.gatewayEnabled)
          : original.copyWith(authToken: 'refreshed'));
      release.complete();
      await checking;

      expect(sent, isEmpty);
      expect(notificationService.requestedServers, [original]);
    });
  }

  test('notification IDs are stable and separate accounts on the same server',
      () async {
    final original = await db.getCurrentlySelectedServer();
    await fileDb.upsertPlaylistNotification(
        PlaylistNotification('playlist', 5, 123, 'A playlist'));
    await checkForNewVideos();
    await checkForNewVideos();
    expect(sent, hasLength(2));
    expect(sent[0]['id'], sent[1]['id']);

    final next = original.copyWith(id: 'second-account', authToken: 'second');
    await db.upsertServer(next);
    await db.useServer(next);
    await fileDb.useServer(next);
    await fileDb.upsertPlaylistNotification(
        PlaylistNotification('playlist', 5, 123, 'A playlist'));
    await checkForNewVideos();

    expect(sent, hasLength(3));
    expect(sent[2]['id'], isNot(sent[0]['id']));
    expect((sent[2]['payload'] as Map)['accountId'], 'second-account');
  });

  test('notification check waits for native notification creation', () async {
    await fileDb.upsertPlaylistNotification(
        PlaylistNotification('playlist', 5, 123, 'A playlist'));
    pendingNotification = Completer<bool>();
    var completed = false;

    final check = checkForNewVideos().then((_) => completed = true);
    for (var attempt = 0; sent.isEmpty && attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(sent, hasLength(1));
    expect(completed, isFalse);

    pendingNotification!.complete(true);
    await check;
    expect(completed, isTrue);
  });

  test('native publication finishing after a profile switch is withdrawn',
      () async {
    await fileDb.upsertPlaylistNotification(
        PlaylistNotification('playlist', 5, 123, 'Private playlist'));
    pendingNotification = Completer<bool>();
    final checking = checkForNewVideos();
    for (var attempt = 0; sent.isEmpty && attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(sent, hasLength(1));
    final person = await db.createProfile('Another person');
    await db.useProfile(person.id);
    pendingNotification!.complete(true);
    await checking;

    expect(cancelled, [sent.single['id']]);
  });
}
