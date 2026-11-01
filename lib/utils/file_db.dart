import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/extensions.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/videos/models/db/dearrow_cache.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../notifications/models/db/channel_notifications.dart';
import '../notifications/models/db/playlist_notifications.dart';
import '../notifications/models/db/subscription_notifications.dart';
import '../settings/models/db/server.dart';
import 'interfaces/db.dart';

part 'file_db.g.dart';

/// this is probably far from the best way to do this but issues with DBs not working on multiple isolates
/// this will just read and write plain json to files
/// methods will follow whatever used to be in the DB
/// this has very low read/write, it should be fine

const _subNotifsFile = 'subscription_notifications.json',
    _channelNotifFile = 'channel_notifications.json',
    _playlistNotifsFile = "playlist_notifications.json",
    _genericSettings = "generic_settings.json",
    _fileDbFolder = 'fileDb';
const _fileNotFoundErrorCode = 2;

final _log = Logger('FileDb');

class FileDB extends IDbClient {
  // Share queues across foreground clients. Background readers see complete
  // files through atomic replacement; this is not a cross-isolate write lock.
  static final _pendingUpdates = <String, Future<void>>{};

  FileDB();

  Future<void> setSubscriptionNotifications(bool b) => _updateGenericSettings(
      (settings) => settings.subscriptionNotifications = b);

  Future<bool> getSubscriptionNotifications() async {
    return (await getGenericSettings()).subscriptionNotifications;
  }

  Future<void> setLocale(String? l) =>
      _updateGenericSettings((settings) => settings.locale = l);

  Future<String?> getLocale() async {
    return (await getGenericSettings()).locale;
  }

  Future<void> updateGenericSettings(FileDbGenericSettings settings) =>
      _updateFile(
          _genericSettings, (file) => _writeMapToFile(file, settings.toJson()));

  Future<void> _updateGenericSettings(
          FutureOr<void> Function(FileDbGenericSettings) update) =>
      _updateFile(_genericSettings, (file) async {
        final settings = await _readGenericSettings(file);
        await update(settings);
        await _writeMapToFile(file, settings.toJson());
      });

  Future<FileDbGenericSettings> getGenericSettings() async {
    return _readGenericSettings(await _openAppFile(_genericSettings));
  }

  Future<FileDbGenericSettings> _readGenericSettings(File file) async {
    var content = await _readFileAsMap(file);
    if (content.isNotEmpty) {
      return FileDbGenericSettings.fromJson(content);
    } else {
      return FileDbGenericSettings();
    }
  }

  Future<SubscriptionNotification?> getLastSubscriptionNotification() async {
    File f = await _openAppFile(_subNotifsFile);
    var content = await _readFileAsMap(f);
    if (content.isNotEmpty) {
      return SubscriptionNotification.fromJson(content);
    } else {
      return null;
    }
  }

  Future<void> setLastSubscriptionNotification(SubscriptionNotification sub) =>
      _updateFile(
          _subNotifsFile, (file) => _writeMapToFile(file, sub.toJson()));

  Future<ChannelNotification?> getChannelNotification(String channelId) async {
    return (await getAllChannelNotifications())
        .firstWhereOrNull((element) => element.channelId == channelId);
  }

  Future<List<ChannelNotification>> getAllChannelNotifications() async {
    File f = await _openAppFile(_channelNotifFile);
    var contents = await _readFileAsMap(f);
    return contents.values.map((e) => ChannelNotification.fromJson(e)).toList();
  }

  Future<void> deleteChannelNotification(ChannelNotification notif) =>
      _updateFileMap(_channelNotifFile,
          (contents) => contents.remove(notif.channelId) != null);

  Future<void> upsertChannelNotification(ChannelNotification notif) =>
      _updateFileMap(_channelNotifFile, (contents) {
        contents[notif.channelId] = notif.toJson();
        return true;
      });

  Future<void> setChannelNotificationLastViewedVideo(
          String channelId, String videoId) =>
      _updateFileMap(_channelNotifFile, (contents) {
        final current = contents[channelId];
        if (current == null) return false;
        final notif = ChannelNotification.fromJson(current)
          ..lastSeenVideoId = videoId
          ..timestamp = DateTime.now().millisecondsSinceEpoch;
        contents[channelId] = notif.toJson();
        return true;
      });

  Future<PlaylistNotification?> getPlaylistNotification(
      String playlistId) async {
    return (await getAllPlaylistNotifications())
        .firstWhereOrNull((element) => element.playlistId == playlistId);
  }

