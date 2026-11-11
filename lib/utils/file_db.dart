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
import '../settings/models/errors/no_server_selected.dart';
import 'file_db_lock.dart';
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
    _profileSettings = 'profile_settings.json',
    _notificationCursors = 'notification_cursors.json',
    _fileDbFolder = 'fileDb';
const _fileNotFoundErrorCode = 2;
const _profileFiles = [
  _channelNotifFile,
  _playlistNotifsFile,
  _subNotifsFile,
  _profileSettings,
  _notificationCursors,
];
const _profileDeleted = 'profile_deleted.marker';

final _log = Logger('FileDb');

class FileDB extends IDbClient {
  // Keep foreground ordering in addition to the OS locks shared by engines.
  static final _pendingUpdates = <String, Future<void>>{};
  static final _heldLocks = Object();

  final String? _fixedProfileId;
  final Server? _fixedAccount;
  String _lastProfileId = 'default';

  FileDB()
      : _fixedProfileId = null,
        _fixedAccount = null;

  FileDB._forProfile(String id, {Server? account})
      : _fixedProfileId = id,
        _fixedAccount = account {
    if (id.isEmpty || id.length > 128) {
      throw ArgumentError.value(id, 'id', 'Invalid profile ID');
    }
  }

  @override
  String get profileId => _fixedProfileId ?? _lastProfileId;

  @override
  FileDB forProfile(String id) => FileDB._forProfile(id);

  /// Freeze both ownership and credentials for a background operation.
  FileDB forAccount(Server server) =>
      FileDB._forProfile(server.profileId, account: server);

  String _profilePath(String name, String id) => id == 'default'
      ? name
      : '${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}.$name';

  Future<String> _selectedProfileId() async {
    if (_fixedProfileId != null) {
      await _ensureProfileAvailable(_fixedProfileId);
      return _fixedProfileId;
    }
    final settings =
        await _readGenericSettings(await _openAppFile(_genericSettings));
    await _ensureProfileAvailable(settings.profileId);
    _lastProfileId = settings.profileId;
    return settings.profileId;
  }

