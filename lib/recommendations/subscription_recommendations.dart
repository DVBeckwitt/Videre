import 'dart:convert';

import '../content_filter/community_filter.dart';
import '../globals.dart' as globals;
import '../music/models/music_library_entry.dart';
import '../music/models/music_track.dart';
import '../music/services/music_catalog_service.dart';
import '../music/services/music_library_service.dart';
import '../network/network_proxy.dart';
import '../player/models/backend_playback.dart';
import '../service.dart';
import '../settings/models/db/server.dart';
import '../settings/models/db/video_filter.dart';
import '../settings/models/errors/invidious_service_error.dart';
import '../settings/models/errors/no_server_selected.dart';
import '../utils/interfaces/db.dart';
import '../utils/video_post_processing.dart';
import '../videos/models/video.dart';
import '../videos/services/watch_history.dart';
import 'subscription_revision.dart';

const _maximumChannels = 200;
const _cacheAge = Duration(minutes: 5);
final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

typedef SubscriptionRecommendationBatch = ({
  Map<String, String> channels,
  List<Video> videos,
  List<MusicTrack> music,
});

/// The visible recommendation surface owns this short request. Followed-channel
/// evidence is a reversible input, never appended to playback or like history.
class SubscriptionRecommendationSource {
  SubscriptionRecommendationSource(IDbClient database,
      {Service? api, MusicCatalogService? catalog, DateTime Function()? clock})
      : _owner = database,
        _database = database.forProfile(database.profileId),
        _api = api,
        _catalog = catalog,
        _clock = clock ?? DateTime.now;

  final IDbClient _owner;
  final IDbClient _database;
  final Service? _api;
  final MusicCatalogService? _catalog;
  final DateTime Function() _clock;

  static final _credentialChanges = <String, int>{};

  /// Retire signed-in evidence while a stable account ID can change identity.
  static Future<T> duringAccountChange<T>(
      IDbClient database, Future<T> Function() change) async {
    final profile = database.profileId;
    _credentialChanges.update(profile, (count) => count + 1, ifAbsent: () => 1);
    try {
      await invalidateStoredSubscriptionRecommendations(database);
      return await change();
    } finally {
      final pending = _credentialChanges[profile]! - 1;
      if (pending == 0) {
        _credentialChanges.remove(profile);
      } else {
        _credentialChanges[profile] = pending;
      }
      recommendationSubscriptionRevision.value++;
    }
  }

  Stream<SubscriptionRecommendationBatch> warm({
    required Server? server,
    required bool Function() isCurrent,
    bool music = false,
    bool forceRefresh = false,
    List<MusicTrack> localMusic = const [],
  }) async* {
    final profileId = _database.profileId;
    final revision = recommendationSubscriptionRevision.value;
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        isCurrent() &&
        _owner.profileId == profileId &&
        revision == recommendationSubscriptionRevision.value &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config);
    if (!current()) return;

    final local = <String, String>{};
    try {
      final follows = await _database.getOfflineSubscriptions();
      for (final channel in follows) {
        _add(local, channel.channelId, channel.channelName);
        if (local.length >= _maximumChannels) break;
      }
    } on UnsupportedError {
      // Some storage adapters have no local subscriptions.
    }
    if (!current()) return;
    final admitted = server != null &&
            server.profileId == profileId &&
            !_credentialChanges.containsKey(profileId)
        ? server
        : null;
    final route = admitted == null ? null : BackendPlayback(admitted);
    Future<void> check() async {
      if (!current() || route == null) throw const _SubscriptionReadCancelled();
      final selected = await _database.getCurrentlySelectedServer();
      if (!current() || !route.matchesConnection(selected)) {
        throw const _SubscriptionReadCancelled();
      }
    }

    final followed = {...local};
    final knownMusic = <String>{
      if (music) ..._musicCreators(localMusic),
    };
    Map<String, String> channels() => {
          for (final entry in followed.entries.take(_maximumChannels))
            if ((!music || knownMusic.contains(entry.key)) &&
                _allowed(entry.key, entry.value, music: music))
              entry.key: entry.value,
        };
    SubscriptionRecommendationBatch batch(
            {List<Video> videos = const [],
            List<MusicTrack> tracks = const []}) =>
        (channels: channels(), videos: videos, music: tracks);

    final online = admitted != null && hasHistoryAccount(admitted);
    Map<String, String>? cached;
    if (online && !forceRefresh) {
      try {
        await check();
        cached = _readCache(admitted);
        followed.addAll(cached ?? const {});
      } on _SubscriptionReadCancelled {
        return;
      } on NoServerSelected {
        // Local follows are still meaningful with no selected server.
      }
    }
    if (!current()) return;
    final initial = channels();
    if (initial.isNotEmpty) yield batch();
    if (!current() || admitted == null || (!online && local.isEmpty)) return;