  Future<List<PlaylistNotification>> getAllPlaylistNotifications() async {
    File f = await _openAppFile(_playlistNotifsFile);
    var contents = await _readFileAsMap(f);
    return contents.values
        .map((e) => PlaylistNotification.fromJson(e))
        .toList();
  }

  Future<void> deletePlaylistNotification(PlaylistNotification notif) =>
      _updateFileMap(_playlistNotifsFile,
          (contents) => contents.remove(notif.playlistId) != null);

  Future<void> upsertPlaylistNotification(PlaylistNotification notif) =>
      _updateFileMap(_playlistNotifsFile, (contents) {
        contents[notif.playlistId] = notif.toJson();
        return true;
      });

  Future<void> setPlaylistNotificationLastViewedVideo(
          String playlistId, int videoCount) =>
      _updateFileMap(_playlistNotifsFile, (contents) {
        final current = contents[playlistId];
        if (current == null) return false;
        final notif = PlaylistNotification.fromJson(current)
          ..lastVideoCount = videoCount
          ..timestamp = DateTime.now().millisecondsSinceEpoch;
        contents[playlistId] = notif.toJson();
        return true;
      });

  Future<void> _updateFileMap(
          String path, bool Function(Map<String, dynamic>) update) =>
      _updateFile(path, (file) async {
        final contents = await _readFileAsMap(file);
        if (update(contents)) await _writeMapToFile(file, contents);
      });

