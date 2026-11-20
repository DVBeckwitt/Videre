import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_player.dart';
import 'package:clipious/music/views/components/music_selection_feedback.dart';
import 'package:clipious/music/views/components/music_playlist_resume.dart';
import 'package:clipious/music/views/components/music_sponsor_notice.dart';
import 'package:clipious/music/views/components/music_sound_sheet.dart';
import 'package:clipious/music/views/components/music_track_results.dart';
import 'package:clipious/network/content_link.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/video_retry_notice.dart';
import 'package:clipious/player/views/components/playlist_loading_notice.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/views/components/playlist_information.dart';
import 'package:clipious/recommendations/candidate_sources.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/router.dart';
import 'package:clipious/search/views/components/pasted_link_dialog.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/offline_video_thumbnail.dart';
import 'package:clipious/videos/views/components/video_watch_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum _MusicSearch { songs, artists, playlists }

class _ArtistReleaseListing {
  final releases = <String, MusicCollection>{};
  final requestedContinuations = <String>{};
  String? continuation;
  bool loading = false;
  bool failed = false;
}

@RoutePage()
class MusicScreen extends StatefulWidget {
  final String? videoId;
  final List<MusicArtistCredit> artistCredits;
  final List<Video> queue;
  final int startIndex;
  final String? playlistId;
  final String? artistId;
  final String? initialQuery;
  final bool embedded;
  final Duration startAt;

  const MusicScreen(
      {super.key,
      this.videoId,
      this.artistCredits = const [],
      this.queue = const [],
      this.startIndex = 0,
      this.playlistId,
      this.artistId,
      this.initialQuery,
      this.startAt = Duration.zero,
      this.embedded = false});

  static Widget tvAudio({Video? video, DownloadedVideo? offlineVideo}) =>
      _MusicTvAudio(video: video, offlineVideo: offlineVideo);

  static void openPlayingArtist(BuildContext context, String id,
      {required bool television}) {
    final player = context.read<PlayerCubit>();
    if (television) {
      Navigator.of(context).push(_TvPlayingArtistRoute(id, player));
    } else {
      // The phone player overlays Main's nested pages as their sibling.
      final router = context.router;
      final pages =
          router.root.innerRouterOf<StackRouter>(MainRoute.name) ?? router;
      player.showMiniPlayer();
      pages.push(MusicRoute(artistId: id));
    }
  }

  static Future<void> playLocalTracks(
      BuildContext context, List<LocalMusicTrack> tracks,
      {int startIndex = 0}) async {
    if (tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length) return;
    if (isTv) {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _MusicTvPlayer(
              videos: const [], localTracks: tracks, startIndex: startIndex)));
    } else {
      await context
          .read<PlayerCubit>()
          .playLocalMusic(tracks, startIndex: startIndex);
    }
  }

  static Future<void> playTracks(BuildContext context, List<Video> videos,
          {PlaylistReference? reference,
          int? startIndex,
          Duration startAt = Duration.zero}) =>
      _playTracks(context, videos.map(_songEntry).toList(),
          reference: reference, startIndex: startIndex, startAt: startAt);

  static Video _songEntry(Video video) => video.musicMetadata != null
      ? video
      : video.copyWith(
          musicMetadata: video.resolveMusicMetadata(
              MusicMetadata(title: video.videoId, artist: '')));

  static Future<void> _playTracks(BuildContext context, List<Video> videos,
      {PlaylistReference? reference,
      int? startIndex,
      required Duration startAt,
      ModalRoute<dynamic>? songLauncher,
      bool Function()? isCurrent}) async {
    if (videos.isEmpty) return;
    if (reference != null && reference.profileId != db.profileId) return;
    final artistRoute = ModalRoute.of(context);
    if (isTv && artistRoute is! _TvPlayingArtistRoute) {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _MusicTvPlayer(
              videos: videos,
              reference: reference,
              startIndex: startIndex ?? 0,
              startAt: startAt)));
      return;
    }
    final player = context.read<PlayerCubit>();
    final returnRoute = songLauncher ??
        (artistRoute is _TvPlayingArtistRoute ? artistRoute : null);
    final before = player.state;
    final failure =
        returnRoute == null ? null : player.musicSelectionFailureRevision.value;
    final playback = reference == null
        ? player.playVideo(videos,
            fromMusic: true,
            audio: true,
            startAt: startAt,
            startIndex: startIndex)
        : player.playPlaylist(videos,
            fromMusic: true,
            reference: reference,
            startIndex: startIndex ?? 0,
            audio: true,
            startAt: startAt);
    if (returnRoute == null) return playback;
    final request = player.musicSelectionRequestRevision;
    bool current() =>
        context.mounted &&
        !player.isClosed &&
        player.musicSelectionRequestRevision == request &&
        returnRoute.isCurrent &&
        (isCurrent?.call() ?? true);
    bool playable(Video video) =>
        !video.filtered &&
        (reference == null || (!video.filterHide && video.isUpcoming != true));
    final assigned = reference == null
        ? assignPlaybackQueueIds(videos.where(playable))
        : assignPlaylistEntryIds(videos).where(playable);
    final queue = assigned.map(playbackQueueId).toList();
    final selected = videos.take(startIndex ?? 0).where(playable).length;
    bool matchesQueue(PlayerState state) =>
        listEquals(state.videos.map(playbackQueueId).toList(), queue);
    // Replaying the active occurrence can have an identical queue throughout
    // preparation. In that case its completed request confirms the handoff.
    final selectedId = queue.elementAtOrNull(selected);
    final wasCurrent =
        before.currentQueueId == selectedId && matchesQueue(before);
    bool popped = false;
    void returnAfterCommit({bool completed = false}) {
      final state = player.state;
      // With no old song to keep playing, the newly expanded queue owns the
      // screen even while its first decoder is still starting.
      final firstQueue = before.currentQueueId == null &&
          state.currentQueueId == null &&
          !identical(state, before);
      if (popped ||
          returnRoute.isFirst ||
          !current() ||
          player.musicSelectionFailureRevision.value != failure ||
          (wasCurrent && !completed) ||
          selectedId == null ||
          !state.isAudio ||
          state.isHidden ||
          state.isMini ||
          (!firstQueue && state.currentQueueId != selectedId) ||
          !matchesQueue(state)) {
        return;
      }
      popped = true;
      returnRoute.navigator!.pop();
    }

    final subscription = returnRoute.isFirst
        ? null
        : player.stream.listen((_) => returnAfterCommit());
    try {
      returnAfterCommit();
      await playback;
      if (current() && player.musicSelectionFailureRevision.value != failure) {
        if (songLauncher != null) {
          throw StateError('The selected song could not be started.');
        }
        return;
      }
      returnAfterCommit(completed: true);
    } finally {
      unawaited(subscription?.cancel());
    }
  }

  @override
  State<MusicScreen> createState() => MusicScreenState();
}

