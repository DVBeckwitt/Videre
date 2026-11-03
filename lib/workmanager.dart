import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:intl/intl.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/notifications/models/db/subscription_notifications.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/file_db.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:logging/logging.dart';
import 'package:workmanager/workmanager.dart';

import 'notifications/notifications.dart';
import 'videos/models/video.dart';
import 'network/native_proxy_http_client.dart';
import 'service.dart';

var log = Logger('background-task');
const taskName = "Clipious background refresh task";

Future<void> configureBackgroundService(SettingsCubit settings) async {
  if (settings.state.backgroundNotifications) {
    await Workmanager().initialize(callbackDispatcher);
  }
}

Future<void> setupTasks(SettingsCubit settings) async {
  try {
    await Workmanager().cancelByUniqueName(taskName);
  } catch (e) {
    log.fine('task not registered');
    // fail silently in case no tasks have been already defined
  }
  // Disabling notifications can finish while cancellation is awaiting Android.
  if (settings.isClosed || !settings.state.backgroundNotifications) return;
  await Workmanager().registerPeriodicTask(taskName, taskName,
      frequency: kDebugMode
          ? const Duration(seconds: 15)
          : Duration(hours: settings.state.backgroundNotificationFrequency),
      constraints: Constraints(
          networkType: NetworkType.connected, requiresBatteryNotLow: true));
}

Future<void> stopTasks() async {
  await Workmanager().cancelAll();
}

@pragma(
    'vm:entry-point') // Mandatory if the App is obfuscated or using Flutter 3.1+
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    log.info(
        "Native called background task: $task"); //simpleTask will be emitted here.
    if (task == taskName) {
      await _backgroundCheck();
    }
    return Future.value(true);
  });
}

Future<void> _backgroundCheck() async {
  try {
    Logger.root.level =
        kDebugMode ? Level.FINEST : Level.INFO; // defaults to Level.INFO
    Logger.root.onRecord.listen((record) async {
      debugPrint(
          '[${record.level.name}] [${record.loggerName}] ${record.message}');
    });
    db = FileDB();
    // The native transport reads the live, atomic proxy policy. A worker must
    // not retain a direct-connection snapshot while foreground settings change.
    service = Service(httpClient: NativeProxyHttpClient());
    await checkForNewVideos();
  } catch (e) {
    log.severe("Error while running workmanager", e);
    rethrow;
  }
}

@visibleForTesting
Future<void> checkForNewVideos() async {
  final source = db;
  final client = service;
  Server server;
  try {
    server = await source.getCurrentlySelectedServer();
  } catch (_) {
    // New profiles may not have an account yet.
    return;
  }
  final check =
      _NotificationCheck(source, client, server, fileDb.forAccount(server));
  await _handleSubscriptionsNotifications(check);
  if (!await check.isCurrent()) return;
  await _handleChannelNotifications(check);
  if (!await check.isCurrent()) return;
  await _handlePlaylistNotifications(check);
}

/// A worker owns the account it started with. Neither a late HTTP response nor
/// a changed global selection may send another person's notifications.
class _NotificationCheck {
  final IDbClient source;
  final Service client;
  final Server server;
  final FileDB files;

  const _NotificationCheck(this.source, this.client, this.server, this.files);

  bool get isLoggedIn =>
      (server.authToken?.isNotEmpty ?? false) ||
      (server.sidCookie?.isNotEmpty ?? false);

  Future<bool> isCurrent() async {
    if (!identical(db, source)) return false;
    try {
      final selected = await source.getCurrentlySelectedServer();
      return selected.profileId == server.profileId &&
          selected.accountId == server.accountId &&
          selected.gatewayEnabled == server.gatewayEnabled &&
          selected.authToken == server.authToken &&
          selected.sidCookie == server.sidCookie &&
          mapEquals(selected.customHeaders, server.customHeaders);
    } catch (_) {
      return false;
    }
  }

  Map<String, String> payload(Map<String, String> content) => {
        ...content,
        'profileId': server.profileId,
        'accountId': server.accountId,
      };

