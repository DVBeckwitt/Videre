import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/no_server_selected.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/video_post_processing.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/watch_history.dart';

/// Discovery was replaced by a profile, connection, or shelf change.
class RecommendationCandidatesCancelled implements Exception {
  const RecommendationCandidatesCancelled();
}

/// Small candidate pools from Videre's existing catalog and local library.
///
/// Ranking never grants authority to resolve a stream. Returned objects contain
/// display metadata only. Remote discovery is explicit and cannot refill itself
/// or fall back to an upstream service when Invidious fails.
/// Pass the active app database; this object captures a fixed profile view and
/// rejects work after the active database/profile is replaced.
class RecommendationCandidates {
  RecommendationCandidates(
    IDbClient database, {
    Service? api,
    MusicCatalogService? musicCatalog,
    bool Function()? isCurrent,
  })  : _source = database,
        _profileId = database.profileId,
        _database = database.forProfile(database.profileId),
        _api = api,
        _musicCatalog = musicCatalog,
        _isCurrent = isCurrent;

  final IDbClient _source;
  final IDbClient _database;
  final String _profileId;
  final Service? _api;
  final MusicCatalogService? _musicCatalog;
  final bool Function()? _isCurrent;
  final _videoSearches = <({String query, String region}),
      ({
    BackendPlayback route,
    Object proxy,
    DateTime expires,
    List<Video> videos
  })>{};
  final _onlineSubscriptionCreators = <String>{};

  Set<String> get onlineSubscriptionCreators =>
      Set.unmodifiable(_onlineSubscriptionCreators);

  void clearVideoDiscovery() {
    _videoSearches.clear();
    _onlineSubscriptionCreators.clear();
  }

  Future<bool> hasVideoDiscoverySubscriptions() async {
    if (!_current) return false;
    try {
      final server = await _database.getCurrentlySelectedServer();
      if (!_current) return false;
      if (hasHistoryAccount(server)) return true;
      final offline = await _database.getOfflineSubscriptions();
      return _current &&
          offline.any((channel) => _channelId.hasMatch(channel.channelId));
    } on Exception {
      return false;
    } on NoServerSelected {
      return false;
    } on UnsupportedError {
      return false;
    } on StateError {
      return false;
    }
  }

  static const maximumLocalCandidates = 80;
  static const maximumVideoDiscoveryCandidates = 40;
  static const maximumVideoDiscoveryQueries = 3;
  static const maximumMusicDiscoveryCandidates = 6;
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  bool get _current {
    try {
      return identical(globals.db, _source) &&
          _source.profileId == _profileId &&
          _database.profileId == _profileId &&
          _isCurrent?.call() != false &&
          !NetworkProxy.instance.isChanging;
    } on StateError {
      return false;
    }
  }

  void _check() {
    if (!_current) throw const RecommendationCandidatesCancelled();
  }

  /// Watched and locally saved videos are metadata, not fabricated events.
  /// Music history stays in the music pool even if the recording is a video.
  List<Video> localVideos({int limit = maximumLocalCandidates}) {
    if (!_current || limit <= 0) return const [];
    final maximum = limit.clamp(0, maximumLocalCandidates);
    try {
      final videos = <Video>[];
      try {
        videos.addAll(_database
            .getLocalHistory()
            .where((entry) => entry.musicMetadata == null)
            .map((entry) => entry.toVideo()));
      } on UnsupportedError {
        // A database without history can still supply saved playlists.
      }
      videos.addAll(_playlistVideos(music: false));
      return _videos(
        videos,
        limit: maximum,
      );
    } on StateError {
      return const [];
    }
  }