class MusicScreenState extends State<MusicScreen> {
  final _search = TextEditingController();
  final _queryFocus = FocusNode();
  VoidCallback? _shortcutBack;
  _MusicSearch _type = _MusicSearch.songs;
  List<MusicTrack> _songs = [];
  List<MusicArtist> _artists = [];
  List<MusicPlaylist> _playlists = [];
  MusicCollection? _collection;
  MusicArtistPage? _artistPage;
  _ArtistReleaseListing? _artistReleases;
  Timer? _artistReleaseCooldown;
  final _browseHistory = <({
    MusicCollection? collection,
    MusicArtistPage? artist,
    _ArtistReleaseListing? releases,
  })>[];
  bool _loading = false;
  bool _browseRequest = false;
  bool _retryingSong = false;
  Object? _failure;
  bool _searched = false;
  String? _submittedQuery;
  MusicTrack? _resolvedSong;
  bool _showCommunityHidden = false;
  bool _starting = false;
  int _playRequest = 0;
  ({List<Video> videos, int startIndex, Duration startAt})? _tvSong;
  int _generation = 0;
  int? _abandonedSongRequest;
  Future<void> Function()? _retry;

  bool get _hasBrowsePage =>
      _collection != null || _artistPage != null || _browseHistory.isNotEmpty;

  void focusSearch({VoidCallback? onBack}) {
    if (onBack != null) setState(() => _shortcutBack = onBack);
    if (_hasBrowsePage || _browseRequest) {
      _browseHistory.clear();
      _backToSearch();
    }
    if (_queryFocus.hasFocus) {
      // Android's Back button can hide the IME while the field keeps focus.
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      _queryFocus.requestFocus();
    }
  }

  void leaveSearch() {
    if (_shortcutBack != null) setState(() => _shortcutBack = null);
  }

  // A direct catalog link has no search results to return to. Preserve in-page
  // history first; submitting a search establishes a new local destination.
  bool get _returnToOrigin =>
      _hasBrowsePage &&
      !_searched &&
      _browseHistory.isEmpty &&
      (widget.artistId != null || widget.playlistId != null);

