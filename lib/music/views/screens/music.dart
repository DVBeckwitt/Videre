import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/app_languages.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_collection_order.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/music_song_tap_queue_scope.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_search.dart';
import 'package:clipious/music/services/music_online_recents.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_catalog_description.dart';
import 'package:clipious/music/views/components/music_collection_panes.dart';
import 'package:clipious/music/views/components/music_collection_sort_menu.dart';
import 'package:clipious/music/views/components/music_fast_scroll.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_song_row_swipe.dart';
import 'package:clipious/music/views/components/music_library_search_results.dart';
import 'package:clipious/music/views/components/music_online_recents_button.dart';
import 'package:clipious/music/views/components/music_player.dart';
import 'package:clipious/music/views/components/music_screen_privacy.dart';
import 'package:clipious/music/views/components/music_selection_feedback.dart';
import 'package:clipious/music/views/components/music_playlist_recommendation_toggle.dart';
import 'package:clipious/music/views/components/music_playlist_resume.dart';
import 'package:clipious/music/views/components/music_sponsor_notice.dart';
import 'package:clipious/music/views/components/music_sound_sheet.dart';
import 'package:clipious/music/views/components/music_status_title.dart';
import 'package:clipious/music/views/components/music_track_results.dart';
import 'package:clipious/network/content_link.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/video_retry_notice.dart';
import 'package:clipious/player/views/components/playlist_loading_notice.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/views/components/playlist_information.dart';
import 'package:clipious/recommendations/candidate_sources.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/router.dart';
import 'package:clipious/search/views/components/pasted_link_dialog.dart';
import 'package:clipious/search/views/components/search_suggestions_panel.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;
import 'package:clipious/settings/models/db/settings.dart' show browsingCountry;
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import '../../models/music_layout.dart';
import 'package:clipious/utils.dart' show DeviceType, getDeviceType;
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
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

enum _MusicSearchSource { online, library }

final _musicLog = Logger('MusicScreen');

String? get _searchCountry => db.getSettings(browsingCountry)?.value;

class _OnlineSearchListing {
  _OnlineSearchListing(this.query, this.type, {required this.paginated})
      : country = _searchCountry,
        proxy = NetworkProxy.instance.config;

  final String query;
  final MusicCatalogSearchType type;
  final bool paginated;
  final String? country;
  final SocksProxyConfig proxy;
  final hits = <MusicCatalogSearchHit>[];
  final _seenHits = <String>{};
  final _seenRaw = <String>{};
  int nextPage = 1;
  int _unidentifiedPages = 0;
  bool hasMore = true;
  bool failed = false;
  Object? pending;

  bool get connectionCurrent =>
      country == _searchCountry &&
      !NetworkProxy.instance.isChanging &&
      identical(proxy, NetworkProxy.instance.config);

  void accept(MusicCatalogSearchPage page) {
    hits.addAll(paginated
        ? page.hits.where((hit) => _seenHits.add(hit.key))
        : page.hits);
    final rawSize = _seenRaw.length;
    _seenRaw.addAll(page.rawKeys);
    final madeProgress = _seenRaw.length > rawSize;
    // A raw page can consist entirely of entries without usable identities.
    // Permit those pages to advance, but bound a stream of unprovable progress.
    _unidentifiedPages = page.rawKeys.isEmpty ? _unidentifiedPages + 1 : 0;
    hasMore = hasMore &&
        page.rawCount > 0 &&
        (madeProgress || (page.rawKeys.isEmpty && _unidentifiedPages < 3));
    nextPage++;
    failed = false;
  }
}

class _ArtistReleaseListing {
  _ArtistReleaseListing(MusicArtistPage page) : uploads = page.songs;