  /// Local songs need no catalog request. A bookmark is not a counted listen.
  List<MusicTrack> localMusic({
    int limit = maximumLocalCandidates,
    Set<String>? ids,
  }) {
    if (!_current || limit <= 0) return const [];
    final maximum = limit.clamp(0, maximumLocalCandidates);
    final videos = <Video>[];
    try {
      final library = MusicLibraryService.forProfile(_source, _profileId);
      videos.addAll(library.entries
          .where((entry) => entry.kind == MusicLibraryKind.song)
          .map((entry) => entry.toVideo()));
      try {
        videos.addAll(_database
            .getLocalHistory()
            .where((entry) => entry.musicMetadata != null)
            .map((entry) => entry.toVideo()));
      } on UnsupportedError {
        // A database without history can still supply saved songs.
      }
      videos.addAll(_playlistVideos(music: true));
      return _videos(
              ids == null
                  ? videos
                  : videos.where((video) => ids.contains(video.videoId)),
              limit: maximum,
              music: true)
          .map(_musicTrack)
          .toList(growable: false);
    } on StateError {
      return const [];
    }
  }

  /// Reads the existing profile-owned playlist store without resolving any
  /// recording. Only an explicit Music marker can classify untagged tracks.
  Iterable<Video> _playlistVideos({required bool music}) sync* {
    try {
      final markedMusic =
          MusicLibraryService.forProfile(_source, _profileId).localPlaylistIds;
      final playlists =
          (_api ?? globals.service).getLocalPlaylists(database: _database);
      for (final playlist in playlists) {
        if (!playlist.isLocal) continue;
        final marked = markedMusic.contains(playlist.playlistId);
        for (final video in playlist.videos) {
          final isMusic = marked || video.musicMetadata != null;
          if (isMusic == music) yield video;
        }
      }
    } on FormatException {
      // Malformed saved metadata cannot start a discovery request.
    } on TypeError {
      // Ignore a damaged playlist schema without changing the saved library.
    } on UnsupportedError {
      // Some database implementations have no local playlist store.
    }
  }

  /// Recent listening has its own pool so a large saved collection cannot hide
  /// the songs the person actually played. Ordering comes from local history.
  List<MusicTrack> listeningHistory({int limit = 12}) {
    if (!_current || limit <= 0) return const [];
    final maximum = limit.clamp(0, maximumLocalCandidates);
    try {
      final videos = _videos(
        _database
            .getLocalHistory()
            .where((entry) => entry.musicMetadata != null)
            .map((entry) => entry.toVideo()),
        limit: maximum,
        music: true,
      );
      if (videos.isEmpty) return const [];
      final savedCovers =
          MusicLibraryService.forProfile(_source, _profileId).coversBySongId;
      return videos
          .map((video) =>
              _musicTrack(video, savedCovers: savedCovers[video.videoId]))
          .toList(growable: false);
    } on UnsupportedError {
      return const [];
    } on StateError {
      return const [];
    }
  }