  Future<void> _ensureProfileAvailable(String id) async {
    final marker = await _openAppFile(_profilePath(_profileDeleted, id));
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('This profile has been deleted');
    }
  }

  Future<T> _withStorageLock<T>(File file, Future<T> Function() action) async {
    final held = Zone.current[_heldLocks] as Set<String>? ?? const <String>{};
    final key = file.absolute.path;
    if (held.contains(key)) return action();
    return withFileDbLock(
        file,
        () => runZoned(action, zoneValues: {
              _heldLocks: {...held, key}
            }));
  }

  Future<T> _withProfileLock<T>(String id, Future<T> Function() action,
      {bool allowDeleted = false}) async {
    final lock = await _openAppFile(_profilePath('profile.lock', id));
    return _withStorageLock(lock, () async {
      if (!allowDeleted) await _ensureProfileAvailable(id);
      return action();
    });
  }

  String? _fileProfile(File file) {
    final name = p.basename(file.path);
    for (final owned in _profileFiles) {
      if (name == owned) return 'default';
      if (name.endsWith('.$owned')) {
        final encoded = name.substring(0, name.length - owned.length - 1);
        return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      }
    }
    return null;
  }

  /// Retire an inactive mirror before removing its exact owned files. The
  /// marker is permanent, including after a partial cleanup failure, so an
  /// already running background isolate cannot recreate this person's data.
  @override
  Future<void> deleteProfile(String id) async {
    if (_fixedProfileId != null) {
      throw StateError('Only the root file database can delete profiles');
    }
    if (id.isEmpty || id.length > 128) {
      throw ArgumentError.value(id, 'id', 'Invalid profile ID');
    }
    // Selection always acquires the generic lock before any profile lock.
    await _updateFile(_genericSettings, (file) async {
      if ((await _readGenericSettings(file)).profileId == id) {
        throw StateError('Switch profiles before deleting the active profile');
      }
      await _withProfileLock(id, () async {
        final marker = await _openAppFile(_profilePath(_profileDeleted, id));
        await marker.writeAsString('', flush: true);
        for (final name in _profileFiles) {
          final owned = await _openAppFile(_profilePath(name, id));
          try {
            await owned.delete();
          } on FileSystemException catch (error) {
            if (error.osError?.errorCode != _fileNotFoundErrorCode) rethrow;
          }
        }
      }, allowDeleted: true);
    });
  }

  Future<void> _updateProfileFile(
      String path, Future<void> Function(File) update) async {
    final id = await _selectedProfileId();
    await _updateFile(_profilePath(path, id), update);
  }

  @override
  Future<void> useProfile(String id) {
    if (id.isEmpty || id.length > 128) {
      throw ArgumentError.value(id, 'id', 'Invalid profile ID');
    }
    if (_fixedProfileId != null) {
      if (_fixedProfileId != id) {
        throw StateError('A fixed profile view cannot switch profiles');
      }
      return _ensureProfileAvailable(id);
    }
    return _updateFile(_genericSettings, (file) async {
      final current = await _readGenericSettings(file);
      await _writeMapToFile(
          await _openAppFile(_profilePath(_profileSettings, current.profileId)),
          current.toJson());
      final selected =
          current.profileId == id ? current : await _readProfileSettings(id);
      await _writeMapToFile(file, selected.toJson());
      _lastProfileId = id;
    });
  }

  Future<FileDbGenericSettings> _readProfileSettings(String id) async {
    final settings = await _readGenericSettings(
        await _openAppFile(_profilePath(_profileSettings, id)));
    settings.profileId = id;
    if (settings.server?.profileId != id) settings.server = null;
    return settings;
  }

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
      forProfile(settings.profileId)._updateGenericSettings((current) {
        current.server = settings.server;
        current.subscriptionNotifications = settings.subscriptionNotifications;
        current.locale = settings.locale;
      });

  Future<void> _updateGenericSettings(
          FutureOr<void> Function(FileDbGenericSettings) update) =>
      _updateFile(_genericSettings, (file) async {
        final active = await _readGenericSettings(file);
        final id = _fixedProfileId ?? active.profileId;
        final settings =
            id == active.profileId ? active : await _readProfileSettings(id);
        await update(settings);
        settings.profileId = id;
        if (settings.server?.profileId != id) settings.server = null;
        await _writeMapToFile(
            await _openAppFile(_profilePath(_profileSettings, id)),
            settings.toJson());
        if (id == active.profileId) {
          await _writeMapToFile(file, settings.toJson());
          _lastProfileId = id;
        }
      });

  Future<FileDbGenericSettings> getGenericSettings() async {
    final active =
        await _readGenericSettings(await _openAppFile(_genericSettings));
    _lastProfileId = active.profileId;
    if (_fixedProfileId != null && _fixedProfileId != active.profileId) {
      final settings = await _readProfileSettings(_fixedProfileId);
      await _ensureProfileAvailable(_fixedProfileId);
      if (_fixedAccount != null) settings.server = _fixedAccount;
      return settings;
    }
    await _ensureProfileAvailable(active.profileId);
    if (active.server?.profileId != active.profileId) active.server = null;
    if (_fixedAccount != null) active.server = _fixedAccount;
    return active;
  }

  Future<FileDbGenericSettings> _readGenericSettings(File file) async {
    var content = await _readFileAsMap(file);
    if (content.isNotEmpty) {
      final settings = FileDbGenericSettings.fromJson(content);
      // Existing notification files belong to the legacy selected account,
      // not to every account subsequently added to the Default person.
      if (!content.containsKey('legacyNotificationAccountId') &&
          settings.profileId == 'default' &&
          settings.server != null &&
          settings.server!.id == null) {
        settings.legacyNotificationAccountId = settings.server!.accountId;
      }
      return settings;
    } else {
      return FileDbGenericSettings();
    }
  }

  Future<_NotificationContext> _notificationContext() async {
    final settings = await getGenericSettings();
    return _NotificationContext(settings.profileId, settings.server?.accountId,
        settings.legacyNotificationAccountId);
  }

  Future<Map<String, dynamic>> _accountCursors(
      _NotificationContext context) async {
    final contents = await _readFileAsMap(await _openAppFile(
        _profilePath(_notificationCursors, context.profileId)));
    final account = contents[context.accountKey];
    return account is Map ? Map<String, dynamic>.from(account) : {};
  }

  Future<void> _updateCursors(_NotificationContext context,
          void Function(Map<String, dynamic>) update) =>
      _updateFile(_profilePath(_notificationCursors, context.profileId),
          (file) async {
        final contents = await _readFileAsMap(file);
        final existing = contents[context.accountKey];
        final account = existing is Map
            ? Map<String, dynamic>.from(existing)
            : <String, dynamic>{};
        update(account);
        contents[context.accountKey] = account;
        await _writeMapToFile(file, contents);
      });

  Map<String, dynamic> _cursorSection(
          Map<String, dynamic> account, String section) =>
      account[section] is Map
          ? Map<String, dynamic>.from(account[section] as Map)
          : {};

  Future<SubscriptionNotification?> getLastSubscriptionNotification() async {
    final context = await _notificationContext();
    final account = await _accountCursors(context);
    final cursor = account['subscription'];
    if (cursor is Map) {
      return SubscriptionNotification.fromJson(
          Map<String, dynamic>.from(cursor));
    }
    if (!context.useLegacyCursors) return null;
    final content = await _readFileAsMap(
        await _openAppFile(_profilePath(_subNotifsFile, context.profileId)));
    return content.isEmpty ? null : SubscriptionNotification.fromJson(content);
  }

  Future<void> setLastSubscriptionNotification(
      SubscriptionNotification sub) async {
    final context = await _notificationContext();
    await _updateCursors(context, (account) {
      account['subscription'] = sub.toJson();
    });
  }

  Future<ChannelNotification?> getChannelNotification(String channelId) async {
    return (await getAllChannelNotifications())
        .firstWhereOrNull((element) => element.channelId == channelId);
  }

  Future<List<ChannelNotification>> getAllChannelNotifications() async {
    final context = await _notificationContext();
    final contents = await _readFileAsMap(
        await _openAppFile(_profilePath(_channelNotifFile, context.profileId)));
    final cursors = _cursorSection(await _accountCursors(context), 'channels');
    return contents.values.map((value) {
      final notification = ChannelNotification.fromJson(value);
      final cursor = cursors[notification.channelId];
      if (cursor is Map) {
        notification.lastSeenVideoId = cursor['lastSeenVideoId'] as String;
        notification.timestamp = cursor['timestamp'] as int;
      } else if (!context.useLegacyCursors ||
          (value as Map).containsKey('cursorAccountId')) {
        notification.lastSeenVideoId = '';
        notification.timestamp = 0;
      }
      return notification;
    }).toList();
  }

  Future<void> deleteChannelNotification(ChannelNotification notif) =>
      _updateFileMap(_channelNotifFile,
          (contents) => contents.remove(notif.channelId) != null);

  Future<void> upsertChannelNotification(ChannelNotification notif) async {
    final context = await _notificationContext();
    await _updateFile(_profilePath(_channelNotifFile, context.profileId),
        (file) async {
      final contents = await _readFileAsMap(file);
      final previous = contents[notif.channelId];
      contents[notif.channelId] = previous is Map
          ? {...previous, 'channelName': notif.channelName}
          : {...notif.toJson(), 'cursorAccountId': context.accountKey};
      await _writeMapToFile(file, contents);
    });
    await _updateCursors(context, (account) {
      final channels = _cursorSection(account, 'channels');
      channels[notif.channelId] = {
        'lastSeenVideoId': notif.lastSeenVideoId,
        'timestamp': notif.timestamp
      };
      account['channels'] = channels;
    });
  }

  Future<void> setChannelNotificationLastViewedVideo(
      String channelId, String videoId) async {
    final context = await _notificationContext();
    final contents = await _readFileAsMap(
        await _openAppFile(_profilePath(_channelNotifFile, context.profileId)));
    if (!contents.containsKey(channelId)) return;
    await _updateCursors(context, (account) {
      final channels = _cursorSection(account, 'channels');
      channels[channelId] = {
        'lastSeenVideoId': videoId,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      };
      account['channels'] = channels;
    });
  }

  Future<PlaylistNotification?> getPlaylistNotification(
      String playlistId) async {
    return (await getAllPlaylistNotifications())
        .firstWhereOrNull((element) => element.playlistId == playlistId);
  }

  Future<List<PlaylistNotification>> getAllPlaylistNotifications() async {
    final context = await _notificationContext();
    final contents = await _readFileAsMap(await _openAppFile(
        _profilePath(_playlistNotifsFile, context.profileId)));
    final cursors = _cursorSection(await _accountCursors(context), 'playlists');
    return contents.values.map((value) {
      final notification = PlaylistNotification.fromJson(value);
      final cursor = cursors[notification.playlistId];
      if (cursor is Map) {
        notification.lastVideoCount = cursor['lastVideoCount'] as int;
        notification.timestamp = cursor['timestamp'] as int;
      } else if (!context.useLegacyCursors ||
          (value as Map).containsKey('cursorAccountId')) {
        notification.lastVideoCount = 0;
        notification.timestamp = 0;
      }
      return notification;
    }).toList();
  }

  Future<void> deletePlaylistNotification(PlaylistNotification notif) =>
      _updateFileMap(_playlistNotifsFile,
          (contents) => contents.remove(notif.playlistId) != null);

  Future<void> upsertPlaylistNotification(PlaylistNotification notif) async {
    final context = await _notificationContext();
    await _updateFile(_profilePath(_playlistNotifsFile, context.profileId),
        (file) async {
      final contents = await _readFileAsMap(file);
      final previous = contents[notif.playlistId];
      contents[notif.playlistId] = previous is Map
          ? {...previous, 'playlistName': notif.playlistName}
          : {...notif.toJson(), 'cursorAccountId': context.accountKey};
      await _writeMapToFile(file, contents);
    });
    await _updateCursors(context, (account) {
      final playlists = _cursorSection(account, 'playlists');
      playlists[notif.playlistId] = {
        'lastVideoCount': notif.lastVideoCount,
        'timestamp': notif.timestamp
      };
      account['playlists'] = playlists;
    });
  }

  Future<void> setPlaylistNotificationLastViewedVideo(
      String playlistId, int videoCount) async {
    final context = await _notificationContext();
    final contents = await _readFileAsMap(await _openAppFile(
        _profilePath(_playlistNotifsFile, context.profileId)));
    if (!contents.containsKey(playlistId)) return;
    await _updateCursors(context, (account) {
      final playlists = _cursorSection(account, 'playlists');
      playlists[playlistId] = {
        'lastVideoCount': videoCount,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      };
      account['playlists'] = playlists;
    });
  }

  Future<void> _updateFileMap(
          String path, bool Function(Map<String, dynamic>) update) =>
      _updateProfileFile(path, (file) async {
        final contents = await _readFileAsMap(file);
        if (update(contents)) await _writeMapToFile(file, contents);
      });

  Future<void> _updateFile(String path, Future<void> Function(File) update) {
    final previous = _pendingUpdates[path] ?? Future<void>.value();
    final result = previous.then((_) async {
      final file = await _openAppFile(path);
      if (path == _genericSettings) {
        return _withStorageLock(
            await _openAppFile('generic_settings.lock'), () => update(file));
      }
      final id = _fileProfile(file);
      if (id == null) throw StateError('FileDB write has no profile owner');
      return _withProfileLock(id, () => update(file));
    });
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

  Future<void> _writeMapToFile(File f, Map<String, dynamic> map,
      {FutureOr<bool> Function()? stillCurrent}) async {
    final id = _fileProfile(f) ?? map['profileId'] as String?;
    if (id == null) throw StateError('FileDB write has no profile owner');
    await _withProfileLock(id, () async {
      var string = jsonEncode(map);
      _log.fine("Writing json to ${f.path}");
      final temporary = File('${f.path}.${const Uuid().v4()}.tmp');
      try {
        await temporary.writeAsString(string, flush: true);
        if (stillCurrent != null) {
          final current = stillCurrent();
          if (!(current is Future<bool> ? await current : current)) return;
        }
        await temporary.rename(f.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
  }

  Future<Map<String, dynamic>> _readFileAsMap(File f) async {
    final id = _fileProfile(f);
    if (id != null) await _ensureProfileAvailable(id);
    Map<String, dynamic> content;
    try {
      final contents = await f.readAsString();
      content = jsonDecode(contents);
    } catch (e) {
      content = {};
    }
    if (id != null) await _ensureProfileAvailable(id);
    return content;
  }

  Future<void> clearDb() async {
    final id = await _selectedProfileId();
    for (final path in _profileFiles) {
      await _updateFile(_profilePath(path, id), (file) async {
        try {
          await file.delete();
        } on FileSystemException catch (error) {
          if (error.osError?.errorCode != _fileNotFoundErrorCode) rethrow;
          log.fine('file doesn\'t exist');
        }
      });
    }
    await _updateFile(_genericSettings, (file) async {
      final active = await _readGenericSettings(file);
      if (active.profileId == id) {
        await _writeMapToFile(
            file, (FileDbGenericSettings()..profileId = id).toJson());
      }
    });
  }

  /*
  * This is getting worst and worst. we will only implement the required things for the work manager.
   */
  @override
  Future<void> useServer(Server server) {
    if (_fixedProfileId != null && _fixedProfileId != server.profileId) {
      throw StateError('The account belongs to another profile');
    }
    return forProfile(server.profileId)
        ._updateGenericSettings((settings) => settings.server = server);
  }

  /// Refresh credentials only for an account that is still selected and
  /// already mirrored. Selection belongs to useProfile/useServer/syncWithDb.
  /// An authentication result may have waited behind a newer account switch.
  Future<void> refreshAccount(Server expected) {
    if (_fixedProfileId != null && _fixedProfileId != expected.profileId) {
      throw StateError('The account belongs to another profile');
    }
    return _updateFile(_genericSettings, (file) async {
      final active = await _readGenericSettings(file);
      if (active.profileId != expected.profileId ||
          active.server?.accountId != expected.accountId) {
        return;
      }
      var latest = _savedSelectedAccount(expected);
      if (latest == null) return;
      active.server = latest;
      await _writeMapToFile(
          await _openAppFile(_profilePath(_profileSettings, active.profileId)),
          active.toJson(),
          stillCurrent: () => _savedSelectedAccount(expected) == latest);
      // A second credential update can finish while the archive is written.
      // Read it again rather than publishing the queued caller's old tokens.
      latest = _savedSelectedAccount(expected);
      if (latest == null) return;
      active.server = latest;
      final publishing = latest;
      await _writeMapToFile(file, active.toJson(),
          stillCurrent: () => _savedSelectedAccount(expected) == publishing);
    });
  }

  Server? _savedSelectedAccount(Server expected) {
    if (db.profileId != expected.profileId) return null;
    final saved =
        db.forProfile(expected.profileId).getAccount(expected.accountId);
    return saved?.inUse == true ? saved : null;
  }

  @override
  Future<Server> getCurrentlySelectedServer() async {
    final server = (await getGenericSettings()).server;
    if (server == null) throw NoServerSelected();
    return server;
  }

  @override
  Future<List<Server>> getServers() async {
    final server = (await getGenericSettings()).server;
    return server == null ? [] : [server];
  }

  @override
  Future<void> addToSearchHistory(SearchHistoryItem searchHistoryItem) {
    throw UnimplementedError();
  }

  Future<void> syncWithDb() async {
    _log.fine('Syncing file settings with DB');
    final id = _fixedProfileId ?? db.profileId;
    await _updateFile(_genericSettings, (file) async {
      // A delayed read from the previous person must not undo a later switch.
      if (db.profileId != id) return;
      final active = await _readGenericSettings(file);
      if (db.profileId != id) return;
      final database = db.forProfile(id);
      await _writeMapToFile(
          await _openAppFile(_profilePath(_profileSettings, active.profileId)),
          active.toJson());
      final settings =
          active.profileId == id ? active : await _readProfileSettings(id);
      // Resolve selection inside the file queue. It may have changed while an
      // earlier update or the documents-directory lookup was still pending.
      Server? selected;
      try {
        selected = await database.getCurrentlySelectedServer();
        selected = _savedSelectedAccount(selected);
        if (selected == null) return;
      } on NoServerSelected {
        _log.fine('No server selected in this profile');
      }
      settings.locale = database.getSettings(localeSettingName)?.value;
      settings.server = selected;
      // Check again after filesystem work before publishing the new snapshot.
      if (db.profileId != id) return;
      final publishing = selected;
      await _writeMapToFile(file, settings.toJson(), stillCurrent: () {
        if (db.profileId != id) return false;
        if (publishing == null) {
          return database
              .getServers()
              .then((servers) => servers.isEmpty && db.profileId == id);
        }
        return _savedSelectedAccount(publishing) == publishing;
      });
      if (db.profileId == id) _lastProfileId = id;
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
      (useProxySettingName) => SettingsValue(useProxySettingName, "true"),
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
  @JsonKey(defaultValue: 'default')
  String profileId = 'default';
  String? legacyNotificationAccountId;
  Server?
      server; // we only store the currently used server because that's what we're interested in
  bool subscriptionNotifications = false;
  String? locale;

  FileDbGenericSettings();

  factory FileDbGenericSettings.fromJson(Map<String, dynamic> json) =>
      _$FileDbGenericSettingsFromJson(json);

  Map<String, dynamic> toJson() => _$FileDbGenericSettingsToJson(this);
}

class _NotificationContext {
  final String profileId;
  final String? accountId;
  final String? legacyAccountId;

  const _NotificationContext(
      this.profileId, this.accountId, this.legacyAccountId);

  String get accountKey => accountId ?? '';

  bool get useLegacyCursors =>
      accountId == null || accountId == legacyAccountId;
}