  @override
  void initState() {
    super.initState();
    _loading = widget.videoId != null &&
        widget.playlistId == null &&
        _sameSession(context.read<AppCubit>().state);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openInitial();
    });
  }

  @override
  void didUpdateWidget(MusicScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.startIndex != widget.startIndex ||
        !listEquals(oldWidget.queue, widget.queue) ||
        oldWidget.playlistId != widget.playlistId ||
        oldWidget.artistId != widget.artistId ||
        oldWidget.startAt != widget.startAt ||
        oldWidget.initialQuery != widget.initialQuery) {
      // Clearing every route argument has no replacement request to invalidate
      // the old one. Revoke it before opening the new destination either way.
      _generation++;
      _tvSong = null;
      _resolvedSong = null;
      _loading = false;
      _retryingSong = false;
      _failure = null;
      _retry = null;
      _openInitial();
    }
  }

  @override
  void dispose() {
    _generation++;
    _artistReleaseCooldown?.cancel();
    _search.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  bool _sameSession(AppState initial) {
    if (!mounted) return false;
    final current = context.read<AppCubit>().state;
    return !current.globalLoading &&
        !current.sessionRecoveryRequired &&
        current.profileId == initial.profileId &&
        current.sessionRevision == initial.sessionRevision &&
        current.server == initial.server;
  }

  bool _active(int generation, AppState initial) =>
      mounted && generation == _generation && _sameSession(initial);

  void _clearForSession() {
    _generation++;
    _artistReleaseCooldown?.cancel();
    _artistReleaseCooldown = null;
    setState(() {
      _loading = false;
      _retryingSong = false;
      _failure = null;
      _searched = false;
      _submittedQuery = null;
      _resolvedSong = null;
      _showCommunityHidden = false;
      _starting = false;
      _tvSong = null;
      _songs = [];
      _artists = [];
      _playlists = [];
      _collection = null;
      _artistPage = null;
      _artistReleases = null;
      _browseHistory.clear();
      _retry = null;
    });
  }

  Future<void> _openInitial() async {
    if (widget.playlistId != null) {
      await _openCollection(widget.playlistId!);
    } else if (widget.videoId != null) {
      await _openSong(widget.videoId!, startAt: widget.startAt);
    } else if (widget.artistId != null) {
      await _openArtist(widget.artistId!);
    } else if (widget.initialQuery?.trim().isNotEmpty == true) {
      _search.text = widget.initialQuery!.trim();
      _type = _MusicSearch.songs;
      await _submit();
    }
  }

  Future<void> _run(Future<void> Function(int, AppState) operation,
      Future<void> Function() retry,
      {bool browse = false}) async {
    final session = context.read<AppCubit>().state;
    if (!_sameSession(session)) return;
    final generation = ++_generation;
    setState(() {
      // Back must restore the source even while the destination is loading
      // or showing its retry action.
      if (browse && (_collection != null || _artistPage != null)) {
        _browseHistory.add((
          collection: _collection,
          artist: _artistPage,
          releases: _artistReleases,
        ));
        _collection = null;
        _artistPage = null;
        _artistReleases = null;
      }
      _loading = true;
      _browseRequest = browse;
      _retryingSong = false;
      _failure = null;
      _retry = retry;
    });
    try {
      await operation(generation, session);
    } catch (error) {
      if (_active(generation, session)) {
        setState(() => _failure = error);
      }
    } finally {
      if (_active(generation, session)) {
        setState(() {
          _loading = false;
          _retryingSong = false;
        });
      }
    }
  }

  Future<void> _submit({bool learn = false, String? retryQuery}) async {
    final query = retryQuery ?? _search.text.trim();
    if (query.isEmpty) return;
    final app = context.read<AppCubit>();
    final session = app.state;
    if (!_sameSession(session)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (learn && ContentLink.completeWebAddress(query) != null) {
      if (!isPastedLinkSourceActive(context)) return;
      final generation = _generation;
      bool current() =>
          _active(generation, session) &&
          _search.text.trim() == query &&
          isPastedLinkSourceActive(context);
      final action = await app.submitPastedAppLink(query,
          music: true,
          chooseOpen: () => choosePastedLinkAction(context),
          isCurrent: current);
      if (!current() || action == PastedLinkAction.handled) return;
      if (action == PastedLinkAction.searchAsText) learn = false;
    }
    // Only an explicit text-field/button submission is a preference signal.
    // Initial routes, filter changes and retries reuse the query without
    // treating it as another search by the person.
    if (learn) unawaited(_learnSearch(query, session));
    final type = _type;
    setState(() {
      _searched = true;
      _submittedQuery = query;
      _showCommunityHidden = false;
      _collection = null;
      _artistPage = null;
      _artistReleases = null;
      _browseHistory.clear();
      _songs = [];
      _artists = [];
      _playlists = [];
    });
    await _run((generation, session) async {
      if (type == _MusicSearch.songs) {
        final songs = await musicCatalogService.searchSongs(query);
        if (_active(generation, session)) setState(() => _songs = songs);
      } else if (type == _MusicSearch.artists) {
        final artists = await musicCatalogService.searchArtists(query);
        if (_active(generation, session)) setState(() => _artists = artists);
      } else {
        final playlists = await musicCatalogService.searchPlaylists(query);
        if (_active(generation, session)) {
          setState(() => _playlists = playlists);
        }
      }
    }, () => _submit(retryQuery: query));
  }

  Future<void> _learnSearch(String query, AppState session) async {
    final recommendations =
        RecommendationService.forProfile(db, session.profileId);
    try {
      await recommendations.recordSearch(query, RecommendationDomain.music);
    } catch (_) {
      if (mounted && _sameSession(session)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.recommendationError)));
      }
    }
  }

  Future<void> _openCollection(String id) async {
    await _run((generation, session) async {
      final collection = await musicCatalogService.getPlaylist(id);
      if (_active(generation, session)) {
        setState(() => _collection = collection);
      }
    }, () => _openCollection(id), browse: true);
  }

  Future<void> _openArtist(String id) async {
    if (!_loading && _artistPage?.artist.id == id) return;
    await _run((generation, session) async {
      final artist = await musicCatalogService.getArtist(id);
      if (_active(generation, session)) {
        final releases = _ArtistReleaseListing();
        setState(() {
          _artistPage = artist;
          _artistReleases = releases;
        });
        unawaited(_loadArtistReleases(artist.artist.id, releases, session));
      }
    }, () => _openArtist(id), browse: true);
  }

  Future<void> _loadArtistReleases(
      String artistId, _ArtistReleaseListing listing, AppState session) async {
    bool current() =>
        _sameSession(session) &&
        (identical(_artistReleases, listing) ||
            _browseHistory.any((page) => identical(page.releases, listing)));
    if (!current() || listing.loading) return;
    if (_artistReleaseCooldown != null) {
      setState(() => listing.failed = true);
      return;
    }
    setState(() {
      listing.loading = true;
      listing.failed = false;
    });
    final continuation = listing.continuation;
    try {
      final page = await musicCatalogService.getArtistReleases(artistId,
          continuation: continuation, isCurrent: current);
      if (!current()) return;
      for (final release in page.releases) {
        listing.releases.putIfAbsent(release.id, () => release);
      }
      if (continuation != null) {
        listing.requestedContinuations.add(continuation);
      }
      listing.continuation =
          listing.requestedContinuations.contains(page.continuation)
              ? null
              : page.continuation;
    } on MusicCatalogUnsupported {
      listing.continuation = null;
    } catch (error) {
      if (!current()) return;
      listing.failed = true;
      final delay = error is InvidiousServiceError ? error.retryAfter : null;
      if (delay != null && delay > Duration.zero) {
        _artistReleaseCooldown?.cancel();
        _artistReleaseCooldown = Timer(delay, () {
          if (mounted) setState(() => _artistReleaseCooldown = null);
        });
      }
    } finally {
      listing.loading = false;
      if (current() &&
          (identical(_artistReleases, listing) ||
              _artistReleaseCooldown != null)) {
        setState(() {});
      }
    }
  }

  Future<void> _openSong(String id, {Duration startAt = Duration.zero}) async {
    final route = ModalRoute.of(context);
    await _run((generation, session) async {
      final owner = db;
      bool current() {
        if (!identical(owner, db) ||
            owner.profileId != session.profileId ||
            !_active(generation, session) ||
            _abandonedSongRequest == generation) {
          return false;
        }
        if (route == null || route.isCurrent) return true;
        if (!route.isFirst) _abandonedSongRequest = generation;
        return false;
      }

      try {
        unawaited(context
            .read<PlayerCubit>()
            .prepareSponsorSegments(id)
            .onError((_, stackTrace) => []));
      } catch (_) {
        // Optional SponsorBlock work must not delay a song link.
      }
      final saved = await prepareDownloadedPlaybackVideo(
          database: owner,
          video: Video(videoId: id),
          server: session.server,
          audioOnly: true,
          isCurrent: current);
      if (!current()) return;
      final selected =
          session.server ?? saved?.playbackConnection?.preferredServer;
      final savedMusic = saved?.musicMetadata;
      final song = savedMusic != null &&
              selected != null &&
              saved?.playbackConnection?.matches(selected) == true
          ? _savedSong(saved!, current)
          : await musicCatalogService.getSong(id,
              loadObserver: VideoLoadObserver(
                  isCurrent: current,
                  onRetry: () {
                    if (current()) setState(() => _retryingSong = true);
                  }));
      if (!current()) return;
      setState(() {
        _retryingSong = false;
        _resolvedSong = song;
      });
      final metadata = song.toVideo();
      final loaded = song.playbackVideo;
      final resolved = loaded != null && loaded.videoId == song.videoId
          ? loaded.preservingMusicMetadataFrom(metadata)
          : metadata;
      final index = widget.startIndex;
      final fromShelf = index >= 0 &&
          index < widget.queue.length &&
          widget.queue[index].videoId == song.videoId;
      final videos = fromShelf
          ? widget.queue.map(MusicScreen._songEntry).toList()
          : [resolved];
      if (fromShelf) {
        videos[index] =
            resolved.copyWith(queueEntryId: videos[index].queueEntryId);
      }
      await _playVideos(videos,
          startIndex: fromShelf ? index : null,
          startAt: startAt,
          songLauncher: route);
    }, () => _openSong(id, startAt: startAt));
  }

  MusicTrack _savedSong(Video saved, bool Function() isCurrent) {
    final music = saved.musicMetadata!;
    var artwork = songCovers(music.thumbnails);
    var credits = music.artistCredits;
    void useMatchingCredits(List<MusicArtistCredit> candidate) {
      if (!credits.any((credit) => credit.id != null) &&
          candidate.any((credit) => credit.id != null) &&
          candidate.artistNames.join(', ') == music.artist) {
        credits = candidate;
      }
    }

    useMatchingCredits(widget.artistCredits);
    if (artwork.isEmpty || !credits.any((credit) => credit.id != null)) {
      try {
        final cached = RecommendationCandidates(db, isCurrent: isCurrent)
            .localMusic(ids: {saved.videoId}, limit: 1).firstOrNull;
        if (artwork.isEmpty && cached != null) artwork = cached.thumbnails;
        if (cached != null) useMatchingCredits(cached.artistCredits);
        // A legacy bookmark can take precedence over a newer matched listen.
        if (!credits.any((credit) => credit.id != null)) {
          useMatchingCredits(db
                  .getHistoryVideoByVideoId(saved.videoId)
                  ?.musicMetadata
                  ?.artistCredits ??
              const []);
        }
      } catch (_) {
        // Optional catalog labels never prevent playback of an admitted file.
      }
    }
    return MusicTrack(
        videoId: saved.videoId,
        title: music.title,
        artists: [music.artist],
        artistCredits: credits,
        uploaderChannelUrl: saved.authorUrl,
        albumTitle: music.album,
        durationSeconds: saved.lengthSeconds,
        isArtTrack: music.isArtTrack,
        thumbnails: artwork,
        videoThumbnails: saved.videoThumbnails,
        playbackVideo: saved);
  }

  Future<void> _play(List<MusicTrack> tracks,
          {PlaylistReference? reference,
          int? startIndex,
          Duration startAt = Duration.zero}) =>
      _playVideos(tracks.map((track) => track.toVideo()).toList(),
          reference: reference, startIndex: startIndex, startAt: startAt);

  Future<void> _playVideos(List<Video> videos,
      {PlaylistReference? reference,
      int? startIndex,
      Duration startAt = Duration.zero,
      ModalRoute<dynamic>? songLauncher}) async {
    final session = context.read<AppCubit>().state;
    if (videos.isEmpty || !_sameSession(session)) return;
    if (songLauncher != null && isTv) {
      // This route owns the TV player and returns directly to its caller.
      setState(() => _tvSong =
          (videos: videos, startIndex: startIndex ?? 0, startAt: startAt));
      return;
    }
    final request = ++_playRequest;
    final generation = _generation;
    bool current() => request == _playRequest && _active(generation, session);
    try {
      await MusicScreen._playTracks(context, videos,
          reference: reference,
          startIndex: startIndex,
          startAt: startAt,
          songLauncher: songLauncher,
          isCurrent: current);
    } catch (_) {
      if (!mounted || !current() || ModalRoute.isCurrentOf(context) == false) {
        return;
      }
      if (songLauncher != null) rethrow;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
    }
  }

  void _backToSearch() {
    _generation++;
    setState(() {
      if (_browseHistory.isNotEmpty) {
        final previous = _browseHistory.removeLast();
        _collection = previous.collection;
        _artistPage = previous.artist;
        _artistReleases = previous.releases;
      } else {
        _collection = null;
        _artistPage = null;
        _artistReleases = null;
      }
      _loading = false;
      _browseRequest = false;
      _retryingSong = false;
      _failure = null;
      _retry = null;
    });
  }

  Future<void> _resumeListening() async {
    final session = context.read<AppCubit>().state;
    if (_starting || !_sameSession(session)) return;
    final player = context.read<PlayerCubit>();
    final saved = player.savedSession;
    if (saved == null) return;
    setState(() => _starting = true);
    try {
      if (isTv) {
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) =>
                _MusicTvPlayer(videos: saved.videos, resumeSession: true)));
      } else {
        await player.resumeSession(fromMusic: true);
      }
    } catch (_) {
      if (!mounted) return;
      if (_sameSession(session)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    } finally {
      if (_sameSession(session)) setState(() => _starting = false);
    }
  }

  Widget _resumeAction() =>
      BlocBuilder<PlayerCubit, PlayerState>(builder: (context, state) {
        final player = context.read<PlayerCubit>();
        final locals = AppLocalizations.of(context)!;
        final activeMusic = !state.isHidden &&
            state.isAudio &&
            (state.currentlyPlaying?.musicMetadata != null ||
                state.offlineCurrentlyPlaying?.musicMetadata != null);
        if (activeMusic && !isTv) {
          return TextButton.icon(
              key: const ValueKey('music-now-playing'),
              onPressed: player.showBigPlayer,
              icon: const Icon(Icons.graphic_eq),
              label: Text(locals.musicNowPlaying));
        }
        final saved = player.savedSession;
        if (saved == null ||
            !saved.audio ||
            (!state.isHidden && state.hasVideo)) {
          return const SizedBox.shrink();
        }
        final resume = TextButton.icon(
            key: const ValueKey('music-resume'),
            onPressed: _starting ? null : _resumeListening,
            icon: const Icon(Icons.play_arrow),
            label: Text(locals.musicResume));
        if (saved.offlineIds.contains(saved.currentId)) {
          if (isLocalMusicPlaybackId(saved.currentId)) {
            final library = LocalMusicLibrary.instance;
            unawaited(library.initialize());
            return ListenableBuilder(
                listenable: library,
                builder: (context, _) => library
                            .acceptsSessionSelection(saved.localSelectionId) &&
                        (!library.loaded ||
                            localMusicTrackForPlayback(saved.currentId) != null)
                    ? resume
                    : const SizedBox.shrink());
          }
          final offline = db.getDownloadByVideoId(saved.currentId);
          if (offline?.downloadComplete == true &&
              offline?.musicMetadata != null) {
            return resume;
          }
        }
        return saved.videos.any((video) =>
                playbackQueueId(video) == saved.currentId &&
                video.musicMetadata != null)
            ? resume
            : const SizedBox.shrink();
      });

  Widget _artwork(List<ImageObject> images) => SizedBox.square(
      dimension: 56,
      child: images.isEmpty
          ? const Icon(Icons.music_note)
          : Thumbnail(
              images: images,
              instanceOnly: true,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
            ));

  Widget _artistByline(List<String> names, List<MusicArtistCredit> credits) {
    if (!credits.any((credit) => credit.id != null)) {
      return Text(names.join(', '),
          maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        for (final credit in credits)
          if (credit.id case final id?)
            TextButton(
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                onPressed: () => _openArtist(id),
                child: Text(credit.name))
          else
            Text(credit.name),
      ],
    );
  }

  Widget _song(List<MusicTrack> queue, int index,
      {bool numbered = true,
      PlaylistReference? reference,
      List<CommunityMatch> matches = const []}) {
    final track = queue[index];
    final row = numbered ? '$index' : 'search-$index';
    Future<void> play() =>
        _play(queue, reference: reference, startIndex: index);
    return ListTile(
      key: ValueKey('music-song-$row-${track.videoId}'),
      leading: !numbered
          ? SizedBox.square(
              dimension: 56,
              child: CommunityMusicArtwork(
                  videoId: track.videoId,
                  music: track.musicMetadata,
                  durationSeconds: track.durationSeconds,
                  fallback: _artwork(track.displayThumbnails)),
            )
          : SizedBox.square(
              dimension: 36,
              child: Stack(fit: StackFit.expand, children: [
                Center(child: Text('${index + 1}')),
                VideoWatchProgress(videoId: track.videoId),
              ])),
      title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _artistByline(track.artists, track.artistCredits),
          if (!numbered && track.albumTitle != null)
            Text(track.albumTitle!,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          if (matches.isNotEmpty) CommunityMatchLabels(matches: matches),
        ],
      ),
      trailing: MusicLibraryActions(videos: [track.toVideo()], onPlay: play),
      onLongPress: () => MusicLibraryActions.showSongMenu(
          context, track.toVideo(),
          onPlay: play),
      onTap: play,
    );
  }

  Widget _results() {
    final locals = AppLocalizations.of(context)!;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failure != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.musicCatalogError, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: Text(locals.retry)),
          ]),
        ),
      );
    }
    final collection = _collection;
    if (collection != null) return _collectionResults(collection);
    final artistPage = _artistPage;
    if (artistPage != null) return _artistResults(artistPage);
    if (!_searched) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.musicInvidiousSearchStart, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(locals.musicInvidiousConnection,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
    }
    if (_type == _MusicSearch.songs) {
      if (_songs.isEmpty) return Center(child: Text(locals.musicNoResults));
      return ListenableBuilder(
        listenable: communityFilters.changes,
        builder: (_, __) {
          final results =
              musicTrackResults(_songs, showHidden: _showCommunityHidden);
          final queue = [for (final (track, _) in results.visible) track];
          final hasNotice = results.hidden > 0;
          return ListView.builder(
            itemCount: results.visible.length + (hasNotice ? 1 : 0),
            itemBuilder: (_, index) {
              if (hasNotice && index == 0) {
                return CommunityHiddenNotice(
                  count: results.hidden,
                  showing: _showCommunityHidden,
                  onToggle: () => setState(
                      () => _showCommunityHidden = !_showCommunityHidden),
                );
              }
              final trackIndex = index - (hasNotice ? 1 : 0);
              return _song(queue, trackIndex,
                  numbered: false, matches: results.visible[trackIndex].$2);
            },
          );
        },
      );
    }
    if (_type == _MusicSearch.artists) {
      if (_artists.isEmpty) return Center(child: Text(locals.musicNoResults));
      return ListView.builder(
          itemCount: _artists.length,
          itemBuilder: (_, index) {
            final artist = _artists[index];
            return ListTile(
                leading: ChannelAvatar(
                    name: artist.name,
                    images: artist.thumbnails,
                    size: 56,
                    instanceOnly: true),
                title: Text(artist.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openArtist(artist.id));
          });
    }
    if (_playlists.isEmpty) return Center(child: Text(locals.musicNoResults));
    return ListView.builder(
        itemCount: _playlists.length,
        itemBuilder: (_, index) {
          final playlist = _playlists[index];
          return ListTile(
              leading: _artwork(playlist.thumbnails),
              title: Text(playlist.title),
              subtitle: playlist.author == null ? null : Text(playlist.author!),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openCollection(playlist.id));
        });
  }

  Widget _collectionResults(MusicCollection collection) {
    final locals = AppLocalizations.of(context)!;
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: collection.id,
        profileId: db.profileId);
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _artwork(collection.thumbnails),
          const SizedBox(height: 12),
          Text(collection.title, style: Theme.of(context).textTheme.titleLarge),
          _artistByline(
              collection.artists,
              MusicArtistCredit.fromCatalog(
                  collection.artists, collection.artistLinks)),
          PlaylistInformation(
              playlist: Playlist(
                  title: collection.title,
                  playlistId: collection.id,
                  author: collection.artists.join(', '),
                  videoCount: collection.videoCount ?? collection.tracks.length,
                  updated: collection.updated,
                  videos: collection.tracks
                      .map((track) => track.toVideo())
                      .toList()),
              reference: reference,
              enabled: !_starting),
          const SizedBox(height: 12),
          FilledButton.icon(
              key: const ValueKey('music-play-all'),
              onPressed: collection.tracks.isEmpty
                  ? null
                  : () => _play(collection.tracks, reference: reference),
              icon: const Icon(Icons.play_arrow),
              label: Text(locals.musicPlayAll)),
          MusicPlaylistResume(
              reference: reference,
              videos:
                  collection.tracks.map((track) => track.toVideo()).toList(),
              enabled: !_starting,
              onPlay: (index, position) => _play(collection.tracks,
                  reference: reference, startIndex: index, startAt: position)),
          const SizedBox(height: 8),
          MusicBookmarkButton(
              entry: MusicLibraryEntry.collection(collection, album: false)),
          MusicLibraryActions(
              videos:
                  collection.tracks.map((track) => track.toVideo()).toList(),
              compact: false),
        ]),
      ),
      if (collection.tracks.isEmpty)
        Padding(
            padding: const EdgeInsets.all(24),
            child: Text(locals.musicEmptyCollection)),
      for (var i = 0; i < collection.tracks.length; i++)
        _song(collection.tracks, i, reference: reference),
    ]);
  }

  Widget _artistResults(MusicArtistPage artistPage) {
    final locals = AppLocalizations.of(context)!;
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ChannelAvatar(
              name: artistPage.artist.name,
              instanceOnly: true,
              images: artistPage.artist.thumbnails,
              size: 56),
          const SizedBox(height: 12),
          Text(artistPage.artist.name,
              style: Theme.of(context).textTheme.titleLarge),
          MusicBookmarkButton(
              entry: MusicLibraryEntry.artist(artistPage.artist)),
          if (artistPage.description case final String description)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(description,
                  maxLines: 6, overflow: TextOverflow.ellipsis),
            ),
        ]),
      ),
      if (_artistReleases case final listing?)
        ..._artistReleaseTiles(artistPage.artist.id, listing),
      if (artistPage.songs.isNotEmpty) ...[
        _sectionTitle(locals.musicChannelUploads),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
                key: const ValueKey('music-play-artist-songs'),
                onPressed: () => _play(artistPage.songs),
                icon: const Icon(Icons.play_arrow),
                label: Text(locals.musicPlayAll)),
          ),
        ),
        for (var i = 0; i < artistPage.songs.length; i++)
          _song(artistPage.songs, i),
      ],
      if (artistPage.songs.isEmpty)
        Padding(
            padding: const EdgeInsets.all(24),
            child: Text(locals.musicArtistEmpty)),
    ]);
  }

  List<Widget> _artistReleaseTiles(
      String artistId, _ArtistReleaseListing listing) {
    final locals = AppLocalizations.of(context)!;
    final canLoad = listing.failed || listing.continuation != null;
    if (listing.releases.isEmpty && !listing.loading && !canLoad) return [];
    return [
      _sectionTitle(locals.musicArtistReleases),
      for (final release in listing.releases.values)
        ListTile(
          key: ValueKey('music-release-${release.id}'),
          leading: release.thumbnails.isEmpty
              ? const SizedBox.square(
                  dimension: 48, child: Icon(Icons.album_outlined))
              : Thumbnail(
                  width: 48,
                  height: 48,
                  instanceOnly: true,
                  images: release.thumbnails,
                  decoration:
                      BoxDecoration(borderRadius: BorderRadius.circular(6)),
                  fallback: const Icon(Icons.album_outlined),
                ),
          title: Text(release.title),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openCollection(release.id),
        ),
      if (listing.loading)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: SizedBox.square(
              dimension: 24,
              child: MotionLoadingIndicator(child: CircularProgressIndicator()),
            ),
          ),
        )
      else if (canLoad)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton(
              onPressed: _artistReleaseCooldown == null
                  ? () => _loadArtistReleases(
                      artistId, listing, context.read<AppCubit>().state)
                  : null,
              child: Text(listing.failed ? locals.retry : locals.loadMore),
            ),
          ),
        ),
    ];
  }

  Widget _sectionTitle(String title) => Padding(
      padding: const EdgeInsets.all(16),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));

  String _searchLabel(_MusicSearch search, AppLocalizations locals) =>
      switch (search) {
        _MusicSearch.songs => locals.musicSongs,
        _MusicSearch.artists => locals.channels,
        _MusicSearch.playlists => locals.musicPlaylists,
      };

  @override
  Widget build(BuildContext context) {
    // A newer page can cover a launcher during lookup. Wait until that page
    // leaves before dismissing the abandoned launcher, so its Back destination
    // is the original browsing screen and its own navigation stays intact.
    if (widget.videoId != null && widget.playlistId == null) {
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        if (!route.isCurrent && _loading && _resolvedSong == null) {
          _abandonedSongRequest = _generation;
        } else if (route.isCurrent && _abandonedSongRequest == _generation) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                _abandonedSongRequest == _generation &&
                route.isCurrent &&
                !route.isFirst) {
              _abandonedSongRequest = null;
              route.navigator!.pop();
            }
          });
        }
      }
    }
    return BlocListener<AppCubit, AppState>(
      listenWhen: (before, after) =>
          before.profileId != after.profileId ||
          before.sessionRevision != after.sessionRevision ||
          before.server != after.server ||
          (!before.globalLoading && after.globalLoading) ||
          (!before.sessionRecoveryRequired && after.sessionRecoveryRequired),
      listener: (context, state) => _clearForSession(),
      child: switch (_tvSong) {
        final song? => _MusicTvPlayer(
            videos: song.videos,
            startIndex: song.startIndex,
            startAt: song.startAt),
        null when widget.videoId != null && widget.playlistId == null =>
          _openingPlayer(context),
        null => _browser(context),
      },
    );
  }

  Widget _openingPlayer(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final song = _resolvedSong;
    final retry = _retry;
    final Widget body;
    if (_loading) {
      body = _retryingSong
          ? const VideoRetryNotice()
          : const CircularProgressIndicator();
    } else if (_failure != null && retry != null) {
      body = _MusicPlaybackFailure(onRetry: retry);
    } else if (song != null) {
      // The expanded player normally owns the screen by now. An interrupted
      // queue admission can be tried again without leaving the song.
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(song.title, textAlign: TextAlign.center),
        if (song.artists.isNotEmpty)
          Text(song.artists.join(', '), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(
            autofocus: isTv,
            onPressed: () {
              final player = context.read<PlayerCubit>();
              if (!player.state.isHidden &&
                  player.state.isAudio &&
                  player.state.currentlyPlaying?.videoId == song.videoId) {
                player.showBigPlayer();
              } else {
                retry?.call();
              }
            },
            icon: const Icon(Icons.play_arrow),
            label: Text(locals.musicPlay)),
      ]);
    } else {
      body = Text(locals.musicPlaybackError, textAlign: TextAlign.center);
    }
    return MusicPlayerOpening(
      onBack: ModalRoute.of(context)?.canPop == true
          ? () => Navigator.of(context).maybePop()
          : null,
      child: body,
    );
  }

  Widget _browser(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final searchOutline = OutlineInputBorder(
        borderRadius: BorderRadius.circular(32), borderSide: BorderSide.none);
    return PopScope(
      canPop: !TickerMode.of(context) ||
          (_shortcutBack == null && (!_hasBrowsePage || _returnToOrigin)),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !TickerMode.of(context)) return;
        if (_hasBrowsePage && !_returnToOrigin) {
          _backToSearch();
        } else {
          _shortcutBack?.call();
        }
      },
      child: Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: Scaffold(
          appBar: widget.embedded && !_hasBrowsePage
              ? null
              : AppBar(
                  title: Text(locals.music),
                  leading: !_hasBrowsePage
                      ? null
                      : IconButton(
                          tooltip: _browseHistory.isEmpty && !_returnToOrigin
                              ? locals.musicBackToSearch
                              : MaterialLocalizations.of(context)
                                  .backButtonTooltip,
                          onPressed: () {
                            if (_returnToOrigin) {
                              Navigator.of(context).maybePop();
                            } else {
                              _backToSearch();
                            }
                          },
                          icon: const Icon(Icons.arrow_back)),
                ),
          body: SafeArea(
            child: Padding(
              padding: isTv
                  ? EdgeInsets.symmetric(
                      horizontal: TvOverscan.horizontal,
                      vertical: TvOverscan.vertical)
                  : EdgeInsets.zero,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: TextField(
                    key: const ValueKey('music-search'),
                    controller: _search,
                    focusNode: _queryFocus,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _submit(learn: true),
                    decoration: InputDecoration(
                        hintText: locals.musicInvidiousSearchHint,
                        filled: true,
                        fillColor: colors.surfaceContainerHigh,
                        border: searchOutline,
                        focusedBorder: searchOutline.copyWith(
                            borderSide: BorderSide(color: colors.primary)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        suffixIcon: IconButton(
                            autofocus: isTv,
                            tooltip: locals.search,
                            onPressed: () => _submit(learn: true),
                            icon: const Icon(Icons.search))),
                  ),
                ),
                if (isTv)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _resumeAction()),
                  )
                else
                  _resumeAction(),
                if (!_hasBrowsePage)
                  SingleChildScrollView(
                    key: const ValueKey('music-search-filters'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      for (final type in _MusicSearch.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                              label: Text(_searchLabel(type, locals)),
                              selected: _type == type,
                              backgroundColor: colors.surfaceContainerHigh,
                              selectedColor: colors.secondaryContainer,
                              side: BorderSide.none,
                              shape: const StadiumBorder(),
                              showCheckmark: false,
                              onSelected: (_) {
                                if (_type == type) return;
                                setState(() => _type = type);
                                // A pasted address needs a submission before
                                // changing result types can search its text.
                                final query = _search.text.trim();
                                if (query.isNotEmpty &&
                                    (query == _submittedQuery ||
                                        ContentLink.completeWebAddress(query) ==
                                            null)) {
                                  _submit();
                                }
                              }),
                        ),
                    ]),
                  ),
                const SizedBox(height: 8),
                Expanded(child: _results()),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keep TV audio mounted under the artist page. Choosing a track reuses its
