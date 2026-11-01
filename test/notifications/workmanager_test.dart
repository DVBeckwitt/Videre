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

  @override
  Future<UserFeed> getUserFeed(
      {int? maxResults, int? page, bool saveLastSeen = true}) async {
    expect(saveLastSeen, isFalse);
    return feed;
  }

  @override
  Future<Playlist> getPublicPlaylists(String playlistId,
      {int? page, bool saveLastSeen = true}) async {
    expect(saveLastSeen, isFalse);
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
  Completer<bool>? pendingNotification;

  setUp(() async {
    documentsDirectory =
        await Directory.systemTemp.createTemp('videre-notification-test-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documentsDirectory.path);
    originalNotifications = AwesomeNotificationsPlatform.instance;
    AwesomeNotificationsPlatform.instance = MethodChannelAwesomeNotifications();
    messenger.setMockMethodCallHandler(notifications, (call) async {
      expect(call.method, 'createNewNotification');
      final arguments = call.arguments as Map<Object?, Object?>;
      sent.add(arguments['content']! as Map<Object?, Object?>);
      return pendingNotification?.future ?? true;
    });
    sent.clear();
    pendingNotification = null;
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(const Server(
        url: 'https://instance.example', inUse: true, authToken: 'test-token'));
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
    expect(sent.single['payload'], {'playlistId': 'playlist'});
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
    expect(sent.single['payload'], {'lastSeenVideo': 'new-upload'});
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
}