  // Stable across isolates and app restarts, unlike String.hashCode. Keep the
  // result inside the notification type's reserved ID range.
  int notificationId(String entity) {
    var hash = 0x811c9dc5;
    for (final unit
        in '${server.profileId}\u0000${server.accountId}\u0000$entity'
            .codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return (hash & 0x7fffffff) % 1000000;
  }

  Future<void> send(String title, String message,
      {required NotificationTypes type,
      required Map<String, String> content,
      required String entity}) async {
    if (!await isCurrent()) return;
    final id = notificationId(entity);
    await sendNotification(title, message,
        type: type, payload: payload(content), id: id);
    // Native publication can be pending while the foreground changes people.
    // Withdraw that late notification instead of leaving another person's
    // private titles on the notification shade.
    if (!await isCurrent()) {
      await AwesomeNotifications().cancel(type.idSpace + id);
    }
  }
}

Future<AppLocalizations> getLocalization([FileDB? settings]) async {
  List<String>? localeString;
  String dbLocale =
      await (settings ?? fileDb).getLocale() ?? Intl.getCurrentLocale();
  localeString = dbLocale.split('_');

  Locale locale = Locale.fromSubtags(
      languageCode: localeString[0],
      scriptCode: localeString.length >= 2 ? localeString[1] : null);

  return await AppLocalizations.delegate.load(locale);
}

Future<void> _handlePlaylistNotifications(_NotificationCheck check) async {
  var notifs = await check.files.getAllPlaylistNotifications();
  for (var n in notifs) {
    if (!await check.isCurrent()) return;
    var videos = await check.client.getPublicPlaylists(n.playlistId,
        saveLastSeen: false, serverOverride: check.server);
    final videosToNotifyAbout = videos.videoCount - n.lastVideoCount;
    if (videos.videos.isEmpty || videosToNotifyAbout <= 0) continue;

    var locals = await getLocalization(check.files);
    if (!await check.isCurrent()) return;
    await check.send(locals.playlistNotificationTitle(n.playlistName),
        locals.playlistNotificationContent(n.playlistName, videosToNotifyAbout),
        type: NotificationTypes.playlist,
        content: {playlistId: n.playlistId},
        entity: n.playlistId);
  }
}

Future<void> _handleChannelNotifications(_NotificationCheck check) async {
  var notifs = await check.files.getAllChannelNotifications();

  for (var n in notifs) {
    // we get the latest video,
    if (!await check.isCurrent()) return;
    var videos = await check.client.getChannelVideos(n.channelId, null,
        saveLastSeen: false, serverOverride: check.server);

    if (videos.videos.isNotEmpty) {
      if (n.lastSeenVideoId.isNotEmpty) {
        // if in list, we calculate
        int videosToNotifyAbout = 0;

        int index = videos.videos
            .indexWhere((element) => element.videoId == n.lastSeenVideoId);

        if (index >= 0) {
          videosToNotifyAbout = index;
        } else {
          videosToNotifyAbout = videos.videos.length;
        }

        // if not we tell that list.size+ new videos are available
        var locals = await getLocalization(check.files);

        if (videosToNotifyAbout > 0) {
          if (!await check.isCurrent()) return;
          await check.send(
              locals.channelNotificationTitle(n.channelName),
              locals.channelNotificationContent(
                  n.channelName, videosToNotifyAbout),
              type: NotificationTypes.channel,
              content: {
                channelId: n.channelId,
                lastSeenVideo: videos.videos.first.videoId
              },
              entity: n.channelId);
        }
      }
    }
  }
}

Future<void> _handleSubscriptionsNotifications(_NotificationCheck check) async {
  bool isEnabled = await check.files.getSubscriptionNotifications();
  if (isEnabled && check.isLoggedIn && await check.isCurrent()) {
    // we need to get the last notification before we call the feed endpoint as it is going to save the last seen video
    final lastNotification =
        await check.files.getLastSubscriptionNotification();
    var feed = await check.client.getUserFeed(
        maxResults: 100, saveLastSeen: false, serverOverride: check.server);
    if (!await check.isCurrent()) return;

    List<Video> videos = [];
    videos.addAll(feed.notifications ?? []);
    videos.addAll(feed.videos ?? []);

    if (videos.isNotEmpty) {
      // we don't send notification for the first run ever to avoid weird behavior
      if (lastNotification == null) {
        var toSave = SubscriptionNotification(
            videos.first.videoId, DateTime.now().millisecondsSinceEpoch);
        await check.files.setLastSubscriptionNotification(toSave);
      } else {
        late int videosToNotifyAbout;
        int index = videos.indexWhere(
            (element) => element.videoId == lastNotification.lastSeenVideoId);
        //more than 100 videos
        if (index == -1) {
          videosToNotifyAbout = videos.length;
        } else {
          videosToNotifyAbout = index;
        }

        var locals = await getLocalization(check.files);

        if (videosToNotifyAbout > 0) {
          if (!await check.isCurrent()) return;
          await check.send(locals.subscriptionNotificationTitle,
              locals.subscriptionNotificationContent(videosToNotifyAbout),
              type: NotificationTypes.subscription,
              content: {lastSeenVideo: videos.first.videoId},
              entity: 'subscriptions');
        }
      }
    }
  }
}
