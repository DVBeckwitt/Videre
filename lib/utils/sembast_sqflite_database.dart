import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/models/music_listening_event.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/person_profile.dart';
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
import '../network/media_companion.dart';
import '../playlists/services/playlist_progress.dart';
import '../playlists/services/playlist_library_service.dart';
import '../playlists/models/playlist_reference.dart';
import '../playlists/models/saved_playlist.dart';
import '../recommendations/subscription_revision.dart';
import 'backup.dart';

const maxLogs = 1000;
const singleId = 1;
const _musicHistoryRecordingPaused = 'music-history-recording-paused';
const _musicListeningEvents = 'musicListeningEvents';

class _AbandonedAccountSetup implements Exception {}

class SembastSqfDb extends IDbClient {
  final log = Logger('SembastSqfLDB');
  final Database _database;
  final String? _fixedProfileId;
  final Set<PlaybackHistoryWrite> _pendingHistory;
  final _profilesStore = stringMapStoreFactory.store('personProfiles');
  final _profileStateStore = stringMapStoreFactory.store('personProfileState');
  final _globalSettingsStore = stringMapStoreFactory.store('settings');
  static const _deviceSettings = {
    networkSocksProxySettingName,
    skipSslVerificationSettingName,
    'download-folder',
    forceTvUiSettingName,
  };

  // Default keeps the original stores. Migrating never duplicates or removes
  // its library, downloads or accounts; new people receive empty stores.
  static String _profileStoreName(String name, String profileId) =>
      profileId == PersonProfile.defaultId ? name : 'profile:$profileId:$name';
  String _storeName(String name) => _profileStoreName(name, profileId);

  StoreRef<String, Map<String, Object?>> get downloadedVideosStore =>
      stringMapStoreFactory.store(_storeName('downloadedVideo'));
  StoreRef<int, Map<String, Object?>> get homeLayoutStore =>
      intMapStoreFactory.store(_storeName('homeLayout'));
  StoreRef<String, Map<String, Object?>> get searchHistoryStore =>
      stringMapStoreFactory.store(_storeName('searchHistory'));
  final appLogsStore = stringMapStoreFactory.store('appLogs');
  StoreRef<String, Map<String, Object?>> get serversStore =>
      stringMapStoreFactory.store(_storeName('serviers'));
  StoreRef<String, Map<String, Object?>> get _companionDecisions =>
      stringMapStoreFactory.store(_storeName('mediaCompanionDecisions'));
  StoreRef<String, Map<String, Object?>> get videoFiltersStore =>
      stringMapStoreFactory.store(_storeName('videoFilters'));
  StoreRef<String, Map<String, Object?>> get settingsStore =>
      stringMapStoreFactory.store(_storeName('settings'));
  final deArrowCacheStore =
      stringMapStoreFactory.store('dearrow'); // use video id as key
  StoreRef<String, Map<String, Object?>> get historyVideoCacheStore =>
      stringMapStoreFactory.store(_storeName('historyVideoCache'));
  StoreRef<String, Map<String, Object?>> playbackHistoryStore(
          PlaybackHistoryOrigin origin) =>
      stringMapStoreFactory.store(_storeName('${origin.name}PlaybackHistory'));
  StoreRef<String, Map<String, Object?>> get _musicListeningStore =>
      stringMapStoreFactory.store(_storeName(_musicListeningEvents));
  StoreRef<String, Map<String, Object?>> get progressStore =>
      stringMapStoreFactory.store(_storeName('progress'));
  StoreRef<String, Map<String, Object?>> get offlineSubscriptions =>
      stringMapStoreFactory.store(_storeName('offline_subscriptions'));

  SembastSqfDb(this._database)
      : _fixedProfileId = null,
        _pendingHistory = {};

  SembastSqfDb._forProfile(
      this._database, this._fixedProfileId, this._pendingHistory);

  Database get db {
    _checkFixedProfile();
    return _database;
  }

  /// Background work may check cancellation without reading a deleted library.
  bool get isProfileAvailable => profileExists(_fixedProfileId ?? profileId);

  bool profileExists(String id) =>
      _profilesStore.record(id).getSync(_database) != null;

  void _checkFixedProfile() {
    final id = _fixedProfileId;
    if (id != null && _profilesStore.record(id).getSync(_database) == null) {
      throw StateError('Profile no longer exists');
    }
  }

  /// Recheck inside a queued transaction: a captured view may have been
  /// deleted after the transaction was requested but before it acquired the DB.
  Future<void> ensureProfileExists(DatabaseClient transaction) async {
    final id = _fixedProfileId ?? profileId;
    if (!await _profilesStore.record(id).exists(transaction)) {
      throw StateError('Profile no longer exists');
    }
  }

  Future<T> _writeProfile<T>(
      Future<T> Function(SembastSqfDb owner, Transaction txn) write) {
    final owner = forProfile(profileId);
    return owner.db.transaction((txn) async {
      await owner.ensureProfileExists(txn);
      return write(owner, txn);
    });
  }

  @override
  String get profileId {
    _checkFixedProfile();
    return _fixedProfileId ??
        (_profileStateStore.record('active').getSync(_database)?['id']
            as String?) ??
        _profilesStore.findFirstSync(_database)?.key ??
        PersonProfile.defaultId;
  }

  @override
  SembastSqfDb forProfile(String id) {
    if (_profilesStore.record(id).getSync(db) == null) {
      throw StateError('Profile no longer exists');
    }
    return _fixedProfileId == id
        ? this
        : SembastSqfDb._forProfile(db, id, _pendingHistory);
  }

  Future<void> _initializeProfiles() => db.transaction((txn) async {
        if (_fixedProfileId != null) await ensureProfileExists(txn);
        var profiles = await _profilesStore.find(txn);
        if (profiles.isEmpty) {
          await _profilesStore
              .record(PersonProfile.defaultId)
              .put(txn, PersonProfile.defaultProfile.toJson());
          profiles = await _profilesStore.find(txn);
        }
        final active = _profileStateStore.record('active');
        final selected = (await active.get(txn))?['id'];
        if (!profiles.any((profile) => profile.key == selected)) {
          await active.put(txn, {'id': profiles.first.key});
        }
      });

  @override
  Future<List<PersonProfile>> getProfiles() async {
    await _initializeProfiles();
    return (await _profilesStore.find(db))
        .map((record) => PersonProfile.fromJson(record.value))
        .toList();
  }

