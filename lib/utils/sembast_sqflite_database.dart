import 'dart:async';
import 'dart:convert';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/db/dearrow_cache.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sembast_sqflite/sembast_sqflite.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:uuid/uuid.dart';

import '../settings/states/settings.dart';
import 'backup.dart';

const maxLogs = 1000;
const singleId = 1;

class SembastSqfDb extends IDbClient {
  final log = Logger('SembastSqfLDB');
  final Database db;
  final downloadedVideosStore = stringMapStoreFactory.store('downloadedVideo');
  final homeLayoutStore =
      intMapStoreFactory.store('homeLayout'); // always use id = 1
  final searchHistoryStore =
      stringMapStoreFactory.store('searchHistory'); // use term as key
  final appLogsStore = stringMapStoreFactory.store('appLogs');
  final serversStore =
      stringMapStoreFactory.store('serviers'); // use server url as key
  final videoFiltersStore = stringMapStoreFactory.store('videoFilters');
  final settingsStore =
      stringMapStoreFactory.store('settings'); // settings name as key;
  final deArrowCacheStore =
      stringMapStoreFactory.store('dearrow'); // use video id as key
  final historyVideoCacheStore =
      stringMapStoreFactory.store('historyVideoCache'); // use historyVideoCache
  final progressStore = stringMapStoreFactory.store('progress');
  final offlineSubscriptions =
      stringMapStoreFactory.store('offline_subscriptions');

  SembastSqfDb(this.db);

  static Future<SembastSqfDb> create() async {
    final docsDir = await getApplicationDocumentsDirectory();
    var dbPath = p.join(docsDir.path, "clipious.db");

    final databaseFactorySqflite =
        getDatabaseFactorySqflite(sqflite.databaseFactory);
    var db = await databaseFactorySqflite.openDatabase(
      dbPath.toString(),
      version: 1,
    );

    return SembastSqfDb(db);
  }

  static Future<SembastSqfDb> createInMemory() async {
    var factory = newDatabaseFactoryMemory();
    var db = await factory.openDatabase("${const Uuid().v4()}.db");
    return SembastSqfDb(db);
  }

  @override
  Future<void> addToSearchHistory(SearchHistoryItem searchHistoryItem) async {
    searchHistoryItem.time = DateTime.now().millisecondsSinceEpoch;
    await searchHistoryStore
        .record(searchHistoryItem.search)
        .put(db, searchHistoryItem.toJson());
    await clearExcessSearchHistory();
  }

  @override
  Future<void> deleteFromSearchHistory(String search) async {
    await searchHistoryStore.record(search).delete(db);
  }

  @override
  Future<void> cleanOldLogs() async {
    // TODO: implement cleanOldLogs
    var all = getAppLogs();
    List<String> ids = all.reversed.skip(maxLogs).map((e) => e.uuid).toList();
    await appLogsStore.delete(db,
        finder: Finder(
            sortOrders: [SortOrder("time")], offset: 0, limit: ids.length));
    log.fine("clearing ${ids.length} logs out of ${all.length}");
  }

  @override
  Future<void> clearExcessSearchHistory() async {
    final limit = int.parse(getSettings(searchHistoryLimitSettingName)?.value ??
        searchHistoryDefaultLength);

    log.fine('History limit ? $limit');

    var count = searchHistoryStore.countSync(db);
    log.fine('search history clear $count/$limit');
    if (count > limit) {
      await searchHistoryStore.delete(db,
          finder: Finder(
              sortOrders: [SortOrder("time")],
              offset: 0,
              limit: count - limit));
      log.fine('clearing ${count - limit} history itens');
    }
  }

  @override
  Future<void> clearSearchHistory() async {
    // TODO: implement clearSearchHistory
    await searchHistoryStore.delete(db);
  }

  @override
  close() async {
    await db.close();
  }

  @override
  Future<void> deleteDownload(DownloadedVideo vid) async {
    await downloadedVideosStore.record(vid.videoId).delete(db);
  }

  @override
  Future<void> deleteFilter(VideoFilter filter) async {
    await videoFiltersStore.record(filter.uuid).delete(db);
  }

  @override
  deleteServerById(Server server) async {
    await serversStore.record(server.url).delete(db);
  }

  @override
  deleteSetting(String name) async {
    await settingsStore.record(name).delete(db);
  }

  @override
  List<DownloadedVideo> getAllDownloads() {
    var records = downloadedVideosStore.findSync(db);
    return records.map((e) {
      var d = DownloadedVideo.fromJson(e.value);
      d = d.copyWith(videoId: e.key);
      return d;
    }).toList();
  }

