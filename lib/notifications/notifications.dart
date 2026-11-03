import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/notifications/models/db/subscription_notifications.dart';
import 'package:clipious/router.dart';
import 'package:logging/logging.dart';
import '../settings/models/db/server.dart';
import '../settings/models/errors/no_server_selected.dart';

final log = Logger('notifications');

const String playlistId = "playlistId",
    lastSeenVideo = "lastSeenVideo",
    channelId = "channelId";

enum NotificationTypes {
  foregroundService(
      id: 'foreground-service',
      description: 'Checks for new videos from sources you selected',
      name: 'Foreground service',
      idSpace: 4000000,
      playSound: false,
      importance: NotificationImportance.Min),
  subscription(
      id: 'subscription-notifications',
      description: 'Get notifications about your subscriptions',
      name: 'New subscription videos',
      idSpace: 1000000),
  channel(
      id: 'channel-notifications',
      description: 'Get notifications from selected channels (bell icon)',
      name: 'Channel new videos',
      idSpace: 2000000),
  playlist(
      id: 'playlist-notifications',
      description: 'Get notification from selected playlists (bell icon)',
      name: 'Playlist new videos',
      idSpace: 3000000);

  final NotificationImportance importance;
  final String id, name, description;
  final bool playSound;

  // to prevent notifications with the same id, when sending notifications this will do idSpace+id
  final int idSpace;

  const NotificationTypes(
      {required this.id,
      required this.name,
      required this.description,
      required this.idSpace,
      this.playSound = true,
      this.importance = NotificationImportance.Default});
}

initializeNotifications() {
  var defaultIcon = 'resource://drawable/app_icon';
  AwesomeNotifications().initialize(
      defaultIcon,
      NotificationTypes.values
          .map((e) => NotificationChannel(
              icon: defaultIcon,
              channelKey: e.id,
              channelName: e.name,
              channelDescription: e.description,
              playSound: e.playSound,
              enableVibration: e.playSound,
              importance: e.importance))
          .toList(),
      debug: kDebugMode);

  AwesomeNotifications()
      .getInitialNotificationAction(removeFromActionEvents: false)
      .then((value) {
    log.info('recieved notification ${value?.channelKey}');
  });
}

class NotificationController {
  static bool Function() canHandleActions = () => true;

  static Future<Server?> _selectedAccount() async {
    if (!canHandleActions()) return null;
    try {
      final server = await db.getCurrentlySelectedServer();
      return canHandleActions() ? server : null;
    } on NoServerSelected {
      return null;
    }
  }

  /// Use this method to detect when a new notification or a schedule is created
  @pragma("vm:entry-point")
  static Future<void> onNotificationCreatedMethod(
      ReceivedNotification receivedNotification) async {
    // Your code goes here
  }

  /// Use this method to detect every time that a new notification is displayed
  @pragma("vm:entry-point")
  static Future<void> onNotificationDisplayedMethod(
      ReceivedNotification receivedNotification) async {
    // Your code goes here
  }

  /// Use this method to detect if the user dismissed a notification
  @pragma("vm:entry-point")
  static Future<void> onDismissActionReceivedMethod(
      ReceivedAction receivedAction) async {
    // Your code goes here
  }

  /// Use this method to detect when the user taps on a notification or action button
  @pragma("vm:entry-point")
  static Future<void> onActionReceivedMethod(
      ReceivedAction receivedAction) async {
    if (receivedAction.payload != null && receivedAction.payload!.isNotEmpty) {
      var payload = receivedAction.payload!;
      final account = await _selectedAccount();
      if (account == null) return;
      // Old notifications must never open another person's private content.
      if (payload['profileId'] != null &&
          (payload['profileId'] != account.profileId ||
              payload['accountId'] != account.accountId)) return;
      if (payload['profileId'] == null && account.profileId != 'default')
        return;
      final notifications = fileDb.forAccount(account);
      if (receivedAction.channelKey == NotificationTypes.channel.id &&
          payload.containsKey(channelId) &&
          payload.containsKey(lastSeenVideo)) {
        log.fine('Launching channel screen');
        appRouter.push(ChannelRoute(channelId: payload[channelId]!));
        await notifications.setChannelNotificationLastViewedVideo(
            payload[channelId]!, payload[lastSeenVideo]!);
      } else if (receivedAction.channelKey == NotificationTypes.playlist.id &&
          payload.containsKey(playlistId)) {
        log.fine('Launching playlist screen');
        final value = await service.getPublicPlaylists(payload[playlistId]!,
            serverOverride: account, saveLastSeen: false);
        final current = await _selectedAccount();
        if (current == null ||
            current.profileId != account.profileId ||
            current.accountId != account.accountId) return;
        appRouter
            .push(PlaylistViewRoute(playlist: value, canDeleteVideos: false));
        await notifications.setPlaylistNotificationLastViewedVideo(
            value.playlistId, value.videoCount);
      } else if (receivedAction.channelKey ==
              NotificationTypes.subscription.id &&
          payload.containsKey(lastSeenVideo)) {
        log.fine('going to subscriptions');
        appRouter.replaceAll([
          const MainRoute(children: [
            MainContentRoute(children: [SubscriptionRoute()])
          ]),
        ]);
        await notifications.setLastSubscriptionNotification(
            SubscriptionNotification(payload[lastSeenVideo]!,
                DateTime.now().millisecondsSinceEpoch));
      }
    }
  }
// Your code goes here
}

Future<void> sendNotification(String title, String message,
    {required NotificationTypes type,
    Map<String, String>? payload,
    int id = 0}) async {
  await AwesomeNotifications().createNotification(
      content: NotificationContent(
          id: type.idSpace + id,
          payload: payload,
          channelKey: type.id,
          title: title,
          body: message,
          actionType: ActionType.Default));
}
