import 'dart:convert';

import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/music_charts.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_video_match.dart';
import 'package:clipious/music/services/music_video_source.dart';
import 'package:clipious/network/content_link.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/video_post_processing.dart'
    show privateVideoString;
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';

/// Music browsing through the selected Invidious instance's standard API.
/// Unsupported YouTube Music feeds never fall back to Google's catalog.
class InvidiousMusicCatalogService extends MusicCatalogService {
  final Service? _service;
  final DateTime Function() _now;
  ({
    Object owner,
    BackendPlayback route,
    DateTime until
  })? _artistReleaseCooldown;

  InvidiousMusicCatalogService({Service? api, DateTime Function()? now})
      : _service = api,
        _now = now ?? DateTime.now;

  static final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final _channelId = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
  static final _playlistId = RegExp(r'^(PL|OLAK5uy_|RD)[a-zA-Z0-9_-]+$');

  static const _discoveryCandidateLimit = 8;
  static const _discoverySongLimit = 6;

  Future<T> _inSession<T>(
      Future<T> Function(Service, Server, Future<void> Function()) load) async {
    final owner = db;
    final profileId = owner.profileId;
    final proxy = NetworkProxy.instance.config;
    final api = _service ?? service;
    final server = await api.preparePlaybackServer();
    final route = BackendPlayback(server);
    bool current() =>
        identical(owner, db) &&
        owner.profileId == profileId &&
        !NetworkProxy.instance.isChanging &&
        identical(NetworkProxy.instance.config, proxy);
    Future<void> check() async {
      if (!current()) {
        throw const MusicCatalogException(
            'The music connection changed. Retry the request.');
      }
      final selected = await owner.getCurrentlySelectedServer();
      if (!current() || !route.matchesConnection(selected)) {
        throw const MusicCatalogException(
            'The music connection changed. Retry the request.');
      }
    }

    await check();
    final value = await load(api, server, check);
    await check();
    return value;
  }

  Map<String, List<ImageObject>> _savedCovers(Server server) =>
      MusicLibraryService.forProfile(db, server.profileId).coversBySongId;

  List<ImageObject> _playlistPreview(List<Video> videos, Server server) {
    final first = videos.firstOrNull;
    return first == null
        ? const []
        : stockSongThumbnails(first.videoId, first.videoThumbnails,
            instanceUrl: server.url);
  }

  MusicTrack _track(
      Video video, Map<String, List<ImageObject>> savedCovers, Server server,
      {Video? playbackVideo,
      String? albumPlaylistId,
      String? albumTitle,
      bool playlistEntry = false}) {
    if (!_videoId.hasMatch(video.videoId) ||
        video.title == null ||
        video.title!.trim().isEmpty) {
      throw const MusicCatalogException(
          'The server returned an invalid music track.');
    }
    final author = video.author;
    final uploaderId = normalizeChannelId(video.authorId) ??
        normalizeChannelId(video.authorUrl) ??
        channelIdFromAuthorUrl(video.authorUrl);
    final uploaderHandle = channelHandleFromAuthorUrl(video.authorUrl);
    return MusicTrack(
      videoId: video.videoId,
      title: video.title!,
      artists: author == null || author.isEmpty ? [] : [author],
      artistLinks: [
        if (author != null && author.trim().isNotEmpty && uploaderId != null)
          MusicArtist(id: uploaderId, name: author),
      ],
      artistCredits: video.stockArtTrackCredits,
      uploaderName: author,
      uploaderChannelId: uploaderId,
      uploaderChannelUrl: uploaderHandle == null
          ? null
          : Uri(pathSegments: ['', '@$uploaderHandle']).toString(),
      durationSeconds: video.lengthSeconds,
      playlistIndex: playlistEntry ? video.index : null,
      playlistIndexId: playlistEntry ? video.indexId : null,
      albumPlaylistId: albumPlaylistId,
      albumTitle: albumTitle ?? video.stockArtTrackAlbum,
      thumbnails: savedCovers[video.videoId] ?? const [],
      videoThumbnails: stockSongThumbnails(video.videoId, video.videoThumbnails,
          instanceUrl: server.url),
      isArtTrack: video.isStockArtTrack,
      playbackVideo: playbackVideo,
    );
  }

  @override
  Future<List<String>> searchSuggestions(String query,
      {bool Function()? isCurrent}) async {
    final text = query.trim();
    if (text.isEmpty || ContentLink.completeWebAddress(text) != null) {
      return const [];
    }
    _requireCurrentDiscovery(isCurrent);
    final suggestions = await _inSession((api, server, checkSession) async {
      final result = await api.getMusicSearchSuggestion(text,
          server: server,
          beforeRequest: () => _checkDiscovery(checkSession, isCurrent));
      if (result.query != text) return const <String>[];

      final seen = <String>{};
      return [
        for (final suggestion in result.suggestions.map((item) => item.trim()))
          if (suggestion.isNotEmpty &&
              ContentLink.completeWebAddress(suggestion) == null &&
              seen.add(suggestion.toLowerCase()))
            suggestion,
      ];
    });
    _requireCurrentDiscovery(isCurrent);
    return suggestions;
  }

  @override
  Future<List<MusicTrack>> searchSongs(String query) async {
    if (query.trim().isEmpty) return [];
    return _inSession((api, server, check) async {
      final covers = _savedCovers(server);
      final results =
          await api.searchMusic(query.trim(), SearchType.video, server, check);
      return [
        for (final video in results.videos) _track(video, covers, server)
      ];
    });
  }

  @override
  Future<List<MusicArtist>> searchArtists(String query) async {
    if (query.trim().isEmpty) return [];
    return _inSession((api, server, check) async =>
        (await api.searchMusic(query.trim(), SearchType.channel, server, check))
            .channels
            .map(_searchArtist)
            .toList());
  }