  @override
  List<VideoFilter> getAllFilters() {
    return videoFiltersStore
        .findSync(db)
        .map((e) => VideoFilter.fromJson(e.value)..uuid = e.key)
        .toList();
  }

  @override
  List<SettingsValue> getAllSettings() {
    return settingsStore
        .findSync(db)
        .map((e) => SettingsValue.fromJson(e.value))
        .toList();
  }

  @override
  List<AppLog> getAppLogs() {
    return appLogsStore
        .findSync(db)
        .map((e) => AppLog.fromJson(e.value)..uuid = e.key)
        .toList();
  }

  @override
  DeArrowCache? getDeArrowCache(String videoId) {
    var v = deArrowCacheStore.record(videoId).getSync(db);

    return v != null ? DeArrowCache.fromJson(v) : null;
  }

  @override
  DownloadedVideo? getDownloadByVideoId(String videoId) {
    var v = downloadedVideosStore.record(videoId).getSync(db);
    return v != null ? DownloadedVideo.fromJson(v) : null;
  }

  @override
  HistoryVideoCache? getHistoryVideoByVideoId(String videoId) {
    var v = historyVideoCacheStore.record(videoId).getSync(db);
    return v != null ? HistoryVideoCache.fromJson(v) : null;
  }

  @override
  HomeLayout getHomeLayout() {
    var findFirstSync = homeLayoutStore.findFirstSync(db);
    if (findFirstSync != null) {
      return HomeLayout.fromJson(findFirstSync.value);
    } else {
      return HomeLayout();
    }
  }

  @override
  List<String> getSearchHistory() {
    var list = searchHistoryStore
        .findSync(db)
        .map((e) => SearchHistoryItem.fromJson(e.value))
        .toList();
    list.sort((a, b) => b.time.compareTo(a.time));
    return list.map((e) => e.search).toList();
  }

  @override
  Server? getServer(String url) {
    var v = serversStore.record(url).getSync(db);
    return v != null ? Server.fromJson(v) : null;
  }

  @override
  Future<List<Server>> getServers() async {
    return (await serversStore.find(db))
        .map((e) => Server.fromJson(e.value))
        .toList();
  }

  @override
  SettingsValue? getSettings(String name) {
    var v = settingsStore.record(name).getSync(db);
    return v != null ? SettingsValue.fromJson(v) : null;
  }

  @override
  double getVideoProgress(String videoId) {
    var v = progressStore.record(videoId).getSync(db);
    return v != null ? Progress.fromJson(v).progress : 0;
  }

  @override
  List<Progress> getAllProgress() => progressStore
      .findSync(db)
      .map((record) => Progress.fromJson(record.value))
      .toList();

  @override
  List<HistoryVideoCache> getLocalHistory() => historyVideoCacheStore
      .findSync(db, finder: Finder(sortOrders: [SortOrder('created', false)]))
      .map((record) => HistoryVideoCache.fromJson(record.value))
      .toList();

  @override
  Future<void> deleteLocalHistory(String videoId) =>
      db.transaction((txn) async {
        await historyVideoCacheStore.record(videoId).delete(txn);
        await progressStore.record(videoId).delete(txn);
        // A saved queue can bring a removed item back into Continue Watching.
        await settingsStore.record('playback-session').delete(txn);
      });

  @override
  Future<void> clearLocalHistory() => db.transaction((txn) async {
        await historyVideoCacheStore.delete(txn);
        await progressStore.delete(txn);
        await settingsStore.record('playback-session').delete(txn);
      });

  @override
  Future<UserBackup> exportBackup() async => UserBackup.parse(jsonEncode({
        'format': 'videre',
        'version': 1,
        'settings': getAllSettings()
            .where(UserBackup.validSetting)
            .map((setting) => setting.toJson())
            .toList(),
        'subscriptions': (await getOfflineSubscriptions())
            .map((sub) => sub.toJson())
            .toList(),
        'filters': getAllFilters()
            .map((filter) => {...filter.toJson(), 'uuid': filter.uuid})
            .toList(),
        'progress':
            getAllProgress().map((progress) => progress.toJson()).toList(),
        'history': getLocalHistory().map((video) => video.toJson()).toList(),
        'playlists': jsonDecode(getSettings('local-playlists')?.value ?? '[]'),
      }));

