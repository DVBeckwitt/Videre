import 'dart:convert';

import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/video_post_processing.dart'
    show privateVideoString;
import 'package:clipious/videos/models/video.dart';

/// Music browsing through the selected Invidious instance's standard API.
/// Unsupported YouTube Music feeds never fall back to Google's catalog.
class InvidiousMusicCatalogService extends MusicCatalogService {
  final Service? _service;

  InvidiousMusicCatalogService({Service? api}) : _service = api;

  static final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final _channelId = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
  static final _playlistId = RegExp(r'^(PL|OLAK5uy_|RD)[a-zA-Z0-9_-]+$');
  static final _videoThumbnail = RegExp(
      r'/vi(?:_webp)?/([A-Za-z0-9_-]{11})/([A-Za-z0-9_-]+)\.(?:jpg|webp)$');

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
      if (!current() || !route.matches(selected)) {
        throw const MusicCatalogException(
            'The music connection changed. Retry the request.');
      }
    }

    await check();
    final value = await load(api, server, check);
    await check();
    return value;
  }

  MusicTrack _track(Video video, {Video? playbackVideo}) {
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
      artistLinks: author != null &&
              author.isNotEmpty &&
              _channelId.hasMatch(video.authorId ?? '')
          ? [MusicArtist(id: video.authorId!, name: author)]
          : [],
      uploaderChannelId: uploaderId,
      uploaderChannelUrl: uploaderHandle == null
          ? null
          : Uri(pathSegments: ['', '@$uploaderHandle']).toString(),
      durationSeconds: video.lengthSeconds,
      thumbnails: video.videoThumbnails,
      playbackVideo: playbackVideo,
    );
  }

  @override
  Future<List<MusicTrack>> searchSongs(String query) async {
    if (query.trim().isEmpty) return [];
    return _inSession((api, _, __) async =>
        (await api.search(query.trim(), type: SearchType.video))
            .videos
            .map(_track)
            .toList());
  }

  @override
  Future<List<MusicArtist>> searchArtists(String query) async {
    if (query.trim().isEmpty) return [];
    return _inSession((api, _, __) async =>
        (await api.search(query.trim(), type: SearchType.channel))
            .channels
            .map((channel) => MusicArtist(
                  id: channel.authorId,
                  name: channel.author,
                  thumbnails: channel.authorThumbnails,
                ))
            .toList());
  }

  @override
  Future<List<MusicPlaylist>> searchPlaylists(String query) async {
    if (query.trim().isEmpty) return [];
    return _inSession((api, _, __) async =>
        (await api.search(query.trim(), type: SearchType.playlist))
            .playlists
            .map((playlist) => MusicPlaylist(
                  id: playlist.playlistId,
                  title: playlist.title,
                  author: playlist.author,
                  thumbnails:
                      playlist.videos.firstOrNull?.videoThumbnails ?? [],
                ))
            .toList());
  }

  // Do not override getTrendingSongs. Invidious's trending endpoint can ignore
  // type=Music and return general livestreams. The inherited unsupported result
  // keeps unrelated videos out of Music without another catalog or fallback.

  @override
  Future<List<MusicTrack>> getDiscoverySongs({bool Function()? isCurrent}) {
    return _inSession((api, server, checkSession) async {
      Future<void> check() async {
        if (isCurrent?.call() == false) {
          throw const MusicCatalogException('The music request was cancelled.');
        }
        await checkSession();
        if (isCurrent?.call() == false) {
          throw const MusicCatalogException('The music request was cancelled.');
        }
      }

      await check();
      final search = await api.search('official music video',
          type: SearchType.video, serverOverride: server, enrichResults: false);
      await check();
      final candidates = <String>[];
      final seen = <String>{};
      for (final video in search.videos) {
        if (!video.filtered &&
            _videoId.hasMatch(video.videoId) &&
            seen.add(video.videoId)) {
          candidates.add(video.videoId);
          if (candidates.length == 8) break;
        }
      }

      Future<({MusicTrack? track, bool failed, bool cooldown})> inspect(
          String id) async {
        await check();
        MusicTrack? track;
        var failed = false;
        var cooldown = false;
        try {
          // One noninteractive lookup per candidate. Service retains its own
          // transport policy (short 429 and NerdVPN startup retries), but
          // discovery neither rotates backends nor adds retries or refills.
          final video =
              await api.getDiscoveryVideoMetadata(id, serverOverride: server);
          if (video.videoId != id) {
            throw const MusicCatalogException(
                'The server returned another music track.');
          }
          if (video.genre?.trim().toLowerCase() == 'music' &&
              video.title != privateVideoString &&
              video.liveNow != true &&
              video.isUpcoming != true &&
              (video.premiereTimestamp ?? 0) <=
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 &&
              !db.getAllFilters().any((filter) => filter.filterVideo(video))) {
            track = _track(video);
          }
        } catch (error) {
          // One unavailable or malformed candidate must not hide other verified
          // music. Session cancellation is checked outside this partial result.
          failed = true;
          cooldown = error is InvidiousServiceError &&
              (error.isRateLimited ||
                  error.retryAfterIsInvalid ||
                  (error.retryAfter ?? Duration.zero) > Duration.zero);
        }
        await check();
        return (track: track, failed: failed, cooldown: cooldown);
      }

      final host = Uri.parse(server.url).host.toLowerCase();
      final concurrency = NetworkProxy.instance.config.enabled ||
              host.replaceFirst(RegExp(r'\.+$'), '').endsWith('.onion')
          ? 1
          : 2;
      final songs = <MusicTrack>[];
      var failures = 0;
      for (var offset = 0; offset < candidates.length;) {
        await check();
        final batch = candidates.skip(offset).take(concurrency).toList();
        final inspected = await Future.wait(batch.map(inspect));
        await check();
        offset += batch.length;
        for (final item in inspected) {
          if (item.failed) failures++;
          if (item.track case final track?) songs.add(track);
        }
        // An instance cooldown also applies to requests for other candidates.
        if (songs.length >= 6 || inspected.any((item) => item.cooldown)) break;
      }
      if (songs.isEmpty && failures > 0) {
        throw const MusicCatalogException(
            'Music discovery could not verify any tracks. Retry the request.');
      }
      return songs.take(6).toList();
    });
  }

  @override
  Future<MusicTrack> getSong(String videoId,
      {VideoLoadObserver? loadObserver}) {
    if (!_videoId.hasMatch(videoId)) {
      throw const MusicCatalogException('Invalid music track.');
    }
    return _inSession((api, server, _) async {
      final connection = BackendPlayback(server);
      final Video video;
      try {
        video = await api.getVideo(videoId,
            serverOverride: loadObserver == null ? server : null,
            loadObserver: loadObserver);
      } on FormatException {
        throw const MusicCatalogException(
            'The server returned an invalid music track.');
      }
      if (video.videoId != videoId) {
        throw const MusicCatalogException(
            'The server returned another music track.');
      }
      return _track(video,
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
    final images = <String, ImageObject>{};
    for (final source in video.videoThumbnails.take(8)) {
      final proxied = invidiousImageUrl(source.url, server);
      if (proxied == null) continue;
      final path = Uri.tryParse(proxied)?.path;
      final match = path == null ? null : _videoThumbnail.firstMatch(path);
      if (match == null || match.group(1) != video.videoId) continue;
      // Keep only a portable thumbnail path. Rendering resolves it against the
      // selected instance without retaining credentials or signed parameters.
      final url = '/vi/${video.videoId}/${match.group(2)}.jpg';
      images.putIfAbsent(url,
          () => ImageObject(source.quality, url, source.width, source.height));
    }
    final candidates = ImageObject.getThumbnailUrlsForSize(
        images.values.toList(),
        width: 320,
        height: 180);
    return MusicLibraryEntry.tryParse(MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: video.videoId,
      title: title,
      subtitle: video.author ?? '',
      durationSeconds: video.lengthSeconds,
      thumbnails: [for (final url in candidates.take(2)) images[url]!],
      usesVideoThumbnails: true,
    ).toJson());
  }

  @override
  Future<MusicArtistPage> getArtist(String id) {
    if (!_channelId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music artist.');
    }
    return _inSession((api, server, check) async {
      final channel =
          await api.getChannel(id, saveLastSeen: false, serverOverride: server);
      await check();
      if (channel.authorId != id) {
        throw const MusicCatalogException(
            'The server returned another artist channel.');
      }
      final videos = await api.getChannelVideos(id, null,
          serverOverride: server,
          saveLastSeen: false,
          sortBy: ChannelSortBy.popular);
      return MusicArtistPage(
        artist: MusicArtist(
          id: channel.authorId,
          name: channel.author,
          thumbnails: channel.authorThumbnails,
        ),
        description: channel.description,
        songs: videos.videos.map(_track).toList(),
      );
    });
  }

  @override
  Future<MusicCollection> getPlaylist(String id) {
    final playlistId = id.startsWith('VL') ? id.substring(2) : id;
    if (!_playlistId.hasMatch(playlistId)) {
      throw const MusicCatalogException('Invalid music playlist.');
    }
    return _inSession((api, server, check) async {
      if (playlistId.startsWith('RD')) {
        final mix = await api.getMix(playlistId, serverOverride: server);
        return MusicCollection(
          id: playlistId,
          title: mix.title,
          artists: mix.author.isEmpty ? [] : [mix.author],
          thumbnails: mix.videos.firstOrNull?.videoThumbnails ?? [],
          tracks: mix.videos.map(_track).toList(),
          videoCount: mix.videoCount,
          updated: mix.updated,
        );
      }
      final first = await api.getPublicPlaylists(playlistId,
          page: 1, saveLastSeen: false, serverOverride: server);
      var page = first;
      var hasFilteredEntries = false;
      final tracks = <MusicTrack>[];
      final signatures = <String>{};
      final identities = <String>{};
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
            tracks.add(_track(video));
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
          return MusicCollection(
            id: playlistId,
            title: first.title,
            artists: first.author.isEmpty ? [] : [first.author],
            thumbnails: first.videos.firstOrNull?.videoThumbnails ?? [],
            tracks: tracks,
            videoCount: first.videoCount,
            updated: first.updated,
          );
        }
        if (pageNumber == 50) break;
        page = await api.getPublicPlaylists(playlistId,
            page: pageNumber + 1, saveLastSeen: false, serverOverride: server);
      }
      throw const MusicCatalogException(
          'The music playlist could not finish loading.');
    });
  }
}
