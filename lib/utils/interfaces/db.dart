import 'package:easy_debounce/easy_debounce.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../home/models/db/home_layout.dart';
import '../../music/models/music_listening_event.dart';
import '../../search/models/db/search_history_item.dart';
import '../../settings/models/db/app_logs.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/person_profile.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/db/video_filter.dart';
import '../../settings/models/errors/no_server_selected.dart';
import '../../videos/models/db/dearrow_cache.dart';
import '../../videos/models/db/history_video_cache.dart';
import '../../videos/models/db/progress.dart';
import '../backup.dart';

abstract class IDbClient {
  String get profileId => PersonProfile.defaultId;

  Future<List<PersonProfile>> getProfiles() async =>
      [PersonProfile.defaultProfile];

  Future<PersonProfile> createProfile(String name) async =>
      throw UnsupportedError('Profiles require the app database');

  Future<void> renameProfile(String id, String name) async =>
      throw UnsupportedError('Profiles require the app database');

  /// Delete an inactive person's local library. The last person is retained.
  Future<void> deleteProfile(String id) async =>
      throw UnsupportedError('Profiles require the app database');

  Future<void> useProfile(String id) async {
    if (id != profileId) {
      throw UnsupportedError('Profiles require the app database');
    }
  }

  /// Capture this view before asynchronous work to keep it in its person's
  /// library even if the selected person changes while the work is pending.
  IDbClient forProfile(String id) {
    if (id == profileId) return this;
    throw UnsupportedError('Profiles require the app database');
  }

  close();

  Server? getServer(String url);

  /// Resolve an account identity without the legacy URL lookup fallback.
  /// A deleted URL-keyed account must never resolve to its replacement.
  Server? getAccount(String accountId) {
    final account = getServer(accountId);
    return account?.accountId == accountId && account?.profileId == profileId
        ? account
        : null;
  }

  /// Call super at the end
  @mustCallSuper
  @mustBeOverridden
  upsertServer(Server server) async {
    var servers = await getServers();
    if (servers.length == 1) {
      await useServer(server);
    }
  }

  Future<List<Server>> getServers();

  /// Null is undecided. An empty decision remembers an explicit decline.
  Set<String>? mediaCompanionDecision(Server server) => null;

  /// A setup decision is committed with the new account. An earlier choice
  /// made for this profile and instance takes precedence.
  Future<Server?> addAccountWithMediaCompanions(Server server,
      {required bool Function() isCurrent, Set<String>? setupDecision}) async {
    if (setupDecision != null) {
      throw UnsupportedError('Companion settings require the app database');
    }
    if (!isCurrent()) return null;
    await upsertServer(server.copyWith(mediaCompanionOrigins: []));
    return getAccount(server.accountId);
  }

  /// User-approved playback origins are updated separately from general
  /// account writes so a stale settings or login snapshot cannot restore trust.
  Future<Server> setMediaCompanionOrigin(Server expected, String origin,
          {required bool enabled}) =>
      setMediaCompanionOrigins(expected, {origin}, enabled: enabled);

  Future<Server> setMediaCompanionOrigins(Server expected, Set<String> changes,
          {required bool enabled}) async =>
      throw UnsupportedError('Companion settings require the app database');

  deleteServerById(Server server);

  deleteServer(Server server) async {
    if ((await getServers()).length >= 2) {
      await deleteServerById(server);
      if (server.inUse) {
        getCurrentlySelectedServer();
      }
    }
  }

  saveSetting(SettingsValue setting);

  Future<void> saveSettings(List<SettingsValue> settings) async {
    for (final setting in settings) {
      await saveSetting(setting);
    }
  }

  List<SettingsValue> getAllSettings();

  deleteSetting(String name);

  SettingsValue? getSettings(String name);

  Future<Server> getCurrentlySelectedServer() async {
    var server =
        (await getServers()).where((element) => element.inUse).firstOrNull;
    if (server == null) {
      log.fine('No servers selected, we try to find one');
      List<Server> servers = await getServers();
      if (servers.isEmpty) {
        log.fine('We don\'t have servers, we need to show the welcome screen');
        throw NoServerSelected();
      }
      // we just select the first of the list
      await useServer(servers.first);
      return servers.first;
    } else {
      return server;
    }
  }

  Future<bool> isLoggedInToCurrentServer() async {
    var currentlySelectedServer = await getCurrentlySelectedServer();
    return (currentlySelectedServer.authToken?.isNotEmpty ?? false) ||
        (currentlySelectedServer.sidCookie?.isNotEmpty ?? false);
  }

  double getVideoProgress(String videoId);