/// player and returns to it, just as Back does after browsing.
class _TvPlayingArtistRoute extends MaterialPageRoute<void> {
  _TvPlayingArtistRoute(String artistId, PlayerCubit player)
      : super(
            builder: (_) => BlocProvider.value(
                value: player, child: MusicScreen(artistId: artistId)));
}

/// TV routes own their player, as the TV home does not mount the phone player.
class _MusicTvPlayer extends StatelessWidget {
  final List<Video> videos;
  final List<LocalMusicTrack>? localTracks;
  final bool resumeSession;
  final PlaylistReference? reference;
  final int startIndex;
  final Duration startAt;

  const _MusicTvPlayer(
      {required this.videos,
      this.localTracks,
      this.resumeSession = false,
      this.reference,
      this.startIndex = 0,
      this.startAt = Duration.zero});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => PlayerCubit(
          PlayerState.init(resumeSession ? null : videos).copyWith(
              isAudio: true, isMini: false, isHidden: false, startAt: startAt),
          context.read<SettingsCubit>(),
          resume: resumeSession,
          fromMusic: true,
          initialLocalMusic: localTracks,
          playlistReference: reference,
          startIndex: startIndex,
          playlistAudio: true),
      child: MusicSelectionFeedback(
          child: Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: Scaffold(
          appBar: AppBar(title: Text(AppLocalizations.of(context)!.music)),
          body: SafeArea(
            child: BlocBuilder<PlayerCubit, PlayerState>(
              builder: (context, state) {
                final player = context.read<PlayerCubit>();
                final tracks = localTracks;
                if (state.offlineCurrentlyPlaying == null &&
                    (tracks != null ||
                        resumeSession &&
                            isLocalMusicPlaybackId(
                                player.savedSession?.currentId))) {
                  if (state.isClosing ||
                      state.mediaEvent.state == MediaState.error) {
                    return _MusicPlaybackFailure(
                        onRetry: tracks == null
                            ? player.resumeSession
                            : () => player.playLocalMusic(tracks,
                                startIndex: startIndex));
                  }
                  return const Center(child: CircularProgressIndicator());
                }
                if (state.isClosing ||
                    (state.videos.isEmpty && state.offlineVideos.isEmpty)) {
                  return _MusicPlaybackFailure(
                      onRetry: resumeSession
                          ? player.resumeSession
                          : () => reference == null
                              ? player.playVideo(videos,
                                  fromMusic: true,
                                  audio: true,
                                  startAt: startAt,
                                  startIndex: startIndex)
                              : player.playPlaylist(videos,
                                  fromMusic: true,
                                  reference: reference!,
                                  startIndex: startIndex,
                                  audio: true,
                                  startAt: startAt));
                }
                if (state.currentlyPlaying == null &&
                    state.offlineCurrentlyPlaying == null) {
                  return PlayerRetryIndicator.visibleFor(state)
                      ? const PlayerRetryIndicator()
                      : const Center(child: CircularProgressIndicator());
                }
                return Stack(
                  fit: StackFit.passthrough,
                  children: [
                    _MusicTvAudio(
                        video: state.currentlyPlaying,
                        offlineVideo: state.offlineCurrentlyPlaying),
                    const Positioned.fill(child: PlayerRetryIndicator()),
                  ],
                );
              },
            ),
          ),
        ),
      )),
    );
  }
}

