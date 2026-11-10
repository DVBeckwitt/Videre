import 'dart:convert';

import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/videos/models/video.dart';

/// Music browsing through the selected Invidious instance's standard API.
/// Unsupported YouTube Music feeds never fall back to Google's catalog.
class InvidiousMusicCatalogService extends MusicCatalogService {
  final Service? _service;

  InvidiousMusicCatalogService({Service? api}) : _service = api;

  static final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final _channelId = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
  static final _playlistId = RegExp(r'^(PL|OLAK5uy_|RD)[a-zA-Z0-9_-]+$');

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
    return MusicTrack(
      videoId: video.videoId,
      title: video.title!,
      artists: author == null || author.isEmpty ? [] : [author],
      artistLinks: author != null &&
              author.isNotEmpty &&
              _channelId.hasMatch(video.authorId ?? '')
          ? [MusicArtist(id: video.authorId!, name: author)]
          : [],
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

  @override
  Future<List<MusicTrack>> getTrendingSongs() =>
      _inSession((api, _, __) async =>
          (await api.getTrending(type: 'Music')).map(_track).toList());

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
  Future<MusicArtistPage> getArtist(String id) {
    if (!_channelId.hasMatch(id)) {
      throw const MusicCatalogException('Invalid music artist.');
    }
    return _inSession((api, server, check) async {
      final channel = await api.getChannel(id);
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