  Progress getVideoPlaybackProgress(String videoId) =>
      Progress(getVideoProgress(videoId), videoId);

  saveProgress(Progress progress);

  List<Progress> getAllProgress() =>
      throw UnsupportedError('Progress is only available in the app database');

  List<HistoryVideoCache> getLocalHistory() =>
      throw UnsupportedError('History is only available in the app database');

  List<HistoryVideoCache> getPlaybackHistory(PlaybackHistoryOrigin origin) =>
      throw UnsupportedError('History is only available in the app database');

  HistoryVideoCache? getPlaybackHistoryVideo(
          PlaybackHistoryOrigin origin, String videoId) =>
      throw UnsupportedError('History is only available in the app database');

  Future<void> recordPlaybackHistory(
          PlaybackHistoryOrigin origin, HistoryVideoCache entry) =>
      upsertHistoryVideo(entry);

  PlaybackHistoryWrite beginPlaybackHistory(
      PlaybackHistoryOrigin origin, String videoId) {
    final owner = forProfile(profileId);
    return PlaybackHistoryWrite(owner.profileId, origin, videoId,
        (entry, _, current) async {
      if (current()) await owner.recordPlaybackHistory(origin, entry);
    });
  }

  bool get musicHistoryRecordingPaused => false;

  Future<void> setMusicHistoryRecordingPaused(bool paused) async =>
      throw UnsupportedError('Music history requires the app database');

  PlaybackHistoryWrite? beginMusicListening(String trackId) => null;

  List<MusicListeningEvent> getMusicListeningEvents({String? trackId}) =>
      const [];

  Future<void> removeMusicListeningTracks(Set<String>? trackIds) async =>
      throw UnsupportedError('Music history requires the app database');

  Future<int> mergeMusicListeningEvents(
          Iterable<MusicListeningEvent> events) async =>
      throw UnsupportedError('Music history requires the app database');

  Future<void> deletePlaybackHistory(
          PlaybackHistoryOrigin origin, String videoId) async =>
      throw UnsupportedError('History is only available in the app database');

  Future<void> clearPlaybackHistory(PlaybackHistoryOrigin origin) async =>
      throw UnsupportedError('History is only available in the app database');

  Future<void> deleteLocalHistory(String videoId) async =>
      throw UnsupportedError('History is only available in the app database');

  Future<void> clearLocalHistory() async =>
      throw UnsupportedError('History is only available in the app database');

  Future<UserBackup> exportBackup() async =>
      throw UnsupportedError('Backups require the app database');

  Future<void> restoreBackup(UserBackup backup, {bool replace = false}) async =>
      throw UnsupportedError('Backups require the app database');

  Future<void> useServer(Server server);

  List<String> getSearchHistory();

  Future<void> addToSearchHistory(SearchHistoryItem searchHistoryItem);

  Future<void> clearExcessSearchHistory();

  Future<void> clearSearchHistory();

  /// Call super at the end
  @mustCallSuper
  @mustBeOverridden
  Future<void> insertLogs(AppLog log) async {
    EasyDebounce.debounce('log-cleaning', const Duration(seconds: 5), () {
      cleanOldLogs();
    });
  }

  Future<void> cleanOldLogs();

  List<AppLog> getAppLogs();

  List<VideoFilter> getAllFilters();

  Future<void> saveFilter(VideoFilter filter);

  Future<void> deleteFilter(VideoFilter filter);

  List<DownloadedVideo> getAllDownloads();

  Future<void> upsertDownload(DownloadedVideo vid);

  Future<void> saveDownloadExport(
      String videoId, ExportedMusicCopy copy) async {
    final download = getDownloadByVideoId(videoId);
    if (download == null || !download.downloadComplete) {
      throw StateError('The original download is unavailable');
    }
    await upsertDownload(download.copyWith(exportedMusic: copy));
  }

  Future<void> deleteDownload(DownloadedVideo vid);

  DownloadedVideo? getDownloadByVideoId(String videoId);

  HistoryVideoCache? getHistoryVideoByVideoId(String videoId);

  Future<void> upsertHistoryVideo(HistoryVideoCache vid);

  // we only want one layout
  Future<void> upsertHomeLayout(HomeLayout layout);

  HomeLayout getHomeLayout();

  DeArrowCache? getDeArrowCache(String videoId);

  Future<void> upsertDeArrowCache(DeArrowCache cache);

  Future<void> deleteFromSearchHistory(String search);

  Future<void> addOfflineSubscription(OfflineSubscription sub);

  Future<void> deleteOfflineSubscription(String channelId);

  Future<bool> isOfflineSubscribed(String channelId);

  Future<List<OfflineSubscription>> getOfflineSubscriptions();
}