  @override
  Future<List<MusicPlaylist>> searchPlaylists(String query) async {
    if (query.trim().isEmpty) return [];
    return _inSession((api, server, check) async => (await api.searchMusic(
            query.trim(), SearchType.playlist, server, check))
        .playlists
        .map((playlist) => _searchPlaylist(playlist, server))
        .toList());
  }

  static MusicArtist _searchArtist(Channel channel) => MusicArtist(
        id: channel.authorId,
        name: channel.author,
        thumbnails: channel.authorThumbnails,
      );

  MusicPlaylist _searchPlaylist(Playlist playlist, Server server,
          {String? id}) =>
      MusicPlaylist(
        id: id ?? playlist.playlistId,
        title: playlist.title,
        author: playlist.author,
        thumbnails: _playlistPreview(playlist.videos, server),
      );

  @override
  Future<List<MusicPlaylist>> findPlaylistsWithSongsInCommon(
      String playlistId, List<String> savedPlaylistIds,
      {required bool Function() isCurrent}) async {
    if (!isCurrent() || !isMusicPlaylistOverlapCandidate(playlistId)) {
      return const [];
    }
    final candidates = savedPlaylistIds
        .where((id) => id != playlistId && isMusicPlaylistOverlapCandidate(id))
        .toSet()
        .take(musicPlaylistOverlapCandidateLimit);
    if (candidates.isEmpty) return const [];

    return _inSession((api, server, checkSession) async {
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);
      Future<Playlist?> publicPage(String id) async {
        // A successful lookup can also resolve unlisted playlists. Require
        // explicit public visibility before using any membership or artwork.
        final page = await api.getMusicPlaylistPage(id, 1, server, check);
        await check();
        return page.playlistId == id &&
                page.type != invidiousPlaylist &&
                page.isListed == true &&
                page.videoCount > 0 &&
                page.title.trim().isNotEmpty
            ? page
            : null;
      }

      Iterable<Video> visibleTracks(Playlist page) =>
          page.videos.where((video) =>
              _videoId.stringMatch(video.videoId) == video.videoId &&
              video.title?.trim().isNotEmpty == true &&
              musicVideoAllowed(video));

      final source = await publicPage(playlistId);
      if (source == null) return const <MusicPlaylist>[];
      final sourceIds =
          visibleTracks(source).map((video) => video.videoId).toSet();
      if (sourceIds.isEmpty) return const <MusicPlaylist>[];

      final matches = <({MusicPlaylist playlist, int shared, int position})>[];
      // Bounded first-page reads keep the shelf independent of normal
      // playlist loading. Each match still proves actual track membership.
      for (final (position, id) in candidates.indexed) {
        try {
          final page = await publicPage(id);
          if (page == null) continue;
          final tracks = visibleTracks(page).toList();
          final shared = tracks
              .map((video) => video.videoId)
              .where(sourceIds.contains)
              .toSet()
              .length;
          if (shared > 0) {
            matches.add((
              playlist: _searchPlaylist(page.copyWith(videos: tracks), server),
              shared: shared,
              position: position,
            ));
          }
        } on InvidiousServiceError catch (error) {
          await check();
          if (musicDiscoveryMustStop(error)) break;
        } on FormatException {
          await check();
        } on TypeError {
          await check();
        }
      }
      matches.sort((a, b) {
        final shared = b.shared.compareTo(a.shared);
        return shared != 0 ? shared : a.position.compareTo(b.position);
      });
      await check();
      return [for (final match in matches) match.playlist];
    });
  }

  @override
  Future<MusicCatalogSearchPage> searchPage(
    String query,
    MusicCatalogSearchType type,
    int page, {
    bool Function()? isCurrent,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    _requireCurrentDiscovery(isCurrent);
    final text = query.trim();
    if (text.isEmpty) {
      return const MusicCatalogSearchPage(hits: [], rawKeys: []);
    }
    final searchType = switch (type) {
      MusicCatalogSearchType.all => SearchType.all,
      MusicCatalogSearchType.songs => SearchType.video,
      MusicCatalogSearchType.channels => SearchType.channel,
      MusicCatalogSearchType.playlists => SearchType.playlist,
    };
    return _inSession((api, server, checkSession) async {
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);
      final rows = await api.searchMusicPage(text, searchType, page,
          server: server, beforeRequest: check);
      await check();
      final hits = <String, MusicCatalogSearchHit>{};
      final rawKeys = <String>[];
      final covers = _savedCovers(server);
      for (final row in rows) {
        if (row is! Map<String, Object?>) continue;
        final identity = _searchIdentity(row);
        if (identity == null) continue;
        final (kind, id) = identity;
        final key = MusicCatalogSearchHit.keyFor(kind, id);
        rawKeys.add(key);
        if (hits.containsKey(key) ||
            (type != MusicCatalogSearchType.all && type != kind)) {
          continue;
        }
        try {
          switch (kind) {
            case MusicCatalogSearchType.songs:
              final video = Video.fromJson(row);
              if (video.title?.trim().isNotEmpty == true &&
                  video.title != privateVideoString) {
                hits[key] = MusicCatalogSongHit(_track(video, covers, server));
              }
            case MusicCatalogSearchType.channels:
              final channel = Channel.fromJson(row);
              if (channel.author.trim().isNotEmpty) {
                hits[key] = MusicCatalogChannelHit(_searchArtist(channel));
              }
            case MusicCatalogSearchType.playlists:
              final playlist = Playlist.fromJson(row);
              if (playlist.title.trim().isNotEmpty) {
                hits[key] = MusicCatalogPlaylistHit(
                    _searchPlaylist(playlist, server, id: id));
              }
            case MusicCatalogSearchType.all:
              break;
          }
        } on TypeError {
          // An isolated malformed row cannot hide the rest of the wire page.
          continue;
        } on FormatException {
          continue;
        }
      }
      await check();
      return MusicCatalogSearchPage(
          hits: hits.values.toList(), rawKeys: rawKeys, rawCount: rows.length);
    });
  }

  static (MusicCatalogSearchType, String)? _searchIdentity(
      Map<String, Object?> row) {
    switch (row) {
      case {'type': 'video', 'videoId': final String id}
          when _videoId.hasMatch(id):
        return (MusicCatalogSearchType.songs, id);
      case {'type': 'channel', 'authorId': final String id}
          when _channelId.hasMatch(id):
        return (MusicCatalogSearchType.channels, id);
      case {'type': 'playlist', 'playlistId': final String rawId}:
        final id = rawId.startsWith('VL') ? rawId.substring(2) : rawId;
        return _playlistId.hasMatch(id)
            ? (MusicCatalogSearchType.playlists, id)
            : null;
      default:
        return null;
    }
  }

  // Do not override getTrendingSongs. Invidious's trending endpoint can ignore
  // type=Music and return general livestreams. The inherited unsupported result
  // keeps unrelated videos out of Music without another catalog or fallback.

  @override
  Future<List<MusicTrack>> getDiscoverySongs(
      {String? artist,
      bool Function()? isCurrent,
      void Function(InvidiousServiceError)? onInstanceFailure}) {
    final artistName =
        String.fromCharCodes((artist ?? '').trim().runes.take(120));
    return _verifiedSongSearch(
        artistName.isEmpty
            ? 'official music video'
            : '$artistName official music video',
        candidateLimit: _discoveryCandidateLimit,
        skipSavedSongs: artistName.isNotEmpty,
        onInstanceFailure: onInstanceFailure,
        isCurrent: isCurrent);
  }

  @override
  Future<List<MusicTrack>> getGenreSongs(String genre,
      {bool Function()? isCurrent,
      void Function(InvidiousServiceError)? onInstanceFailure}) async {
    if (!musicExploreGenres.contains(genre)) return const [];
    return _verifiedSongSearch('$genre music',
        candidateLimit: 4,
        onInstanceFailure: onInstanceFailure ?? (failure) => throw failure,
        isCurrent: isCurrent);
  }

  Future<List<MusicTrack>> _verifiedSongSearch(String query,
      {required int candidateLimit,
      bool skipSavedSongs = false,
      void Function(InvidiousServiceError)? onInstanceFailure,
      bool Function()? isCurrent}) async {
    _requireCurrentDiscovery(isCurrent);
    return _inSession((api, server, checkSession) async {
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);

      await check();
      final search =
          await api.searchMusic(query, SearchType.video, server, check);
      await check();
      final candidates = <String>[];
      final seen = <String>{
        if (skipSavedSongs)
          for (final entry
              in MusicLibraryService.forProfile(db, server.profileId).entries)
            if (entry.kind == MusicLibraryKind.song) entry.id,
      };
      for (final video in search.videos) {
        if (!video.filtered &&
            _videoId.hasMatch(video.videoId) &&
            seen.add(video.videoId)) {
          candidates.add(video.videoId);
          if (candidates.length == candidateLimit) break;
        }
      }
      return _inspectDiscoverySongs(api, server, candidates, check, isCurrent,
          onInstanceFailure: onInstanceFailure);
    });
  }

  @override
  Future<List<MusicTrack>> getRelatedSongs(Iterable<String> seedIds,
      {bool Function()? isCurrent}) async {
    final seeds = <String>{};
    for (final id in seedIds) {
      if (_videoId.hasMatch(id)) seeds.add(id);
      if (seeds.length == 3) break;
    }
    if (seeds.isEmpty) return const [];
    _requireCurrentDiscovery(isCurrent);
    return _inSession((api, server, checkSession) async {
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);
      final lanes = <List<String>>[];
      var seedFailures = 0;
      for (final seed in seeds) {
        await check();
        try {
          final video = await _discoveryVideo(api, server, seed, isCurrent);
          lanes.add(_relatedLane(video, excluding: seeds));
        } catch (error) {
          await check();
          if (musicDiscoveryMustStop(error)) {
            rethrow;
          }
          seedFailures++;
        }
        await check();
      }

      return _inspectDiscoverySongs(
          api, server, _interleaveDiscoveryLanes(lanes), check, isCurrent,
          seedFailures: seedFailures);
    });
  }

  @override
  Future<List<MusicTrack>> getArtistMixSongs(Iterable<String> artistIds,
      {bool Function()? isCurrent}) async {
    final seeds = <String>{};
    for (final artistId in artistIds) {
      final id = normalizeChannelId(artistId);
      if (id != null) seeds.add(id);
      if (seeds.length == MusicCatalogService.artistMixSeedLimit) break;
    }
    if (seeds.isEmpty) return const [];
    _requireCurrentDiscovery(isCurrent);
    return _inSession((api, server, checkSession) async {
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);
      final lanes = <List<String>>[];
      final expectedAuthors = <String, Set<String>>{};
      for (final id in seeds) {
        await check();
        try {
          final channel = await api.getMusicChannel(id, server, check);
          await check();
          if (channel.authorId != id) continue;
          final uploads = await api.getMusicChannelVideos(id, server, check);
          await check();
          final lane = {
            for (final row in uploads.videos)
              if (_videoId.hasMatch(row.videoId) &&
                  !row.filtered &&
                  !row.filterHide &&
                  (row.authorId == null || row.authorId == id))
                row.videoId,
          }.take(_discoveryCandidateLimit).toList();
          lanes.add(lane);
          for (final videoId in lane) {
            (expectedAuthors[videoId] ??= {}).add(id);
          }
        } catch (error) {
          await check();
          if (musicDiscoveryMustStop(error)) rethrow;
        }
      }

      final anchors = <String, Video>{};
      var instanceRejected = false;
      final directIds = _interleaveDiscoveryLanes(lanes);
      final direct = await _inspectDiscoverySongs(
          api, server, directIds, check, isCurrent,
          accept: (video) =>
              expectedAuthors[video.videoId]?.contains(video.authorId) == true,
          onInstanceFailure: (_) => instanceRejected = true,
          onVerified: (video) {
            if (video.authorId case final id?) {
              anchors.putIfAbsent(id, () => video);
            }
          });
      if (direct.isEmpty || instanceRejected) return direct;

      // Keep one related lane per verified artist. Seed tracks win duplicate
      // IDs, and a failure in related lookup leaves the verified tracks usable.
      final seen = directIds.toSet();
      final relatedIds = _interleaveDiscoveryLanes([
        for (final id in seeds)
          if (anchors[id] case final video?)
            _relatedLane(video, excluding: seen),
      ]);
      try {
        final related = await _inspectDiscoverySongs(
            api, server, relatedIds, check, isCurrent,
            accept: (video) =>
                !seeds.contains(video.authorId) ||
                anchors.containsKey(video.authorId),
            onInstanceFailure: (_) {});
        return [...direct, ...related];
      } catch (_) {
        await check();
        return direct;
      }
    });
  }

  static List<String> _relatedLane(Video video,
          {required Set<String> excluding}) =>
      {
        for (final related in video.recommendedVideos)
          if (_videoId.hasMatch(related.videoId) &&
              !excluding.contains(related.videoId) &&
              !related.filtered &&
              !related.filterHide)
            related.videoId,
      }.take(_discoveryCandidateLimit).toList();

  /// Walk each seed's bounded lane in selection order. Only the first
  /// occurrence of a video ID consumes a lookup.
  static List<String> _interleaveDiscoveryLanes(List<List<String>> lanes) {
    final candidates = <String>{};
    for (var index = 0; index < _discoveryCandidateLimit; index++) {
      for (final lane in lanes) {
        if (index < lane.length) candidates.add(lane[index]);
      }
    }
    return candidates.take(_discoveryCandidateLimit).toList();
  }

  static void _requireCurrentDiscovery(bool Function()? isCurrent) {
    if (isCurrent?.call() == false) {
      throw const MusicCatalogException('The music request was cancelled.');
    }
  }

  static Future<void> _checkDiscovery(
      Future<void> Function() checkSession, bool Function()? isCurrent) async {
    _requireCurrentDiscovery(isCurrent);
    await checkSession();
    _requireCurrentDiscovery(isCurrent);
  }

  static bool _discoveryCooldown(Object error) =>
      error is InvidiousServiceError &&
      (error.isRateLimited ||
          error.retryAfterIsInvalid ||
          (error.retryAfter ?? Duration.zero) > Duration.zero);

  static Future<Video> _discoveryVideo(
      Service api, Server server, String id, bool Function()? isCurrent) async {
    final video = await api.getDiscoveryVideoMetadata(id,
        serverOverride: server, isCurrent: () => isCurrent?.call() != false);
    if (video.videoId != id) {
      throw const MusicCatalogException(
          'The server returned another music track.');
    }
    return video;
  }

  @override
  Future<List<MusicTrack>> getSubscriptionSongs(Iterable<Video> uploads,
      {required Server expectedServer, bool Function()? isCurrent}) async {
    final expected = BackendPlayback(expectedServer);
    final authors = <String, String>{};
    for (final upload in uploads) {
      final creator = upload.authorId;
      if (!_videoId.hasMatch(upload.videoId) ||
          creator == null ||
          !_channelId.hasMatch(creator) ||
          upload.filtered ||
          upload.filterHide) {
        continue;
      }
      authors.putIfAbsent(upload.videoId, () => creator);
      if (authors.length >= 8) break;
    }
    if (authors.isEmpty || isCurrent?.call() == false) return const [];
    return _inSession((api, server, checkSession) async {
      Future<void> check() async {
        if (isCurrent?.call() == false || !expected.matches(server)) {
          throw const MusicCatalogException('The music request was cancelled.');
        }
        await checkSession();
        if (isCurrent?.call() == false) {
          throw const MusicCatalogException('The music request was cancelled.');
        }
      }

      return _inspectDiscoverySongs(
          api, server, authors.keys.toList(), check, isCurrent,
          accept: (video) => video.authorId == authors[video.videoId]);
    });
  }

  Future<List<MusicTrack>> _inspectDiscoverySongs(
      Service api,
      Server server,
      List<String> candidates,
      Future<void> Function() check,
      bool Function()? isCurrent,
      {int seedFailures = 0,
      void Function(InvidiousServiceError)? onInstanceFailure,
      bool Function(Video)? accept,
      void Function(Video)? onVerified}) async {
    final covers = _savedCovers(server);
    Future<
        ({
          (MusicTrack, Video)? verified,
          bool failed,
          bool connectionFailed,
          InvidiousServiceError? rejection,
        })> inspect(String id) async {
      await check();
      (MusicTrack, Video)? verified;
      var failed = false;
      var connectionFailed = false;
      InvidiousServiceError? rejection;
      try {
        // One noninteractive lookup per candidate. Service retains its own
        // transport policy (short 429 and NerdVPN startup retries), but
        // discovery neither rotates backends nor adds retries or refills.
        final video = await _discoveryVideo(api, server, id, isCurrent);
        if (accept?.call(video) != false &&
            video.genre?.trim().toLowerCase() == 'music' &&
            video.title != privateVideoString &&
            video.liveNow != true &&
            video.isUpcoming != true &&
            (video.premiereTimestamp ?? 0) <=
                DateTime.now().millisecondsSinceEpoch ~/ 1000 &&
            !db.getAllFilters().any((filter) => filter.filterVideo(video))) {
          verified = (_track(video, covers, server), video);
        }
      } catch (error) {
        // One unavailable or malformed candidate must not hide other verified
        // music. Session cancellation is checked outside this partial result.
        failed = true;
        connectionFailed = isMusicBrowseConnectionFailure(error);
        if (error is InvidiousServiceError &&
            (_discoveryCooldown(error) ||
                (onInstanceFailure != null && musicDiscoveryMustStop(error)))) {
          rejection = error;
        }
      }
      await check();
      return (
        verified: verified,
        failed: failed,
        connectionFailed: connectionFailed,
        rejection: rejection,
      );
    }

    final host = Uri.parse(server.url).host.toLowerCase();
    final concurrency = NetworkProxy.instance.config.enabled ||
            host.replaceFirst(RegExp(r'\.+$'), '').endsWith('.onion')
        ? 1
        : 2;
    final songs = <MusicTrack>[];
    var failures = seedFailures;
    var connectionFailed = false;
    for (var offset = 0; offset < candidates.length;) {
      await check();
      final batch = candidates.skip(offset).take(concurrency).toList();
      final inspected = await Future.wait(batch.map(inspect));
      await check();
      offset += batch.length;
      InvidiousServiceError? rejection;
      for (final item in inspected) {
        if (item.failed) failures++;
        connectionFailed = connectionFailed || item.connectionFailed;
        if (item.verified case (final track, final video)
            when songs.length < _discoverySongLimit) {
          songs.add(track);
          onVerified?.call(video);
        }
        if (item.rejection case final error?) {
          if (rejection == null ||
              (error.retryAfter ?? Duration.zero) >
                  (rejection.retryAfter ?? Duration.zero)) {
            rejection = error;
          }
        }
      }
      if (rejection != null) {
        if (onInstanceFailure != null) {
          onInstanceFailure(rejection);
          if (songs.isEmpty) throw rejection;
        }
        break;
      }
      if (songs.length >= _discoverySongLimit) break;
    }
    if (songs.isEmpty && failures > 0) {
      const message =
          'Music discovery could not verify any tracks. Retry the request.';
      throw connectionFailed
          ? const MusicCatalogConnectionFailure(message)
          : const MusicCatalogException(message);
    }
    return songs.take(_discoverySongLimit).toList();
  }

  @override
  Future<Video?> findMusicVideo(Video song,
      {required bool Function() isCurrent}) async {
    final connection = song.backendPlayback ?? song.playbackConnection;
    if (!isCurrent() ||
        connection == null ||
        song.downloadPlaybackOnly ||
        song.musicMetadata == null ||
        !_videoId.hasMatch(song.videoId)) {
      return null;
    }
    return _inSession((api, selected, checkSession) async {
      if (!isCurrent() || !connection.matches(selected)) return null;
      if (!musicVideoAllowed(song)) return null;
      if (isVisualMusicUpload(song) && hasMusicVideoSource(song)) return song;

      final recording = MusicVideoRecording.fromSong(song);
      if (recording == null) return null;
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);

      // The audio may use an explicitly selected backend. Keep that route for
      // both the search and the actual video; do not spend its fallback budget.
      final server = connection.server;
      final results = await api.searchMusic(
          '${recording.artist} ${recording.title} official music video',
          SearchType.video,
          server,
          check);
      await check();
      final labeled = <String>{};
      final other = <String>{};
      for (final row in results.videos.take(10)) {
        if (!_videoId.hasMatch(row.videoId) || !musicVideoAllowed(row)) {
          continue;
        }
        // A saved queue label can omit the current upload's video designation.
        // A search row for that exact ID can recover it without substituting a
        // different recording. Never probe the current confirmed Art Track.
        if (row.videoId == song.videoId) {
          if (song.musicMetadata?.isArtTrack != true &&
              !song.isStockArtTrack &&
              hasMusicVideoLabel(row)) {
            labeled.add(row.videoId);
          }
        } else if (recording.matches(row, fullMetadata: false)) {
          (hasMusicVideoLabel(row) ? labeled : other).add(row.videoId);
        }
      }
      for (final id in {...labeled, ...other}.take(3)) {
        await check();
        try {
          final detail = await api.getCatalogSongVideo(id, server, null, check);
          await check();
          if (detail.videoId != id ||
              !musicVideoAllowed(detail) ||
              !isVisualMusicUpload(detail) ||
              (id != song.videoId &&
                  !recording.matches(detail, fullMetadata: true))) {
            continue;
          }
          final admitted = detail.copyWith(
              playbackConnection: connection,
              backendPlayback: song.backendPlayback);
          if (hasMusicVideoSource(admitted)) return admitted;
        } on InvidiousServiceError catch (failure) {
          if (musicDiscoveryMustStop(failure)) rethrow;
        } on FormatException {
          // An invalid candidate cannot establish a match. Try the next one.
        }
      }
      return null;
    });
  }

  @override
  Future<MusicTrack> getSong(String videoId,
      {VideoLoadObserver? loadObserver}) {
    if (!_videoId.hasMatch(videoId)) {
      throw const MusicCatalogException('Invalid music track.');
    }
    return _inSession((api, server, check) async {
      final covers = _savedCovers(server);
      final connection = BackendPlayback(server);
      final Video video;
      try {
        video =
            await api.getCatalogSongVideo(videoId, server, loadObserver, check);
      } on FormatException {
        throw const MusicCatalogException(
            'The server returned an invalid music track.');
      }
      if (video.videoId != videoId) {
        throw const MusicCatalogException(
            'The server returned another music track.');
      }
      return _track(video, covers, server,
          playbackVideo: loadObserver == null
              ? null
              : video.copyWith(
                  formatStreams: video.formatStreams ?? [],
                  adaptiveFormats: video.adaptiveFormats ?? [],
                  playbackConnection: video.playbackConnection ??
                      video.backendPlayback ??
                      connection));
    });
  }

  @override
  Future<MusicRecordingAvailability> checkRecordingAvailability(String videoId,
      {required bool Function() isCurrent}) async {
    if (_videoId.stringMatch(videoId) != videoId) {
      throw const MusicCatalogException('Invalid music track.');
    }
    _requireCurrentDiscovery(isCurrent);
    final availability = await _inSession((api, server, _) async {
      _requireCurrentDiscovery(isCurrent);
      try {
        final video = await _discoveryVideo(api, server, videoId, isCurrent);
        final title = video.title?.trim();
        if (title == null || title.isEmpty) {
          throw const MusicCatalogException(
              'The server returned an invalid music track.');
        }
        return title == privateVideoString
            ? MusicRecordingAvailability.missing
            : MusicRecordingAvailability.available;
      } on InvidiousServiceError catch (error) {
        // Invidious reports this recording-specific reason as a JSON 404.
        // A missing endpoint or a provider outage can also produce a 404.
        if ((error.statusCode == 404 || error.statusCode == 410) &&
            error.errorCode == 'Video unavailable' &&
            !error.responseWasHtml &&
            !error.isGatewayAccessFailure &&
            !error.retryAfterIsInvalid &&
            error.retryAfter == null) {
          return MusicRecordingAvailability.missing;
        }
        rethrow;
      }
    });
    _requireCurrentDiscovery(isCurrent);
    return availability;
  }

  @override
  Future<void> loadSavedSongDetails(Iterable<String> ids,
      {required bool Function() isCurrent,
      required Future<void> Function(String id, MusicLibraryEntry? details)
          onResult}) async {
    if (!isCurrent()) return;
    await _inSession((api, server, check) async {
      final seen = <String>{};
      var previousServerFailure = false;
      for (final id in ids.take(musicLibraryMaximumEntries)) {
        if (!isCurrent()) return;
        if (!seen.add(id)) continue;
        await check();
        if (!isCurrent()) return;

        MusicLibraryEntry? details;
        var serverFailure = false;
        if (_videoId.stringMatch(id) == id) {
          try {
            final video = await api.getDiscoveryVideoMetadata(id,
                serverOverride: server, isCurrent: isCurrent);
            if (video.videoId == id && video.title != privateVideoString) {
              details = _savedSongDetails(video, server);
            }
          } on StateError {
            if (!isCurrent()) return;
            rethrow;
          } on FormatException {
            // Malformed metadata belongs to this entry, not the rest of the batch.
          } on InvidiousServiceError catch (error) {
            final status = error.statusCode;
            final itemError = !error.isGatewayAccessFailure &&
                !error.responseWasHtml &&
                !error.retryAfterIsInvalid &&
                error.retryAfter == null;
            final unavailable = status == 404 ||
                status == 410 ||
                (status != null && status >= 200 && status < 300);
            // Invidious also uses 500 for failures to load individual videos.
            // Continue past one structured error, but stop on a repeated 500.
            serverFailure = status == 500 && error.errorCode != null;
            if (!itemError ||
                !(unavailable || (serverFailure && !previousServerFailure))) {
              rethrow;
            }
          }
        }
        previousServerFailure = serverFailure;
        if (!isCurrent()) return;
        await check();
        if (!isCurrent()) return;
        await onResult(id, details);
      }
    });
  }

  MusicLibraryEntry? _savedSongDetails(Video video, Server server) {
    final title = video.title;
    if (title == null || title.trim().isEmpty) return null;
    final images = stockSongThumbnails(video.videoId, video.videoThumbnails,
        artTrack: video.isStockArtTrack, instanceUrl: server.url);
    final candidates =
        ImageObject.getThumbnailUrlsForSize(images, width: 320, height: 180);
    final credits = video.stockArtTrackCredits;
    return MusicLibraryEntry.tryParse(MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: video.videoId,
      title: title,
      subtitle:
          credits.isEmpty ? video.author ?? '' : credits.artistNames.join(', '),
      artistCredits: credits.isNotEmpty
          ? credits
          : [
              if (MusicArtistCredit.forAuthor(
                      video.author, video.authorId, video.authorUrl)
                  case final credit?)
                credit,
            ],
      album: video.stockArtTrackAlbum,
      durationSeconds: video.lengthSeconds,
      thumbnails: [
        for (final url in candidates.take(2))
          images.firstWhere((image) => image.url == url)
      ],
      usesVideoThumbnails: true,
      isArtTrack: video.isStockArtTrack,
    ).toJson());
  }

  @override
  Future<MusicArtistPage> getArtist(String id) =>
      _getArtist(id, deferUploads: false);

  @override
  Future<MusicArtistPage> getArtistOverview(String id, {String? artistName}) =>
      _getArtist(id, deferUploads: true, artistName: artistName);

  Future<MusicArtistPage> _getArtist(String id,
      {required bool deferUploads, String? artistName}) {
    if (!_channelId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music artist.');
    }
    return _inSession((api, server, check) async {
      Future<Channel> loadChannel(String channelId) async {
        final channel = await api.getMusicChannel(channelId, server, check);
        await check();
        if (channel.authorId != channelId) {
          throw const MusicCatalogException(
            'The server returned another artist channel.',
          );
        }
        return channel;
      }

      Channel channel;
      try {
        channel = await loadChannel(id);
      } on InvidiousServiceError catch (error) {
        if (artistName == null ||
            error.responseWasHtml ||
            error.errorCode?.trim().isNotEmpty != true ||
            error.retryAfter != null ||
            musicDiscoveryMustStop(error) ||
            !const {404, 410, 500}.contains(error.statusCode)) {
          rethrow;
        }
        final matchedId =
            await _findTopicArtist(id, artistName, api, server, check);
        if (matchedId == null) rethrow;
        channel = await loadChannel(matchedId);
      }
      return MusicArtistPage(
        artist: MusicArtist(
          id: channel.authorId,
          name: channel.author,
          thumbnails: channel.authorThumbnails,
        ),
        description: _nonBlank(channel.description),
        loadsUploadsSeparately: deferUploads,
        songs: deferUploads
            ? const []
            : (await _artistUploadsPage(channel.authorId, api, server, check))
                .songs,
      );
    });
  }

  Future<String?> _findTopicArtist(
    String topicId,
    String artistName,
    Service api,
    Server server,
    Future<void> Function() check,
  ) async {
    String normalizeName(String name) =>
        name.trim().replaceAll(RegExp(r'\s+'), ' ');
    const topicSuffix = ' - topic';
    var query = normalizeName(artistName);
    if (query.toLowerCase().endsWith(topicSuffix)) {
      query = query.substring(0, query.length - topicSuffix.length);
    }
    if (query.isEmpty || query.length > 1024) return null;

    final name = query.toLowerCase();
    final rows = await api.searchMusicPage(query, SearchType.channel, 1,
        server: server, beforeRequest: check);
    await check();
    var foundTopic = false;
    final matches = <String>{};
    for (final row in rows) {
      if (row
          case {
            'type': 'channel',
            'authorId': final String id,
            'author': final String author,
            'autoGenerated': final bool autoGenerated,
          }) {
        final label = normalizeName(author).toLowerCase();
        if (id == topicId) {
          foundTopic |= autoGenerated && label == '$name$topicSuffix';
        } else if (label == name &&
            !autoGenerated &&
            row['authorVerified'] == true &&
            _channelId.hasMatch(id)) {
          matches.add(id);
        }
      }
    }
    // A display name alone cannot identify an artist. Require the same
    // provider to recognize the original Topic ID and one verified match.
    return foundTopic && matches.length == 1 ? matches.single : null;
  }

  @override
  Future<List<MusicTrack>> getArtistUploads(
    String id, {
    bool Function()? isCurrent,
  }) =>
      getArtistUploadsPage(id, isCurrent: isCurrent).then((page) => page.songs);

  @override
  Future<MusicArtistUploads> getArtistUploadsPage(
    String id, {
    String? continuation,
    bool Function()? isCurrent,
  }) {
    if (!_channelId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music artist.');
    }
    if (continuation != null && !_validArtistUploadCursor(continuation)) {
      throw const MusicCatalogException('Invalid artist uploads continuation.');
    }
    _requireCurrentDiscovery(isCurrent);
    return _inSession(
      (api, server, check) => _artistUploadsPage(
        id,
        api,
        server,
        () => _checkDiscovery(check, isCurrent),
        continuation: continuation,
      ),
    );
  }

  static bool _validArtistUploadCursor(String token) =>
      token.isNotEmpty &&
      token.length <= 8192 &&
      !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(token);

  Future<MusicArtistUploads> _artistUploadsPage(
    String id,
    Service api,
    Server server,
    Future<void> Function() check, {
    String? continuation,
  }) async {
    await check();
    final videos = await api.getMusicChannelVideos(id, server, check,
        continuation: continuation);
    await check();
    final covers = _savedCovers(server);
    final next = videos.continuation;
    return MusicArtistUploads(
      songs: [for (final video in videos.videos) _track(video, covers, server)],
      continuation:
          next != null && next != continuation && _validArtistUploadCursor(next)
              ? next
              : null,
    );
  }

  @override
  Future<MusicArtistReleases> getArtistReleases(String id,
      {String? continuation, bool Function()? isCurrent}) {
    if (!_channelId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music artist.');
    }
    _requireCurrentDiscovery(isCurrent);
    return _inSession((api, server, checkSession) async {
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);
      await check();
      final remaining = _artistReleaseDeadline(server)?.difference(_now());
      if (remaining != null && remaining > Duration.zero) {
        throw InvidiousServiceError('The releases endpoint is cooling down.',
            statusCode: 429, retryAfter: remaining);
      }
      Map<String, dynamic> data;
      try {
        data = await api.getMusicChannelReleases(id, server, check,
            continuation: continuation);
      } on InvidiousServiceError catch (error) {
        await checkSession();
        final delay = error.retryAfter;
        if (delay != null && delay > Duration.zero) {
          final until = _now().add(delay);
          if (_artistReleaseDeadline(server)?.isAfter(until) != true) {
            _artistReleaseCooldown =
                (owner: db, route: BackendPlayback(server), until: until);
          }
        }
        await check();
        // Older instances may omit the route. Genuine access failures and
        // cooldowns must remain visible to callers.
        if (!musicDiscoveryMustStop(error) &&
            (error.statusCode == 404 || error.statusCode == 501)) {
          return const MusicArtistReleases();
        }
        rethrow;
      }
      await check();
      final releases = <MusicCollection>[];
      final seen = <String>{};
      for (final entry in data['playlists'] as List) {
        if (entry
            case {'playlistId': final String id, 'title': final String title}) {
          final playlistId = id.startsWith('VL') ? id.substring(2) : id;
          if (!_playlistId.hasMatch(playlistId) ||
              playlistId.startsWith('RD') ||
              title.trim().isEmpty ||
              !seen.add(playlistId)) {
            continue;
          }
          final author = entry['author'];
          final image = entry['playlistThumbnail'];
          final count = entry['videoCount'];
          final authorName = author is String ? _nonBlank(author) : null;
          releases.add(MusicCollection(
            id: playlistId,
            title: title,
            artists: [if (authorName != null) authorName],
            thumbnails: [
              if (image is String &&
                  image.isNotEmpty &&
                  invidiousImageUrl(image, server) != null)
                ImageObject(null, image, 0, 0),
            ],
            videoCount: count is int && count >= 0 ? count : null,
          ));
        }
      }
      final next = data['continuation'];
      return MusicArtistReleases(
        releases: releases,
        continuation:
            next is String && next.trim().isNotEmpty && next != continuation
                ? next
                : null,
      );
    });
  }

  static String? _nonBlank(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  DateTime? _artistReleaseDeadline(Server server) {
    final cooldown = _artistReleaseCooldown;
    return cooldown != null &&
            identical(cooldown.owner, db) &&
            cooldown.route.matchesConnection(server)
        ? cooldown.until
        : null;
  }

  @override
  Future<List<MusicTrack>> getChartSongs(String playlistId,
      {bool Function()? isCurrent}) {
    if (!musicCharts.any((chart) => chart.playlistId == playlistId)) {
      throw const MusicCatalogException('Invalid music chart.');
    }
    _requireCurrentDiscovery(isCurrent);
    return _inSession((api, server, checkSession) async {
      Future<void> check() => _checkDiscovery(checkSession, isCurrent);
      final page = await api.getMusicPlaylistPage(playlistId, 1, server, check);
      await check();
      if (page.playlistId != playlistId) {
        throw const MusicCatalogException('The server returned another chart.');
      }
      final covers = _savedCovers(server);
      final seen = <String>{};
      // Keep the first page of the Top 100 for fresh local eligibility checks.
      // The playlist's filter flags describe the settings at fetch time.
      return [
        for (final video in page.videos
            .where((video) =>
                _videoId.hasMatch(video.videoId) &&
                video.title?.trim().isNotEmpty == true &&
                musicVideoAvailable(video) &&
                seen.add(video.videoId))
            .take(100))
          _track(video, covers, server),
      ];
    });
  }

  @override
  Future<MusicCollection> getPlaylist(String id) => _loadPlaylist(id);

  @override
  Future<MusicCollection> getPlaylistProgressively(String id,
          {required void Function(MusicCollection) onProgress,
          required bool Function() isCurrent}) =>
      _loadPlaylist(id, onProgress: onProgress, isCurrent: isCurrent);

  Future<MusicCollection> _loadPlaylist(String id,
      {void Function(MusicCollection)? onProgress,
      bool Function()? isCurrent}) {
    final playlistId = id.startsWith('VL') ? id.substring(2) : id;
    if (!_playlistId.hasMatch(playlistId)) {
      throw const MusicCatalogException('Invalid music playlist.');
    }
    return _inSession((api, server, checkSession) async {
      Future<void> check() async {
        await checkSession();
        if (isCurrent?.call() == false) {
          throw const MusicCatalogException('The music request was cancelled.');
        }
      }

      final covers = _savedCovers(server);
      if (playlistId.startsWith('RD')) {
        final mix = await api.getMix(playlistId,
            serverOverride: server, enrichResults: false, beforeRequest: check);
        return MusicCollection(
          id: playlistId,
          title: mix.title,
          artists: mix.author.isEmpty ? [] : [mix.author],
          thumbnails: _playlistPreview(mix.videos, server),
          tracks: [
            for (final video in mix.videos)
              _track(video, covers, server, playlistEntry: true)
          ],
          videoCount: mix.videoCount,
          updated: mix.updated,
        );
      }
      final first =
          await api.getMusicPlaylistPage(playlistId, 1, server, check);
      final author = _nonBlank(first.author);
      final authorId = normalizeChannelId(first.authordId) ??
          channelIdFromAuthorUrl(first.authorUrl);
      final albumId = validMusicAlbumPlaylistId(playlistId);
      final albumTitle =
          albumId != null && first.title.trim().isNotEmpty ? first.title : null;
      final thumbnails = _playlistPreview(first.videos, server);
      var page = first;
      var hasFilteredEntries = false;
      final tracks = <MusicTrack>[];
      final signatures = <String>{};
      final identities = <String>{};
      MusicCollection snapshot({required bool complete}) => MusicCollection(
            id: playlistId,
            title: first.title,
            artists: [if (author != null) author],
            playlistAuthor: author == null
                ? null
                : MusicArtistCredit(name: author, id: authorId),
            description: _nonBlank(first.description),
            thumbnails: thumbnails,
            tracks: List.unmodifiable(tracks),
            videoCount: first.videoCount,
            updated: first.updated,
            loadingComplete: complete,
          );

      for (var pageNumber = 1; pageNumber <= 50; pageNumber++) {
        await check();
        if (page.playlistId != playlistId ||
            page.videoCount != first.videoCount) {
          throw const MusicCatalogException(
              'The music playlist changed while loading. Retry the request.');
        }
        final signature = jsonEncode([
          for (final video in page.videos)
            [video.videoId, video.indexId, video.index],
          page.removedByFilter,
        ]);
        if (page.videoCount < 0 ||
            page.removedByFilter < 0 ||
            (page.videos.isNotEmpty && !signatures.add(signature))) {
          throw const MusicCatalogException(
              'The server returned an invalid music playlist page.');
        }
        for (final video in page.videos) {
          final identity = playlistSourceEntryId(video);
          if (identity == null || identities.add(identity)) {
            tracks.add(_track(video, covers, server,
                albumPlaylistId: albumId,
                albumTitle: albumTitle,
                playlistEntry: true));
          }
        }
        // Invidious pages can overlap. Filtered entries have already lost their
        // source identities, so adding their counts could finish too early.
        // When filtering occurred, wait for the server's terminal empty page.
        // A final lookback-only window may precede it; the repeated-page and
        // page-budget guards still bound that traversal.
        hasFilteredEntries |= page.removedByFilter > 0;
        if ((!hasFilteredEntries && tracks.length >= first.videoCount) ||
            (page.videos.isEmpty && page.removedByFilter == 0)) {
          return snapshot(complete: true);
        }
        onProgress?.call(snapshot(complete: false));
        if (pageNumber == 50) break;
        page = await api.getMusicPlaylistPage(
            playlistId, pageNumber + 1, server, check);
      }
      throw const MusicCatalogException(
          'The music playlist could not finish loading.');
    });
  }
}