  String _profileName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      throw const FormatException(
          'Use a profile name between 1 and 80 characters.');
    }
    return trimmed;
  }

  @override
  Future<PersonProfile> createProfile(String name) async {
    final profile =
        PersonProfile(id: const Uuid().v4(), name: _profileName(name));
    await _initializeProfiles();
    await db.transaction((txn) async {
      if (_fixedProfileId != null) await ensureProfileExists(txn);
      await _profilesStore.record(profile.id).put(txn, profile.toJson());
    });
    return profile;
  }

  @override
  Future<void> renameProfile(String id, String name) async {
    final profile = PersonProfile(id: id, name: _profileName(name));
    await _initializeProfiles();
    await db.transaction((txn) async {
      if (_fixedProfileId != null) await ensureProfileExists(txn);
      final record = _profilesStore.record(id);
      if (!await record.exists(txn)) {
        throw StateError('Profile no longer exists');
      }
      await record.put(txn, profile.toJson());
    });
  }

  @override
  Future<void> useProfile(String id) async {
    if (_fixedProfileId != null) {
      _checkFixedProfile();
      if (id == _fixedProfileId) return;
      throw StateError('A captured profile cannot change its owner');
    }
    await _initializeProfiles();
    await db.transaction((txn) async {
      if (!await _profilesStore.record(id).exists(txn)) {
        throw StateError('Profile no longer exists');
      }
      await _profileStateStore.record('active').put(txn, {'id': id});
    });
  }

  @override
  Future<void> deleteProfile(String id) => db.transaction((txn) async {
        if (_fixedProfileId != null) await ensureProfileExists(txn);
        final profiles = await _profilesStore.find(txn);
        if (!profiles.any((profile) => profile.key == id)) {
          throw StateError('Profile no longer exists');
        }
        if (profiles.length <= 1) {
          throw StateError('The last profile cannot be deleted');
        }
        if ((await _profileStateStore.record('active').get(txn))?['id'] == id) {
          throw StateError(
              'Switch to another profile before deleting this one');
        }
        final owner = forProfile(id);
        owner._cancelPendingHistory();
        final revocations = <Server, Set<String>>{};
        for (final row in await owner.serversStore.find(txn)) {
          final account = _mediaAccount(row.value);
          if (account != null &&
              account.profileId == id &&
              account.accountId == row.key &&
              trustedMediaCompanionOrigins(account).isNotEmpty) {
            revocations[account] = {};
          }
        }
        String storeName(String name) =>
            id == PersonProfile.defaultId ? name : 'profile:$id:$name';
        for (final name in [
          'downloadedVideo',
          'searchHistory',
          'serviers',
          'mediaCompanionDecisions',
          'videoFilters',
          'historyVideoCache',
          for (final origin in PlaybackHistoryOrigin.values)
            '${origin.name}PlaybackHistory',
          _musicListeningEvents,
          'progress',
          'offline_subscriptions',
        ]) {
          await stringMapStoreFactory.store(storeName(name)).delete(txn);
        }
        await intMapStoreFactory.store(storeName('homeLayout')).delete(txn);
        final settings = stringMapStoreFactory.store(storeName('settings'));
        if (id == PersonProfile.defaultId) {
          for (final record in await settings.find(txn)) {
            if (!_deviceSettings.contains(record.key)) {
              await settings.record(record.key).delete(txn);
            }
          }
        } else {
          await settings.delete(txn);
        }
        for (final name in [
          'watchState',
          'watchMembership',
          'watchOutbox',
          'watchSync',
        ]) {
          await stringMapStoreFactory.store('$name:$id').delete(txn);
        }
        await _profilesStore.record(id).delete(txn);
        // Native validates the whole profile edit before changing any reader.
        // A refusal rolls the database transaction back with all grants intact.
        await setNativeMediaCompanionAccounts(revocations);
      });

  static Future<SembastSqfDb> create() async {
    final docsDir = await getApplicationDocumentsDirectory();
    var dbPath = p.join(docsDir.path, "clipious.db");

    final databaseFactorySqflite =
        getDatabaseFactorySqflite(sqflite.databaseFactory);
    var db = await databaseFactorySqflite.openDatabase(
      dbPath.toString(),
      version: 1,
    );

    final client = SembastSqfDb(db);
    await client._initializeProfiles();
    return client;
  }

  static Future<SembastSqfDb> createInMemory() async {
    var factory = newDatabaseFactoryMemory();
    var db = await factory.openDatabase("${const Uuid().v4()}.db");
    final client = SembastSqfDb(db);
    await client._initializeProfiles();
    return client;
  }

  @override
  Future<void> addToSearchHistory(SearchHistoryItem searchHistoryItem) async {
    if (_fixedProfileId == null) {
      return forProfile(profileId).addToSearchHistory(searchHistoryItem);
    }
    searchHistoryItem.time = DateTime.now().millisecondsSinceEpoch;
    await _writeProfile((owner, txn) => owner.searchHistoryStore
        .record(searchHistoryItem.search)
        .put(txn, searchHistoryItem.toJson()));
    await clearExcessSearchHistory();
  }

  @override
  Future<void> deleteFromSearchHistory(String search) async {
    await _writeProfile(
        (owner, txn) => owner.searchHistoryStore.record(search).delete(txn));
  }

  @override
  Future<void> cleanOldLogs() async {
    final count = appLogsStore.countSync(db);
    final excess = count - maxLogs;
    if (excess <= 0) return;
    await appLogsStore.delete(db,
        finder: Finder(sortOrders: [SortOrder("time")], limit: excess));
    log.fine("clearing $excess logs out of $count");
  }

  @override
  Future<void> clearExcessSearchHistory() async {
    if (_fixedProfileId == null) {
      return forProfile(profileId).clearExcessSearchHistory();
    }
    final limit = int.parse(getSettings(searchHistoryLimitSettingName)?.value ??
        searchHistoryDefaultLength);

    log.fine('History limit ? $limit');

    var count = searchHistoryStore.countSync(db);
    log.fine('search history clear $count/$limit');
    if (count > limit) {
      await _writeProfile((owner, txn) => owner.searchHistoryStore.delete(txn,
          finder: Finder(
              sortOrders: [SortOrder("time")],
              offset: 0,
              limit: count - limit)));
      log.fine('clearing ${count - limit} history itens');
    }
  }

  @override
  Future<void> clearSearchHistory() async {
    await _writeProfile((owner, txn) => owner.searchHistoryStore.delete(txn));
  }

  @override
  close() async {
    if (_fixedProfileId != null) return;
    for (final pending in _pendingHistory.toList()) {
      pending.cancel();
    }
    await db.close();
  }

  @override
  Future<void> deleteDownload(DownloadedVideo vid) async {
    if (vid.profileId != profileId) {
      throw StateError('Download belongs to a different profile');
    }
    await _writeProfile((owner, txn) =>
        owner.downloadedVideosStore.record(vid.videoId).delete(txn));
  }

  @override
  Future<void> deleteFilter(VideoFilter filter) async {
    await _writeProfile((owner, txn) =>
        owner.videoFiltersStore.record(filter.uuid).delete(txn));
  }

  @override
  deleteServerById(Server server) async {
    _checkServerOwner(server);
    await _writeProfile((owner, txn) async {
      final record = owner.serversStore.record(server.accountId);
      final row = await record.get(txn);
      final account = _mediaAccount(row);
      if (account != null) await _revokeMediaCompanions(account);
      await record.delete(txn);
    });
  }

  @override
  deleteSetting(String name) async {
    await _writeProfile(
        (owner, txn) => owner._settingsFor(name).record(name).delete(txn));
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

  /// The provider renamed a shared document. Update existing references in one
  /// transaction so retries and profile switches cannot resurrect an old URI.
  Future<Set<String>> reconcileDownloadedDocumentRename(
      String oldUri, String newUri) async {
    final old = _contentDocumentUri(oldUri);
    final current = _contentDocumentUri(newUri);
    if (old == null || current == null || old == current) return {};

    final before = old.pathSegments;
    final after = current.pathSegments;
    final renamedSafDocument = old.authority == current.authority &&
        _isTreeDocument(before) &&
        _isTreeDocument(after) &&
        before[1] == after[1];
    final renamedMediaStoreItem = old.authority == 'media' &&
        current.authority == 'media' &&
        _isPrimaryMediaStoreAudio(before) &&
        _isPrimaryMediaStoreAudio(after);
    if (!renamedSafDocument && !renamedMediaStoreItem) return {};

    String? replacement(Object? value) {
      if (value is! String) return null;
      final uri = _contentDocumentUri(value);
      if (uri == null || uri.authority != old.authority) return null;
      if (renamedMediaStoreItem) return uri == old ? newUri : null;
      final stored = uri.pathSegments;
      if (!_isTreeDocument(stored) || stored[3] != before[3]) return null;
      // A download can have its own grant to another tree containing the same
      // document. The provider ID changes on rename, the tree grant does not.
      final treePrefix = value.substring(0, value.lastIndexOf('/') + 1);
      return '$treePrefix${Uri.encodeComponent(after[3])}';
    }

    return db.transaction((txn) async {
      final changedProfiles = <String>{};
      for (final profile in await _profilesStore.find(txn)) {
        final store = stringMapStoreFactory
            .store(_profileStoreName('downloadedVideo', profile.key));
        final records = await store.find(txn,
            finder: Finder(filter: Filter.equals('downloadComplete', true)));
        for (final record in records) {
          final row = record.value;
          if ((row['profileId'] ?? PersonProfile.defaultId) != profile.key) {
            continue;
          }
          final storageUri = replacement(row['storageUri']);
          final exported = row['exportedMusic'];
          final exportedUri = exported is Map && exported['complete'] == true
              ? replacement(exported['uri'])
              : null;
          if (storageUri == null && exportedUri == null) continue;
          await record.ref.put(txn, {
            ...row,
            if (storageUri != null) 'storageUri': storageUri,
            if (exportedUri != null)
              'exportedMusic': {...(exported as Map), 'uri': exportedUri},
          });
          changedProfiles.add(profile.key);
        }
      }
      return changedProfiles;
    });
  }

  static Uri? _contentDocumentUri(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'content' &&
            uri.host.isNotEmpty &&
            uri.host == uri.authority &&
            !uri.hasQuery &&
            !uri.hasFragment
        ? uri
        : null;
  }

  static bool _isTreeDocument(List<String> path) =>
      path.length == 4 &&
      path[0] == 'tree' &&
      path[1].isNotEmpty &&
      path[2] == 'document' &&
      path[3].isNotEmpty;

  static bool _isPrimaryMediaStoreAudio(List<String> path) =>
      path.length == 4 &&
      path[0] == 'external_primary' &&
      path[1] == 'audio' &&
      path[2] == 'media' &&
      RegExp(r'^[1-9][0-9]*$').hasMatch(path[3]);

  @override
  List<VideoFilter> getAllFilters() {
    return videoFiltersStore
        .findSync(db)
        .map((e) => VideoFilter.fromJson(e.value)..uuid = e.key)
        .toList();
  }

  @override
  List<SettingsValue> getAllSettings() {
    final personal = settingsStore
        .findSync(db)
        .map((e) => SettingsValue.fromJson(e.value))
        .where((setting) => !_deviceSettings.contains(setting.name));
    final device = _globalSettingsStore
        .findSync(db)
        .map((e) => SettingsValue.fromJson(e.value))
        .where((setting) => _deviceSettings.contains(setting.name));
    return [...personal, ...device];
  }

  StoreRef<String, Map<String, Object?>> _settingsFor(String name) =>
      _deviceSettings.contains(name) ? _globalSettingsStore : settingsStore;

  void _checkServerOwner(Server server) {
    if (server.profileId != profileId) {
      throw StateError('Account belongs to a different profile');
    }
  }

  List<Server> _savedServers() {
    return serversStore
        .findSync(db)
        .map((record) => Server.fromJson(record.value))
        .where((server) => server.profileId == profileId)
        .map((server) => _withInstanceDecision(server, db))
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
    final entries = [
      if (historyVideoCacheStore.record(videoId).getSync(db) case final row?)
        HistoryVideoCache.fromJson(row),
      for (final origin in PlaybackHistoryOrigin.values)
        if (getPlaybackHistoryVideo(origin, videoId) case final entry?) entry,
    ]..sort((a, b) => b.created.compareTo(a.created));
    return entries.firstOrNull;
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
  Server? getServer(String key) {
    final saved = serversStore.record(key).getSync(db);
    if (saved != null) {
      final server = Server.fromJson(saved);
      if (server.profileId == profileId) {
        return _withInstanceDecision(server, db);
      }
    }
    // Exact account keys (including legacy URL keys) win. A URL that is not
    // itself an account key resolves only within this person, preferring the
    // selected account when several new accounts share an endpoint.
    final matches = _savedServers().where((server) => server.url == key);
    return matches.where((server) => server.inUse).firstOrNull ??
        matches.firstOrNull;
  }

  @override
  Future<List<Server>> getServers() async {
    return _savedServers();
  }

  @override
  Future<Server> getCurrentlySelectedServer() => _fixedProfileId == null
      ? forProfile(profileId).getCurrentlySelectedServer()
      : super.getCurrentlySelectedServer();

  @override
  Future<void> deleteServer(Server server) async {
    if (_fixedProfileId == null) {
      return forProfile(profileId).deleteServer(server);
    }
    _checkServerOwner(server);
    await super.deleteServer(server);
  }

  @override
  SettingsValue? getSettings(String name) {
    var v = _settingsFor(name).record(name).getSync(db);
    return v != null ? SettingsValue.fromJson(v) : null;
  }

  @override
  double getVideoProgress(String videoId) {
    return getVideoPlaybackProgress(videoId).progress;
  }

  @override
  Progress getVideoPlaybackProgress(String videoId) {
    final value = progressStore.record(videoId).getSync(db);
    return value == null ? Progress(0, videoId) : Progress.fromJson(value);
  }

  @override
  List<Progress> getAllProgress() => progressStore
      .findSync(db)
      .map((record) => Progress.fromJson(record.value))
      .toList();

  @override
  List<HistoryVideoCache> getLocalHistory() {
    final entries = _historyByDate([
      historyVideoCacheStore,
      playbackHistoryStore(PlaybackHistoryOrigin.video),
    ])
      ..addAll(getPlaybackHistory(PlaybackHistoryOrigin.music));
    entries.sort((a, b) => b.created.compareTo(a.created));
    final ids = <String>{};
    return entries.where((entry) => ids.add(entry.videoId)).toList();
  }

  @override
  List<HistoryVideoCache> getPlaybackHistory(PlaybackHistoryOrigin origin) {
    if (origin != PlaybackHistoryOrigin.music) {
      return _historyByDate([playbackHistoryStore(origin)]);
    }
    final ids = <String>{};
    return [
      for (final event in getMusicListeningEvents())
        if (event.source != MusicListeningSource.device &&
            ids.add(event.trackId))
          event.entry,
    ];
  }

  List<HistoryVideoCache> _historyByDate(
          List<StoreRef<String, Map<String, Object?>>> stores) =>
      [
        for (final store in stores)
          for (final record in store.findSync(db))
            HistoryVideoCache.fromJson(record.value),
      ]..sort((a, b) => b.created.compareTo(a.created));

  @override
  HistoryVideoCache? getPlaybackHistoryVideo(
      PlaybackHistoryOrigin origin, String videoId) {
    if (origin == PlaybackHistoryOrigin.music) {
      final entry = getMusicListeningEvents(trackId: videoId)
          .where((event) => event.source != MusicListeningSource.device)
          .firstOrNull
          ?.entry;
      return entry?..origin = origin;
    }
    final row = playbackHistoryStore(origin).record(videoId).getSync(db);
    return row == null
        ? null
        : (HistoryVideoCache.fromJson(row)..origin = origin);
  }

  @override
  Future<void> recordPlaybackHistory(
          PlaybackHistoryOrigin origin, HistoryVideoCache entry) =>
      beginPlaybackHistory(origin, entry.videoId).record(entry);

  @override
  PlaybackHistoryWrite beginPlaybackHistory(
          PlaybackHistoryOrigin origin, String videoId) =>
      _newHistoryWrite(origin, videoId, (owner, txn, entry, _, current) async {
        if (origin == PlaybackHistoryOrigin.music &&
            await owner._musicRecordingPausedIn(txn)) {
          return false;
        }
        if (!current()) return false;
        await owner
            .playbackHistoryStore(origin)
            .record(videoId)
            .put(txn, entry.toJson());
        return true;
      });

  PlaybackHistoryWrite _newHistoryWrite(
      PlaybackHistoryOrigin origin,
      String videoId,
      Future<bool> Function(SembastSqfDb, Transaction, HistoryVideoCache,
              PlaylistReference?, bool Function())
          write,
      {bool notify = false}) {
    final owner = forProfile(profileId);
    final pending = PlaybackHistoryWrite(owner.profileId, origin, videoId,
        (entry, playlist, current) async {
      final stored = await owner._writeProfile(
          (owner, txn) => write(owner, txn, entry, playlist, current));
      if (notify && stored) playbackHistoryRevision.value++;
    }, onFinish: _pendingHistory.remove);
    _pendingHistory.add(pending);
    return pending;
  }

  @override
  bool get musicHistoryRecordingPaused =>
      getSettings(_musicHistoryRecordingPaused)?.value == 'true';

  Future<bool> _musicRecordingPausedIn(Transaction txn) async =>
      (await settingsStore
          .record(_musicHistoryRecordingPaused)
          .get(txn))?['value'] ==
      'true';

  @override
  Future<void> setMusicHistoryRecordingPaused(bool paused) async {
    final profile = forProfile(profileId);
    if (paused) {
      profile._cancelPendingHistory(origin: PlaybackHistoryOrigin.music);
    }
    await profile._writeProfile((owner, txn) async {
      final setting = SettingsValue(_musicHistoryRecordingPaused, '$paused');
      await owner.settingsStore.record(setting.name).put(txn, setting.toJson());
    });
    if (paused) {
      profile._cancelPendingHistory(origin: PlaybackHistoryOrigin.music);
    }
    playbackHistoryRevision.value++;
  }

  @override
  PlaybackHistoryWrite? beginMusicListening(String trackId) {
    if (musicHistoryRecordingPaused) return null;
    return _newHistoryWrite(PlaybackHistoryOrigin.music, trackId,
        (owner, txn, entry, playlist, current) async {
      if (await owner._musicRecordingPausedIn(txn) || !current()) return false;
      final event = MusicListeningEvent(
        id: const Uuid().v4(),
        entry: entry,
        source: trackId.startsWith('device:')
            ? MusicListeningSource.device
            : entry.playedFromDownload
                ? MusicListeningSource.download
                : MusicListeningSource.catalog,
        playlist: playlist?.profileId == owner.profileId ? playlist : null,
      );
      await owner._musicListeningStore
          .record(event.id)
          .put(txn, event.toJson());
      return true;
    }, notify: true);
  }

  @override
  List<MusicListeningEvent> getMusicListeningEvents({String? trackId}) {
    final legacy = playbackHistoryStore(PlaybackHistoryOrigin.music);
    final previous = trackId == null
        ? legacy.findSync(db).map((row) => row.value)
        : [if (legacy.record(trackId).getSync(db) case final row?) row];
    final events = [
      for (final row in _musicListeningStore.findSync(db,
          finder: trackId == null
              ? null
              : Finder(filter: Filter.equals('trackId', trackId))))
        MusicListeningEvent.fromJson(row.value),
      for (final row in previous)
        MusicListeningEvent.legacy(HistoryVideoCache.fromJson(row)),
    ]..sort((a, b) {
        final dateOrder = b.playedAt.compareTo(a.playedAt);
        return dateOrder != 0 ? dateOrder : b.id.compareTo(a.id);
      });
    final confirmed = {
      for (final event in events)
        if (!event.isLegacy) (event.trackId, event.playedAt),
    };
    final seen = <String>{};
    return [
      for (final event in events)
        if ((!event.isLegacy ||
                !confirmed.contains((event.trackId, event.playedAt))) &&
            seen.add(event.id))
          event,
    ];
  }

  @override
  Future<int> mergeMusicListeningEvents(
      Iterable<MusicListeningEvent> events) async {
    final input = events.toList();
    if (input.isEmpty) return 0;
    final added = await _writeProfile((owner, txn) async {
      final store = owner._musicListeningStore;
      var count = 0;
      // A legacy snapshot can refer to a confirmed event in the same import.
      for (final event in [
        ...input.where((event) => !event.isLegacy),
        ...input.where((event) => event.isLegacy),
      ]) {
        final record = store.record(event.id);
        if (await record.exists(txn) ||
            (event.isLegacy && await owner._hasListeningAt(txn, event))) {
          continue;
        }
        await record.put(txn, owner._ownListeningEvent(event.toJson()));
        count++;
      }
      return count;
    });
    if (added > 0) playbackHistoryRevision.value++;
    return added;
  }

  Future<bool> _hasListeningAt(
      Transaction txn, MusicListeningEvent event) async {
    final previous = await playbackHistoryStore(PlaybackHistoryOrigin.music)
        .record(event.trackId)
        .get(txn);
    if (previous != null &&
        HistoryVideoCache.fromJson(previous).created.toUtc() ==
            event.playedAt) {
      return true;
    }
    return await _musicListeningStore.findFirst(txn,
            finder: Finder(
              filter: Filter.and([
                Filter.equals('trackId', event.trackId),
                Filter.equals('playedAt', event.playedAt.toIso8601String()),
              ]),
            )) !=
        null;
  }

  Map<String, dynamic> _ownListeningEvent(Map<String, dynamic> row) {
    final playlist = PlaylistReference.tryParse(row['playlist']);
    if (playlist == null || playlist.profileId == profileId) return row;
    final owned = {...row}..remove('playlist');
    if (playlist.kind != PlaylistSourceKind.account) {
      owned['playlist'] = {...playlist.toJson(), 'profileId': profileId};
    }
    return owned;
  }

  @override
  Future<void> removeMusicListeningTracks(Set<String>? trackIds) async {
    final ids = trackIds == null ? null : Set<String>.of(trackIds);
    if (ids?.isEmpty == true) return;
    if (ids == null) {
      _cancelPendingHistory(origin: PlaybackHistoryOrigin.music);
    } else {
      for (final id in ids) {
        _cancelPendingHistory(origin: PlaybackHistoryOrigin.music, videoId: id);
      }
    }
    await _writeProfile((owner, txn) async {
      final legacy = owner.playbackHistoryStore(PlaybackHistoryOrigin.music);
      if (ids == null) {
        await legacy.delete(txn);
        await owner._musicListeningStore.delete(txn);
      } else {
        await legacy.records(ids.toList()).delete(txn);
        await owner._musicListeningStore.delete(txn,
            finder: Finder(filter: Filter.inList('trackId', ids.toList())));
      }
    });
    playbackHistoryRevision.value++;
  }

  void _cancelPendingHistory({PlaybackHistoryOrigin? origin, String? videoId}) {
    final profile = profileId;
    for (final pending in _pendingHistory.toList()) {
      if (pending.profileId == profile &&
          (origin == null || pending.origin == origin) &&
          (videoId == null || pending.videoId == videoId)) {
        pending.cancel();
      }
    }
  }

  @override
  Future<void> deletePlaybackHistory(
      PlaybackHistoryOrigin origin, String videoId) {
    if (origin == PlaybackHistoryOrigin.music) {
      return removeMusicListeningTracks({videoId});
    }
    _cancelPendingHistory(origin: origin, videoId: videoId);
    return _writeProfile((owner, txn) =>
        owner.playbackHistoryStore(origin).record(videoId).delete(txn));
  }

  @override
  Future<void> clearPlaybackHistory(PlaybackHistoryOrigin origin) {
    if (origin == PlaybackHistoryOrigin.music) {
      return removeMusicListeningTracks(null);
    }
    _cancelPendingHistory(origin: origin);
    return _writeProfile(
        (owner, txn) => owner.playbackHistoryStore(origin).delete(txn));
  }

  @override
  Future<void> deleteLocalHistory(String videoId) {
    if (_fixedProfileId == null) {
      return forProfile(profileId).deleteLocalHistory(videoId);
    }
    _cancelPendingHistory(videoId: videoId);
    return db.transaction((txn) async {
      await ensureProfileExists(txn);
      await historyVideoCacheStore.record(videoId).delete(txn);
      for (final origin in PlaybackHistoryOrigin.values) {
        await playbackHistoryStore(origin).record(videoId).delete(txn);
      }
      await _musicListeningStore.delete(txn,
          finder: Finder(filter: Filter.equals('trackId', videoId)));
      await progressStore.record(videoId).delete(txn);
      await stringMapStoreFactory
          .store('watchState:$profileId')
          .record(videoId)
          .delete(txn);
      for (final name in ['watchMembership', 'watchOutbox']) {
        await stringMapStoreFactory.store('$name:$profileId').delete(txn,
            finder: Finder(filter: Filter.equals('videoId', videoId)));
      }
      // Remove the deleted video from any saved playback session as well.
      await settingsStore.record('playback-session').delete(txn);
      await _resetPlaylistProgress(txn, videoId: videoId);
    });
  }

  @override
  Future<void> clearLocalHistory() {
    if (_fixedProfileId == null) {
      return forProfile(profileId).clearLocalHistory();
    }
    _cancelPendingHistory();
    return db.transaction((txn) async {
      await ensureProfileExists(txn);
      await historyVideoCacheStore.delete(txn);
      for (final origin in PlaybackHistoryOrigin.values) {
        await playbackHistoryStore(origin).delete(txn);
      }
      await _musicListeningStore.delete(txn);
      await progressStore.delete(txn);
      for (final name in ['watchState', 'watchMembership', 'watchOutbox']) {
        await stringMapStoreFactory.store('$name:$profileId').delete(txn);
      }
      await settingsStore.record('playback-session').delete(txn);
      await _resetPlaylistProgress(txn);
    });
  }

  Future<void> _resetPlaylistProgress(DatabaseClient txn,
      {String? videoId}) async {
    final record = settingsStore.record(playlistProgressSettingName);
    final stored = await record.get(txn);
    await record.put(
        txn,
        SettingsValue(
                playlistProgressSettingName,
                resetPlaylistProgress(stored?['value'] as String?,
                    videoId: videoId))
            .toJson());
  }

  @override
  Future<UserBackup> exportBackup() async {
    if (_fixedProfileId == null) return forProfile(profileId).exportBackup();
    return UserBackup.parse(jsonEncode({
      'format': 'videre',
      'version': 1,
      'settings': getAllSettings()
          .where(UserBackup.validSetting)
          .map((setting) => setting.toJson())
          .toList(),
      'subscriptions':
          (await getOfflineSubscriptions()).map((sub) => sub.toJson()).toList(),
      'filters': getAllFilters()
          .map((filter) => {...filter.toJson(), 'uuid': filter.uuid})
          .toList(),
      'progress':
          getAllProgress().map((progress) => progress.toJson()).toList(),
      'history':
          historyVideoCacheStore.findSync(db).map((r) => r.value).toList(),
      for (final origin in PlaybackHistoryOrigin.values)
        '${origin.name}History': playbackHistoryStore(origin)
            .findSync(db)
            .map((r) => r.value)
            .toList(),
      _musicListeningEvents:
          _musicListeningStore.findSync(db).map((r) => r.value).toList(),
      'playlists': jsonDecode(getSettings('local-playlists')?.value ?? '[]'),
      'savedPlaylists': [
        for (final saved in SavedPlaylist.decodeLibrary(
            getSettings(playlistLibrarySettingName)?.value, profileId))
          if (saved.reference.kind == PlaylistSourceKind.public)
            UserBackup.portablePlaylist(saved),
      ],
      'watchState': stringMapStoreFactory
          .store('watchState:$profileId')
          .findSync(db)
          .map((record) => {...record.value, 'videoId': record.key})
          .toList(),
    }));
  }

  @override
  Future<void> restoreBackup(UserBackup backup, {bool replace = false}) async {
    if (_fixedProfileId == null) {
      return forProfile(profileId).restoreBackup(backup, replace: replace);
    }
    if (replace && !backup.subscriptionsOnly) _cancelPendingHistory();
    final stores = {
      'settings': settingsStore,
      'subscriptions': offlineSubscriptions,
      'filters': videoFiltersStore,
      'progress': progressStore,
      'history': historyVideoCacheStore,
      for (final origin in PlaybackHistoryOrigin.values)
        '${origin.name}History': playbackHistoryStore(origin),
      _musicListeningEvents: _musicListeningStore,
    };
    const keys = {
      'settings': 'name',
      'subscriptions': 'channelId',
      'filters': 'uuid',
      'progress': 'videoId',
      'history': 'videoId',
      'videoHistory': 'videoId',
      'musicHistory': 'videoId',
      _musicListeningEvents: 'id',
    };
    // Commit the library together; a failed restore must leave the old data usable.
    await db.transaction((txn) async {
      await ensureProfileExists(txn);
      for (final entry in stores.entries) {
        if (backup.subscriptionsOnly && entry.key != 'subscriptions') continue;
        if (replace) {
          if (entry.key == 'settings') {
            for (final setting
                in getAllSettings().where(UserBackup.validSetting)) {
              if (_deviceSettings.contains(setting.name)) continue;
              await settingsStore.record(setting.name).delete(txn);
            }
          } else {
            await entry.value.delete(txn);
          }
        }
        for (final row in backup.sections[entry.key]!) {
          final key = row[keys[entry.key]] as String;
          // Portable libraries never reconfigure another person's/device's
          // network security, storage grants or platform selection.
          if (entry.key == 'settings' && _deviceSettings.contains(key)) {
            continue;
          }
          if (!replace &&
              entry.key == 'settings' &&
              key == 'music-library-v1') {
            final existing = await settingsStore.record(key).get(txn);
            if (existing != null) {
              final merged = UserBackup.mergeMusicLibrary(
                  existing['value'] as String, row['value'] as String);
              await settingsStore
                  .record(key)
                  .put(txn, SettingsValue(key, merged).toJson());
              continue;
            }
          }
          if (!replace && await entry.value.record(key).exists(txn)) continue;
          await entry.value.record(key).put(
              txn,
              entry.key == _musicListeningEvents
                  ? _ownListeningEvent(row)
                  : row);
        }
      }
      if (!backup.subscriptionsOnly) {
        final watchedStore =
            stringMapStoreFactory.store('watchState:$profileId');
        final outboxStore =
            stringMapStoreFactory.store('watchOutbox:$profileId');
        final oldWatched = {
          for (final row in await watchedStore.find(txn)) row.key: row.value
        };
        final playbackSequence = stringMapStoreFactory
            .store('watchSync:$profileId')
            .record('playback-revision');
        var playbackRevision =
            (await playbackSequence.get(txn))?['value'] as int? ?? 0;
        if (replace) {
          await watchedStore.delete(txn);
          await outboxStore.delete(txn);
        }
        for (final row
            in backup.sections['watchState'] ?? <Map<String, dynamic>>[]) {
          final videoId = row['videoId'] as String;
          final previous = oldWatched[videoId];
          if (!replace && previous != null) continue;
          // Clearing history removes the video's row but not the profile's
          // sequence. Imported state must not revive an old callback revision.
          playbackRevision =
              max(playbackRevision, previous?['revision'] as int? ?? 0) + 1;
          await watchedStore
              .record(videoId)
              .put(txn, {...row, 'revision': playbackRevision});
          // Imported library state is local. Cancel superseded intents rather
          // than uploading the imported data to any saved account.
          if (!replace) {
            await outboxStore.delete(txn,
                finder: Finder(filter: Filter.equals('videoId', videoId)));
          }
        }
        await playbackSequence.put(txn, {'value': playbackRevision});
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
        final storedBookmarks =
            await settingsStore.record(playlistLibrarySettingName).get(txn);
        final bookmarks = <String, SavedPlaylist>{
          for (final saved in SavedPlaylist.decodeLibrary(
              storedBookmarks?['value'] as String?, profileId))
            if (!replace || saved.reference.kind == PlaylistSourceKind.account)
              saved.reference.key: saved,
        };
        for (final row in backup.sections['savedPlaylists'] ??
            const <Map<String, dynamic>>[]) {
          final saved = SavedPlaylist.tryParse({
            ...row,
            'reference': PlaylistReference(
              kind: PlaylistSourceKind.public,
              playlistId: row['playlistId'] as String,
              profileId: profileId,
            ).toJson(),
          });
          if (saved == null) {
            throw const FormatException('Invalid saved playlist.');
          }
          bookmarks.putIfAbsent(saved.reference.key, () => saved);
        }
        final bookmarkValue = jsonEncode({
          'version': 1,
          'entries': bookmarks.values.map((saved) => saved.toJson()).toList(),
        });
        if (bookmarks.length > playlistLibraryMaximumEntries ||
            utf8.encode(bookmarkValue).length > playlistLibraryMaximumBytes) {
          throw const FormatException('The saved playlist library is full.');
        }
        await settingsStore.record(playlistLibrarySettingName).put(txn,
            SettingsValue(playlistLibrarySettingName, bookmarkValue).toJson());
        await settingsStore.record('playback-session').delete(txn);
        if (replace) await _resetPlaylistProgress(txn);
      }
    });
    PlaylistLibraryService.notifyProfileChanged(this, profileId);
    playbackHistoryRevision.value++;
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
    await _writeProfile((owner, txn) =>
        owner.videoFiltersStore.record(filter.uuid).put(txn, filter.toJson()));
  }

  @override
  saveProgress(Progress progress) async {
    if (_fixedProfileId == null) {
      return forProfile(profileId).saveProgress(progress);
    }
    // Compare and write together so overlapping playback/seek updates cannot
    // lose a visible progress or watched-status transition.
    final displayChanged = await db.transaction((txn) async {
      await ensureProfileExists(txn);
      final record = progressStore.record(progress.videoId);
      final previous = await record.get(txn);
      await record.put(txn, progress.toJson());
      return progressDisplayChanged(
          previous == null ? null : Progress.fromJson(previous), progress);
    });
    if (displayChanged) {
      playbackHistoryRevision.value++;
    }
  }

  @override
  Future<void> saveSetting(SettingsValue setting) => saveSettings([setting]);

  @override
  Future<void> saveSettings(List<SettingsValue> settings) async {
    await _writeProfile((owner, txn) async {
      for (final setting in settings) {
        await owner
            ._settingsFor(setting.name)
            .record(setting.name)
            .put(txn, setting.toJson());
      }
    });
  }

  @override
  Future<void> upsertDeArrowCache(DeArrowCache cache) async {
    await deArrowCacheStore.record(cache.videoId).put(db, cache.toJson());
  }

  @override
  Future<void> upsertDownload(DownloadedVideo vid) async {
    if (vid.profileId != profileId) {
      throw StateError('Download belongs to a different profile');
    }
    await _writeProfile((owner, txn) =>
        owner.downloadedVideosStore.record(vid.videoId).put(txn, vid.toJson()));
  }

  @override
  Future<void> saveDownloadExport(String videoId, ExportedMusicCopy copy) =>
      _writeProfile((owner, txn) async {
        final record = owner.downloadedVideosStore.record(videoId);
        final download = await record.get(txn);
        if (download == null || download['downloadComplete'] != true) {
          throw StateError('The original download is unavailable');
        }
        // A provider rename can update the source reference during an export.
        await record.put(txn, {...download, 'exportedMusic': copy.toJson()});
      });

  @override
  Future<void> upsertHistoryVideo(HistoryVideoCache vid) async {
    await _writeProfile((owner, txn) => owner.historyVideoCacheStore
        .record(vid.videoId)
        .put(txn, vid.toJson()));
  }

  @override
  Future<void> upsertHomeLayout(HomeLayout layout) async {
    await _writeProfile((owner, txn) =>
        owner.homeLayoutStore.record(singleId).put(txn, layout.toJson()));
  }

  @override
  upsertServer(Server server) async {
    if (_fixedProfileId == null) {
      return forProfile(profileId).upsertServer(server);
    }
    _checkServerOwner(server);
    await _writeProfile((owner, txn) async {
      final record = owner.serversStore.record(server.accountId);
      final previous = _mediaAccount(await record.get(txn));
      final address = mediaCompanionInstanceAddress(server);
      final same = previous != null &&
          previous.profileId == server.profileId &&
          previous.accountId == server.accountId &&
          mediaCompanionInstanceAddress(previous) == address;
      // Incoming account data cannot grant access. Before the first shared
      // decision, preserve any local legacy permission on its original account.
      final origins = owner._decision(server, txn) ??
          (same ? trustedMediaCompanionOrigins(previous) : <String>{});
      final saved =
          server.copyWith(mediaCompanionOrigins: origins.toList()..sort());
      final fences = <Server, Set<String>>{};
      if (!same) {
        if (previous != null &&
            trustedMediaCompanionOrigins(previous).isNotEmpty) {
          fences[previous] = {};
        }
        if (origins.isNotEmpty) fences[saved] = origins;
      }
      await record.put(txn, saved.toJson());
      await setNativeMediaCompanionAccounts(fences);
    });
    await super.upsertServer(server);
  }

  // Legacy databases can contain incomplete rows. Resolving a playback scope
  // needs only the account identity, instance address and local permission.
  static Server? _mediaAccount(Map<String, Object?>? row) {
    final url = row?['url'];
    if (url is! String) return null;
    final profile = row!['profileId'] ?? PersonProfile.defaultId;
    final id = row['id'];
    if (profile is! String || (id != null && id is! String)) return null;
    final origins = row['mediaCompanionOrigins'];
    return Server(
        url: url,
        profileId: profile,
        id: id as String?,
        mediaCompanionOrigins:
            origins is List ? origins.whereType<String>().toList() : []);
  }

  static Future<void> _revokeMediaCompanions(Server account) async {
    if (trustedMediaCompanionOrigins(account).isNotEmpty) {
      await setNativeMediaCompanionOrigins(account, const {});
    }
  }

  Set<String>? _decision(Server server, DatabaseClient client) {
    final address = mediaCompanionInstanceAddress(server);
    if (address == null) return null;
    final row = _companionDecisions.record(address).getSync(client);
    if (row == null) return null;
    final origins = row['origins'];
    return origins is List
        ? trustedMediaCompanionOrigins(server.copyWith(
            mediaCompanionOrigins: origins.whereType<String>().toList()))
        : <String>{};
  }

  @override
  Set<String>? mediaCompanionDecision(Server server) {
    _checkServerOwner(server);
    return _decision(server, db);
  }

  Server _withInstanceDecision(Server account, DatabaseClient client) {
    final decision = _decision(account, client);
    return decision == null
        ? account
        : account.copyWith(mediaCompanionOrigins: decision.toList()..sort());
  }

  /// Update only the playback permission field on matching account rows.
  /// Their credentials, account keys and independent settings stay in place.
  Future<List<Server>> _storeDecision(
      Transaction txn, String address, Set<String> origins) async {
    final sorted = origins.toList()..sort();
    final accounts = <Server>[];
    for (final row in await serversStore.find(txn)) {
      final account = _mediaAccount(row.value);
      if (account == null ||
          row.key != account.accountId ||
          account.profileId != profileId ||
          mediaCompanionInstanceAddress(account) != address) {
        continue;
      }
      accounts.add(account);
      await serversStore
          .record(row.key)
          .update(txn, {'mediaCompanionOrigins': sorted});
    }
    await _companionDecisions.record(address).put(txn, {'origins': sorted});
    return accounts;
  }

  @override
  Future<Server?> addAccountWithMediaCompanions(Server server,
      {required bool Function() isCurrent, Set<String>? setupDecision}) async {
    _checkServerOwner(server);
    final address = mediaCompanionInstanceAddress(server);
    final proposed =
        setupDecision == null ? null : Set<String>.unmodifiable(setupDecision);
    if (proposed != null) {
      final valid = trustedMediaCompanionOrigins(
          server.copyWith(mediaCompanionOrigins: proposed.toList()));
      if (address == null ||
          proposed.length != valid.length ||
          !valid.containsAll(proposed)) {
        throw const FormatException(
            'Invalid setup account or media companions');
      }
    }
    try {
      return await _writeProfile((owner, txn) async {
        if (!isCurrent()) return null;
        final record = owner.serversStore.record(server.accountId);
        if (await record.exists(txn)) {
          throw StateError('Account already exists');
        }
        final existing = owner._decision(server, txn);
        final origins = existing ?? proposed ?? <String>{};
        final first = await owner.serversStore.count(txn) == 0;
        final saved = server.copyWith(
            inUse: first, mediaCompanionOrigins: origins.toList()..sort());
        final previous = <Server, Set<String>>{};
        if (existing == null && proposed != null) {
          // The transaction serializes competing first-time choices.
          for (final account
              in await owner._storeDecision(txn, address!, origins)) {
            previous[account] = trustedMediaCompanionOrigins(account);
          }
        }
        if (origins.isNotEmpty) previous[saved] = {};
        await record.put(txn, saved.toJson());
        if (!isCurrent()) throw _AbandonedAccountSetup();
        await setNativeMediaCompanionAccounts(
            {for (final account in previous.keys) account: origins});
        if (!isCurrent()) {
          await setNativeMediaCompanionAccounts(previous);
          throw _AbandonedAccountSetup();
        }
        return saved;
      });
    } on _AbandonedAccountSetup {
      return null;
    }
  }

  @override
  Future<Server> setMediaCompanionOrigins(Server expected, Set<String> changes,
      {required bool enabled}) {
    _checkServerOwner(expected);
    return _writeProfile((owner, txn) async {
      final row = await owner.serversStore.record(expected.accountId).get(txn);
      if (row == null) throw StateError('Account no longer exists');
      final saved = Server.fromJson(row);
      if (saved.url != expected.url ||
          saved.accountId != expected.accountId ||
          saved.profileId != expected.profileId) {
        throw StateError('Instance changed');
      }
      final normalized =
          changes.map(parseMediaCompanionOrigin).nonNulls.toSet();
      final address = mediaCompanionInstanceAddress(saved);
      if (address == null ||
          changes.isEmpty ||
          normalized.length != changes.length ||
          normalized.contains(Uri.parse(saved.url).origin)) {
        throw const FormatException('Invalid media companion origin');
      }
      final origins = {
        ...(owner._decision(saved, txn) ?? trustedMediaCompanionOrigins(saved))
      };
      if (enabled) {
        origins.addAll(normalized);
        if (origins.length > maxMediaCompanionOrigins) {
          throw const FormatException('Too many media companion origins');
        }
      } else {
        origins.removeAll(normalized);
      }
      final accounts = await owner._storeDecision(txn, address, origins);
      await setNativeMediaCompanionAccounts(
          {for (final account in accounts) account: origins});
      return saved.copyWith(mediaCompanionOrigins: origins.toList()..sort());
    });
  }

  @override
  Future<void> useServer(Server server) {
    if (_fixedProfileId == null) return forProfile(profileId).useServer(server);
    _checkServerOwner(server);
    final record = serversStore.record(server.accountId);
    final existed = record.getSync(db) != null;
    return db.transaction((txn) async {
      await ensureProfileExists(txn);
      final stored = await record.get(txn);
      if (stored == null && existed) {
        throw StateError('Account no longer exists');
      }
      // Selection changes only selection. A queued token refresh must not be
      // overwritten by the account snapshot captured before this transaction.
      final latest = _withInstanceDecision(
          stored == null
              ? server.copyWith(mediaCompanionOrigins: [])
              : Server.fromJson(stored),
          txn);
      _checkServerOwner(latest);
      await serversStore.update(txn, {'inUse': false},
          finder: Finder(filter: Filter.equals('inUse', true)));
      await record.put(txn, latest.copyWith(inUse: true).toJson());
      if (stored == null && trustedMediaCompanionOrigins(latest).isNotEmpty) {
        await setNativeMediaCompanionOrigins(
            latest, trustedMediaCompanionOrigins(latest));
      }
    });
  }

  @override
  Future<void> addOfflineSubscription(OfflineSubscription sub) async {
    await _writeProfile((owner, txn) => owner.offlineSubscriptions
        .record(sub.channelId)
        .put(txn, sub.toJson()));
    recommendationSubscriptionRevision.value++;
  }

  @override
  Future<void> deleteOfflineSubscription(String channelId) async {
    await _writeProfile((owner, txn) =>
        owner.offlineSubscriptions.record(channelId).delete(txn));
    recommendationSubscriptionRevision.value++;
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