  /// Up to three explicit Flow-selected searches or one related-video lookup.
  /// Searches are sequential and only reused within the same admitted route.
  /// An empty profile without a query has no invented discovery seed.
  Future<List<Video>> discoverVideos(
      {String? query,
      List<String> queries = const [],
      Video? seed,
      bool includeSubscriptions = false,
      bool Function()? isCurrent}) async {
    _check();
    final cleanQueries = [if (query != null) query else ...queries]
        .map(_query)
        .where((query) => query.isNotEmpty)
        .toSet()
        .take(maximumVideoDiscoveryQueries)
        .toList();
    final selectedSeed = seed ??
        (includeSubscriptions ? null : localVideos(limit: 1).firstOrNull);
    if (!includeSubscriptions &&
        cleanQueries.isEmpty &&
        (selectedSeed == null || !_videoId.hasMatch(selectedSeed.videoId))) {
      return const [];
    }
    return _inSession((api, server, check) async {
      final candidates = <Video>[];
      final reserveSubscription = includeSubscriptions && query == null;
      final remaining =
          maximumVideoDiscoveryQueries - (reserveSubscription ? 1 : 0);
      if (cleanQueries.isNotEmpty) {
        final proxy = NetworkProxy.instance.config;
        final region = _database.getSettings(browsingCountry)?.value ?? 'US';
        final searches = cleanQueries.take(remaining).toList();
        final perSearch = (maximumVideoDiscoveryCandidates /
                (searches.length + (reserveSubscription ? 1 : 0)))
            .ceil();
        for (final cleanQuery in searches) {
          await check();
          final cacheKey = (query: cleanQuery, region: region);
          final cached = _videoSearches[cacheKey];
          final now = DateTime.now();
          if (cached != null &&
              cached.expires.isAfter(now) &&
              identical(cached.proxy, proxy) &&
              cached.route.matches(server)) {
            candidates.addAll(cached.videos.take(perSearch));
            continue;
          }
          final results = await api.getVideoRecommendationCandidates(
              query: cleanQuery, server: server, beforeRequest: check);
          await check();
          final videos =
              _videos(results, limit: maximumVideoDiscoveryCandidates);
          candidates.addAll(videos.take(perSearch));
          _videoSearches.remove(cacheKey);
          _videoSearches[cacheKey] = (
            route: BackendPlayback(server),
            proxy: proxy,
            expires: now.add(const Duration(minutes: 5)),
            videos: videos,
          );
          if (_videoSearches.length > 12) {
            _videoSearches.remove(_videoSearches.keys.first);
          }
        }
      } else if (selectedSeed != null &&
          _videoId.hasMatch(selectedSeed.videoId)) {
        final metadata = await api.getDiscoveryVideoMetadata(
          selectedSeed.videoId,
          serverOverride: server,
          isCurrent: () => _current && isCurrent?.call() != false,
        );
        if (metadata.videoId != selectedSeed.videoId) {
          throw const FormatException('Unexpected discovery recording.');
        }
        candidates.addAll(metadata.recommendedVideos
            .take(reserveSubscription ? 20 : maximumVideoDiscoveryCandidates));
      }
      if (reserveSubscription) {
        try {
          if (hasHistoryAccount(server)) {
            await check();
            final feed = await api.getVideoRecommendationCandidates(
                server: server, beforeRequest: check);
            await check();
            final videos = _videos(feed, limit: 20);
            _onlineSubscriptionCreators
              ..clear()
              ..addAll(
                  videos.map((video) => video.authorId).whereType<String>());
            candidates.addAll(videos);
          } else {
            final followed = (await _database.getOfflineSubscriptions())
                .where((channel) => _channelId.hasMatch(channel.channelId))
                .firstOrNull;
            await check();
            if (followed != null) {
              final uploads = await api.getVideoRecommendationCandidates(
                  channelId: followed.channelId,
                  server: server,
                  beforeRequest: check);
              await check();
              candidates.addAll(uploads);
            }
          }
        } on RecommendationCandidatesCancelled {
          rethrow;
        } on Exception {
          if (candidates.isEmpty) rethrow;
          // An unavailable optional feed does not discard usable search results.
        }
      }
      await check();
      return _videos(candidates,
          limit: maximumVideoDiscoveryCandidates,
          excludedId: cleanQueries.isEmpty ? selectedSeed?.videoId : null);
    }, isCurrent: isCurrent);
  }

  /// Reuses the production catalog's eight-inspection/six-result music budget,
  /// category validation, route-specific concurrency, cooldowns and filtering.
  Future<List<MusicTrack>> discoverMusic({String? artist}) async {
    _check();
    return _inSession((_, __, check) async {
      final tracks = await (_musicCatalog ?? musicCatalogService)
          .getDiscoverySongs(artist: _query(artist), isCurrent: () => _current);
      await check();
      return _videos(tracks.map((track) => track.toVideo()),
              limit: maximumMusicDiscoveryCandidates, music: true)
          .map(_musicTrack)
          .toList(growable: false);
    });
  }