    final api = _api ?? globals.service;
    try {
      await check();
      if (online && cached == null) {
        final subscriptions = await api.getRecommendationSubscriptions(
            server: admitted, beforeRequest: check);
        await check();
        final fetched = <String, String>{};
        for (final subscription in subscriptions) {
          _add(fetched, subscription.authorId, subscription.author);
          if (fetched.length >= _maximumChannels) break;
        }
        followed.addAll(fetched);
        if (!current()) return;
        await _writeCache(admitted, fetched);
        await check();
        if (!_sameChannels(initial, channels())) yield batch();
      }

      // One signed-in feed page and at most two local uploads, with a lower
      // limit when an account feed already ran. No generic discovery here.
      final eligibleFollows = {
        for (final entry in followed.entries.take(_maximumChannels))
          if (_allowed(entry.key, entry.value, music: music)) entry.key,
      };
      if (eligibleFollows.isEmpty) return;
      final videos = <Video>[
        if (online)
          ...await api.getVideoRecommendationCandidates(
              server: admitted, beforeRequest: check),
      ];
      final represented = videos.map((video) => video.authorId).toSet();
      for (final channel in local.keys
          .where(
              (id) => eligibleFollows.contains(id) && !represented.contains(id))
          .take(online ? 1 : 2)) {
        await check();
        final uploads = await api.getVideoRecommendationCandidates(
            channelId: channel, server: admitted, beforeRequest: check);
        videos.addAll(
            uploads.where((video) => video.authorId == channel).take(8));
      }
      await check();
      final filters = _database.getAllFilters();
      final seen = <String>{};
      final candidates = videos
          .where((video) =>
              eligibleFollows.contains(video.authorId) &&
              _videoId.hasMatch(video.videoId) &&
              video.title?.trim().isNotEmpty == true &&
              video.title != privateVideoString &&
              !video.filtered &&
              !video.filterHide &&
              video.isUpcoming != true &&
              (!music || video.liveNow != true) &&
              !filters.any((filter) => filter.filterVideo(video)) &&
              seen.add(video.videoId))
          .take(24)
          .toList(growable: false);
      if (!music) {
        if (candidates.isNotEmpty) yield batch(videos: candidates);
        return;
      }

      // Invidious's lightweight feed does not prove Music category. The
      // existing discovery verifier owns the small metadata read budget.
      final knownUploads = {
        for (final video in candidates) video.videoId: video.authorId
      };
      final verified = await (_catalog ?? musicCatalogService)
          .getSubscriptionSongs(candidates,
              expectedServer: admitted, isCurrent: current);
      await check();
      final tracks = verified
          .where((track) =>
              track.uploaderChannelId != null &&
              track.uploaderChannelId == knownUploads[track.videoId])
          .take(6)
          .toList();
      knownMusic.addAll(
          tracks.map((track) => track.uploaderChannelId).whereType<String>());
      if (tracks.isNotEmpty) yield batch(tracks: tracks);
    } on _SubscriptionReadCancelled {
      return;
    } on NoServerSelected {
      return;
    } on InvidiousServiceError {
      // An unavailable account feed must leave local follows usable.
      return;
    } on Exception {
      // Optional catalog enrichment cannot hide already emitted local seeds.
      return;
    } on StateError {
      return;
    }
  }

  Set<String> _musicCreators(List<MusicTrack> tracks) => {
        for (final entry
            in MusicLibraryService.forProfile(_owner, _database.profileId)
                .entries)
          if (entry.kind == MusicLibraryKind.artist &&
              _channelId.hasMatch(entry.id))
            entry.id,
        for (final track in tracks)
          if (track.uploaderChannelId case final id?
              when _channelId.hasMatch(id))
            id,
      };

  bool _allowed(String id, String name, {required bool music}) {
    final channel = Video(videoId: '', authorId: id, author: name);
    return !_database.getAllFilters().any((filter) =>
            (filter.type == FilterType.channelName ||
                filter.filterAll == true) &&
            filter.filterVideo(channel)) &&
        !communityFilters
            .match(authorId: id, music: music)
            .any((match) => match.action == CommunityAction.hide);
  }

  Map<String, String>? _readCache(Server server) {
    final text =
        _database.getSettings(subscriptionRecommendationCacheSetting)?.value;
    if (text == null || text.length > 160000) return null;
    try {
      final data = jsonDecode(text);
      final now = _clock().millisecondsSinceEpoch;
      if (data is! Map ||
          data['account'] != server.accountId ||
          data['origin'] != Uri.parse(server.url).origin ||
          data['at'] is! int ||
          data['channels'] is! Map) {
        return null;
      }
      final age = now - (data['at'] as int);
      if (age < 0 || age >= _cacheAge.inMilliseconds) return null;
      return <String, String>{}..addEntries((data['channels'] as Map)
          .entries
          .take(_maximumChannels)
          .where((row) =>
              row.key is String &&
              row.value is String &&
              _channelId.hasMatch(row.key as String) &&
              (row.value as String).length <= 320)
          .map((row) => MapEntry(row.key as String, row.value as String)));
    } on FormatException {
      return null;
    } on StateError {
      return null;
    }
  }

  Future<void> _writeCache(Server server, Map<String, String> channels) async {
    try {
      await writeSubscriptionRecommendationCache(
          _database,
          jsonEncode({
            'account': server.accountId,
            'origin': Uri.parse(server.url).origin,
            'at': _clock().millisecondsSinceEpoch,
            'channels': channels,
          }));
    } on Object {
      // A storage failure cannot hide this session's successfully read follows.
    }
  }

  static void _add(Map<String, String> channels, String id, String name) {
    if (_channelId.hasMatch(id)) {
      channels.putIfAbsent(
          id, () => String.fromCharCodes(name.trim().runes.take(150)));
    }
  }

  static bool _sameChannels(Map<String, String> lhs, Map<String, String> rhs) =>
      lhs.length == rhs.length &&
      lhs.entries.every((entry) => rhs[entry.key] == entry.value);
}

class _SubscriptionReadCancelled implements Exception {
  const _SubscriptionReadCancelled();
}