  @override
  Future<void> restoreBackup(UserBackup backup, {bool replace = false}) async {
    final stores = {
      'settings': settingsStore,
      'subscriptions': offlineSubscriptions,
      'filters': videoFiltersStore,
      'progress': progressStore,
      'history': historyVideoCacheStore
    };
    const keys = {
      'settings': 'name',
      'subscriptions': 'channelId',
      'filters': 'uuid',
      'progress': 'videoId',
      'history': 'videoId'
    };
    // Commit the library together; a failed restore must leave the old data usable.
    await db.transaction((txn) async {
      for (final entry in stores.entries) {
        if (backup.subscriptionsOnly && entry.key != 'subscriptions') continue;
        if (replace) {
          if (entry.key == 'settings') {
            for (final setting
                in getAllSettings().where(UserBackup.validSetting)) {
              await settingsStore.record(setting.name).delete(txn);
            }
          } else {
            await entry.value.delete(txn);
          }
        }
        for (final row in backup.sections[entry.key]!) {
          final key = row[keys[entry.key]] as String;
          if (!replace && await entry.value.record(key).exists(txn)) continue;
          await entry.value.record(key).put(txn, row);
        }
      }
      if (!backup.subscriptionsOnly) {
        final old = replace
            ? <dynamic>[]
            : jsonDecode(getSettings('local-playlists')?.value ?? '[]') as List;
        final lists = <String, dynamic>{
          for (final playlist in old) playlist['playlistId'] as String: playlist
        };
        for (final playlist in backup.sections['playlists']!) {
          final id = playlist['playlistId'] as String;
          if (lists.containsKey(id)) {
            final videos = <String, dynamic>{
              for (final video in lists[id]['videos'] as List)
                video['videoId'] as String: video
            };
            for (final video in playlist['videos'] as List) {
              videos.putIfAbsent(video['videoId'] as String, () => video);
            }
            lists[id] = {
              ...lists[id] as Map,
              'videos': videos.values.toList(),
              'videoCount': videos.length
            };
          } else {
            lists[id] = playlist;
          }
        }
        await settingsStore.record('local-playlists').put(
            txn,
            SettingsValue('local-playlists', jsonEncode(lists.values.toList()))
                .toJson());
        await settingsStore.record('playback-session').delete(txn);
      }
    });
  }

  @override
  Future<void> insertLogs(AppLog log) async {
    log.uuid = const Uuid().v4();
    await appLogsStore.add(db, log.toJson());
    super.insertLogs(log);
  }

  @override
  Future<void> saveFilter(VideoFilter filter) async {
    if (filter.uuid == VideoFilter(value: "").uuid) {
      // generate new id
      filter.uuid = const Uuid().v4();
    }
    await videoFiltersStore.record(filter.uuid).put(db, filter.toJson());
  }

  @override
  saveProgress(Progress progress) async {
    await progressStore.record(progress.videoId).put(db, progress.toJson());
  }

  @override
  saveSetting(SettingsValue setting) async {
    await settingsStore.record(setting.name).put(db, setting.toJson());
  }

  @override
  Future<void> upsertDeArrowCache(DeArrowCache cache) async {
    await deArrowCacheStore.record(cache.videoId).put(db, cache.toJson());
  }

  @override
  Future<void> upsertDownload(DownloadedVideo vid) async {
    await downloadedVideosStore.record(vid.videoId).put(db, vid.toJson());
  }

  @override
  Future<void> upsertHistoryVideo(HistoryVideoCache vid) async {
    await historyVideoCacheStore.record(vid.videoId).put(db, vid.toJson());
  }

  @override
  Future<void> upsertHomeLayout(HomeLayout layout) async {
    await homeLayoutStore.record(singleId).put(db, layout.toJson());
  }

  @override
  upsertServer(Server server) async {
    await serversStore.record(server.url).put(db, server.toJson());
    await super.upsertServer(server);
  }

  @override
  Future<void> useServer(Server server) async {
    List<Server> servers = List.from(await getServers());
    for (int i = 0; i < servers.length; i++) {
      Server s = servers[i].copyWith(inUse: false);
      await serversStore.record(s.url).put(db, s.toJson());
    }

    await serversStore
        .record(server.url)
        .put(db, server.copyWith(inUse: true).toJson());
  }

  @override
  Future<void> addOfflineSubscription(OfflineSubscription sub) async {
    await offlineSubscriptions.record(sub.channelId).put(db, sub.toJson());
  }

  @override
  Future<void> deleteOfflineSubscription(String channelId) async {
    await offlineSubscriptions.record(channelId).delete(db);
  }

  @override
  Future<List<OfflineSubscription>> getOfflineSubscriptions() {
    return offlineSubscriptions.find(db).then((values) =>
        values.map((e) => OfflineSubscription.fromJson(e.value)).toList());
  }

  @override
  Future<bool> isOfflineSubscribed(String channelId) {
    return offlineSubscriptions.record(channelId).exists(db);
  }
}