class _MusicPlaybackFailure extends StatelessWidget {
  final VoidCallback onRetry;

  const _MusicPlaybackFailure({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(locals.musicPlaybackError, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton.icon(
            autofocus: true,
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(locals.retry)),
      ]),
    );
  }
}

/// Keep the decoder mounted while Music and its queue change presentation.
class _MusicTvAudio extends StatelessWidget {
  final Video? video;
  final DownloadedVideo? offlineVideo;

  const _MusicTvAudio({this.video, this.offlineVideo});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final locals = AppLocalizations.of(context)!;
    return BlocProvider(
      create: (_) => AudioPlayerCubit(
          AudioPlayerState(video: video, offlineVideo: offlineVideo),
          player,
          context.read<SettingsCubit>()),
      child: BlocListener<PlayerCubit, PlayerState>(
        listenWhen: (before, after) =>
            before.mediaCommand != after.mediaCommand &&
            after.mediaCommand != null,
        listener: (context, state) =>
            context.read<AudioPlayerCubit>().handleCommand(state.mediaCommand!),
        child: BlocBuilder<AudioPlayerCubit, AudioPlayerState>(
          builder: (context, audio) {
            final state = context.watch<PlayerCubit>().state;
            final current = state.currentlyPlaying ?? video;
            final offline = state.offlineCurrentlyPlaying ?? offlineVideo;
            final metadata = current?.musicMetadata ?? offline?.musicMetadata;
            final musicImages = metadata?.thumbnails ?? const <ImageObject>[];
            if (audio.error != null ||
                state.mediaEvent.state == MediaState.error) {
              return _MusicPlaybackFailure(
                  onRetry: current == null && offline == null
                      ? player.resumeSession
                      : player.retryCurrentVideo);
            }
            if ((state.currentlyPlaying?.musicMetadata ??
                    state.offlineCurrentlyPlaying?.musicMetadata) !=
                null) {
              return const TvOverscan(child: MusicPlayer(television: true));
            }
            // The TV video route also hosts Listen mode for ordinary videos.
            // Its simpler transport works without inventing Music metadata.
            return Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: TvOverscan.horizontal,
                  vertical: TvOverscan.vertical),
              child: Column(children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: offline != null
                          ? OfflineVideoThumbnail(
                              borderRadius: 16, video: offline)
                          : Thumbnail(
                              images: musicImages.isNotEmpty
                                  ? musicImages
                                  : current?.videoThumbnails,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16))),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(metadata?.title ?? current?.title ?? offline?.title ?? '',
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge),
                Text(
                    metadata?.artist ??
                        current?.author ??
                        offline?.author ??
                        '',
                    maxLines: 1),
                if (metadata?.album case final String album)
                  Text(album, maxLines: 1),
                const MusicSponsorNotice(),
                if (audio.loading) const LinearProgressIndicator(),
                if (state.backendRecovery case final recovery?)
                  BackendRecoveryNotice(recovery: recovery, compact: true),
                const PlaylistLoadingNotice(),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                      tooltip: locals.musicPrevious,
                      onPressed: state.hasQueue ? player.playPrevious : null,
                      icon: const Icon(Icons.skip_previous)),
                  IconButton(
                      tooltip: locals.musicRewind,
                      onPressed: player.rewind,
                      icon: const Icon(Icons.fast_rewind)),
                  IconButton.filled(
                      autofocus: true,
                      tooltip: state.isPlaying
                          ? locals.musicPause
                          : locals.musicPlay,
                      onPressed: player.togglePlaying,
                      icon: Icon(
                          state.isPlaying ? Icons.pause : Icons.play_arrow)),
                  IconButton(
                      tooltip: locals.musicForward,
                      onPressed: player.fastForward,
                      icon: const Icon(Icons.fast_forward)),
                  IconButton(
                      tooltip: locals.musicNext,
                      onPressed: state.hasQueue ? player.playNext : null,
                      icon: const Icon(Icons.skip_next)),
                ]),
                TextButton.icon(
                    key: const ValueKey('music-tv-sound'),
                    onPressed: () => showMusicSoundSheet(context, player),
                    icon: const Icon(Icons.tune),
                    label: Text(locals.musicSound)),
              ]),
            );
          },
        ),
      ),
    );
  }
}