  List<MusicTrack> uploads;
  bool uploadsLoading = false;
  bool uploadsFailed = false;
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
  final String? queueTitle;
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
      this.queueTitle,
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
      unawaited(openPlayingSource(context, MusicScreen(artistId: id),
          television: true));
    } else {
      // The phone player overlays Main's nested pages as their sibling.
      final router = context.router;
      final pages =
          router.root.innerRouterOf<StackRouter>(MainRoute.name) ?? router;
      player.showMiniPlayer();
      pages.push(MusicRoute(artistId: id));
    }
  }

  /// Cover the player with a browsable route while keeping its decoder mounted.
  static Future<void> openPlayingSource(BuildContext context, Widget page,
      {required bool television}) async {
    final app = context.read<AppCubit>();
    final session = app.state;
    if (session.globalLoading ||
        session.sessionRecoveryRequired ||
        session.profileId != db.profileId) {
      return;
    }
    final player = context.read<PlayerCubit>();
    await Navigator.of(context, rootNavigator: !television)
        .push<void>(_PlayingMusicSourceRoute(page, player, app, session));
  }

  static Future<void> openDeviceCollection(BuildContext context, Widget page) =>
      ModalRoute.of(context) is _PlayingMusicSourceRoute
          ? openPlayingSource(context, page, television: isTv)
          : Navigator.of(context)
              .push<void>(MaterialPageRoute(builder: (_) => page));

  static Future<void> playLocalTracks(
      BuildContext context, List<LocalMusicTrack> tracks,
      {int startIndex = 0, String? queueTitle, bool songTap = false}) async {
    if (tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length) return;
    final route = ModalRoute.of(context);
    if (isTv && route is! _PlayingMusicSourceRoute) {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _MusicTvPlayer(
              videos: const [],
              localTracks: tracks,
              queueTitle: queueTitle,
              startIndex: startIndex,
              songTap: songTap)));
    } else {
      final player = context.read<PlayerCubit>();
      final failure = route is _PlayingMusicSourceRoute
          ? player.musicSelectionFailureRevision.value
          : null;
      await player.playLocalMusic(tracks,
          startIndex: startIndex, queueTitle: queueTitle, songTap: songTap);
      if (route is _PlayingMusicSourceRoute &&
          context.mounted &&
          !player.isClosed &&
          route.isCurrent &&
          player.musicSelectionFailureRevision.value == failure &&
          player.isLocalMusicSession &&
          localMusicTrackId(player.state.currentQueueId ?? '') ==
              tracks[startIndex].playbackId) {
        route.navigator!.pop();
      }
    }
  }

  static Future<void> playOnDeviceTracks(
      BuildContext context, List<OnDeviceMusicEntry> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool songTap = false,
      bool Function()? isCurrent}) async {
    if (startIndex < 0 ||
        startIndex >= tracks.length ||
        isCurrent?.call() == false) {
      return;
    }
    final route = ModalRoute.of(context);
    if (isTv && route is! _PlayingMusicSourceRoute) {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _MusicTvPlayer(
              videos: const [],
              onDeviceTracks: tracks,
              onDeviceMusicIsCurrent: isCurrent,
              queueTitle: queueTitle,
              startIndex: startIndex,
              songTap: songTap)));
      return;
    }
    final player = context.read<PlayerCubit>();
    final failure = player.musicSelectionFailureRevision.value;
    await player.playOnDeviceMusic(tracks,
        startIndex: startIndex,
        queueTitle: queueTitle,
        songTap: songTap,
        isCurrent: isCurrent);
    if (route is! _PlayingMusicSourceRoute ||
        !context.mounted ||
        player.isClosed ||
        !route.isCurrent ||
        isCurrent?.call() == false ||
        player.musicSelectionFailureRevision.value != failure ||
        player.state.mediaEvent.state == MediaState.error) {
      return;
    }
    final playing = player.state.offlineCurrentlyPlaying;
    final chosen = tracks[startIndex];
    if (playing == null) return;
    final track = chosen.deviceTrack;
    final matches = track != null
        ? localMusicTrackId(playing.videoId) == track.playbackId
        : playing.videoId == chosen.download!.videoId &&
            playing.explicitMusicDownload ==
                musicDownloadFileFingerprint(
                    chosen.download!, chosen.downloadFileProof!);
    if (matches) route.navigator!.pop();
  }

  static Future<void> playTracks(BuildContext context, List<Video> videos,
          {PlaylistReference? reference,
          PlaylistReference? recommendationSource,
          String? queueTitle,
          int? startIndex,
          Duration startAt = Duration.zero,
          bool shuffleOnce = false,
          bool songTap = false}) =>
      _playTracks(context, videos.map(_songEntry).toList(),
          reference: reference,
          recommendationSource: recommendationSource,
          queueTitle: queueTitle,
          startIndex: startIndex,
          startAt: startAt,
          shuffleOnce: shuffleOnce,
          songTap: songTap);

  static Future<void> playCollectionTracks(
      BuildContext context, List<Video> videos,
      {required String queueTitle,
      bool shuffle = false,
      List<PlaylistReference?>? recommendationSources,
      bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return;
    if (recommendationSources != null &&
        recommendationSources.length != videos.length) {
      throw ArgumentError(
          'Collection tracks and source references must align.');
    }
    final rows = [
      for (final (index, video) in videos.indexed)
        if (!video.filtered && !video.filterHide && video.isUpcoming != true)
          (video: _songEntry(video), source: recommendationSources?[index]),
    ];
    if (rows.isEmpty) return;
    List<Video> tracks() => [for (final row in rows) row.video];
    List<PlaylistReference?>? sources() => recommendationSources == null
        ? null
        : [for (final row in rows) row.source];
    if (!isTv) {
      await context.read<PlayerCubit>().playMusicCollectionQueue(tracks(),
          queueTitle: queueTitle,
          shuffle: shuffle,
          isCurrent: isCurrent,
          recommendationSources: sources());
      return;
    }
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return;
    // A retry starts with the same collection order as the original request.
    if (shuffle) rows.shuffle();
    final playable = tracks();
    final alignedSources = sources();
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (routeContext) =>
            _MusicTvPlayer(videos: playable, collectionQueue: (
              title: queueTitle,
              isCurrent: () => routeContext.mounted && session.isCurrent,
              recommendationSources: alignedSources,
            ))));
  }

  static Future<void> playSeededMix(BuildContext context, Video seed,
      {required bool inPlayer, required bool Function() isCurrent}) async {
    final locals = AppLocalizations.of(context)!;
    final route = ModalRoute.of(context);
    bool current() => isCurrent() && route?.isActive != false;
    Future<bool?> start(PlayerCubit player) async {
      try {
        return await player.playMusicMix(seed,
            queueTitle: locals.musicSeededMixTitle(seed.musicMetadata!.title),
            loadCandidates: (isCurrent) => musicCatalogService
                .getRelatedSongs([seed.videoId], isCurrent: isCurrent),
            isCurrent: current);
      } catch (error) {
        _musicLog.fine('Could not start Music mix (${error.runtimeType})');
        return false;
      }
    }

    if (isTv && !inPlayer && route is! _PlayingMusicSourceRoute) {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _MusicTvPlayer(videos: [seed], startMix: start)));
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(locals.musicStartingMix)));
    final started = await start(context.read<PlayerCubit>());
    if (started == false && current() && messenger?.mounted == true) {
      messenger!
          .showSnackBar(SnackBar(content: Text(locals.musicMixUnavailable)));
    }
  }

  static Video _songEntry(Video video) => video.musicMetadata != null
      ? video
      : video.copyWith(
          musicMetadata: video.resolveMusicMetadata(
              MusicMetadata(title: video.videoId, artist: '')));

  static Future<void> _playTracks(BuildContext context, List<Video> videos,
      {PlaylistReference? reference,
      PlaylistReference? recommendationSource,
      String? queueTitle,
      int? startIndex,
      required Duration startAt,
      bool shuffleOnce = false,
      bool songTap = false,
      ModalRoute<dynamic>? songLauncher,
      bool Function()? isCurrent}) async {
    if (videos.isEmpty) return;
    if (reference != null && reference.profileId != db.profileId) return;
    if (recommendationSource != null &&
        recommendationSource.profileId != db.profileId) {
      return;
    }
    final sourceRoute = ModalRoute.of(context);
    if (isTv && sourceRoute is! _PlayingMusicSourceRoute) {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _MusicTvPlayer(
              videos: videos,
              reference: reference,
              recommendationSource: recommendationSource,
              queueTitle: queueTitle,
              startIndex: startIndex ?? 0,
              startAt: startAt,
              shuffleOnce: shuffleOnce,
              songTap: songTap)));
      return;
    }
    final player = context.read<PlayerCubit>();
    final returnRoute = songLauncher ??
        (sourceRoute is _PlayingMusicSourceRoute ? sourceRoute : null);
    final before = player.state;
    final failure =
        returnRoute == null ? null : player.musicSelectionFailureRevision.value;
    final playlistGeneration =
        shuffleOnce && returnRoute != null ? player.playlistGeneration : null;
    final playback = reference == null
        ? player.playVideo(videos,
            fromMusic: true,
            recommendationSource: recommendationSource,
            queueTitle: queueTitle,
            audio: true,
            startAt: startAt,
            startIndex: startIndex,
            songTap: songTap)
        : player.playPlaylist(videos,
            fromMusic: true,
            reference: reference,
            startIndex: startIndex ?? 0,
            audio: true,
            startAt: startAt,
            shuffleOnce: shuffleOnce,
            songTap: songTap);
    if (returnRoute == null) return playback;
    final songOnly = songTap &&
        player.settings.state.musicSongTapQueueScope ==
            MusicSongTapQueueScope.songOnly;
    final request = player.musicSelectionRequestRevision;
    bool current() =>
        context.mounted &&
        !player.isClosed &&
        player.musicSelectionRequestRevision == request &&
        returnRoute.isCurrent &&
        (isCurrent?.call() ?? true);
    bool playable(Video video) =>
        !video.filtered &&
        (!isLocalMusicPlaybackId(video.videoId) ||
            LocalMusicLibrary.instance.playlistTrackById(video.videoId) !=
                null) &&
        (reference == null || (!video.filterHide && video.isUpcoming != true));
    final assigned = reference == null
        ? assignPlaybackQueueIds(videos.where(playable))
        : assignPlaylistEntryIds(videos).where(playable);
    final sourceQueue = assigned.map(playbackQueueId).toList();
    final start = startIndex ?? 0;
    final available = (startIndex == null && reference == null) ||
        (start >= 0 && start < videos.length && playable(videos[start]));
    final selectedId = available
        ? sourceQueue.elementAtOrNull(videos.take(start).where(playable).length)
        : null;
    final queue = songOnly ? [if (selectedId != null) selectedId] : sourceQueue;
    final shuffledIds = shuffleOnce ? queue.toSet() : null;
    bool matchesQueue(PlayerState state) => shuffledIds == null
        ? listEquals(state.videos.map(playbackQueueId).toList(), queue)
        : state.videos.length == queue.length &&
            state.videos
                .every((video) => shuffledIds.contains(playbackQueueId(video)));
    // Replaying the active occurrence can have an identical queue throughout
    // preparation. In that case its completed request confirms the handoff.
    String? expectedId(PlayerState snapshot) =>
        shuffleOnce && snapshot.videos.isNotEmpty
            ? playbackQueueId(snapshot.videos.first)
            : selectedId;
    final wasCurrent =
        before.currentQueueId == expectedId(before) && matchesQueue(before);
    bool popped = false;
    void returnAfterCommit({bool completed = false}) {
      final state = player.state;
      // With no old song to keep playing, the newly expanded queue owns the
      // screen even while its first decoder is still starting.
      final firstQueue = before.currentQueueId == null &&
          state.currentQueueId == null &&
          !identical(state, before);
      final nextId = expectedId(state);
      if (popped ||
          returnRoute.isFirst ||
          !current() ||
          player.musicSelectionFailureRevision.value != failure ||
          (wasCurrent && !completed) ||
          (playlistGeneration != null &&
              player.playlistGeneration == playlistGeneration) ||
          nextId == null ||
          !state.isAudio ||
          state.isHidden ||
          state.isMini ||
          (!firstQueue && state.currentQueueId != nextId) ||
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

class MusicScreenState extends State<MusicScreen> with WidgetsBindingObserver {
  static const _voiceSearchChannel = MethodChannel('videre/music_voice_search');
  final _onlineSearch = TextEditingController();
  final _librarySearch = TextEditingController();
  final _queryFocus = FocusNode();
  final _playlistFindQuery = TextEditingController();
  final _playlistFindInput = FocusNode();
  final _playlistFindButton = FocusNode();
  final _librarySearchScroll = ScrollController();
  final _searchScrollScope = Object();
  _MusicSearchSource _searchSource = _MusicSearchSource.online;
  bool _visitedLibrarySearch = false;
  bool _voiceSearchAvailable = false;
  bool _voiceSearchPending = false;
  bool _onlineVoiceDraftPending = false;
  int _searchIntentRevision = 0;
  int _searchSessionRevision = 0;
  int _onlineResultRevision = 0;
  int _libraryResultRevision = 0;
  VoidCallback? _shortcutBack;
  MusicCatalogSearchType _type = MusicCatalogSearchType.songs;
  MusicLibrarySearchType _libraryType = MusicLibrarySearchType.all;
  _OnlineSearchListing? _onlineListing;
  Timer? _suggestionTimer;
  int _suggestionRequest = 0;
  var _suggestionDraft = (text: '', composing: false);
  ({List<String> items, bool Function() isCurrent})? _onlineSuggestions;
  bool _foreground = true;
  bool _androidKeyboardVisible = false;
  MusicCollection? _collection;
  bool _findingPlaylist = false;
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
  bool _returningToOrigin = false;
  bool _retryingSong = false;
  Object? _failure;
  MusicTrack? _resolvedSong;
  bool _showCommunityHidden = false;
  bool _starting = false;
  int _playRequest = 0;
  ({
    List<Video> videos,
    int startIndex,
    Duration startAt,
    String? queueTitle,
    bool songTap,
  })? _tvSong;
  int _generation = 0;
  int? _abandonedSongRequest;
  Future<void> Function()? _retry;

  bool get _hasBrowsePage =>
      _collection != null || _artistPage != null || _browseHistory.isNotEmpty;

  bool get _canSwitchSearchSource =>
      widget.embedded &&
      !isTv &&
      !_hasDirectBrowseLink &&
      widget.videoId == null;

  bool get _searchingLibrary =>
      _canSwitchSearchSource && _searchSource == _MusicSearchSource.library;

  bool get _canUseOnlineRecents =>
      _canSwitchSearchSource && !_searchingLibrary && !_hasBrowsePage;

  bool get _searched => _onlineListing != null;

  TextEditingController get _search =>
      _searchingLibrary ? _librarySearch : _onlineSearch;

  void _selectSearchSource(_MusicSearchSource source) {
    if (source == _searchSource) return;
    _clearOnlineSuggestions();
    _searchIntentRevision++;
    setState(() {
      _searchSource = source;
      if (source == _MusicSearchSource.library) {
        _visitedLibrarySearch = true;
        _onlineListing?.pending = null;
      }
    });
  }

  Widget _withOnlineRecents(Widget field) {
    if (!_canUseOnlineRecents) return field;
    return Row(children: [
      Expanded(child: field),
      MusicOnlineRecentsButton(onUse: (query) {
        if (!_canUseOnlineRecents) return;
        _searchIntentRevision++;
        _onlineVoiceDraftPending = false;
        _fillOnlineQuery(query);
        _queryFocus.requestFocus();
      }),
    ]);
  }

  void _submitActiveSearch() {
    if (_searchingLibrary) {
      _queryFocus.unfocus();
    } else {
      _onlineVoiceDraftPending = false;
      unawaited(_submit(learn: true));
    }
  }

  void _selectOnlineType(MusicCatalogSearchType type) {
    if (_searchingLibrary || _type == type) return;
    setState(() {
      _type = type;
      _onlineListing?.pending = null;
    });
    // A pasted address needs a submission before changing result types can
    // search its text. The user also needs to submit a dictated draft.
    final query = _onlineSearch.text.trim();
    if (!_onlineVoiceDraftPending &&
        query.isNotEmpty &&
        (query == _onlineListing?.query ||
            ContentLink.completeWebAddress(query) == null)) {
      unawaited(_submit());
    }
  }

  void _selectLibraryType(MusicLibrarySearchType type) {
    if (!_searchingLibrary || _libraryType == type) return;
    setState(() {
      _libraryType = type;
      _libraryResultRevision++;
    });
  }

  void _searchInputChanged(String input) {
    if (!_searchingLibrary && input.trim().isEmpty) {
      _onlineVoiceDraftPending = false;
    }
    if (_searchingLibrary &&
        _librarySearchScroll.hasClients &&
        _librarySearchScroll.offset != 0) {
      _librarySearchScroll.jumpTo(0);
    }
  }

  bool get _canSuggestOnline =>
      _foreground &&
      !_onlineVoiceDraftPending &&
      !_searchingLibrary &&
      !_hasBrowsePage &&
      !(_browseRequest && (_loading || _failure != null)) &&
      isPastedLinkSourceActive(context) &&
      context.read<SettingsCubit?>()?.state.distractionFreeMode != true;

  void _clearOnlineSuggestions() {
    _suggestionTimer?.cancel();
    _suggestionRequest++;
    if (_onlineSuggestions != null) {
      setState(() => _onlineSuggestions = null);
    }
  }

  void _onlineDraftChanged() {
    final value = _onlineSearch.value;
    final draft = (
      text: value.text,
      composing: value.isComposingRangeValid && !value.composing.isCollapsed,
    );
    if (draft == _suggestionDraft) return;
    _suggestionDraft = draft;
    _clearOnlineSuggestions();
    final query = draft.text.trim();
    if (draft.composing ||
        query.isEmpty ||
        ContentLink.completeWebAddress(query) != null ||
        !_canSuggestOnline) {
      return;
    }
    final request = _suggestionRequest;
    final session = context.read<AppCubit>().state;
    final database = db;
    final proxy = NetworkProxy.instance;
    final connection = proxy.config;
    bool current() =>
        request == _suggestionRequest &&
        _sameSession(session) &&
        identical(database, db) &&
        database.profileId == session.profileId &&
        _canSuggestOnline &&
        _onlineSearch.text.trim() == query &&
        !proxy.isChanging &&
        identical(connection, proxy.config);
    bool canRequest() => current() && _queryFocus.hasFocus;

    _suggestionTimer = Timer(const Duration(milliseconds: 500), () async {
      if (!canRequest()) return;
      try {
        final suggestions = await musicCatalogService.searchSuggestions(query,
            isCurrent: canRequest);
        if (suggestions.isNotEmpty && canRequest()) {
          setState(() => _onlineSuggestions = (
                items: suggestions,
                isCurrent: current,
              ));
        }
      } catch (_) {
        // Suggestions are optional. The user can still submit the draft.
      }
    });
  }

  void _useOnlineSuggestion(String suggestion, {required bool submit}) {
    final suggestions = _onlineSuggestions;
    if (suggestions == null ||
        !suggestions.isCurrent() ||
        !suggestions.items.contains(suggestion)) {
      return;
    }
    _fillOnlineQuery(suggestion, refreshSuggestions: !submit);
    if (submit) {
      _submitActiveSearch();
    } else {
      _queryFocus.requestFocus();
    }
  }

  // Stored queries stay local until the next edit or an explicit submission.
  void _fillOnlineQuery(String query, {bool refreshSuggestions = false}) {
    if (!refreshSuggestions) {
      _clearOnlineSuggestions();
      _suggestionDraft = (text: query, composing: false);
    }
    _onlineSearch.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  Future<void> _checkVoiceSearchAvailability() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final available =
          await _voiceSearchChannel.invokeMethod<bool>('isAvailable');
      if (mounted && available == true) {
        setState(() => _voiceSearchAvailable = true);
      }
    } on MissingPluginException {
      // Builds without an Android recognizer use the regular search field.
    } on PlatformException {
      // Typed search is available if the device cannot check for a provider.
    }
  }

  Future<void> _startVoiceSearch() async {
    if (_voiceSearchPending) return;
    final locals = AppLocalizations.of(context)!;
    final session = context.read<AppCubit>().state;
    final languageTag =
        parseSavedLocale(context.read<SettingsCubit>().state.locale)
            ?.toLanguageTag();
    final generation = _generation;
    final intent = _searchIntentRevision;
    final controller = _search;
    final draft = controller.text;
    bool current() =>
        _active(generation, session) &&
        intent == _searchIntentRevision &&
        controller.text == draft &&
        TickerMode.of(context) &&
        ModalRoute.of(context)?.isCurrent != false;

    void showFailure() {
      if (!current()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(locals.musicVoiceSearchFailed)),
      );
    }

    setState(() => _voiceSearchPending = true);
    try {
      final consent = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(locals.musicVoiceSearch),
          content: Text(locals.musicVoiceSearchPrivacy),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(locals.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(locals.musicVoiceSearchStart),
            ),
          ],
        ),
      );
      if (consent != true || !current()) return;
      _queryFocus.unfocus();
      final transcript = (await _voiceSearchChannel.invokeMethod<String>(
        'recognize',
        {if (languageTag != null) 'languageTag': languageTag},
      ))
          ?.trim();
      if (transcript == null || transcript.isEmpty || !current()) return;
      if (_searchingLibrary) {
        controller.value = TextEditingValue(
          text: transcript,
          selection: TextSelection.collapsed(offset: transcript.length),
        );
        _searchInputChanged(transcript);
      } else {
        _onlineVoiceDraftPending = true;
        _fillOnlineQuery(transcript);
      }
    } on MissingPluginException {
      showFailure();
    } on PlatformException {
      showFailure();
    } finally {
      if (mounted) setState(() => _voiceSearchPending = false);
    }
  }

  void focusSearch({VoidCallback? onBack}) {
    if (onBack != null) setState(() => _shortcutBack = onBack);
    if (_hasBrowsePage || _browseRequest) {
      _backToSearch(clearHistory: true);
    }
    if (_queryFocus.hasFocus) {
      // Android's Back button can hide the IME while the field keeps focus.
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      _queryFocus.requestFocus();
    }
  }

  void leaveSearch() {
    _clearOnlineSuggestions();
    _searchIntentRevision++;
    if (_shortcutBack != null || _onlineListing?.pending != null) {
      setState(() {
        _shortcutBack = null;
        _onlineListing?.pending = null;
      });
    }
  }

  // A direct catalog link has no search results to return to. Preserve in-page
  // history first; submitting a search establishes a new local destination.
  bool get _hasDirectBrowseLink =>
      widget.artistId != null || widget.playlistId != null;

  bool get _returnToOrigin =>
      _hasBrowsePage &&
      !_searched &&
      _browseHistory.isEmpty &&
      _hasDirectBrowseLink;

  @override
  void initState() {
    super.initState();
    unawaited(_checkVoiceSearchAvailability());
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _onlineSearch.addListener(_onlineDraftChanged);
    NetworkProxy.instance.addBeforeApply(_retireOnlineConnection);
    _loading = widget.videoId != null &&
        widget.playlistId == null &&
        _sameSession(context.read<AppCubit>().state);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openInitial();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboardVisible = defaultTargetPlatform == TargetPlatform.android &&
        (MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0) > 0;
    final keyboardClosed = _androidKeyboardVisible && !keyboardVisible;
    _androidKeyboardVisible = keyboardVisible;
    if (keyboardClosed && !_searchingLibrary) _queryFocus.unfocus();
    if (keyboardClosed || !isPastedLinkSourceActive(context)) {
      _clearOnlineSuggestions();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _clearOnlineSuggestions();
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
      _clearOnlineSuggestions();
      _generation++;
      _resetPlaylistFind();
      _onlineListing?.pending = null;
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
    WidgetsBinding.instance.removeObserver(this);
    NetworkProxy.instance.removeBeforeApply(_retireOnlineConnection);
    _artistReleaseCooldown?.cancel();
    _suggestionTimer?.cancel();
    _onlineSearch.removeListener(_onlineDraftChanged);
    _onlineSearch.dispose();
    _librarySearch.dispose();
    _librarySearchScroll.dispose();
    _queryFocus.dispose();
    _playlistFindQuery.dispose();
    _playlistFindInput.dispose();
    _playlistFindButton.dispose();
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
    _clearOnlineSuggestions();
    _generation++;
    _searchIntentRevision++;
    _searchSessionRevision++;
    if (_onlineVoiceDraftPending || _canSwitchSearchSource) {
      _onlineSearch.clear();
    }
    _onlineVoiceDraftPending = false;
    if (_canSwitchSearchSource) {
      _librarySearch.clear();
      _type = MusicCatalogSearchType.songs;
      _libraryType = MusicLibrarySearchType.all;
    }
    _artistReleaseCooldown?.cancel();
    _artistReleaseCooldown = null;
    setState(() {
      _resetPlaylistFind();
      _loading = false;
      _retryingSong = false;
      _failure = null;
      _onlineListing = null;
      _resolvedSong = null;
      _showCommunityHidden = false;
      _starting = false;
      _tvSong = null;
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
      _searchIntentRevision++;
      _searchSource = _MusicSearchSource.online;
      _onlineVoiceDraftPending = false;
      _fillOnlineQuery(widget.initialQuery!.trim());
      _type = MusicCatalogSearchType.songs;
      await _submit();
    }
  }

  Future<void> _run(Future<void> Function(int, AppState) operation,
      Future<void> Function() retry,
      {bool browse = false}) async {
    final session = context.read<AppCubit>().state;
    if (!_sameSession(session)) return;
    if (browse) _clearOnlineSuggestions();
    final generation = ++_generation;
    setState(() {
      if (browse) {
        _onlineListing?.pending = null;
        _resetPlaylistFind();
      }
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
    final query = retryQuery ?? _onlineSearch.text.trim();
    if (_searchingLibrary || query.isEmpty) return;
    _clearOnlineSuggestions();
    final app = context.read<AppCubit>();
    final session = app.state;
    if (!_sameSession(session)) return;
    final intent = _searchIntentRevision;
    FocusManager.instance.primaryFocus?.unfocus();
    if (learn && ContentLink.completeWebAddress(query) != null) {
      if (!isPastedLinkSourceActive(context)) return;
      final generation = _generation;
      bool current() =>
          _active(generation, session) &&
          intent == _searchIntentRevision &&
          _onlineSearch.text.trim() == query &&
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
    if (learn) {
      if (_canUseOnlineRecents && MusicOnlineRecents.canSaveQuery(query)) {
        unawaited(_rememberOnlineSearch(query, session));
      }
      unawaited(_learnSearch(query, session, intent));
    }
    final listing =
        _OnlineSearchListing(query, _type, paginated: _canSwitchSearchSource);
    setState(() {
      _onlineListing = listing;
      _onlineResultRevision++;
      _showCommunityHidden = false;
      _resetPlaylistFind();
      _collection = null;
      _artistPage = null;
      _artistReleases = null;
      _browseHistory.clear();
    });
    await _run((generation, session) async {
      bool ownsResults() =>
          _active(generation, session) &&
          identical(_onlineListing, listing) &&
          _type == listing.type;
      try {
        final page = listing.paginated
            ? await musicCatalogService.searchPage(query, listing.type, 1,
                isCurrent: () => ownsResults() && listing.connectionCurrent)
            : MusicCatalogSearchPage(
                hits: await _legacySearch(query, listing.type), rawKeys: []);
        if (!ownsResults()) return;
        if (!listing.connectionCurrent) {
          throw const MusicCatalogException(
              'The music connection changed. Retry the request.');
        }
        setState(() => listing.accept(page));
      } catch (_) {
        if (ownsResults()) rethrow;
      }
    }, () => _submit(retryQuery: query));
  }

  Future<List<MusicCatalogSearchHit>> _legacySearch(
          String query, MusicCatalogSearchType type) async =>
      switch (type) {
        MusicCatalogSearchType.songs =>
          (await musicCatalogService.searchSongs(query))
              .map(MusicCatalogSongHit.new)
              .toList(),
        MusicCatalogSearchType.channels =>
          (await musicCatalogService.searchArtists(query))
              .map(MusicCatalogChannelHit.new)
              .toList(),
        MusicCatalogSearchType.playlists =>
          (await musicCatalogService.searchPlaylists(query))
              .map(MusicCatalogPlaylistHit.new)
              .toList(),
        MusicCatalogSearchType.all => throw const MusicCatalogUnsupported(),
      };

  Future<void> _retireOnlineConnection() async {
    if (!mounted) return;
    _clearOnlineSuggestions();
    await _retireOnlinePagination();
  }

  Future<void> _retireOnlinePagination() async {
    final listing = _onlineListing;
    if (!mounted || listing == null || !listing.hasMore) return;
    setState(() {
      listing.hasMore = false;
      listing.pending = null;
    });
  }

  Future<void> _loadMore(_OnlineSearchListing listing) async {
    if (!mounted) return;
    final session = context.read<AppCubit>().state;
    final route = ModalRoute.of(context);
    final generation = _generation;
    final intent = _searchIntentRevision;
    bool ownsResults() =>
        _active(generation, session) &&
        intent == _searchIntentRevision &&
        identical(_onlineListing, listing) &&
        _type == listing.type &&
        _canSwitchSearchSource &&
        !_searchingLibrary &&
        !_loading &&
        !_hasBrowsePage &&
        TickerMode.of(context) &&
        route?.isCurrent != false;
    if (!ownsResults() || !listing.hasMore || listing.pending != null) return;
    if (!listing.connectionCurrent) {
      await _retireOnlinePagination();
      return;
    }
    final request = Object();
    bool current() =>
        ownsResults() &&
        identical(listing.pending, request) &&
        listing.connectionCurrent;
    setState(() {
      listing.pending = request;
    });
    try {
      final page = await musicCatalogService.searchPage(
          listing.query, listing.type, listing.nextPage,
          isCurrent: current);
      if (current()) setState(() => listing.accept(page));
    } catch (_) {
      if (current()) setState(() => listing.failed = true);
    } finally {
      if (mounted &&
          identical(_onlineListing, listing) &&
          identical(listing.pending, request)) {
        setState(() {
          listing.pending = null;
          if (!listing.connectionCurrent) listing.hasMore = false;
        });
      }
    }
  }

  Future<void> _learnSearch(String query, AppState session, int intent) async {
    final recommendations =
        RecommendationService.forProfile(db, session.profileId);
    try {
      await recommendations.recordSearch(query, RecommendationDomain.music);
    } catch (_) {
      if (mounted && intent == _searchIntentRevision && _sameSession(session)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.recommendationError)));
      }
    }
  }

  Future<void> _rememberOnlineSearch(String query, AppState session) async {
    final database = db;
    bool current() =>
        identical(db, database) &&
        _sameSession(session) &&
        database.profileId == session.profileId;
    if (!current()) return;
    try {
      final recents =
          MusicOnlineRecents.forProfile(database, session.profileId);
      if (recents.enabled) {
        await recents.recordSubmission(query, isCurrent: current);
      }
    } catch (_) {
      if (mounted && current() && isPastedLinkSourceActive(context)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context)!.error)));
      }
    }
  }

  Future<void> _openCollection(String id, {bool retrying = false}) async {
    await _run((generation, session) async {
      bool current() => _active(generation, session);
      final previousLength = _collection?.tracks.length ?? 0;
      final collection = await musicCatalogService.getPlaylistProgressively(id,
          isCurrent: current, onProgress: (snapshot) {
        // On retry, keep the previous prefix visible while it is reloaded.
        if (current() && snapshot.tracks.length >= previousLength) {
          setState(() => _collection = snapshot);
        }
      });
      if (current()) setState(() => _collection = collection);
    }, () => _openCollection(id, retrying: _collection != null),
        browse: !retrying);
  }

  void _openPlaylistFind() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _findingPlaylist = true);
    _playlistFindInput.requestFocus();
  }

  void _resetPlaylistFind() {
    if (!_findingPlaylist) return;
    _findingPlaylist = false;
    _playlistFindInput.unfocus();
    _playlistFindQuery.clear();
  }

  void _closePlaylistFind() {
    setState(_resetPlaylistFind);
    _playlistFindButton.requestFocus();
  }

  Future<void> _openArtist(String id) async {
    if (!_loading && _artistPage?.artist.id == id) return;
    await _run(
      (generation, session) async {
        final artist = await musicCatalogService.getArtistOverview(id);
        if (_active(generation, session)) {
          final releases = _ArtistReleaseListing(artist);
          setState(() {
            _artistPage = artist;
            _artistReleases = releases;
          });
          if (artist.loadsUploadsSeparately) {
            unawaited(_loadArtistUploads(artist.artist.id, releases, session));
          }
          unawaited(_loadArtistReleases(artist.artist.id, releases, session));
        }
      },
      () => _openArtist(id),
      browse: true,
    );
  }

  bool _artistListingCurrent(_ArtistReleaseListing listing, AppState session) =>
      _sameSession(session) &&
      (identical(_artistReleases, listing) ||
          _browseHistory.any((page) => identical(page.releases, listing)));

  Future<void> _loadArtistUploads(
    String artistId,
    _ArtistReleaseListing listing,
    AppState session,
  ) async {
    bool current() => _artistListingCurrent(listing, session);
    if (!current() || listing.uploadsLoading) return;
    final proxy = NetworkProxy.instance.config;
    setState(() {
      listing.uploadsLoading = true;
      listing.uploadsFailed = false;
    });
    try {
      final tracks = await musicCatalogService.getArtistUploads(
        artistId,
        isCurrent: () =>
            current() &&
            !NetworkProxy.instance.isChanging &&
            identical(NetworkProxy.instance.config, proxy),
      );
      if (!current()) return;
      if (!identical(NetworkProxy.instance.config, proxy)) {
        listing.uploadsFailed = true;
      } else {
        listing.uploads = tracks;
      }
    } catch (_) {
      if (current()) listing.uploadsFailed = true;
    } finally {
      listing.uploadsLoading = false;
      if (current() && identical(_artistReleases, listing)) setState(() {});
    }
  }

  Future<void> _loadArtistReleases(
      String artistId, _ArtistReleaseListing listing, AppState session) async {
    bool current() => _artistListingCurrent(listing, session);
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
        final occurrence = videos[index];
        videos[index] = resolved.copyWith(
            queueEntryId: occurrence.queueEntryId,
            musicMetadata: resolved.musicMetadata
                ?.withAlbumFrom(occurrence.musicMetadata));
      }
      await _playVideos(videos,
          startIndex: fromShelf ? index : null,
          queueTitle: fromShelf ? widget.queueTitle : null,
          startAt: startAt,
          songTap: fromShelf,
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
        albumPlaylistId: music.albumPlaylistId,
        durationSeconds: saved.lengthSeconds,
        isArtTrack: music.isArtTrack,
        thumbnails: artwork,
        videoThumbnails: saved.videoThumbnails,
        playbackVideo: saved);
  }

  Future<void> _play(List<MusicTrack> tracks,
          {PlaylistReference? reference,
          String? queueTitle,
          int? startIndex,
          Duration startAt = Duration.zero,
          bool songTap = false}) =>
      _playVideos(tracks.map((track) => track.toVideo()).toList(),
          reference: reference,
          queueTitle: queueTitle,
          startIndex: startIndex,
          startAt: startAt,
          songTap: songTap);

  Future<void> _playVideos(List<Video> videos,
      {PlaylistReference? reference,
      String? queueTitle,
      int? startIndex,
      Duration startAt = Duration.zero,
      bool shuffleOnce = false,
      bool songTap = false,
      ModalRoute<dynamic>? songLauncher}) async {
    final session = context.read<AppCubit>().state;
    if (videos.isEmpty || !_sameSession(session)) return;
    if (songLauncher != null && isTv) {
      // This route owns the TV player and returns directly to its caller.
      setState(() => _tvSong = (
            videos: videos,
            startIndex: startIndex ?? 0,
            startAt: startAt,
            queueTitle: queueTitle,
            songTap: songTap
          ));
      return;
    }
    final request = ++_playRequest;
    final generation = _generation;
    final intent = _searchIntentRevision;
    bool current() =>
        request == _playRequest &&
        intent == _searchIntentRevision &&
        _active(generation, session);
    try {
      await MusicScreen._playTracks(context, videos,
          reference: reference,
          queueTitle: queueTitle,
          startIndex: startIndex,
          startAt: startAt,
          shuffleOnce: shuffleOnce,
          songTap: songTap,
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

  void _backToSearch({bool clearHistory = false}) {
    _generation++;
    setState(() {
      _resetPlaylistFind();
      if (clearHistory) _browseHistory.clear();
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

  bool _canReturnToBrowseCaller(ModalRoute<Object?>? route) =>
      !_searched &&
      _hasDirectBrowseLink &&
      !widget.embedded &&
      _shortcutBack == null &&
      route != null &&
      !route.isFirst;

  Future<void> _returnToBrowseRoot(
      ModalRoute<Object?>? route, AppState session, int generation) async {
    bool current() =>
        _active(generation, session) &&
        TickerMode.of(context) &&
        identical(ModalRoute.of(context), route) &&
        route?.isCurrent != false;

    if (_returningToOrigin || !_hasBrowsePage || !current()) return;
    if (!_canReturnToBrowseCaller(route)) {
      _backToSearch(clearHistory: true);
      return;
    }

    // Retain the displayed detail while this route's own PopScope updates.
    // Other scopes can still veto the pop, and a newly opened route stays put.
    setState(() => _returningToOrigin = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!current() || !_canReturnToBrowseCaller(route)) return;
      await route!.navigator?.maybePop();
      if (!route.isActive) _generation++;
    } finally {
      if (mounted) setState(() => _returningToOrigin = false);
    }
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
        final deviceId = saved.currentDeviceId;
        if (deviceId != null) {
          final library = LocalMusicLibrary.instance;
          final savedPlaylistFile = !saved.offlineIds.contains(saved.currentId);
          unawaited(library.initialize());
          return ListenableBuilder(
              listenable: library,
              builder: (context, _) => (savedPlaylistFile
                          ? library.enabled && !library.unavailable
                          : library.acceptsSessionSelection(
                              saved.localSelectionId)) &&
                      (!library.loaded ||
                          localMusicTrackForPlayback(deviceId) != null)
                  ? resume
                  : const SizedBox.shrink());
        }
        final downloadId = saved.currentSavedDownloadId;
        if (downloadId != null) {
          final fingerprint = saved.offlineFingerprints[saved.currentId];
          if (fingerprint != null) {
            return readyMusicDownload(db, downloadId,
                        fingerprint: fingerprint) !=
                    null
                ? resume
                : const SizedBox.shrink();
          }
          final offline = db.getDownloadByVideoId(downloadId);
          if (offline?.downloadComplete == true &&
              offline?.musicMetadata != null) {
            return resume;
          }
        }
        return saved.videos.any((video) =>
                playbackQueueId(video) == saved.currentId &&
                video.musicMetadata != null &&
                (video.explicitMusicDownload == null ||
                    readyMusicDownload(db, video.videoId,
                            fingerprint: video.explicitMusicDownload) !=
                        null))
            ? resume
            : const SizedBox.shrink();
      });

  Widget _artwork(List<ImageObject> images) => SizedBox.square(
      dimension: 56,
      child: images.isEmpty
          ? const Icon(Icons.music_note)
          : Thumbnail(
              musicArtwork: true,
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

  Widget _song(List<MusicTrack> queue, int index, MusicLayout layout,
      {bool numbered = true,
      String? section,
      PlaylistReference? reference,
      String? queueTitle,
      List<CommunityMatch> matches = const []}) {
    final track = queue[index];
    final video = track.toVideo();
    final sourceIndex = track.playlistIndex;
    final displayPosition =
        (sourceIndex != null && sourceIndex >= 0 ? sourceIndex : index) + 1;
    final row = '${section ?? (numbered ? '' : 'search-')}$index';
    Future<void> play({bool songTap = false}) {
      if (_findingPlaylist) _playlistFindInput.unfocus();
      return _play(queue,
          reference: reference,
          queueTitle: queueTitle,
          startIndex: index,
          songTap: songTap);
    }

    final tile = ListTile(
      minTileHeight: layout.compactRows ? kMinInteractiveDimension : null,
      minVerticalPadding: layout.compactRows ? 4 : null,
      leading: !numbered
          ? SizedBox.square(
              dimension: layout.compactRows ? 40 : 56,
              child: CommunityMusicArtwork(
                  videoId: track.videoId,
                  music: track.musicMetadata,
                  durationSeconds: track.durationSeconds,
                  fallback: _artwork(track.displayThumbnails)),
            )
          : SizedBox.square(
              dimension: 36,
              child: Stack(fit: StackFit.expand, children: [
                Center(child: Text('$displayPosition')),
                VideoWatchProgress(videoId: track.videoId),
              ])),
      title: MusicStatusTitle.song(
          video: video,
          child: Text(track.title,
              maxLines: layout.titleLines(2), overflow: TextOverflow.ellipsis)),
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
      trailing: MusicLibraryActions(
          videos: [video], onPlay: play, recommendationSource: reference),
      onLongPress: () => MusicLibraryActions.showSongMenu(context, video,
          onPlay: play, recommendationSource: reference),
      onTap: () => play(songTap: true),
    );
    return MusicSongRowSwipe(
      key: ValueKey('music-song-$row-${track.videoId}'),
      onAction: (action) => MusicLibraryActions.queueSong(
          context, video, action,
          recommendationSource: reference),
      child: tile,
    );
  }

  Widget _libraryResults() {
    final session = context.read<AppCubit>().state;
    final intent = _searchIntentRevision;
    final type = _libraryType;
    final revision = _libraryResultRevision;
    bool current() =>
        _sameSession(session) &&
        intent == _searchIntentRevision &&
        _searchingLibrary;
    return ValueListenableBuilder<TextEditingValue>(
      key: ValueKey(_searchSessionRevision),
      valueListenable: _librarySearch,
      builder: (context, draft, _) => MusicLibrarySearchResults(
        query: draft.text,
        type: type,
        active: _searchingLibrary && TickerMode.of(context),
        controller: _librarySearchScroll,
        searchFocusNode: _queryFocus,
        scrollKey: PageStorageKey((
          _searchScrollScope,
          _searchSessionRevision,
          _MusicSearchSource.library,
          revision,
        )),
        isSessionCurrent: current,
        isCurrent: () =>
            current() &&
            _libraryResultRevision == revision &&
            _librarySearch.text == draft.text,
      ),
    );
  }

  Widget _results(MusicLayout layout) {
    final online =
        _searchingLibrary ? null : _onlineResultsWithSuggestions(layout);
    if (!_canSwitchSearchSource || !_visitedLibrarySearch) return online!;
    // Keep verified file results ready when returning to Library. The inactive
    // adapter has no attached list that navigation reselect could scroll.
    return Stack(fit: StackFit.expand, children: [
      if (online != null) online,
      Offstage(
        key: const ValueKey('music-search-library-source'),
        offstage: !_searchingLibrary,
        child: KeyedSubtree(
          key: const ValueKey('music-search-library-viewport'),
          child: _libraryResults(),
        ),
      ),
    ]);
  }

  Widget _onlineResultsWithSuggestions(MusicLayout layout) {
    final suggestions = _onlineSuggestions;
    final showSuggestions = suggestions != null && suggestions.isCurrent();
    // Cover results while editing and retain their scroll position for Back.
    return Stack(fit: StackFit.expand, children: [
      Offstage(
        offstage: showSuggestions,
        child: ExcludeFocus(
          excluding: showSuggestions,
          child: TickerMode(
            enabled: !showSuggestions,
            child: KeyedSubtree(
              key: const ValueKey('music-search-online-viewport'),
              child: _onlineResults(layout),
            ),
          ),
        ),
      ),
      if (showSuggestions)
        ListView.builder(
          key: const ValueKey('music-search-suggestions'),
          primary: false,
          itemCount: suggestions.items.length,
          itemBuilder: (context, index) {
            final suggestion = suggestions.items[index];
            return SearchSuggestionTile(
              suggestion: suggestion,
              onSubmit: () => _useOnlineSuggestion(suggestion, submit: true),
              onFill: () => _useOnlineSuggestion(suggestion, submit: false),
            );
          },
        ),
    ]);
  }

  Widget _onlineResults(MusicLayout layout) {
    final locals = AppLocalizations.of(context)!;
    final collection = _collection;
    if (collection != null) {
      return Builder(
          builder: (context) =>
              _collectionResults(context, collection, layout));
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failure != null) {
      return Center(
        child: SingleChildScrollView(
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
    final artistPage = _artistPage;
    if (artistPage != null) return _artistResults(artistPage, layout);
    final listing = _onlineListing;
    if (listing == null) {
      return Center(
        child: SingleChildScrollView(
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
    final scrollKey = PageStorageKey((
      _searchScrollScope,
      _searchSessionRevision,
      _onlineResultRevision,
      _type
    ));
    if (listing.type != _type) {
      return Center(child: Text(locals.musicNoResults));
    }
    return ListenableBuilder(
      listenable: communityFilters.changes,
      builder: (_, __) =>
          _onlineListingView(listing, scrollKey, locals, layout),
    );
  }

  Widget _onlineListingView(_OnlineSearchListing listing, Key scrollKey,
      AppLocalizations locals, MusicLayout layout) {
    final hits = listing.hits;
    final mixed = listing.type == MusicCatalogSearchType.all;
    final songsOnly = listing.type == MusicCatalogSearchType.songs;
    final songs = musicTrackResults(
      [for (final hit in hits.whereType<MusicCatalogSongHit>()) hit.track],
      showHidden: _showCommunityHidden,
    );
    final queue = [for (final (track, _) in songs.visible) track];
    final songIndexes = {
      if (mixed)
        for (var index = 0; index < queue.length; index++)
          queue[index].videoId: index,
    };
    final visible = songsOnly
        ? [for (final track in queue) MusicCatalogSongHit(track)]
        : [
            for (final hit in hits)
              if (hit is! MusicCatalogSongHit ||
                  songIndexes.containsKey(hit.id))
                hit,
          ];
    final canContinue = _canSwitchSearchSource &&
        listing.paginated &&
        listing.hasMore &&
        listing.connectionCurrent;
    if (visible.isEmpty && songs.hidden == 0 && !canContinue) {
      return Center(child: Text(locals.musicNoResults));
    }
    final headers = <Widget>[
      if (songs.hidden > 0)
        CommunityHiddenNotice(
          count: songs.hidden,
          showing: _showCommunityHidden,
          onToggle: () =>
              setState(() => _showCommunityHidden = !_showCommunityHidden),
        ),
      if (visible.isNotEmpty && mixed)
        Semantics(
            header: true, child: _sectionTitle(locals.musicSearchTopResult)),
      if (visible.isEmpty && songs.hidden == 0)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(locals.musicNoResults, textAlign: TextAlign.center),
        ),
    ];
    return ListView.builder(
      key: scrollKey,
      itemCount: headers.length + visible.length + (canContinue ? 1 : 0),
      itemBuilder: (_, index) {
        if (index < headers.length) return headers[index];
        final row = index - headers.length;
        if (row == visible.length) return _onlinePageFooter(listing, locals);
        final hit = visible[row];
        switch (hit) {
          case MusicCatalogSongHit():
            final songIndex = songsOnly ? row : songIndexes[hit.id]!;
            return _song(queue, songIndex, layout,
                numbered: false,
                queueTitle: locals.search,
                matches: songs.visible[songIndex].$2);
          case MusicCatalogChannelHit(:final artist):
            return ListTile(
                key: listing.paginated ? ValueKey(hit.key) : null,
                leading: ChannelAvatar(
                    musicArtwork: true,
                    name: artist.name,
                    images: artist.thumbnails,
                    size: 56,
                    instanceOnly: true),
                title: MusicStatusTitle.bookmark(
                    kind: MusicLibraryKind.artist,
                    id: artist.id,
                    child: Text(artist.name)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openArtist(artist.id));
          case MusicCatalogPlaylistHit(:final playlist):
            return ListTile(
                key: listing.paginated ? ValueKey(hit.key) : null,
                leading: _artwork(playlist.thumbnails),
                title: MusicStatusTitle.bookmark(
                    kind: MusicLibraryKind.playlist,
                    id: playlist.id,
                    child: Text(playlist.title)),
                subtitle:
                    playlist.author == null ? null : Text(playlist.author!),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openCollection(playlist.id));
        }
      },
    );
  }

  Widget _onlinePageFooter(
          _OnlineSearchListing listing, AppLocalizations locals) =>
      Padding(
        key: const ValueKey('music-search-page-footer'),
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(
            child: listing.pending != null
                ? Semantics(
                    liveRegion: true,
                    child: CircularProgressIndicator(
                        semanticsLabel: locals.musicSearchLoadingMore),
                  )
                : TextButton(
                    onPressed: () => unawaited(_loadMore(listing)),
                    child:
                        Text(listing.failed ? locals.retry : locals.loadMore),
                  ),
          ),
        ),
      );

  Widget _collectionResults(
      BuildContext context, MusicCollection collection, MusicLayout layout) {
    final locals = AppLocalizations.of(context)!;
    final session = context.read<AppCubit>().state;
    final generation = _generation;
    final videos = collection.tracks.map((track) => track.toVideo()).toList();
    final query = _playlistFindQuery.text;
    final terms = _findingPlaylist ? musicSearchTerms(query) : const <String>[];
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: collection.id,
        displayTitle: collection.title,
        profileId: db.profileId);
    final order = MusicCollectionSortMenu.playlistOrder(context, reference);
    final displayIndices =
        order.orderIndices(videos, sortValue: musicPlaylistTrackSortValue);
    String matchText(int index) {
      final track = collection.tracks[index];
      return normalizeMusicSearchText(
          '${track.title} ${track.artists.join(' ')} ${track.albumTitle ?? ''}');
    }

    // Sort and filter a projection, keeping the playback queue in source order.
    final matching = [
      for (final index in displayIndices)
        if (terms.isEmpty || terms.every(matchText(index).contains)) index,
    ];
    final loadStatus = collection.loadingComplete
        ? null
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_findingPlaylist) Text(locals.musicPlaylistFindPartial),
                if (_loading)
                  Text(locals.playlistLoadingMore)
                else ...[
                  if (_failure != null) Text(locals.playlistLoadFailed),
                  TextButton(
                    onPressed: () => unawaited(
                        _openCollection(collection.id, retrying: true)),
                    child:
                        Text(_failure != null ? locals.retry : locals.loadMore),
                  ),
                ],
              ],
            ),
          );
    final details = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _artwork(collection.thumbnails),
        const SizedBox(height: 12),
        Text(collection.title, style: Theme.of(context).textTheme.titleLarge),
        if (validMusicAlbumPlaylistId(collection.id) != null)
          Text(locals.musicCatalogRelease),
        if (collection.playlistAuthor case final author?)
          _artistByline(
            [locals.musicCatalogPlaylistAuthor(author.name)],
            [
              MusicArtistCredit(
                name: locals.musicCatalogPlaylistAuthor(author.name),
                id: author.id,
              ),
            ],
          )
        else if (collection.artists.isNotEmpty)
          _artistByline(
            collection.artists,
            MusicArtistCredit.fromCatalog(
              collection.artists,
              collection.artistLinks,
            ),
          ),
        if (collection.description case final description?)
          MusicCatalogDescription(title: collection.title, text: description),
        PlaylistInformation(
            playlist: Playlist(
                title: collection.title,
                playlistId: collection.id,
                author: collection.artists.join(', '),
                videoCount: collection.videoCount ?? collection.tracks.length,
                updated: collection.updated,
                videos: videos),
            reference: reference,
            complete: collection.loadingComplete,
            enabled: !_starting),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
                key: const ValueKey('music-play-all'),
                onPressed:
                    !collection.loadingComplete || collection.tracks.isEmpty
                        ? null
                        : () => _play(collection.tracks, reference: reference),
                icon: const Icon(Icons.play_arrow),
                label: Text(locals.musicPlayAll)),
            if (collection.tracks.isNotEmpty)
              MusicCollectionSortMenu.playlist(
                reference: reference,
                order: order,
                compact: true,
                isCurrent: () =>
                    mounted &&
                    _collection?.id == collection.id &&
                    _sameSession(session),
              ),
            if (collection.loadingComplete && videos.isNotEmpty)
              MusicPlaylistSelectionActions.wholePlaylist(
                videos: videos,
                recommendationSource: reference,
                isCurrent: () =>
                    !_starting &&
                    identical(_collection, collection) &&
                    _active(generation, session),
                onPlay: (shuffle) => _playVideos(videos,
                    reference: reference, shuffleOnce: shuffle),
              ),
          ],
        ),
        MusicPlaylistResume(
            reference: reference,
            videos: videos,
            enabled: collection.loadingComplete && !_starting,
            onPlay: (index, position) => _play(collection.tracks,
                reference: reference, startIndex: index, startAt: position)),
        const SizedBox(height: 8),
        MusicBookmarkButton(
            entry: MusicLibraryEntry.collection(collection, album: false)),
        if (collection.loadingComplete)
          MusicLibraryActions(
              videos: videos, compact: false, recommendationSource: reference),
        MusicPlaylistRecommendationToggle(reference: reference),
        if (!_findingPlaylist && loadStatus != null) loadStatus,
      ]),
    );
    return MusicCollectionPanes(
      detailsKey: PageStorageKey((
        'music-catalog-collection-details',
        session.profileId,
        session.sessionRevision,
        collection.id
      )),
      details: details,
      buildTracks: (_, split) {
        final header = <Widget>[
          if (!split && !_findingPlaylist) details,
          if (matching.isEmpty && collection.loadingComplete)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(terms.isEmpty
                  ? locals.musicEmptyCollection
                  : locals.musicNoResults),
            ),
        ];
        final tracksKey = PageStorageKey((
          'music-catalog-collection-tracks',
          session.profileId,
          session.sessionRevision,
          collection.id
        ));
        final view = ListView.builder(
          key: _findingPlaylist
              ? ValueKey(('music-playlist-find', query))
              : tracksKey,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: header.length + matching.length,
          itemBuilder: (_, position) => position < header.length
              ? header[position]
              : _song(
                  collection.tracks, matching[position - header.length], layout,
                  reference: reference),
        );
        final tracks = MusicFastScroll(
          scope: (
            session.profileId,
            collection.id,
            order,
            _findingPlaylist,
            query
          ),
          leadingItems: header.length,
          sections: musicFastScrollSectionsFor<int>(context, matching,
              sortValue: order.field == MusicCollectionSortField.source
                  ? null
                  : (index) => MusicCollectionOrder.normalizeSortValue(
                      musicPlaylistTrackSortValue(videos[index], order.field))),
          child: view,
        );
        if (!_findingPlaylist) return tracks;
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  key: const ValueKey('music-public-playlist-query'),
                  controller: _playlistFindQuery,
                  focusNode: _playlistFindInput,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _playlistFindInput.unfocus(),
                  decoration: InputDecoration(
                    labelText: locals.musicSearchPlaylist,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: MaterialLocalizations.of(context)
                                .clearButtonTooltip,
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setState(_playlistFindQuery.clear);
                              _playlistFindInput.requestFocus();
                            },
                          ),
                  ),
                ),
              ),
              if (loadStatus != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: loadStatus,
                ),
              Expanded(child: tracks),
            ]);
      },
    );
  }

  Widget _artistResults(MusicArtistPage artistPage, MusicLayout layout) {
    final locals = AppLocalizations.of(context)!;
    final session = context.read<AppCubit>().state;
    final details = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChannelAvatar(
            musicArtwork: true,
            name: artistPage.artist.name,
            instanceOnly: true,
            images: artistPage.artist.thumbnails,
            size: 56,
          ),
          const SizedBox(height: 12),
          Text(
            artistPage.artist.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          MusicBookmarkButton(
            entry: MusicLibraryEntry.artist(artistPage.artist),
          ),
          if (normalizeChannelId(artistPage.artist.id) case final channelId?)
            TextButton(
              onPressed: () =>
                  context.router.push(ChannelRoute(channelId: channelId)),
              child: Text(locals.musicCatalogViewChannel),
            ),
          if (artistPage.description case final String description
              when description.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: MusicCatalogDescription(
                title: artistPage.artist.name,
                text: description,
              ),
            ),
        ],
      ),
    );
    final listing = _artistReleases;
    final releases = listing == null
        ? const <Widget>[]
        : _artistReleaseTiles(artistPage.artist.id, listing);
    final uploads = listing?.uploads ?? artistPage.songs;
    final librarySession = MusicLibrarySession(context.read<AppCubit>());
    final playAll = Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: FilledButton.icon(
          key: const ValueKey('music-play-artist-songs'),
          onPressed: () => _play(uploads, queueTitle: artistPage.artist.name),
          icon: const Icon(Icons.play_arrow),
          label: Text(locals.musicPlayAll),
        ),
      ),
    );
    return ListenableBuilder(
      listenable: librarySession.library.changes,
      builder: (context, _) {
        final saved = _savedArtistTracks(librarySession, artistPage.artist.id);
        return MusicCollectionPanes(
          detailsKey: PageStorageKey((
            'music-catalog-artist-details',
            session.profileId,
            session.sessionRevision,
            artistPage.artist.id,
          )),
          details: Column(
            children: [details, if (uploads.isNotEmpty) playAll, ...releases],
          ),
          buildTracks: (_, split) => ListView(
            key: PageStorageKey((
              'music-catalog-artist-tracks',
              session.profileId,
              session.sessionRevision,
              artistPage.artist.id,
            )),
            children: [
              if (!split) ...[details, ...releases],
              if (saved.isNotEmpty) ...[
                _sectionTitle(locals.musicSavedSongs),
                for (var i = 0; i < saved.length; i++)
                  _song(
                    saved,
                    i,
                    layout,
                    section: 'artist-saved-',
                    queueTitle: artistPage.artist.name,
                  ),
              ],
              _sectionTitle(locals.musicChannelUploads),
              if (listing?.uploadsLoading == true)
                _artistSectionProgress(locals.musicChannelUploads)
              else if (listing?.uploadsFailed == true)
                ListTile(
                  title: Text(locals.musicCatalogError),
                  trailing: TextButton(
                    key: const ValueKey('music-retry-artist-uploads'),
                    onPressed: () => _loadArtistUploads(
                      artistPage.artist.id,
                      listing!,
                      session,
                    ),
                    child: Text(locals.retry),
                  ),
                )
              else if (uploads.isNotEmpty) ...[
                if (!split) playAll,
                for (var i = 0; i < uploads.length; i++)
                  _song(uploads, i, layout, queueTitle: artistPage.artist.name),
              ] else
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(locals.musicArtistEmpty),
                ),
            ],
          ),
        );
      },
    );
  }

  List<MusicTrack> _savedArtistTracks(MusicLibrarySession session, String id) {
    if (!session.isCurrent) return const [];
    return [
      for (final entry in session.library.entries)
        if (entry.kind == MusicLibraryKind.song &&
            entry.artistCredits.any((credit) => credit.id == id))
          MusicTrack(
            videoId: entry.id,
            title: entry.title,
            artistCredits: entry.artistCredits,
            albumPlaylistId: entry.albumPlaylistId,
            albumTitle: entry.album,
            durationSeconds: entry.durationSeconds,
            thumbnails: entry.coverThumbnails,
            videoThumbnails: entry.displayThumbnails,
            isArtTrack: entry.isArtTrack,
          ),
    ];
  }

  Widget _artistSectionProgress(String label) => Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: MotionLoadingIndicator(
              child: CircularProgressIndicator(semanticsLabel: label),
            ),
          ),
        ),
      );

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
                  musicArtwork: true,
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
        _artistSectionProgress(locals.musicArtistReleases)
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

  String _searchLabel(MusicCatalogSearchType search, AppLocalizations locals) =>
      switch (search) {
        MusicCatalogSearchType.all => locals.musicSearchAll,
        MusicCatalogSearchType.songs => locals.musicSongs,
        MusicCatalogSearchType.channels => locals.channels,
        MusicCatalogSearchType.playlists => locals.musicPlaylists,
      };

  String _librarySearchLabel(
          MusicLibrarySearchType search, AppLocalizations locals) =>
      switch (search) {
        MusicLibrarySearchType.all => locals.musicSearchAll,
        MusicLibrarySearchType.songs => locals.musicSongs,
        MusicLibrarySearchType.playlists => locals.musicPlaylists,
      };

  Widget _searchFilters<T>(
    List<T> types, {
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> select,
  }) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: const ValueKey('music-search-filters'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        for (final type in types)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label(type)),
              selected: selected == type,
              backgroundColor: colors.surfaceContainerHigh,
              selectedColor: colors.secondaryContainer,
              side: BorderSide.none,
              shape: const StadiumBorder(),
              showCheckmark: false,
              onSelected: (_) => select(type),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => MusicScreenPrivacySurface(
        active: !widget.embedded,
        child: _buildMusicScreen(context),
      );

  Widget _buildMusicScreen(BuildContext context) {
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
    return MultiBlocListener(
      listeners: [
        BlocListener<AppCubit, AppState>(
          listenWhen: (before, after) =>
              before.profileId != after.profileId ||
              before.sessionRevision != after.sessionRevision ||
              before.server != after.server ||
              (!before.globalLoading && after.globalLoading) ||
              (!before.sessionRecoveryRequired &&
                  after.sessionRecoveryRequired),
          listener: (context, state) => _clearForSession(),
        ),
        if (context.read<SettingsCubit?>() != null)
          BlocListener<SettingsCubit, SettingsState>(
            listener: (context, state) {
              if (state.distractionFreeMode) _clearOnlineSuggestions();
              if (_onlineListing?.country != _searchCountry) {
                unawaited(_retireOnlinePagination());
              }
            },
          ),
      ],
      child: switch (_tvSong) {
        final song? => _MusicTvPlayer(
            videos: song.videos,
            queueTitle: song.queueTitle,
            startIndex: song.startIndex,
            startAt: song.startAt,
            songTap: song.songTap),
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

  Widget _browseUp(BuildContext context, AppLocalizations locals) {
    if (_findingPlaylist) {
      return IconButton(
        key: const ValueKey('music-browser-up'),
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        icon: const BackButtonIcon(),
        onPressed: _closePlaylistFind,
      );
    }
    final route = ModalRoute.of(context);
    final session = context.read<AppCubit>().state;
    final generation = _generation;
    final upLabel = _browseHistory.isEmpty && !_returnToOrigin
        ? locals.musicBackToSearch
        : MaterialLocalizations.of(context).backButtonTooltip;
    final rootLabel = _canReturnToBrowseCaller(route)
        ? locals.musicReturnToPreviousScreen
        : _searched
            ? locals.musicReturnToSearchResults
            : locals.musicBackToSearch;
    void returnToRoot() =>
        unawaited(_returnToBrowseRoot(route, session, generation));
    return MergeSemantics(
      child: Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: rootLabel): returnToRoot,
        },
        child: GestureDetector(
          excludeFromSemantics: true,
          onLongPress: returnToRoot,
          child: Tooltip(
            message: upLabel,
            triggerMode: TooltipTriggerMode.manual,
            child: IconButton(
              key: const ValueKey('music-browser-up'),
              onPressed: () {
                if (_returnToOrigin) {
                  Navigator.of(context).maybePop();
                } else {
                  _backToSearch();
                }
              },
              icon: const Icon(Icons.arrow_back),
            ),
          ),
        ),
      ),
    );
  }

  Widget _browser(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final showingSuggestions = _onlineSuggestions?.isCurrent() == true;
    final searchOutline = OutlineInputBorder(
        borderRadius: BorderRadius.circular(32), borderSide: BorderSide.none);
    return PopScope(
      canPop: !TickerMode.of(context) ||
          (!_findingPlaylist &&
              !showingSuggestions &&
              _shortcutBack == null &&
              (!_hasBrowsePage || _returnToOrigin || _returningToOrigin)),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _returningToOrigin || !TickerMode.of(context)) return;
        if (_findingPlaylist) {
          _closePlaylistFind();
        } else if (showingSuggestions) {
          _clearOnlineSuggestions();
          _queryFocus.unfocus();
        } else if (_hasBrowsePage && !_returnToOrigin) {
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
                  leading: _hasBrowsePage ? _browseUp(context, locals) : null,
                  actions: [
                    if (_collection != null && !_findingPlaylist)
                      IconButton(
                        key: const ValueKey('music-public-playlist-find'),
                        focusNode: _playlistFindButton,
                        tooltip: locals.musicSearchPlaylist,
                        onPressed: _openPlaylistFind,
                        icon: const Icon(Icons.search),
                      ),
                  ],
                ),
          body: SafeArea(
            child: Padding(
              padding: isTv
                  ? EdgeInsets.symmetric(
                      horizontal: TvOverscan.horizontal,
                      vertical: TvOverscan.vertical)
                  : EdgeInsets.zero,
              child: LayoutBuilder(builder: (context, constraints) {
                final layout = context.select((SettingsCubit? cubit) =>
                    cubit?.state.musicLayout ?? const MusicLayout.defaults());
                if (_findingPlaylist) return _results(layout);
                Widget controls =
                    Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: _withOnlineRecents(TextField(
                      key: const ValueKey('music-search'),
                      controller: _search,
                      focusNode: _queryFocus,
                      enableIMEPersonalizedLearning: !_searchingLibrary,
                      textInputAction: TextInputAction.search,
                      onChanged: _searchInputChanged,
                      onSubmitted: (_) => _submitActiveSearch(),
                      decoration: InputDecoration(
                          hintText: _searchingLibrary
                              ? locals.musicSearchLibraryHint
                              : locals.musicInvidiousSearchHint,
                          filled: true,
                          fillColor: colors.surfaceContainerHigh,
                          border: searchOutline,
                          focusedBorder: searchOutline.copyWith(
                              borderSide: BorderSide(color: colors.primary)),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 14),
                          prefixIcon: _voiceSearchAvailable
                              ? IconButton(
                                  key: const ValueKey('music-voice-search'),
                                  tooltip: locals.musicVoiceSearch,
                                  onPressed: _voiceSearchPending
                                      ? null
                                      : _startVoiceSearch,
                                  icon: const Icon(Icons.mic),
                                )
                              : null,
                          suffixIcon: IconButton(
                              autofocus: isTv,
                              tooltip: locals.search,
                              onPressed: _submitActiveSearch,
                              icon: const Icon(Icons.search))),
                    )),
                  ),
                  if (_canSwitchSearchSource &&
                      !_hasBrowsePage &&
                      !(_browseRequest && _loading))
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                        child: SegmentedButton<_MusicSearchSource>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: _MusicSearchSource.online,
                              label: Text(locals.musicSearchOnlineSource,
                                  key: const ValueKey(
                                      'music-search-source-online')),
                            ),
                            ButtonSegment(
                              value: _MusicSearchSource.library,
                              label: Text(locals.musicLibrary,
                                  key: const ValueKey(
                                      'music-search-source-library')),
                            ),
                          ],
                          selected: {_searchSource},
                          onSelectionChanged: (sources) =>
                              _selectSearchSource(sources.single),
                        ),
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
                    if (_searchingLibrary)
                      _searchFilters(
                        MusicLibrarySearchType.values,
                        selected: _libraryType,
                        label: (type) => _librarySearchLabel(type, locals),
                        select: _selectLibraryType,
                      )
                    else
                      _searchFilters(
                        [
                          MusicCatalogSearchType.songs,
                          if (_canSwitchSearchSource)
                            MusicCatalogSearchType.all,
                          MusicCatalogSearchType.channels,
                          MusicCatalogSearchType.playlists,
                        ],
                        selected: _type,
                        label: (type) => _searchLabel(type, locals),
                        select: _selectOnlineType,
                      ),
                  const SizedBox(height: 8),
                ]);
                if (widget.embedded && getDeviceType() == DeviceType.phone) {
                  // Reserve room for results whenever the query controls fit.
                  // In a short viewport the remaining controls can scroll.
                  final minimumQueryHeight =
                      MediaQuery.textScalerOf(context).scale(16) + 52;
                  final resultsSpace =
                      (constraints.maxHeight - minimumQueryHeight)
                          .clamp(0.0, 64.0);
                  controls = ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight - resultsSpace),
                    child: SingleChildScrollView(child: controls),
                  );
                }
                return Column(
                    children: [controls, Expanded(child: _results(layout))]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// The source route shares the player that opened it, including on TV.
class _PlayingMusicSourceRoute extends MaterialPageRoute<void> {
  _PlayingMusicSourceRoute(
      Widget page, PlayerCubit player, AppCubit app, AppState session)
      : super(builder: (_) {
          return MultiBlocProvider(
            providers: [
              BlocProvider.value(value: player),
              BlocProvider.value(value: app),
            ],
            child: BlocBuilder<AppCubit, AppState>(builder: (context, state) {
              final sameSession = !state.globalLoading &&
                  !state.sessionRecoveryRequired &&
                  state.profileId == db.profileId &&
                  state.profileId == session.profileId &&
                  state.sessionRevision == session.sessionRevision &&
                  state.server == session.server;
              return PlayerModalBackHandler(
                priority: 5,
                onBack: () => unawaited(Navigator.of(context).maybePop()),
                child: sameSession
                    ? page
                    : Scaffold(
                        appBar: AppBar(),
                        body: Center(
                            child: Text(AppLocalizations.of(context)!
                                .musicSourceUnavailable))),
              );
            }),
          );
        });
}

/// TV routes own their player, as the TV home does not mount the phone player.
class _MusicTvPlayer extends StatelessWidget {
  final List<Video> videos;
  final String? queueTitle;
  final ({
    String title,
    bool Function() isCurrent,
    List<PlaylistReference?>? recommendationSources,
  })? collectionQueue;
  final List<LocalMusicTrack>? localTracks;
  final List<OnDeviceMusicEntry>? onDeviceTracks;
  final bool Function()? onDeviceMusicIsCurrent;
  final bool resumeSession;
  final PlaylistReference? reference;
  final PlaylistReference? recommendationSource;
  final int startIndex;
  final Duration startAt;
  final bool shuffleOnce;
  final bool songTap;
  final Future<bool?> Function(PlayerCubit)? startMix;

  const _MusicTvPlayer(
      {required this.videos,
      this.queueTitle,
      this.collectionQueue,
      this.localTracks,
      this.onDeviceTracks,
      this.onDeviceMusicIsCurrent,
      this.resumeSession = false,
      this.reference,
      this.recommendationSource,
      this.startIndex = 0,
      this.startAt = Duration.zero,
      this.shuffleOnce = false,
      this.songTap = false,
      this.startMix});

  @override
  Widget build(BuildContext context) =>
      MusicScreenPrivacySurface(child: _buildPlayer(context));

  Widget _buildPlayer(BuildContext context) {
    // Startup and retry must assign a tapped occurrence from the same source.
    final initial = PlayerState.init(resumeSession || songTap ? null : videos);
    return BlocProvider(
      create: (context) => PlayerCubit(
          initial.copyWith(
              videos: songTap && !resumeSession ? videos : initial.videos,
              isAudio: true,
              isMini: false,
              isHidden: false,
              startAt: startAt),
          context.read<SettingsCubit>(),
          resume: resumeSession,
          fromMusic: true,
          initialSongTap: songTap,
          initialLocalMusic: localTracks,
          initialOnDeviceMusic: onDeviceTracks,
          initialOnDeviceMusicIsCurrent: onDeviceMusicIsCurrent,
          initialQueueTitle: queueTitle,
          initialMusicCollection: collectionQueue,
          initialMusicMix: startMix,
          playlistReference: reference,
          initialRecommendationSource: recommendationSource,
          startIndex: startIndex,
          playlistShuffleOnce: shuffleOnce,
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
                final mix = startMix;
                if (mix != null &&
                    state.currentlyPlaying == null &&
                    state.mediaEvent.state == MediaState.error) {
                  return _MusicPlaybackFailure(
                      onRetry: () => player.startInitialMusicMix(mix));
                }
                final tracks = localTracks;
                final onDevice = onDeviceTracks;
                final saved = player.savedSession;
                final pinned = saved != null &&
                    saved.offlineFingerprints.containsKey(saved.currentId);
                if (collectionQueue case final collection?) {
                  context.watch<AppCubit>();
                  if (!collection.isCurrent()) {
                    return Center(
                        child: Text(AppLocalizations.of(context)!
                            .musicSourceUnavailable));
                  }
                  if (state.isClosing ||
                      state.videos.isEmpty ||
                      (state.currentlyPlaying == null &&
                          state.mediaEvent.state == MediaState.error)) {
                    return _MusicPlaybackFailure(
                        onRetry: () => player.playMusicCollectionQueue(videos,
                            queueTitle: collection.title,
                            isCurrent: collection.isCurrent,
                            recommendationSources:
                                collection.recommendationSources));
                  }
                }
                if (state.currentlyPlaying == null &&
                    state.offlineCurrentlyPlaying == null &&
                    (tracks != null ||
                        onDevice != null ||
                        resumeSession &&
                            (saved?.currentDeviceId != null || pinned))) {
                  if (state.isClosing ||
                      state.mediaEvent.state == MediaState.error) {
                    return _MusicPlaybackFailure(
                        onRetry: onDevice != null
                            ? () => player.playOnDeviceMusic(onDevice,
                                startIndex: startIndex,
                                queueTitle: queueTitle,
                                songTap: songTap,
                                isCurrent: onDeviceMusicIsCurrent)
                            : tracks == null
                                ? player.resumeSession
                                : () => player.playLocalMusic(tracks,
                                    startIndex: startIndex,
                                    queueTitle: queueTitle,
                                    songTap: songTap));
                  }
                  return const Center(child: CircularProgressIndicator());
                }
                if (state.isClosing ||
                    (state.videos.isEmpty && state.offlineVideos.isEmpty)) {
                  return _MusicPlaybackFailure(
                      onRetry: mix != null
                          ? () => player.startInitialMusicMix(mix)
                          : resumeSession
                              ? player.resumeSession
                              : () => reference == null
                                  ? player.playVideo(videos,
                                      queueTitle: queueTitle,
                                      fromMusic: true,
                                      recommendationSource:
                                          recommendationSource,
                                      audio: true,
                                      startAt: startAt,
                                      startIndex: startIndex,
                                      songTap: songTap)
                                  : player.playPlaylist(videos,
                                      fromMusic: true,
                                      reference: reference!,
                                      startIndex: startIndex,
                                      shuffleOnce: shuffleOnce,
                                      audio: true,
                                      startAt: startAt,
                                      songTap: songTap));
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
  final PlaybackFailureReason? reason;

  const _MusicPlaybackFailure({required this.onRetry, this.reason});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(playbackFailureText(locals, reason, music: true),
            textAlign: TextAlign.center),
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
                  reason: player.playbackFailureReason,
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
                      onPressed:
                          state.hasQueue || player.hasMusicRequestSuccessor
                              ? player.playNext
                              : null,
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
