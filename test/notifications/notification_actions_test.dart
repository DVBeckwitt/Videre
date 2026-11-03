import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/notifications/models/db/playlist_notifications.dart';
import 'package:clipious/notifications/notifications.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RecordingRouter extends AppRouter {
  _RecordingRouter() : super(hasServer: true);

  final pushed = <PageRouteInfo>[];

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) async {
    pushed.add(route);
    return null;
  }
}

ReceivedAction _action(NotificationTypes type, Server owner) =>
    ReceivedAction().fromMap({
      'id': 1,
      'channelKey': type.id,
      'payload': {
        'profileId': owner.profileId,
        'accountId': owner.accountId,
        'playlistId': 'list-id',
        'channelId': 'channel-id',
        'lastSeenVideo': 'last-video',
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const account = Server(url: 'https://instance.example', id: 'account');
  const playlist = Playlist(
      title: 'A playlist', playlistId: 'list-id', author: '', videoCount: 9);
  late SembastSqfDb database;
  late Directory documents;
  late _RecordingRouter router;
  late MockClient client;
  final requests = <http.Request>[];

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('videre-notif-action-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    db = database = await SembastSqfDb.createInMemory();
    await database.upsertServer(account);
    await fileDb.useServer(await database.getCurrentlySelectedServer());
    await fileDb.forAccount(account).upsertPlaylistNotification(
        PlaylistNotification('list-id', 2, 0, 'A playlist'));
    appRouter = router = _RecordingRouter();
    NotificationController.canHandleActions = () => true;
    requests.clear();
    client = MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(playlist.toJson()), 200);
    });
    service = Service(httpClient: client);
  });

  tearDown(() async {
    NotificationController.canHandleActions = () => true;
    service = Service();
    client.close();
    router.dispose();
    await database.close();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  test('queued notification actions are ignored in an empty profile', () async {
    final empty = await database.createProfile('No account yet');
    await database.useProfile(empty.id);

    await NotificationController.onActionReceivedMethod(
        _action(NotificationTypes.playlist, account));

    expect(requests, isEmpty);
    expect(router.pushed, isEmpty);
    expect(router.stack, isEmpty);
  });

  test('switching or recovery blocks all notification route types', () async {
    NotificationController.canHandleActions = () => false;

    for (final type in [
      NotificationTypes.channel,
      NotificationTypes.playlist,
      NotificationTypes.subscription,
    ]) {
      await NotificationController.onActionReceivedMethod(
          _action(type, account));
    }

    expect(requests, isEmpty);
    expect(router.pushed, isEmpty);
    expect(router.stack, isEmpty);
    expect(await fileDb.forAccount(account).getLastSubscriptionNotification(),
        isNull);
  });

  test('another account on the same server cannot open an old notification',
      () async {
    final other = account.copyWith(id: 'other-account');
    await database.upsertServer(other);
    await database.useServer(other);

    await NotificationController.onActionReceivedMethod(
        _action(NotificationTypes.playlist, account));

    expect(requests, isEmpty);
    expect(router.pushed, isEmpty);
  });

  for (final switchToEmptyProfile in [false, true]) {
    test(
        'pending playlist action is ignored when ${switchToEmptyProfile ? 'profile becomes empty' : 'session becomes blocked'}',
        () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final delayedClient = MockClient((request) async {
        started.complete();
        return response.future;
      });
      addTearDown(delayedClient.close);
      service = Service(httpClient: delayedClient);
      final pending = NotificationController.onActionReceivedMethod(
          _action(NotificationTypes.playlist, account));
      await started.future;
      if (switchToEmptyProfile) {
        final empty = await database.createProfile('Empty person');
        await database.useProfile(empty.id);
      } else {
        NotificationController.canHandleActions = () => false;
      }
      response.complete(http.Response(jsonEncode(playlist.toJson()), 200));
      await pending;

      expect(router.pushed, isEmpty);
      final saved =
          await fileDb.forAccount(account).getAllPlaylistNotifications();
      expect(saved.single.lastVideoCount, 2);
      expect(saved.single.timestamp, 0);
    });
  }

  test('a current playlist notification opens and advances only its cursor',
      () async {
    await NotificationController.onActionReceivedMethod(
        _action(NotificationTypes.playlist, account));

    expect(requests.single.url.path, '/api/v1/playlists/list-id');
    expect(router.pushed.single.routeName, PlaylistViewRoute.name);
    final saved =
        await fileDb.forAccount(account).getAllPlaylistNotifications();
    expect(saved.single.lastVideoCount, 9);
    expect(saved.single.timestamp, greaterThan(0));
  });
}