  Future<void> _updateFile(String path, Future<void> Function(File) update) {
    final previous = _pendingUpdates[path] ?? Future<void>.value();
    final result = previous.then((_) async => update(await _openAppFile(path)));
    // A failed update still reaches its caller without blocking later changes.
    _pendingUpdates[path] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<File> _openAppFile(String path) async {
    var docsDir = await getApplicationDocumentsDirectory();
    docsDir = Directory(p.join(docsDir.path, _fileDbFolder));

    if (!(await docsDir.exists())) {
      await docsDir.create(recursive: true);
    }

    var dbPath = p.join(docsDir.path, path);

    return File(dbPath);
  }

  Future<void> _writeMapToFile(File f, Map<String, dynamic> map) async {
    var string = jsonEncode(map);
    _log.fine("Writing json to ${f.path}");
    final temporary = File('${f.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsString(string, flush: true);
      await temporary.rename(f.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Map<String, dynamic>> _readFileAsMap(File f) async {
    try {
      final contents = await f.readAsString();

      return jsonDecode(contents);
    } catch (e) {
      return {};
    }
  }

  Future<void> clearDb() async {
    for (final path in const [
      _channelNotifFile,
      _playlistNotifsFile,
      _subNotifsFile,
      _genericSettings,
    ]) {
      await _updateFile(path, (file) async {
        try {
          await file.delete();
        } on FileSystemException catch (error) {
          if (error.osError?.errorCode != _fileNotFoundErrorCode) rethrow;
          log.fine('file doesn\'t exist');
        }
      });
    }
  }

  /*
  * This is getting worst and worst. we will only implement the required things for the work manager.
   */
  @override
  Future<void> useServer(Server server) =>
      _updateGenericSettings((settings) => settings.server = server);

  @override
  Future<Server> getCurrentlySelectedServer() async {
    return (await getGenericSettings()).server!;
  }

  @override
  Future<List<Server>> getServers() async {
    return [(await getGenericSettings()).server!];
  }

  @override
  Future<void> addToSearchHistory(SearchHistoryItem searchHistoryItem) {
    throw UnimplementedError();
  }

  Future<void> syncWithDb() async {
    _log.fine('Syncing file settings with DB');
    await _updateGenericSettings((fileSettings) async {
      fileSettings.locale = db.getSettings(localeSettingName)?.value;
      try {
        fileSettings.server = await db.getCurrentlySelectedServer();
      } catch (err) {
        _log.fine("No server selected in the DB settings, we proceed without");
      }
    });
  }

  /*
  We don't care about anything below this
   */
  @override
  Future<void> cleanOldLogs() {
    throw UnimplementedError();
  }

  @override
  Future<void> clearExcessSearchHistory() {
    throw UnimplementedError();
  }

  @override
  Future<void> clearSearchHistory() {
    // TODO: implement clearSearchHistory
    throw UnimplementedError();
  }

  @override
  close() {
    // TODO: implement close
    throw UnimplementedError();
  }

  @override
  Future<void> deleteDownload(DownloadedVideo vid) {
    // TODO: implement deleteDownload
    throw UnimplementedError();
  }

  @override
  Future<void> deleteFilter(VideoFilter filter) {
    // TODO: implement deleteFilter
    throw UnimplementedError();
  }

  @override
  deleteServerById(Server server) {
    // TODO: implement deleteServerById
    throw UnimplementedError();
  }

  @override
  deleteSetting(String name) {
    // TODO: implement deleteSetting
    throw UnimplementedError();
  }

  @override
  List<DownloadedVideo> getAllDownloads() {
    // TODO: implement getAllDownloads
    throw UnimplementedError();
  }

  @override
  List<VideoFilter> getAllFilters() {
    // TODO: implement getAllFilters
    throw UnimplementedError();
  }

  @override
  List<SettingsValue> getAllSettings() {
    // TODO: implement getAllSettings
    throw UnimplementedError();
  }

  @override
  List<AppLog> getAppLogs() {
    // TODO: implement getAppLogs
    throw UnimplementedError();
  }

  @override
  DeArrowCache? getDeArrowCache(String videoId) {
    // TODO: implement getDeArrowCache
    throw UnimplementedError();
  }

  @override
  DownloadedVideo? getDownloadByVideoId(String videoId) {
    // TODO: implement getDownloadByVideoId
    throw UnimplementedError();
  }

  @override
  HistoryVideoCache? getHistoryVideoByVideoId(String videoId) {
    // TODO: implement getHistoryVideoByVideoId
    throw UnimplementedError();
  }

  @override
  HomeLayout getHomeLayout() {
    // TODO: implement getHomeLayout
    throw UnimplementedError();
  }

  @override
  List<String> getSearchHistory() {
    // TODO: implement getSearchHistory
    throw UnimplementedError();
  }

  @override
  Server? getServer(String url) {
    // TODO: implement getServer
    throw UnimplementedError();
  }

  @override
  SettingsValue? getSettings(String name) {
    _log.fine("trying to get setting $name");
    return switch (name) {
      (useProxySettingName) => SettingsValue(useProxySettingName, "false"),
      (_) => throw UnimplementedError()
    };
  }

  @override
  double getVideoProgress(String videoId) {
    // TODO: implement getVideoProgress
    throw UnimplementedError();
  }

  @override
  Future<void> insertLogs(AppLog log) async {
    await super.insertLogs(log);
  }

  @override
  Future<void> saveFilter(VideoFilter filter) {
    // TODO: implement saveFilter
    throw UnimplementedError();
  }

  @override
  saveProgress(Progress progress) {
    // TODO: implement saveProgress
    throw UnimplementedError();
  }

  @override
  saveSetting(SettingsValue setting) {
    // TODO: implement saveSetting
    throw UnimplementedError();
  }

  @override
  Future<void> upsertDeArrowCache(DeArrowCache cache) {
    // TODO: implement upsertDeArrowCache
    throw UnimplementedError();
  }

  @override
  Future<void> upsertDownload(DownloadedVideo vid) {
    // TODO: implement upsertDownload
    throw UnimplementedError();
  }

  @override
  Future<void> upsertHistoryVideo(HistoryVideoCache vid) {
    // TODO: implement upsertHistoryVideo
    throw UnimplementedError();
  }

  @override
  Future<void> upsertHomeLayout(HomeLayout layout) {
    // TODO: implement upsertHomeLayout
    throw UnimplementedError();
  }

  @override
  upsertServer(Server server) async {
    await super.upsertServer(server);
  }

  @override
  Future<void> deleteFromSearchHistory(String search) {
    // TODO: implement deleteFromSearchHistory
    throw UnimplementedError();
  }

  @override
  Future<void> addOfflineSubscription(OfflineSubscription sub) {
    // TODO: implement addOfflineSubscription
    throw UnimplementedError();
  }

  @override
  Future<void> deleteOfflineSubscription(String channelId) {
    // TODO: implement deleteOfflineSubscription
    throw UnimplementedError();
  }

  @override
  Future<List<OfflineSubscription>> getOfflineSubscriptions() {
    // TODO: implement getOfflineSubscriptions
    throw UnimplementedError();
  }

  @override
  Future<bool> isOfflineSubscribed(String channelId) {
    // TODO: implement isOfflineSubscribed
    throw UnimplementedError();
  }
}

@JsonSerializable()
class FileDbGenericSettings {
  Server?
      server; // we only store the currently used server because that's what we're interested in
  bool subscriptionNotifications = false;
  String? locale;

  FileDbGenericSettings();

  factory FileDbGenericSettings.fromJson(Map<String, dynamic> json) =>
      _$FileDbGenericSettingsFromJson(json);

  Map<String, dynamic> toJson() => _$FileDbGenericSettingsToJson(this);
}
