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
import '../../subscription_management/models/subscription_group.dart';
import '../../videos/models/db/dearrow_cache.dart';
import '../../videos/models/db/history_video_cache.dart';
import '../../videos/models/db/progress.dart';
import '../../videos/models/music_metadata.dart';
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

  /// Observe the initial setting and subsequent committed changes.
  Stream<SettingsValue?> watchSetting(String name) => const Stream.empty();

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
        (entry, _, __, current) async {
      if (!current()) return false;
      await owner.recordPlaybackHistory(origin, entry);
      return true;
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

  Future<void> removeMusicListeningEvents(
          Iterable<MusicListeningEvent> events) async =>
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

  bool isPlaylistOwnedMusicDownload(String videoId) => false;

  Set<String> getPlaylistOwnedMusicDownloadIds() => const {};

  /// Create a playlist-only job if the profile has no matching download.
  Future<bool> insertPlaylistOwnedMusicDownload(DownloadedVideo video) async =>
      false;

  /// Promote an existing playlist-only job to an explicit download.
  Future<bool> makeMusicDownloadExplicit(String videoId) async => false;

  /// A transfer can bind an old row's account and record its output container
  /// after the UI captures it. Its requested audio and destination stay fixed.
  static bool isSameAudioDownloadJob(
          DownloadedVideo expected, DownloadedVideo current) =>
      expected.audioOnly &&
      current.audioOnly &&
      expected.videoId == current.videoId &&
      expected.profileId == current.profileId &&
      (expected.accountId == null || expected.accountId == current.accountId) &&
      expected.quality == current.quality &&
      expected.musicFormat == current.musicFormat &&
      expected.audioTrackId == current.audioTrackId &&
      expected.folderUri == current.folderUri;

  /// Adds Music labels and explicit ownership without replacing saved audio.
  Future<bool> adoptMusicDownload(DownloadedVideo expected, MusicMetadata music,
      {String? notificationTicket}) async {
    final current = getDownloadByVideoId(expected.videoId);
    if (current == null || !isSameAudioDownloadJob(expected, current)) {
      return false;
    }
    final needsLabels = current.musicMetadata == null;
    final needsTicket = !current.downloadComplete &&
        !current.downloadFailed &&
        !current.authenticationRequired &&
        current.notificationTicket == null &&
        notificationTicket != null;
    if (needsLabels || needsTicket) {
      await upsertDownload(current.copyWith(
        musicMetadata: current.musicMetadata ?? music,
        notificationTicket:
            needsTicket ? notificationTicket : current.notificationTicket,
      ));
    }
    return await makeMusicDownloadExplicit(expected.videoId) ||
        needsLabels ||
        needsTicket;
  }

  Future<void> saveDownloadExport(String videoId, ExportedMusicCopy copy,
      {DownloadedVideo? expectedSource}) async {
    final download = getDownloadByVideoId(videoId);
    if (download == null) {
      throw StateError('The original download is unavailable');
    }
    download.validateExportReceipt(copy, expectedSource: expectedSource);
    await upsertDownload(switch ((copy.editSignature, copy.complete)) {
      (null, _) => download.copyWith(exportedMusic: copy),
      (_, true) => download.copyWith(
          editedMusicExport: copy, pendingEditedMusicExport: null),
      (_, false) => download.copyWith(
          editedMusicExport: download.editedMusicExport?.complete == true
              ? download.editedMusicExport
              : null,
          pendingEditedMusicExport: copy),
    });
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

  /// Observes the groups owned by the profile selected at the call site.
  Stream<List<SubscriptionGroup>> watchSubscriptionGroups() =>
      Stream.value(const []);

  Future<void> saveSubscriptionGroup(SubscriptionGroup group) async =>
      throw UnsupportedError('Subscription groups require the app database');

  Future<void> deleteSubscriptionGroup(String id) async =>
      throw UnsupportedError('Subscription groups require the app database');
}