  Future<T> _inSession<T>(
    Future<T> Function(Service, Server, Future<void> Function()) load, {
    bool Function()? isCurrent,
  }) async {
    void checkRequest() {
      _check();
      if (isCurrent?.call() == false) {
        throw const RecommendationCandidatesCancelled();
      }
    }

    checkRequest();
    final proxy = NetworkProxy.instance.config;
    final region = _database.getSettings(browsingCountry)?.value;
    final api = _api ?? globals.service;
    final server = await api.preparePlaybackServer();
    checkRequest();
    if (server.profileId != _profileId ||
        !identical(proxy, NetworkProxy.instance.config)) {
      throw const RecommendationCandidatesCancelled();
    }
    final route = BackendPlayback(server);
    Future<void> check() async {
      checkRequest();
      final selected = await _database.getCurrentlySelectedServer();
      checkRequest();
      if (!identical(proxy, NetworkProxy.instance.config) ||
          _database.getSettings(browsingCountry)?.value != region ||
          !route.matches(selected)) {
        throw const RecommendationCandidatesCancelled();
      }
    }

    await check();
    final result = await load(api, server, check);
    await check();
    return result;
  }

  List<Video> _videos(Iterable<Video> candidates,
      {required int limit, bool music = false, String? excludedId}) {
    if (limit <= 0) return const [];
    final filters = _database.getAllFilters();
    final ids = <String>{if (excludedId != null) excludedId};
    final results = <Video>[];
    for (final video in candidates) {
      if (!_videoId.hasMatch(video.videoId) ||
          video.title?.trim().isNotEmpty != true ||
          video.title == privateVideoString ||
          video.filtered ||
          video.filterHide ||
          video.isUpcoming == true ||
          filters.any((filter) => filter.filterVideo(video)) ||
          communityFilters
              .match(
                  authorId: video.authorId,
                  authorUrl: video.authorUrl,
                  music: music)
              .any((match) => match.action == CommunityAction.hide) ||
          !ids.add(video.videoId)) {
        continue;
      }
      results.add(_displayVideo(video));
      if (results.length == limit) break;
    }
    return List.unmodifiable(results);
  }

  static String _query(String? value) => String.fromCharCodes((value ?? '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .trim()
      .runes
      .take(120));

  static final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');

  static Video _displayVideo(Video video) => Video(
        videoId: video.videoId,
        title: video.title,
        author: video.author,
        authorId: video.authorId,
        authorUrl: video.authorUrl,
        lengthSeconds: video.lengthSeconds,
        published: video.published,
        publishedText: video.publishedText,
        viewCount: video.viewCount,
        viewCountText: video.viewCountText,
        likeCount: video.likeCount,
        description: video.description,
        keywords: video.keywords,
        genre: video.genre,
        liveNow: video.liveNow,
        videoThumbnails: video.videoThumbnails,
        authorThumbnails: video.authorThumbnails,
        musicMetadata: video.musicMetadata,
      );

  static MusicTrack _musicTrack(Video video, {List<ImageObject>? savedCovers}) {
    final metadata = video.musicMetadata;
    final artist = metadata?.artist ?? video.author ?? '';
    final credits = metadata?.artistCredits ??
        [
          if (MusicArtistCredit.forAuthor(
                  video.author, video.authorId, video.authorUrl)
              case final credit?)
            credit,
        ];
    final covers = songCovers(metadata?.thumbnails ?? const []);
    return MusicTrack(
      videoId: video.videoId,
      title: metadata?.title ?? video.title ?? video.videoId,
      artists: [if (artist.isNotEmpty) artist],
      artistCredits: credits,
      uploaderChannelId: video.authorId,
      uploaderChannelUrl: video.authorUrl,
      albumTitle: metadata?.album,
      durationSeconds: video.lengthSeconds,
      isArtTrack: metadata?.isArtTrack ?? false,
      thumbnails: savedCovers ?? covers,
      videoThumbnails: video.videoThumbnails,
    );
  }
}
