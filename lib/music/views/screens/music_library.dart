import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/models/music_collection_order.dart';
import 'package:clipious/music/models/music_download_order.dart';
import 'package:clipious/music/models/device_playlist_track.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_layout.dart';
import 'package:clipious/music/models/music_playlist_selection.dart';
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_search.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_playlist_covers.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/services/music_playlist_folder_service.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/cached_music_library.dart';
import 'package:clipious/music/services/music_visibility.dart';
import 'package:clipious/music/views/components/music_collection_panes.dart';
import 'package:clipious/music/views/components/music_collection_selection_bar.dart';
import 'package:clipious/music/views/components/music_collection_sort_menu.dart';
import 'package:clipious/music/views/components/music_details_dialog.dart';
import 'package:clipious/music/views/components/music_download_removal.dart';
import 'package:clipious/music/views/components/music_download_storage_summary.dart';
import 'package:clipious/music/views/components/music_duration_label.dart';
import 'package:clipious/music/views/components/music_fast_scroll.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_song_row_swipe.dart';
import 'package:clipious/music/views/components/music_offline_filter.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/music/views/components/music_playlist_edit_actions.dart';
import 'package:clipious/music/views/components/music_playlist_rename.dart';
import 'package:clipious/music/views/components/music_playlist_cover.dart';
import 'package:clipious/music/views/components/music_playlist_recovery.dart';
import 'package:clipious/music/views/components/music_playlist_folder_actions.dart';
import 'package:clipious/music/views/components/music_playlist_recommendation_toggle.dart';
import 'package:clipious/music/views/components/m3u_playlist_actions.dart';
import 'package:clipious/music/views/components/music_playlist_resume.dart';
import 'package:clipious/music/views/components/music_playlist_suggestions.dart';
import 'package:clipious/music/views/components/music_playlist_offline.dart';
import 'package:clipious/music/views/components/music_saved_queues.dart';
import 'package:clipious/music/views/components/music_screen_privacy.dart';
import 'package:clipious/music/views/components/music_playlist_hidden_songs.dart';
import 'package:clipious/music/views/components/music_playlist_undo.dart';
import 'package:clipious/music/views/components/music_saved_song_removal.dart';
import 'package:clipious/music/views/components/music_song_selection_bar.dart';
import 'package:clipious/music/views/components/music_status_title.dart';
import 'package:clipious/music/views/components/takeout_import_dialog.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_history.dart';
import 'package:clipious/music/views/screens/music_rule_playlists.dart';
import 'package:clipious/music/views/screens/music_layout_editor.dart';
import 'package:clipious/music/views/screens/music_listening_statistics.dart';
import 'package:clipious/music/views/screens/music_automatic_collections.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/podcasts/views/podcast_library.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/views/components/playlist_information.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_watch_progress.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:videre_proxy/videre_proxy.dart';

enum _LibraryFilter {
  all(null),
  playlists(MusicLibraryCategory.playlists),
  songs(MusicLibraryCategory.songs),
  onDevice(MusicLibraryCategory.onDevice),
  channels(MusicLibraryCategory.channels),
  downloads(MusicLibraryCategory.downloads),
  podcasts(MusicLibraryCategory.podcasts),
  cachedSongs(MusicLibraryCategory.cachedSongs);

  const _LibraryFilter(this.category);

  final MusicLibraryCategory? category;

  static final byCategory = {
    for (final filter in values)
      if (filter.category case final category?) category: filter,
  };
}

typedef _LibraryItem = ({Playlist? playlist, MusicLibraryEntry? bookmark});
typedef _LibrarySelection = ({
  _LibraryFilter filter,
  Set<String> ids,
  double? offset,
  bool savedSongs,
});

/// The Music home's Library body, or a standalone detail for a local source.
class MusicLibraryPage extends StatefulWidget {
  final PlaylistReference? source;
  final LocalMusicLibrary? deviceLibrary;

  const MusicLibraryPage({super.key, this.source, this.deviceLibrary});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  late _LibraryFilter _filter;
  bool _grid = !isTv;
  String? _playlistId;
  String? _folderId;
  Object? _suggestedShuffle;
  MusicLibrarySession? _sourceSession;
  final _playlistQuery = TextEditingController();
  final _playlistQueryFocus = FocusNode(debugLabel: 'Music playlist query');
  final _playlistSearchFocus = FocusNode(debugLabel: 'Search Music playlist');
  final _playlistSelectFocus = FocusNode(debugLabel: 'Select playlist songs');
  final _playlistExitSelectionFocus =
      FocusNode(debugLabel: 'Close playlist selection');
  final _playlistSelection = MusicPlaylistSelection();
  (String, String?)? _playlistScan;
  Object? _playlistSelectionScope;
  bool get _playlistSelecting => _playlistSelectionScope != null;
  final _playlistScroll = ScrollController(keepScrollOffset: false);
  bool _playlistSearching = false;
  double? _playlistOffsetBeforeSearch;
  final _libraryQuery = TextEditingController();
  final _libraryQueryFocus = FocusNode(debugLabel: 'Library query');
  final _libraryFindFocus = FocusNode(debugLabel: 'Search Music Library');
  final _librarySelectFocus = FocusNode(debugLabel: 'Select library songs');
  final _libraryExitSelectionFocus =
      FocusNode(debugLabel: 'Close library selection');
  final _libraryFindScroll = ScrollController(keepScrollOffset: false);
  _LibraryFilter? _findFilter;
  bool get _savedSongsFinding => _findFilter == _LibraryFilter.songs;
  final _downloadSearchText = Expando<String>();
  _LibrarySelection? _librarySelection;
  Set<String>? get _savedSongsSelection =>
      _librarySelection?.savedSongs == true ? _librarySelection!.ids : null;
  Set<String>? get _downloadsSelection =>
      _selectionIn(_LibraryFilter.downloads);
  Set<String>? get _collectionSelection => _savedSongsSelection != null
      ? null
      : _selectionIn(_LibraryFilter.all) ??
          _selectionIn(_LibraryFilter.playlists);
  int _collectionSelectionRevision = 0;

  Set<String>? _selectionIn(_LibraryFilter filter) {
    final selection = _librarySelection;
    return selection != null && selection.filter == filter
        ? selection.ids
        : null;
  }

  @override
  void initState() {
    super.initState();
    final saved = context.read<SettingsCubit?>()?.state.musicLayout;
    _filter = _defaultFilter(_categoryFilters(saved));
  }

  List<_LibraryFilter> _categoryFilters(MusicLayout? layout) => [
        for (final category in (layout ?? const MusicLayout.defaults())
            .visibleLibraryCategories)
          if (category.isAvailable(
              tv: isTv,
              deviceFolders: supportsLocalMusicFolders,
              playbackCache: PlaybackCache.supported))
            _LibraryFilter.byCategory[category]!,
      ];

  _LibraryFilter _defaultFilter(List<_LibraryFilter> filters) =>
      isTv ? filters.firstOrNull ?? _LibraryFilter.all : _LibraryFilter.all;

  @override
  void didUpdateWidget(MusicLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _sourceSession = null;
      _folderId = null;
      _resetPlaylistSearch();
      _resetLibraryFind();
    }
  }

  @override
  void dispose() {
    _playlistScroll.dispose();
    _playlistQuery.dispose();
    _playlistQueryFocus.dispose();
    _playlistSearchFocus.dispose();
    _playlistSelectFocus.dispose();
    _playlistExitSelectionFocus.dispose();
    _libraryFindScroll.dispose();
    _libraryQuery.dispose();
    _libraryQueryFocus.dispose();
    _libraryFindFocus.dispose();
    _librarySelectFocus.dispose();
    _libraryExitSelectionFocus.dispose();
    super.dispose();
  }

  void _resetLibraryFind() {
    _findFilter = null;
    _librarySelection = null;
    _libraryQueryFocus.unfocus();
    _libraryQuery.clear();
  }

  void _toggleLibraryFind(_LibraryFilter filter) {
    if (_filter != filter || _librarySelection != null) return;
    final opening = _findFilter != filter;
    if (opening) {
      setState(() => _findFilter = filter);
    } else {
      setState(_resetLibraryFind);
    }
    final session = context.read<AppCubit>().state;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          (_findFilter == filter) != opening ||
          _librarySelection != null ||
          _filter != filter ||
          !TickerMode.of(context)) {
        return;
      }
      final current = context.read<AppCubit>().state;
      if (current.profileId != session.profileId ||
          current.sessionRevision != session.sessionRevision) {
        return;
      }
      final focus = opening ? _libraryQueryFocus : _libraryFindFocus;
      if (focus.context != null) focus.requestFocus();
    });
  }

  void _jumpToLibraryFindStart() {
    if (_libraryFindScroll.hasClients && _libraryFindScroll.offset != 0) {
      _libraryFindScroll.jumpTo(0);
    }
  }

  void _startLibrarySelection(_LibraryFilter filter,
      {String? rowId, bool savedSongs = false}) {
    if (_filter != filter || _librarySelection != null) return;
    final ids = <String>{if (rowId != null) rowId};
    _libraryQueryFocus.unfocus();
    setState(() {
      _librarySelection = (
        filter: filter,
        ids: ids,
        savedSongs: savedSongs,
        offset: _findFilter == filter && _libraryFindScroll.hasClients
            ? _libraryFindScroll.offset
            : null,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(_librarySelection?.ids, ids) &&
          TickerMode.of(context)) {
        _libraryExitSelectionFocus.requestFocus();
      }
    });
  }

  void _exitLibrarySelection() {
    final selection = _librarySelection;
    if (!mounted || selection == null) return;
    final offset = selection.offset;
    final session = context.read<AppCubit>().state;
    setState(() => _librarySelection = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _librarySelection != null ||
          _filter != selection.filter ||
          !TickerMode.of(context)) {
        return;
      }
      final current = context.read<AppCubit>().state;
      if (current.profileId != session.profileId ||
          current.sessionRevision != session.sessionRevision) {
        return;
      }
      if (offset != null && _libraryFindScroll.hasClients) {
        final position = _libraryFindScroll.position;
        _libraryFindScroll.jumpTo(offset
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble());
      }
      // Restoring an offscreen toolbar's focus would scroll Find back to it.
      if ((!selection.savedSongs || selection.filter == _LibraryFilter.songs) &&
          (_findFilter != selection.filter || offset == 0) &&
          _librarySelectFocus.context != null) {
        _librarySelectFocus.requestFocus();
      }
    });
  }

  void _toggleLibrarySelection(String id) {
    final ids = _librarySelection?.ids;
    if (ids == null) return;
    setState(() {
      if (!ids.remove(id)) ids.add(id);
      if (identical(ids, _collectionSelection)) _collectionSelectionRevision++;
    });
  }

  void _resetPlaylistSearch() {
    _suggestedShuffle = null;
    _playlistSelectionScope = null;
    _playlistSelection.clear();
    _playlistSearching = false;
    _playlistOffsetBeforeSearch = null;
    _playlistQueryFocus.unfocus();
    _playlistQuery.clear();
  }

  void _jumpToPlaylistResults() {
    if (_playlistScroll.hasClients && _playlistScroll.offset != 0) {
      _playlistScroll.jumpTo(0);
    }
  }

  void _togglePlaylistSearch() {
    if (!_playlistSearching) {
      _playlistOffsetBeforeSearch =
          _playlistScroll.hasClients ? _playlistScroll.offset : null;
      setState(() => _playlistSearching = true);
      _jumpToPlaylistResults();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _playlistSearching &&
            !_playlistSelecting &&
            TickerMode.of(context)) {
          _playlistQueryFocus.requestFocus();
        }
      });
      return;
    }
    final offset = _playlistOffsetBeforeSearch;
    final playlist = _playlistId;
    final source = widget.source;
    setState(_resetPlaylistSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _playlistSearching ||
          playlist != _playlistId ||
          source != widget.source ||
          !TickerMode.of(context)) {
        return;
      }
      if (offset != null && _playlistScroll.hasClients) {
        final position = _playlistScroll.position;
        _playlistScroll.jumpTo(offset
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble());
      }
      _playlistSearchFocus.requestFocus();
    });
  }

  void _backFromLocalPlaylist() {
    if (_playlistSelecting) {
      _exitPlaylistSelection();
    } else if (_playlistSearching) {
      _togglePlaylistSearch();
    } else {
      setState(() {
        _playlistId = null;
        _suggestedShuffle = null;
      });
    }
  }

  void _startPlaylistSelection([String? rowId]) {
    final scope = Object();
    _playlistQueryFocus.unfocus();
    setState(() {
      _playlistSelectionScope = scope;
      if (rowId != null) _playlistSelection.toggle(rowId);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_playlistSelectionScope, scope)) {
        _playlistExitSelectionFocus.requestFocus();
      }
    });
  }

  void _exitPlaylistSelection() {
    if (!mounted || !_playlistSelecting) return;
    setState(() {
      _playlistSelectionScope = null;
      _playlistSelection.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_playlistSelecting && TickerMode.of(context)) {
        _playlistSelectFocus.requestFocus();
      }
    });
  }

  Future<void> _play(List<Video> videos,
      {PlaylistReference? reference,
      String? queueTitle,
      int? startIndex,
      Duration startAt = Duration.zero,
      bool shuffleOnce = false,
      bool songTap = false,
      bool collectionDetail = false}) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent ||
        _sourceSession?.isCurrent == false ||
        videos.isEmpty) {
      return;
    }
    try {
      await MusicScreen.playTracks(context, videos,
          reference: reference,
          queueTitle: queueTitle,
          startIndex: startIndex,
          startAt: startAt,
          shuffleOnce: shuffleOnce,
          songTap: songTap,
          collectionDetail: collectionDetail);
    } catch (_) {
      if (mounted && session.isCurrent) _error();
    }
  }

  Future<void> _playOffline(List<Video> videos, MusicOfflineView offline,
      {required String title,
      int startIndex = 0,
      PlaylistReference? reference}) async {
    if (!offline.isCurrent() ||
        videos.isEmpty ||
        _sourceSession?.isCurrent == false) {
      return;
    }
    try {
      await MusicScreen.playCollectionTracks(context, videos,
          queueTitle: title,
          startIndex: startIndex,
          recommendationSources: reference == null
              ? null
              : List<PlaylistReference?>.filled(videos.length, reference),
          isCurrent: offline.isCurrent);
    } catch (_) {
      if (mounted && offline.isCurrent()) _error();
    }
  }

  Future<void> _playSuggestedShuffle(
      Playlist playlist, List<Video> songs, PlaylistReference reference) async {
    if (_suggestedShuffle != null) return;
    final source = widget.source;
    final session = MusicLibrarySession(context.read<AppCubit>());
    final player = context.read<PlayerCubit>();
    final catalog = musicCatalogService;
    final route = ModalRoute.of(context);
    final tickerMode = TickerMode.getNotifier(context);
    final request = Object();
    bool current() =>
        mounted &&
        identical(_suggestedShuffle, request) &&
        session.isCurrent &&
        reference.profileId == session.library.profileId &&
        _sourceSession?.isCurrent != false &&
        widget.source == source &&
        (source != null || _playlistId == playlist.playlistId) &&
        !_playlistSelecting &&
        !_playlistSearching &&
        route?.isCurrent != false &&
        tickerMode.value &&
        identical(musicCatalogService, catalog);
    final playlistContents = jsonEncode(playlist.videos);
    bool samePlaylist() => session.playlists.any((latest) =>
        latest.playlistId == playlist.playlistId &&
        jsonEncode(latest.videos) == playlistContents);
    final playbackRevision = player.musicSelectionRequestRevision;
    bool stillRequesting() =>
        current() &&
        !player.isClosed &&
        player.musicSelectionRequestRevision == playbackRevision;
    final originals = assignPlaylistEntryIds(songs)
        .where((song) =>
            !song.filtered && !song.filterHide && song.isUpcoming != true)
        .toList();
    if (originals.isEmpty) return;

    final locals = AppLocalizations.of(context)!;
    void showMessage(String message) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

    setState(() => _suggestedShuffle = request);
    try {
      if (!stillRequesting() || !samePlaylist()) return;
      final List<MusicTrack> candidates;
      try {
        candidates = await loadMusicPlaylistSuggestions(playlist, catalog,
            isCurrent: stillRequesting);
      } catch (_) {
        if (stillRequesting()) {
          showMessage(locals.musicPlaylistSuggestionsUnavailable);
        }
        return;
      }
      if (!mounted || !stillRequesting() || !samePlaylist()) return;
      final suggestions = eligibleMusicPlaylistSuggestions(
          playlist, reference.profileId, candidates);
      if (suggestions.isEmpty) {
        showMessage(locals.musicPlaylistNoSuggestions);
        return;
      }

      // Start with a playlist song and insert at most one suggestion per three
      // originals. The normal shuffle toggle stays independent of this queue.
      originals.shuffle();
      final insertions = suggestions.iterator;
      final queue = <Video>[];
      final sources = <PlaylistReference?>[];
      for (final (index, song) in originals.indexed) {
        queue.add(song);
        sources.add(reference);
        if (((index + 1) % 3 == 0 || index == originals.length - 1) &&
            insertions.moveNext()) {
          queue.add(markMusicQueueSuggestion(insertions.current.toVideo()));
          sources.add(null);
        }
      }
      await MusicScreen.playCollectionTracks(context, queue,
          queueTitle: playlist.title,
          recommendationSources: sources,
          isCurrent: () => current() && samePlaylist());
    } catch (_) {
      if (current()) _error();
    } finally {
      if (mounted && identical(_suggestedShuffle, request)) {
        setState(() => _suggestedShuffle = null);
      }
    }
  }

  void _error() => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.musicPlaybackError)));

  Future<void> _openBookmark(MusicLibraryEntry entry, List<_LibraryItem> items,
      {required bool songTap}) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || entry.kind == MusicLibraryKind.album) return;
    if (entry.kind == MusicLibraryKind.song) {
      if (_savedSongsFinding) _libraryQueryFocus.unfocus();
      final songs = [
        for (final item in items)
          if (item.bookmark case final song?
              when song.kind == MusicLibraryKind.song)
            song.toVideo(),
      ];
      final index = songs.indexWhere((song) => song.videoId == entry.id);
      if (index >= 0) {
        await _play(songs,
            startIndex: index,
            queueTitle: AppLocalizations.of(context)!.musicSavedSongs,
            songTap: songTap);
      }
      return;
    }
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(
              artistId: entry.kind == MusicLibraryKind.artist ? entry.id : null,
              playlistId:
                  entry.kind == MusicLibraryKind.playlist ? entry.id : null,
            )));
    if (mounted && session.isCurrent) setState(() {});
  }

  Widget _artwork(List<ImageObject> images,
          {IconData icon = Icons.music_note}) =>
      SizedBox.square(
        dimension: 52,
        child: images.isEmpty
            ? Icon(icon)
            : Thumbnail(
                musicArtwork: true,
                images: images,
                instanceOnly: true,
                decoration:
                    BoxDecoration(borderRadius: BorderRadius.circular(8))),
      );

  Widget _empty() => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(AppLocalizations.of(context)!.musicLibraryEmpty,
              textAlign: TextAlign.center)));

  Future<void> _removeBookmark(MusicLibraryEntry entry) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return;
    try {
      await session.library.remove(entry.kind, entry.id);
    } catch (_) {
      if (mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.musicLibraryActionError)));
      }
    }
  }

  Widget _bookmarkActions(
      MusicLibraryEntry entry, Future<void> Function() onOpen,
      {Video? offlineSong}) {
    final locals = AppLocalizations.of(context)!;
    final removeLabel = switch (entry.kind) {
      MusicLibraryKind.song => locals.musicRemoveSong,
      MusicLibraryKind.album => locals.musicRemoveAlbum,
      MusicLibraryKind.artist => locals.musicRemoveArtist,
      MusicLibraryKind.playlist => locals.musicRemovePlaylist,
    };
    return entry.kind == MusicLibraryKind.song
        ? MusicLibraryActions(
            videos: [offlineSong ?? entry.toVideo()],
            onPlay: onOpen,
            onSelectSong: _filter == _LibraryFilter.all
                ? () => _startLibrarySelection(_LibraryFilter.all,
                    rowId: entry.id, savedSongs: true)
                : null,
          )
        : IconButton(
            tooltip: removeLabel,
            onPressed: () => _removeBookmark(entry),
            icon: const Icon(Icons.bookmark_remove_outlined));
  }

  Widget _bookmarkArtwork(MusicLibraryEntry? entry, Widget fallback) {
    if (entry == null || entry.kind != MusicLibraryKind.song) return fallback;
    return CommunityMusicArtwork(
        videoId: entry.id,
        music: entry.toVideo().musicMetadata!,
        durationSeconds: entry.durationSeconds,
        fallback: fallback);
  }

  Widget _bookmarkTitle(MusicLibraryEntry? entry, Widget title) {
    if (entry == null) return title;
    return entry.kind == MusicLibraryKind.song
        ? MusicStatusTitle.song(video: entry.toVideo(), child: title)
        : MusicStatusTitle.bookmark(
            kind: entry.kind, id: entry.id, child: title);
  }

  String _bookmarkDisplayTitle(
          MusicLibraryEntry entry, MusicLibraryService library) =>
      entry.kind == MusicLibraryKind.artist
          ? library.artistDisplayName(
              MusicArtistIdentity.catalog(entry.id), entry.title)
          : entry.displayTitle;

  String _bookmarkDisplaySubtitle(MusicLibraryEntry entry, String displayTitle,
          MusicLibraryService library) =>
      entry.kind == MusicLibraryKind.artist && displayTitle != entry.title
          ? entry.title
          : library.catalogArtistByline(entry.subtitle, entry.artistCredits);

  Widget _bookmark(
      _LibraryItem item,
      Future<void> Function() onOpen,
      Future<void> Function() onPlay,
      MusicLayout layout,
      MusicLibraryService library,
      {Widget? movePlaylist,
      Video? offlineSong}) {
    final entry = item.bookmark!;
    final title = _bookmarkDisplayTitle(entry, library);
    final subtitle = _bookmarkDisplaySubtitle(entry, title, library);
    final selected = _itemSelected(item);
    final enabled = _librarySelection == null || selected != null;
    final artworkSize = layout.compactRows ? 40.0 : 52.0;
    final tile = ListTile(
        enabled: enabled,
        selected: selected ?? false,
        minTileHeight: layout.compactRows ? kMinInteractiveDimension : null,
        minVerticalPadding: layout.compactRows ? 4 : null,
        leading: entry.kind == MusicLibraryKind.artist
            ? ChannelAvatar(
                musicArtwork: true,
                name: entry.title,
                images: entry.thumbnails,
                size: artworkSize,
                instanceOnly: true)
            : SizedBox.square(
                dimension: artworkSize,
                child:
                    _bookmarkArtwork(entry, _artwork(entry.displayThumbnails))),
        title: _bookmarkTitle(
            entry,
            Text(title,
                maxLines: entry.kind == MusicLibraryKind.song
                    ? layout.titleLines(2)
                    : 2,
                overflow: TextOverflow.ellipsis)),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: selected != null
            ? ExcludeSemantics(
                child: Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank))
            : enabled
                ? _playlistRowActions(movePlaylist,
                    _bookmarkActions(entry, onPlay, offlineSong: offlineSong))
                : null,
        onLongPress: _itemLongPress(item),
        onTap: enabled ? onOpen : null);
    return MusicSongRowSwipe(
      key: _itemKey(item),
      onAction:
          enabled && selected == null && entry.kind == MusicLibraryKind.song
              ? (action) => MusicLibraryActions.queueSong(
                  context, offlineSong ?? entry.toVideo(), action)
              : null,
      child: tile,
    );
  }

  Widget _playlistSearchButton() => IconButton(
        key: const ValueKey('music-local-playlist-search'),
        focusNode: _playlistSearchFocus,
        tooltip: _playlistSearching
            ? MaterialLocalizations.of(context).closeButtonTooltip
            : AppLocalizations.of(context)!.musicSearchPlaylist,
        icon: Icon(_playlistSearching ? Icons.close : Icons.search),
        onPressed: _togglePlaylistSearch,
      );

  Widget _playlistSelectButton() => IconButton(
        key: const ValueKey('music-local-playlist-select'),
        focusNode: _playlistSelectFocus,
        tooltip: AppLocalizations.of(context)!.musicQueueSelect,
        icon: const Icon(Icons.checklist_rounded),
        onPressed: _startPlaylistSelection,
      );

  Widget _collectionSearchField({
    required Key key,
    required String label,
    required TextEditingController controller,
    required FocusNode focusNode,
    required VoidCallback onQueryChanged,
    bool compact = false,
  }) =>
      Padding(
        padding: EdgeInsetsDirectional.fromSTEB(16, 4, compact ? 0 : 16, 8),
        child: ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, input, _) => TextField(
            key: key,
            controller: controller,
            focusNode: focusNode,
            textInputAction: TextInputAction.search,
            onChanged: (_) => onQueryChanged(),
            decoration: InputDecoration(
              isDense: true,
              labelText: label,
              prefixIcon: compact ? null : const Icon(Icons.search),
              suffixIcon: input.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip:
                          MaterialLocalizations.of(context).clearButtonTooltip,
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        controller.clear();
                        onQueryChanged();
                        focusNode.requestFocus();
                      },
                    ),
            ),
          ),
        ),
      );

  Widget _playlistSearchField() => _collectionSearchField(
        key: const ValueKey('music-local-playlist-query'),
        label: AppLocalizations.of(context)!.musicSearchPlaylist,
        controller: _playlistQuery,
        focusNode: _playlistQueryFocus,
        onQueryChanged: _jumpToPlaylistResults,
      );

  Widget _libraryFindButton(Key key, _LibraryFilter filter, String label) {
    final finding = _findFilter == filter;
    return IconButton(
      key: key,
      focusNode: _libraryFindFocus,
      tooltip: finding
          ? MaterialLocalizations.of(context).closeButtonTooltip
          : label,
      icon: Icon(finding ? Icons.close : Icons.search),
      onPressed: () => _toggleLibraryFind(filter),
    );
  }

  Widget _librarySelectButton(Key key, _LibraryFilter filter,
          {String? label}) =>
      IconButton(
        key: key,
        focusNode: _librarySelectFocus,
        tooltip: label ?? AppLocalizations.of(context)!.musicQueueSelect,
        icon: const Icon(Icons.checklist_rounded),
        onPressed: () => _startLibrarySelection(filter,
            savedSongs: filter == _LibraryFilter.songs),
      );

  Widget _saveFilteredPlaylistButton(
          Iterable<Video> matches, String profileId) =>
      IconButton(
        tooltip: AppLocalizations.of(context)!.musicSaveResultsAsPlaylist,
        icon: const Icon(Icons.playlist_add_rounded),
        onPressed: () {
          if (db.profileId != profileId) return;
          MusicLibraryActions.createPlaylist(context,
              videos: matches.toList(growable: false));
        },
      );

  Widget _libraryControlsRow({
    required Widget leading,
    required List<Widget> actions,
    required double actionWidth,
  }) =>
      Row(children: [
        Expanded(child: leading),
        if (actions.length * kMinInteractiveDimension <= actionWidth)
          ...actions
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: actionWidth),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
          ),
      ]);

  Widget _libraryFindView({
    required Key key,
    required Widget toolbar,
    required Widget results,
    required int count,
    bool pinned = false,
  }) {
    final header = Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: toolbar,
    );
    return CustomScrollView(
      key: key,
      controller: _libraryFindScroll,
      semanticChildCount: count,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        if (pinned)
          PinnedHeaderSliver(child: header)
        else
          SliverFloatingHeader(child: header),
        results,
      ],
    );
  }

  Widget _playlistSelectionBar(List<String> visible, List<Video> selected,
      String title, PlaylistReference reference,
      {required bool Function() isCurrent,
      LocalMusicLibrary? devices,
      List<OnDeviceMusicEntry>? Function()? resolveOnDevice,
      Future<void> Function(List<Video>)? onPlay,
      Future<void> Function()? onRemoveFromPlaylist}) {
    final allSelected = selected.isNotEmpty &&
        visible.every(_playlistSelection.selected.contains);
    return MusicSongSelectionBar(
      selected: selected,
      allSelected: allSelected,
      onToggleAll: allSelected
          ? () => setState(_playlistSelection.clear)
          : visible.isEmpty
              ? null
              : () => setState(() => _playlistSelection.toggleAll(visible)),
      onClose: _exitPlaylistSelection,
      closeFocus: _playlistExitSelectionFocus,
      isCurrent: isCurrent,
      deviceLibrary: devices,
      resolveOnDevice: resolveOnDevice,
      onRemoveFromPlaylist: onRemoveFromPlaylist,
      recommendationSource: reference,
      onPlay: onPlay ??
          (tracks) => MusicScreen.playTracks(context, tracks,
              queueTitle: title, recommendationSource: reference),
    );
  }

  Widget _savedSongsSelectionBar(List<_LibraryItem> visible,
      List<_LibraryItem> all, Set<String> scope, MusicCollectionOrder order,
      {MusicOfflineView? offline, Map<String, Video> offlineSongs = const {}}) {
    final locals = AppLocalizations.of(context)!;
    final filter = _filter;
    final title = locals.musicSavedSongs;
    final session = MusicLibrarySession(context.read<AppCubit>());
    final offlineEnabled = offline?.enabled == true;
    final selected = [
      for (final item in offlineEnabled ? visible : all)
        if (scope.contains(item.bookmark!.id)) item.bookmark!,
    ];
    final selectedIds = selected.map((entry) => entry.id).toList();
    final visibleIds = {for (final item in visible) item.bookmark!.id};
    final allSelected = selected.isNotEmpty && visibleIds.every(scope.contains);
    bool isCurrent() {
      if (!mounted ||
          !session.isCurrent ||
          !identical(_savedSongsSelection, scope) ||
          (offlineEnabled && !offline!.isCurrent())) {
        return false;
      }
      final settings = context.read<SettingsCubit?>();
      final currentOrder = MusicCollectionOrder.decode(
          settings?.state.settings[_libraryOrderSetting(filter)]?.value);
      if (currentOrder != order) return false;
      final live = <_LibraryItem>[
        for (final entry in session.library.entries)
          if (entry.kind == MusicLibraryKind.song && scope.contains(entry.id))
            if (!offlineEnabled || visibleIds.contains(entry.id))
              (playlist: null, bookmark: entry),
      ];
      return listEquals(selectedIds, [
        for (final item in _sortedLibraryItems(live, order)) item.bookmark!.id,
      ]);
    }

    Future<void> removeSavedSongs() async {
      final removed = await confirmMusicSavedSongRemoval(
          context, session.library, selectedIds,
          isCurrent: isCurrent);
      if (removed &&
          mounted &&
          session.isCurrent &&
          identical(_savedSongsSelection, scope)) {
        _exitLibrarySelection();
      }
    }

    return MusicSongSelectionBar(
      selected: [
        for (final entry in selected)
          offlineEnabled ? offlineSongs[entry.id]! : entry.toVideo(),
      ],
      allSelected: allSelected,
      onToggleAll: allSelected || visibleIds.isNotEmpty
          ? () => setState(() {
                scope.clear();
                if (!allSelected) scope.addAll(visibleIds);
              })
          : null,
      onClose: _exitLibrarySelection,
      closeFocus: _libraryExitSelectionFocus,
      isCurrent: isCurrent,
      removal: selected.isEmpty
          ? null
          : (
              label: locals.musicRemoveSelectedSavedSongs,
              run: removeSavedSongs
            ),
      onPlay: (tracks) => offlineEnabled
          ? _playOffline(tracks, offline!, title: title)
          : MusicScreen.playTracks(context, tracks, queueTitle: title),
    );
  }

  Widget _collectionSelectionBar(List<_LibraryItem> collections,
      Set<String> scope, MusicLibraryService library) {
    final ids = collections.map((item) => _itemKey(item).value).toSet();
    scope.retainAll(ids);
    final selected = [
      for (final item in collections)
        if (scope.contains(_itemKey(item).value)) item,
    ];
    final localSnapshots = {
      for (final item in selected)
        if (item.playlist case final playlist?)
          playlist.playlistId: jsonEncode(playlist),
    };
    final allSelected = ids.isNotEmpty && ids.every(scope.contains);
    final session = MusicLibrarySession(context.read<AppCubit>());
    final route = ModalRoute.of(context);
    final revision = _collectionSelectionRevision;
    bool ownerCurrent() =>
        mounted &&
        session.isCurrent &&
        identical(_collectionSelection, scope) &&
        _collectionSelectionRevision == revision &&
        scope.length == selected.length &&
        route?.isCurrent != false &&
        TickerMode.of(context);

    bool sourcesCurrent() {
      final local = localSnapshots.isNotEmpty
          ? {
              for (final playlist in session.playlists)
                playlist.playlistId: playlist
            }
          : const <String, Playlist>{};
      final savedIds = {
        for (final entry in session.library.entries)
          if (entry.kind == MusicLibraryKind.playlist) entry.id,
      };
      return selected.every((item) => switch (item) {
            (playlist: final playlist?, bookmark: _) =>
              jsonEncode(local[playlist.playlistId]) ==
                      localSnapshots[playlist.playlistId] &&
                  library.isMusicPlaylist(playlist),
            (playlist: _, bookmark: final entry?) =>
              savedIds.contains(entry.id),
            _ => false,
          });
    }

    return MusicCollectionSelectionBar(
      selectedCount: selected.length,
      allSelected: allSelected,
      onToggleAll: ids.isEmpty
          ? null
          : () => setState(() {
                _collectionSelectionRevision++;
                scope.clear();
                if (!allSelected) scope.addAll(ids);
              }),
      onClose: _exitLibrarySelection,
      closeFocus: _libraryExitSelectionFocus,
      isCurrent: () => ownerCurrent() && sourcesCurrent(),
      loadTracks: () async {
        const unavailable = (
          tracks: <Video>[],
          recommendationSources: <PlaylistReference?>[],
        );
        final tracks = <Video>[];
        final recommendationSources = <PlaylistReference?>[];
        final covers = library.coversBySongId;
        final catalog = musicCatalogService;
        final visibility = MusicVisibility.forProfile(db, library.profileId);
        final devices = widget.deviceLibrary ?? LocalMusicLibrary.instance;
        if (supportsLocalMusicFolders &&
            !devices.loaded &&
            !devices.unavailable &&
            selected.any((item) =>
                item.playlist?.videos
                    .any((video) => isLocalMusicPlaybackId(video.videoId)) ??
                false)) {
          await devices.refresh();
        }
        for (final item in selected) {
          if (!ownerCurrent()) return unavailable;
          final source = _playlistReference(item, library.profileId);
          if (item.playlist case final playlist?) {
            for (final video in playlist.videos) {
              final music = video.musicMetadata;
              if (music == null ||
                  video.filtered ||
                  video.filterHide ||
                  video.isUpcoming == true ||
                  devices.isPlaylistTrackHiddenByAdvisory(video.videoId) ||
                  (source != null &&
                      visibility.isHiddenInPlaylist(source, video.videoId)) ||
                  (isLocalMusicPlaybackId(video.videoId) &&
                      devices.playlistTrackById(video.videoId) == null)) {
                continue;
              }
              final savedCover = covers[video.videoId];
              // The combined queue gets new occurrence IDs for every copy.
              tracks.add(video.copyWith(
                queueEntryId: null,
                indexId: null,
                index: null,
                musicMetadata: savedCover == null
                    ? music
                    : music.withThumbnails(savedCover),
              ));
              recommendationSources.add(source);
            }
          } else {
            final collection = await catalog.getPlaylist(item.bookmark!.id);
            if (!ownerCurrent()) return unavailable;
            for (final track in collection.tracks) {
              if (source != null &&
                  visibility.isHiddenInPlaylist(source, track.videoId)) {
                continue;
              }
              tracks.add(track.toVideo());
              recommendationSources.add(source);
            }
          }
        }
        return (tracks: tracks, recommendationSources: recommendationSources);
      },
    );
  }

  Widget _localPlaylist(BuildContext context, Playlist playlist,
      MusicLibraryService library, MusicLayout layout) {
    final devices = widget.deviceLibrary ?? LocalMusicLibrary.instance;
    final visibility = MusicVisibility.forProfile(db, library.profileId);
    final hasDeviceEntries = supportsLocalMusicFolders &&
        playlist.videos.any((video) => isLocalMusicPlaybackId(video.videoId));
    return ListenableBuilder(
      listenable: Listenable.merge([visibility, if (hasDeviceEntries) devices]),
      builder: (context, _) {
        final request = (playlist.playlistId, devices.selectionId);
        if (hasDeviceEntries &&
            !devices.loaded &&
            !devices.unavailable &&
            _playlistScan != request) {
          _playlistScan = request;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _playlistScan == request) {
              unawaited(devices.refresh());
            }
          });
        }
        return _localPlaylistContent(
            context, playlist, library, devices, layout, visibility);
      },
    );
  }

  Widget _localPlaylistContent(
      BuildContext context,
      Playlist playlist,
      MusicLibraryService library,
      LocalMusicLibrary devices,
      MusicLayout layout,
      MusicVisibility visibility) {
    final savedCovers = library.coversBySongId;
    final reference = PlaylistReference.forPlaylist(
        playlist, db.forProfile(library.profileId));
    final hidden = <String, Video>{};
    final songs = <Video>[];
    final keys = <ValueKey<String>>[];
    final hiddenIds = {
      for (final video in playlist.videos)
        if (devices.isPlaylistTrackHiddenByAdvisory(video.videoId))
          video.videoId,
    };
    final assignedEntries = _playlistSelection.reconcile(playlist.videos);
    for (final (index, video) in playlist.videos.indexed) {
      final music = video.musicMetadata;
      if (music == null || hiddenIds.contains(video.videoId)) continue;
      final covers = savedCovers[video.videoId];
      // Identify rows by their source occurrence. Playback and saved progress
      // still use the same Music-only queue IDs used before filtering by text.
      final entry = assignedEntries[index];
      final track = devices.playlistTrackById(video.videoId);
      final current = track == null ? null : devicePlaylistVideo(track);
      final song = current != null
          ? entry.copyWith(
              title: current.title,
              author: current.author,
              musicMetadata: current.musicMetadata,
              lengthSeconds: current.lengthSeconds)
          : covers == null
              ? entry
              : entry.copyWith(musicMetadata: music.withThumbnails(covers));
      if (visibility.isHiddenInPlaylist(reference, song.videoId)) {
        hidden[song.videoId] = song;
      } else {
        keys.add(ValueKey(entry.queueEntryId!));
        songs.add(song);
      }
    }
    return MusicOfflineFilter(
      key: ValueKey((library.profileId, playlist.playlistId, 'offline-filter')),
      videos: songs,
      builder: (context, offline) => MusicPlaylistOrderBuilder(
        reference: reference,
        builder: (context, order, sortValue) => _localPlaylistTracks(
            context, playlist, library, devices, songs, keys, offline,
            layout: layout,
            visibility: visibility,
            hidden: hidden.values.toList(),
            displayOrder: order,
            sortValue: sortValue),
      ),
    );
  }

  Widget _localPlaylistTracks(
    BuildContext context,
    Playlist playlist,
    MusicLibraryService library,
    LocalMusicLibrary devices,
    List<Video> songs,
    List<ValueKey<String>> keys,
    MusicOfflineView offline, {
    required MusicLayout layout,
    required MusicVisibility visibility,
    required List<Video> hidden,
    required MusicCollectionOrder displayOrder,
    required MusicPlaylistSortValue sortValue,
  }) {
    final locals = AppLocalizations.of(context)!;
    final covers = MusicPlaylistCovers.forProfile(db, library.profileId);
    final title = playlist.playlistId == localWatchLaterId
        ? locals.watchLater
        : playlist.title;
    final appState = context.read<AppCubit>().state;
    final instanceUrl = appState.server?.url;
    final reference = PlaylistReference.forPlaylist(
        playlist, db.forProfile(library.profileId));
    bool available(Video song) =>
        !isLocalMusicPlaybackId(song.videoId) ||
        devices.playlistTrackById(song.videoId) != null;
    final playableIndexes = [
      for (final (index, song) in songs.indexed)
        if (available(song)) index,
    ];
    final playableSongs = [
      for (final index in playableIndexes) songs[index],
    ];
    String displayTitle(Video song) =>
        library.savedSong(song.videoId)?.savedTitle ??
        song.musicMetadata!.title;
    Object? displaySortValue(Video song, MusicCollectionSortField field) =>
        switch (field) {
          MusicCollectionSortField.title => displayTitle(song),
          MusicCollectionSortField.artist => library.catalogArtistByline(
              song.musicMetadata!.artist, song.musicMetadata!.artistCredits),
          _ => sortValue(song, field),
        };
    final displayIndices =
        displayOrder.orderIndices(songs, sortValue: displaySortValue);
    final offlineEntries = offline.entries;
    final filteredIndices = offline.enabled
        ? [
            for (final index in displayIndices)
              if (offlineEntries?[index] != null) index,
          ]
        : displayIndices;
    List<Video> offlineQueue(Iterable<int> indices) => [
          for (final index in indices)
            offlineEntries![index]!.copyWith(queueEntryId: keys[index].value),
        ];
    final offlineButton = musicOfflineFilterButton(context, offline,
        key: const ValueKey('music-local-playlist-offline-filter'));
    final sortMenu = MusicCollectionSortMenu.playlist(
      reference: reference,
      order: displayOrder,
      compact: true,
      isCurrent: () =>
          mounted && _playlistId == playlist.playlistId && !_playlistSelecting,
      onChanged: _jumpToPlaylistResults,
    );
    final openedSource = widget.source;
    List<(String?, String, bool, bool, bool?)> queueEntries(
            Iterable<Video> videos) =>
        [
          for (final song in assignPlaylistEntryIds(videos.where((v) =>
              v.musicMetadata != null &&
              !visibility.isHiddenInPlaylist(reference, v.videoId) &&
              !devices.isPlaylistTrackHiddenByAdvisory(v.videoId))))
            (
              song.queueEntryId,
              song.videoId,
              song.filtered,
              song.filterHide,
              song.isUpcoming
            )
        ];
    bool playlistIsCurrent() {
      if (!mounted ||
          !reference.matchesOwner(db) ||
          _playlistSearching ||
          _playlistSelecting ||
          widget.source != openedSource ||
          (openedSource == null && _playlistId != playlist.playlistId) ||
          _sourceSession?.isCurrent == false) {
        return false;
      }
      final current = service
          .getLocalPlaylists(database: db.forProfile(library.profileId))
          .where(
              (item) => item.isLocal && item.playlistId == playlist.playlistId)
          .firstOrNull;
      return current != null &&
          listEquals(queueEntries(current.videos), queueEntries(songs)) &&
          listEquals(playableSongs, songs.where(available).toList());
    }

    final searchable = _playlistSearching
        ? [
            for (final song in songs)
              normalizeMusicSearchText([
                displayTitle(song),
                song.musicMetadata!.artist,
                for (final credit in song.musicMetadata!.artistCredits)
                  credit.name,
              ].join(' ')),
          ]
        : const <String>[];
    Future<void> playSong(int index, List<int> visible,
        {bool songTap = false}) {
      _playlistQueryFocus.unfocus();
      if (offline.enabled) {
        return _playOffline(offlineQueue(visible), offline,
            title: title,
            startIndex: visible.indexOf(index),
            reference: reference);
      }
      return _play(songs,
          reference: reference,
          startIndex: index,
          songTap: songTap,
          collectionDetail: true);
    }

    final selectionScope = _playlistSelectionScope;
    final selection = _playlistSelection.selected.toSet();
    final selectedInOrder = [
      for (final key in keys)
        if (selection.contains(key.value)) key.value,
    ];
    final session = selectionScope == null
        ? null
        : MusicLibrarySession(context.read<AppCubit>());
    bool selectionIsCurrent() {
      if (!mounted ||
          session?.isCurrent != true ||
          _sourceSession?.isCurrent == false ||
          !identical(_playlistSelectionScope, selectionScope) ||
          (offline.enabled && !offline.isCurrent())) {
        return false;
      }
      final current = session!.playlists
          .where(
              (item) => item.isLocal && item.playlistId == playlist.playlistId)
          .firstOrNull;
      if (current == null) return false;
      final assigned = _playlistSelection.reconcile(current.videos);

      return listEquals(selectedInOrder, [
        for (final song in assigned)
          if (!visibility.isHiddenInPlaylist(reference, song.videoId) &&
              !devices.isPlaylistTrackHiddenByAdvisory(song.videoId) &&
              _playlistSelection.selected.contains(song.queueEntryId))
            song.queueEntryId!,
      ]);
    }

    Future<void> removeSelected(Iterable<Video> entries) async {
      final owner = session!;
      final playlists = service;
      final undo = await playlists.removeLocalPlaylistSongs(
        reference,
        entryIds: {for (final song in entries) song.indexId!},
        isCurrent: selectionIsCurrent,
      );
      if (undo != null) owner.library.notifyChanged();
      if (!mounted || !owner.isCurrent) return;
      final sameSelection = identical(_playlistSelectionScope, selectionScope);
      if (undo == null) {
        if (sameSelection) _error();
        return;
      }
      if (sameSelection) _exitPlaylistSelection();
      showMusicPlaylistUndo(
        this.context,
        owner,
        message: locals.musicPlaylistSongsRemoved,
        undo: () => playlists.undoLocalPlaylistSongRemoval(
          undo,
          isCurrent: () => owner.isCurrent,
        ),
      );
    }

    final canPin = widget.source == null || library.isMusicPlaylist(playlist);
    final pinned = library.pinnedLocalPlaylistIds.contains(playlist.playlistId);
    final canSuggest = appState.server != null &&
        playlist.playlistId != localWatchLaterId &&
        hasMusicPlaylistSuggestionSeeds(playlist);
    final visibleVideos = [
      for (final song in playlist.videos)
        if (!devices.isPlaylistTrackHiddenByAdvisory(song.videoId) &&
            !visibility.isHiddenInPlaylist(reference, song.videoId))
          song,
    ];

    final hasHiddenEntries = visibleVideos.length != playlist.videos.length;

    Widget details({bool showHeading = false}) => Column(children: [
          if (showHeading && widget.source == null)
            ListTile(
              title: Semantics(header: true, child: Text(title)),
              subtitle: Text(locals.onDevice),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PlaylistInformation(
              playlist: !hasHiddenEntries
                  ? playlist
                  : playlist.copyWith(
                      videos: visibleVideos, videoCount: visibleVideos.length),
              reference: reference,
              showServerCopy: !_playlistSearching && !hasHiddenEntries,
            ),
          ),
          if (!_playlistSelecting &&
              !_playlistSearching &&
              !playlist.isEditLocked &&
              playlist.playlistId != localWatchLaterId)
            MusicPlaylistRenameButton(reference: reference, title: title),
          if (playlist.isLocal &&
              !isTv &&
              !_playlistSearching &&
              !_playlistSelecting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: MusicPlaylistOffline(playlist: playlist),
            ),
          if (supportsLocalMusicFolders &&
              playlist.playlistId != localWatchLaterId &&
              !_playlistSelecting &&
              !_playlistSearching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: M3uPlaylistActions(playlist: playlist),
              ),
            ),
          if (!_playlistSelecting && !_playlistSearching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                if (widget.source != null) offlineButton,
                if (offline.enabled || playableIndexes.isNotEmpty)
                  FilledButton.icon(
                      onPressed: offline.enabled
                          ? filteredIndices.isEmpty
                              ? null
                              : () => playSong(
                                  filteredIndices.first, filteredIndices)
                          : () =>
                              playSong(playableIndexes.first, playableIndexes),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(locals.musicPlayAll)),
                if (!offline.enabled && playableIndexes.isNotEmpty) ...[
                  if (canSuggest &&
                      playableSongs.any((song) =>
                          !song.filtered &&
                          !song.filterHide &&
                          song.isUpcoming != true))
                    OutlinedButton.icon(
                      key: const ValueKey('music-playlist-suggested-shuffle'),
                      onPressed: _suggestedShuffle == null
                          ? () => _playSuggestedShuffle(
                              playlist, playableSongs, reference)
                          : null,
                      icon: _suggestedShuffle == null
                          ? const Icon(Icons.shuffle)
                          : const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                      label: Text(locals.musicPlaylistSuggestedShuffle),
                    ),
                  MusicPlaylistResume(
                      reference: reference,
                      videos: playableSongs,
                      onPlay: (index, position) => _play(songs,
                          reference: reference,
                          startIndex: playableIndexes[index],
                          startAt: position)),
                  MusicPlaylistSelectionActions.wholePlaylist(
                      videos: playableSongs,
                      isCurrent: playlistIsCurrent,
                      recommendationSource: reference,
                      onPlay: (shuffle) => _play(playableSongs,
                          reference: reference, shuffleOnce: shuffle)),
                ],
                if (offline.enabled
                    ? filteredIndices.isNotEmpty
                    : playableIndexes.isNotEmpty)
                  MusicLibraryActions(
                      videos: offline.enabled
                          ? offlineQueue(filteredIndices)
                          : songs,
                      compact: false,
                      recommendationSource: reference),
                if (playlist.playlistId != localWatchLaterId)
                  MusicPlaylistEditActions(
                    playlist: playlist,
                    reference: reference,
                    allowReorder: displayOrder.isSourceOrder,
                  ),
                if (canPin)
                  OutlinedButton.icon(
                    onPressed: () => _setPlaylistPinned(
                        library, playlist.playlistId,
                        pinned: !pinned),
                    icon:
                        Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                    label: Text(pinned
                        ? locals.musicUnpinPlaylist
                        : locals.musicPinPlaylist),
                  ),
              ]),
            ),
          if (!_playlistSelecting &&
              !_playlistSearching &&
              !playlist.isEditLocked &&
              MusicPlaylistCovers.supports(playlist.playlistId))
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MusicPlaylistCoverEditor(
                  key: ValueKey((library.profileId, playlist.playlistId)),
                  covers: covers,
                  playlistId: playlist.playlistId,
                ),
              ),
            ),
          if (!_playlistSelecting &&
              !_playlistSearching &&
              playlist.playlistId != localWatchLaterId &&
              library.isMusicPlaylist(playlist))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: MusicPlaylistDeleteButton(
                  playlist: playlist,
                  onDeleted: widget.source == null
                      ? null
                      : () {
                          if (ModalRoute.of(context)?.isCurrent == true) {
                            Navigator.of(context).pop();
                          }
                        },
                ),
              ),
            ),
          if (!_playlistSelecting && !_playlistSearching)
            MusicPlaylistRecommendationToggle(reference: reference),
          if (hidden.isNotEmpty && !_playlistSelecting && !_playlistSearching)
            MusicPlaylistHiddenSongs(
                playlist: reference, visibility: visibility, songs: hidden),
        ]);

    Widget tracks(BuildContext context, bool split) => ValueListenableBuilder(
          valueListenable: _playlistQuery,
          builder: (_, input, __) {
            final terms = musicSearchTerms(input.text);
            final visible = [
              for (final index in filteredIndices)
                if (terms.isEmpty ||
                    musicSearchMatchesWithArtistAliases(
                        terms,
                        searchable[index],
                        catalogArtistSearchAliases(library,
                            songs[index].musicMetadata!.artistCredits)))
                  index,
            ];
            final positions = {
              for (final (position, index) in visible.indexed)
                keys[index]: position,
            };
            final selectedIndices = [
              for (final index in offline.enabled ? visible : displayIndices)
                if (selection.contains(keys[index].value)) index,
            ];
            final deviceSelection = devices.selectionId;
            List<OnDeviceMusicEntry>? resolveDeviceSongs() {
              if (!selectionIsCurrent() ||
                  !devices.acceptsSessionSelection(deviceSelection)) {
                return null;
              }
              final entries = <OnDeviceMusicEntry>[];
              for (final index in selectedIndices) {
                final track = devices.playlistTrackById(songs[index].videoId,
                    visibleOnly: true);
                if (track == null) return null;
                entries.add(OnDeviceMusicEntry.device(track));
              }
              return entries;
            }

            final view = CustomScrollView(
              key: ValueKey((library.profileId, playlist.playlistId)),
              controller: _playlistScroll,
              slivers: [
                if (_playlistSelecting ||
                    _playlistSearching ||
                    widget.source == null)
                  PinnedHeaderSliver(
                    child: Material(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: _playlistSelecting
                          ? _playlistSelectionBar(
                              [for (final index in visible) keys[index].value],
                              offline.enabled
                                  ? offlineQueue(selectedIndices)
                                  : [
                                      for (final index in selectedIndices)
                                        songs[index]
                                    ],
                              playlist.title,
                              reference,
                              isCurrent: selectionIsCurrent,
                              devices: devices,
                              resolveOnDevice:
                                  selectedIndices.isNotEmpty && selectedIndices.every((index) => isLocalMusicPlaybackId(songs[index].videoId))
                                      ? resolveDeviceSongs
                                      : null,
                              onPlay: offline.enabled
                                  ? (tracks) => _playOffline(tracks, offline,
                                      title: title, reference: reference)
                                  : null,
                              onRemoveFromPlaylist: playlist.isEditLocked ||
                                      playlist.playlistId == localWatchLaterId
                                  ? null
                                  : () =>
                                      removeSelected(selectedIndices.map((index) => songs[index])))
                          : _playlistSearching
                              ? Row(children: [
                                  Expanded(child: _playlistSearchField()),
                                  if (terms.isNotEmpty && visible.isNotEmpty)
                                    _saveFilteredPlaylistButton(
                                        visible.map((index) => songs[index]),
                                        library.profileId),
                                  offlineButton,
                                  if (widget.source == null)
                                    _playlistSelectButton(),
                                  if (widget.source == null)
                                    _playlistSearchButton(),
                                  if (widget.source == null && songs.isNotEmpty)
                                    sortMenu,
                                ])
                              : ListTile(
                                  leading: IconButton(
                                      tooltip: MaterialLocalizations.of(context)
                                          .backButtonTooltip,
                                      icon: const Icon(Icons.arrow_back),
                                      onPressed: _backFromLocalPlaylist),
                                  title:
                                      Text(split ? locals.musicSongs : title),
                                  subtitle:
                                      split ? null : Text(locals.onDevice),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        offlineButton,
                                        if (filteredIndices.isNotEmpty)
                                          _playlistSelectButton(),
                                        _playlistSearchButton(),
                                        if (songs.isNotEmpty) sortMenu,
                                      ]),
                                ),
                    ),
                  ),
                if (!split && !_playlistSearching)
                  SliverToBoxAdapter(child: details()),
                if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: offline.enabled && filteredIndices.isEmpty
                        ? musicOfflineCollectionEmpty(context, offline)
                        : terms.isEmpty
                            ? _empty()
                            : Center(child: Text(locals.musicNoResults)),
                  )
                else
                  SliverList.builder(
                      itemCount: visible.length,
                      findChildIndexCallback: (key) => positions[key],
                      itemBuilder: (_, position) {
                        final index = visible[position];
                        final song = offlineEntries?[index] ?? songs[index];
                        final music = song.musicMetadata!;
                        final device = isLocalMusicPlaybackId(song.videoId);
                        final playable = available(song);
                        final id = keys[index].value;
                        final picked = selection.contains(id);
                        final tile = ListTile(
                            selected: picked,
                            minTileHeight: layout.compactRows
                                ? kMinInteractiveDimension
                                : null,
                            minVerticalPadding: layout.compactRows ? 4 : null,
                            leading: SizedBox.square(
                              dimension: layout.compactRows ? 40 : 52,
                              child: device
                                  ? Icon(playable
                                      ? Icons.music_note_outlined
                                      : Icons.link_off)
                                  : Stack(fit: StackFit.expand, children: [
                                      CommunityMusicArtwork(
                                          videoId: song.videoId,
                                          music: music,
                                          durationSeconds: song.lengthSeconds,
                                          fallback: _artwork(
                                              displaySongThumbnails(
                                                  song.videoId,
                                                  music.thumbnails,
                                                  song.videoThumbnails,
                                                  artTrack: music.isArtTrack,
                                                  instanceUrl: instanceUrl))),
                                      VideoWatchProgress(videoId: song.videoId),
                                    ]),
                            ),
                            title: MusicStatusTitle.song(
                                video: song,
                                child: Text(displayTitle(song),
                                    maxLines: layout.explicitTitleLines,
                                    overflow: layout.explicitTitleLines == null
                                        ? null
                                        : TextOverflow.ellipsis)),
                            subtitle: Text(device
                                ? [
                                    if (music.artist.isNotEmpty) music.artist,
                                    playable
                                        ? locals.onDevice
                                        : locals.localMusicHiddenFileUnavailable
                                  ].join(' • ')
                                : library.catalogArtistByline(
                                    music.artist, music.artistCredits)),
                            trailing: _playlistSelecting
                                ? ExcludeSemantics(
                                    child: Icon(picked
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank))
                                : MusicLibraryActions(
                                    videos: [song],
                                    localPlaylistId: playlist.isEditLocked
                                        ? null
                                        : playlist.playlistId,
                                    replacementPlaylist:
                                        !playlist.isEditLocked &&
                                                playlist.playlistId !=
                                                    localWatchLaterId &&
                                                !isLocalMusicPlaybackId(
                                                    song.videoId)
                                            ? reference
                                            : null,
                                    playlistVisibility: reference,
                                    recommendationSource: reference,
                                    onPlay: playable
                                        ? () => playSong(index, visible)
                                        : null),
                            onLongPress: _playlistSelecting
                                ? null
                                : () => _startPlaylistSelection(id),
                            onTap: _playlistSelecting
                                ? () => setState(() => _playlistSelection.toggle(id))
                                : playable
                                    ? () => playSong(index, visible, songTap: true)
                                    : null);
                        return MusicSongRowSwipe(
                          key: keys[index],
                          onAction: _playlistSelecting || !playable
                              ? null
                              : (action) => MusicLibraryActions.queueSong(
                                  context, song, action,
                                  recommendationSource: reference),
                          child: tile,
                        );
                      }),
                if (canSuggest)
                  SliverToBoxAdapter(
                    child: MusicPlaylistSuggestions(
                      key: ValueKey((
                        library.profileId,
                        playlist.playlistId,
                        appState.sessionRevision,
                      )),
                      playlist: playlist,
                      profileId: library.profileId,
                      visible: !playlist.isEditLocked &&
                          !_playlistSelecting &&
                          !_playlistSearching,
                    ),
                  ),
              ],
            );
            return MusicFastScroll(
              scope: (
                library.profileId,
                playlist.playlistId,
                displayOrder,
                offline.enabled,
                input.text
              ),
              sections: musicFastScrollSectionsFor<int>(context, visible,
                  sortValue: displayOrder.field ==
                          MusicCollectionSortField.source
                      ? null
                      : (index) => MusicCollectionOrder.normalizeSortValue(
                          displaySortValue(songs[index], displayOrder.field))),
              child: view,
            );
          },
        );
    return MusicCollectionPanes(
      details: details(showHeading: true),
      buildTracks: tracks,
      detailsKey: PageStorageKey((library.profileId, playlist.playlistId)),
    );
  }

  Future<void> _setPlaylistPinned(MusicLibraryService library, String id,
      {required bool pinned}) async {
    final session =
        _sourceSession ?? MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || session.library.profileId != library.profileId) {
      return;
    }
    try {
      await library.setLocalPlaylistPinned(id, pinned: pinned);
    } catch (_) {
      if (!mounted || !session.isCurrent) return;
      final locals = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(locals.musicLibraryActionError)));
    }
  }

  Widget _sourcePlaylist(PlaylistReference source, MusicLayout layout,
      {required bool active}) {
    final locals = AppLocalizations.of(context)!;
    final app = context.read<AppCubit>();
    final session = _sourceSession ??= MusicLibrarySession(app);
    final library = session.library;
    return ListenableBuilder(
      listenable: library.changes,
      builder: (context, _) {
        final ownsSource = source.kind == PlaylistSourceKind.local &&
            source.matchesOwner(db) &&
            app.state.profileId == source.profileId &&
            session.isCurrent;
        final playlist = ownsSource
            ? service
                .getLocalPlaylists(database: db.forProfile(source.profileId))
                .where((playlist) =>
                    playlist.isLocal &&
                    playlist.playlistId == source.playlistId)
                .firstOrNull
            : null;
        final title = playlist == null
            ? locals.musicPlaylists
            : playlist.playlistId == localWatchLaterId
                ? locals.watchLater
                : playlist.title;
        return PopScope(
          canPop: playlist == null ||
              (!_playlistSelecting && !_playlistSearching) ||
              !active,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && playlist != null && active) {
              if (_playlistSelecting) {
                _exitPlaylistSelection();
              } else if (_playlistSearching) {
                _togglePlaylistSearch();
              }
            }
          },
          child: Scaffold(
            appBar: AppBar(
              leading: const BackButton(),
              title: Text(title),
              actions: [
                if (playlist != null && !_playlistSelecting) ...[
                  if (playlist.videos.any((song) => song.musicMetadata != null))
                    _playlistSelectButton(),
                  _playlistSearchButton(),
                  if (playlist.videos.any((song) => song.musicMetadata != null))
                    MusicCollectionSortMenu.playlist(
                      reference: source,
                      order: MusicCollectionSortMenu.playlistOrder(
                          context, source),
                      compact: true,
                      isCurrent: () =>
                          widget.source == source && !_playlistSelecting,
                      onChanged: _jumpToPlaylistResults,
                    ),
                ],
              ],
            ),
            body: playlist == null
                ? Center(child: Text(locals.musicSourceUnavailable))
                : _localPlaylist(context, playlist, library, layout),
          ),
        );
      },
    );
  }

  Widget _catalogLibrary(
      BuildContext context,
      MusicLibraryService library,
      List<_LibraryFilter> filters,
      MusicPlaylistFolderService folderService,
      MusicLayout layout) {
    final playlists = service
        .getLocalPlaylists(database: db.forProfile(library.profileId))
        .where(library.isMusicPlaylist)
        .toList();
    final selected = playlists
        .where((playlist) => playlist.playlistId == _playlistId)
        .firstOrNull;
    if (selected != null)
      return _localPlaylist(context, selected, library, layout);
    if (_playlistId case final missingId?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _playlistId == missingId &&
            db.profileId == library.profileId) {
          setState(() {
            _playlistId = null;
            _resetPlaylistSearch();
          });
        }
      });
    }
    final folderData = folderService.snapshot;
    final folder = folderData.folder(_folderId);
    if (_folderId case final missingId? when folder == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _folderId == missingId &&
            db.profileId == library.profileId &&
            folderService.snapshot.folder(missingId) == null) {
          setState(() => _folderId = null);
        }
      });
    }
    final kind = folder != null
        ? MusicLibraryKind.playlist
        : switch (_filter) {
            _LibraryFilter.all => null,
            _LibraryFilter.playlists => MusicLibraryKind.playlist,
            _LibraryFilter.songs => MusicLibraryKind.song,
            _LibraryFilter.channels => MusicLibraryKind.artist,
            _LibraryFilter.downloads => MusicLibraryKind.song,
            _LibraryFilter.podcasts => MusicLibraryKind.song,
            _LibraryFilter.onDevice => null,
            _LibraryFilter.cachedSongs => null,
          };
    final entries = library.entries
        .where((entry) =>
            entry.kind != MusicLibraryKind.album &&
            (kind == null || entry.kind == kind))
        .toList();
    final hasPlaylists =
        _filter == _LibraryFilter.playlists || _filter == _LibraryFilter.all;
    final filter = _filter;
    final settingName = _libraryOrderSetting(filter);
    final order = MusicCollectionSortMenu.readOrder(context, settingName);
    final allFolders = folderData.folders;
    final childFolders = [
      if (hasPlaylists)
        for (final item in allFolders)
          if (item.parentId == folder?.id) item,
    ];
    final folders = [
      for (final index in order.orderIndices(childFolders,
          sortValue: (item, field) =>
              field == MusicCollectionSortField.title ? item.name : null))
        childFolders[index],
    ];
    final folderItems = <_LibraryItem>[
      if (hasPlaylists)
        for (final playlist in playlists) (playlist: playlist, bookmark: null),
      for (final entry in entries) (playlist: null, bookmark: entry),
    ];
    if (hasPlaylists) {
      folderItems.removeWhere((item) {
        final source = _playlistReference(item, library.profileId);
        return (source == null ? null : folderData.folderFor(source)) !=
            folder?.id;
      });
    }
    final sortedItems = _sortedLibraryItems(folderItems, order);
    final shortcuts = folder == null && _filter == _LibraryFilter.all
        ? filters
            .where((filter) =>
                filter == _LibraryFilter.songs ||
                (filter == _LibraryFilter.downloads &&
                    context.watch<DownloadManagerCubit?>() != null))
            .toList()
        : const <_LibraryFilter>[];
    final pins =
        hasPlaylists ? library.pinnedLocalPlaylistIds : const <String>{};
    final items = pins.isEmpty
        ? sortedItems
        : [
            ...sortedItems
                .where((item) => pins.contains(item.playlist?.playlistId)),
            ...sortedItems
                .where((item) => !pins.contains(item.playlist?.playlistId)),
          ];
    if (filter == _LibraryFilter.songs) {
      return MusicOfflineFilter(
        key: ValueKey((library.profileId, 'saved-songs-offline-filter')),
        videos: [for (final item in items) item.bookmark!.toVideo()],
        builder: (context, offline) => _libraryItems(context, library, order,
            items, shortcuts, pins, layout, folderService, folder, folders,
            offline: offline),
      );
    }
    return _libraryItems(context, library, order, items, shortcuts, pins,
        layout, folderService, folder, folders);
  }

  Widget _libraryItems(
      BuildContext context,
      MusicLibraryService library,
      MusicCollectionOrder order,
      List<_LibraryItem> sourceItems,
      List<_LibraryFilter> shortcuts,
      Set<String> pins,
      MusicLayout layout,
      MusicPlaylistFolderService folderService,
      MusicPlaylistFolder? folder,
      List<MusicPlaylistFolder> folders,
      {MusicOfflineView? offline}) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final hasPlaylists =
        _filter == _LibraryFilter.playlists || _filter == _LibraryFilter.all;
    final folderSession =
        hasPlaylists ? MusicLibrarySession(context.read<AppCubit>()) : null;
    bool isCurrent() =>
        mounted && folderSession?.isCurrent == true && _folderId == folder?.id;
    final selection = _savedSongsSelection;
    final savedSongItems = sourceItems
        .where((item) => item.bookmark?.kind == MusicLibraryKind.song)
        .toList();
    selection?.retainAll(savedSongItems.map((item) => item.bookmark!.id));
    final offlineSongs = {
      if (offline?.entries case final entries?)
        for (final song in entries)
          if (song != null) song.videoId: song,
    };
    final offlineEnabled = offline?.enabled == true;
    final items = offlineEnabled
        ? sourceItems
            .where((item) => offlineSongs.containsKey(item.bookmark!.id))
            .toList()
        : sourceItems;
    final empty = offlineEnabled
        ? musicOfflineCollectionEmpty(context, offline!)
        : _empty();
    Future<void> playOfflineSong(
        _LibraryItem item, List<_LibraryItem> visible) {
      _libraryQueryFocus.unfocus();
      final songs = [
        for (final row in visible) offlineSongs[row.bookmark!.id]!
      ];
      final index = visible.indexOf(item);
      return _playOffline(songs, offline!,
          title: locals.musicSavedSongs, startIndex: index);
    }

    final finding = _savedSongsFinding;
    final filter = _filter;
    final settingName = _libraryOrderSetting(filter);
    final searchButton = _libraryFindButton(
        const ValueKey('music-saved-songs-search'),
        _LibraryFilter.songs,
        locals.musicSearchSavedSongs);
    Widget sortMenu({required bool compact}) => MusicCollectionSortMenu(
          key: const ValueKey('music-library-sort'),
          settingName: settingName,
          order: order,
          compact: compact,
          savedOrder: true,
          fields: filter == _LibraryFilter.songs
              ? MusicCollectionSortMenu.standardFields
              : const [
                  MusicCollectionSortField.source,
                  MusicCollectionSortField.title
                ],
          isCurrent: () =>
              mounted &&
              _filter == filter &&
              _playlistId == null &&
              _librarySelection == null,
          onChanged: () {
            if (finding) _jumpToLibraryFindStart();
          },
        );
    final collections = items.where(_isCollection).toList();
    final collectionSelection = _collectionSelection;
    Widget toolbar({Widget? saveResults}) => Padding(
          padding: EdgeInsetsDirectional.only(start: finding ? 0 : 18, end: 8),
          child: LayoutBuilder(builder: (context, constraints) {
            final actions = <Widget>[
              if (saveResults != null) saveResults,
              if (finding) sortMenu(compact: true),
              if (offline != null)
                musicOfflineFilterButton(context, offline,
                    key: const ValueKey('music-saved-songs-offline-filter')),
              if (hasPlaylists && folder == null)
                const MusicRulePlaylistsButton(),
              if (hasPlaylists && folder == null)
                IconButton(
                    tooltip: locals.createNewPlaylist,
                    onPressed: () =>
                        MusicLibraryActions.createPlaylist(context),
                    icon: const Icon(Icons.playlist_add_rounded)),
              if (hasPlaylists)
                IconButton(
                    tooltip: locals.musicRecentlyDeletedPlaylists,
                    onPressed: () => showRecentlyDeletedMusicPlaylists(context),
                    icon: const Icon(Icons.restore_from_trash_outlined)),
              if (hasPlaylists)
                IconButton(
                  key: const ValueKey('music-playlist-new-folder'),
                  tooltip: locals.musicPlaylistNewFolder,
                  onPressed: () => MusicPlaylistFolderActions.create(
                      context, folderService,
                      parentId: folder?.id, isCurrent: isCurrent),
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
              if (hasPlaylists && supportsLocalMusicFolders)
                IconButton(
                  key: const ValueKey('music-import-m3u'),
                  tooltip: locals.musicM3uImport,
                  onPressed: () async {
                    final session =
                        MusicLibrarySession(context.read<AppCubit>());
                    final id = await importDevicePlaylist(context);
                    if (!mounted || id == null || !session.isCurrent) return;
                    setState(() {
                      final tabs = _categoryFilters(layout);
                      _filter = tabs.contains(_LibraryFilter.playlists)
                          ? _LibraryFilter.playlists
                          : _LibraryFilter.all;
                      _folderId = null;
                      _playlistId = id;
                      _resetPlaylistSearch();
                      _resetLibraryFind();
                    });
                  },
                  icon: const Icon(Icons.playlist_add_check),
                ),
              if (_filter == _LibraryFilter.songs && !finding) searchButton,
              if (filter == _LibraryFilter.songs && items.isNotEmpty)
                _librarySelectButton(
                    const ValueKey('music-saved-songs-select'), filter),
              if (collections.isNotEmpty)
                _librarySelectButton(
                  const ValueKey('music-library-select-collections'),
                  _filter,
                  label: locals.musicSelectCollections,
                ),
              IconButton(
                  key: const ValueKey('music-library-layout'),
                  tooltip: _grid
                      ? locals.musicLibraryListView
                      : locals.musicLibraryGridView,
                  onPressed: () {
                    setState(() => _grid = !_grid);
                    if (finding) _jumpToLibraryFindStart();
                  },
                  icon: Icon(_grid ? Icons.view_list : Icons.grid_view)),
              if (finding) searchButton,
            ];
            final width = constraints.maxWidth;
            final sortWidth =
                math.max(96.0, MediaQuery.textScalerOf(context).scale(96));
            final compactSort =
                width < sortWidth + actions.length * kMinInteractiveDimension;
            final leadingWidth = finding
                ? math.min(144.0, width / 2)
                : compactSort
                    ? kMinInteractiveDimension
                    : sortWidth;
            return _libraryControlsRow(
              leading: finding
                  ? _collectionSearchField(
                      key: const ValueKey('music-saved-songs-query'),
                      label: locals.musicSearchSavedSongs,
                      controller: _libraryQuery,
                      focusNode: _libraryQueryFocus,
                      onQueryChanged: _jumpToLibraryFindStart,
                      compact: true)
                  : Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: sortMenu(compact: compactSort)),
              actions: actions,
              actionWidth: math.max(0.0, width - leadingWidth),
            );
          }),
        );
    if (finding) {
      final searchable = [
        for (final item in items)
          normalizeMusicSearchText([
            item.bookmark!.displayTitle,
            item.bookmark!.subtitle,
            for (final credit in item.bookmark!.artistCredits) credit.name,
          ].join(' ')),
      ];
      return ValueListenableBuilder(
        valueListenable: _libraryQuery,
        builder: (_, input, __) {
          final terms = musicSearchTerms(input.text);
          final matches = [
            for (final (index, item) in items.indexed)
              if (musicSearchMatchesWithArtistAliases(
                  terms,
                  searchable[index],
                  catalogArtistSearchAliases(
                      library, item.bookmark!.artistCredits)))
                item,
          ];
          return _collection(matches, const [], library, order, layout,
              playbackItems: items,
              offlineSongs: offlineSongs,
              onOpenSong: offlineEnabled
                  ? (item) => playOfflineSong(item, matches)
                  : null,
              searchToolbar: selection == null
                  ? toolbar(
                      saveResults: terms.isNotEmpty && matches.isNotEmpty
                          ? _saveFilteredPlaylistButton(
                              matches.map((item) => item.bookmark!.toVideo()),
                              library.profileId)
                          : null)
                  : _savedSongsSelectionBar(matches, items, selection, order,
                      offline: offline, offlineSongs: offlineSongs),
              emptyResults: matches.isEmpty
                  ? terms.isEmpty || items.isEmpty
                      ? empty
                      : Center(child: Text(locals.musicNoResults))
                  : null);
        },
      );
    }
    return Column(children: [
      if (folder != null && collectionSelection == null)
        Row(children: [
          BackButton(
              key: const ValueKey('music-playlist-folder-back'),
              onPressed: () => _backFromFolder(folderService)),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium),
            ),
          ),
        ]),
      if (collectionSelection != null)
        _collectionSelectionBar(collections, collectionSelection, library)
      else if (selection != null)
        _savedSongsSelectionBar(offlineEnabled ? items : savedSongItems,
            savedSongItems, selection, order,
            offline: offline, offlineSongs: offlineSongs)
      else
        toolbar(),
      if (selection == null &&
          !offlineEnabled &&
          _filter == _LibraryFilter.songs &&
          sourceItems.any((item) => item.bookmark!.needsSongDetails))
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => showMusicDetailsDialog(
                  context, [for (final item in sourceItems) item.bookmark!]),
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: Text(locals.musicLoadSongDetails),
            ),
          ),
        ),
      Expanded(
        child: items.isEmpty && folders.isEmpty && shortcuts.isEmpty
            ? folder == null
                ? empty
                : Center(child: Text(locals.musicPlaylistEmptyFolder))
            : _collection(items, shortcuts, library, order, layout,
                pinnedPlaylistIds: pins,
                offlineSongs: offlineSongs,
                onOpenSong: offlineEnabled
                    ? (item) => playOfflineSong(item, items)
                    : null,
                folders: folders,
                folderMenu: (item) => MusicPlaylistFolderActions.folderMenu(
                    context, folderService, item, isCurrent: isCurrent),
                movePlaylist: folderSession == null ||
                        folderService.snapshot.folders.isEmpty
                    ? null
                    : (item) =>
                        _movePlaylist(item, folderService, folderSession)),
      ),
    ]);
  }

  PlaylistReference? _playlistReference(_LibraryItem item, String profileId) {
    final localId = item.playlist?.playlistId;
    final bookmark = item.bookmark;
    if (localId == null && bookmark?.kind != MusicLibraryKind.playlist) {
      return null;
    }
    return PlaylistReference.tryParse({
      'kind': localId == null ? 'public' : 'local',
      'profileId': profileId,
      'playlistId': localId ?? bookmark!.id,
    });
  }

  Widget? _movePlaylist(_LibraryItem item, MusicPlaylistFolderService folders,
      MusicLibrarySession session) {
    final source = _playlistReference(item, session.library.profileId);
    if (source == null) return null;
    return MusicPlaylistFolderActions.movePlaylistButton(
        context, folders, source, isCurrent: () {
      if (!mounted || !session.isCurrent) return false;
      return source.kind == PlaylistSourceKind.local
          ? session.playlists.any((playlist) =>
              playlist.playlistId == source.playlistId &&
              session.library.isMusicPlaylist(playlist))
          : session.library
              .contains(MusicLibraryKind.playlist, source.playlistId);
    });
  }

  void _backFromFolder(MusicPlaylistFolderService folders) =>
      setState(() => _folderId = folders.snapshot.folder(_folderId)?.parentId);

  ValueKey<String> _folderKey(MusicPlaylistFolder folder) =>
      ValueKey('music-playlist-folder-${folder.id}');

  Widget _playlistRowActions(Widget? move, Widget action) => move == null
      ? action
      : Row(mainAxisSize: MainAxisSize.min, children: [move, action]);

  ValueKey<String> _itemKey(_LibraryItem item) => item.playlist != null
      ? ValueKey('music-local-${item.playlist!.playlistId}')
      : ValueKey(
          'music-saved-${item.bookmark!.kind.name}-${item.bookmark!.id}');

  String _itemTitle(_LibraryItem item) {
    if (item.playlist case final playlist?) {
      return playlist.playlistId == localWatchLaterId
          ? AppLocalizations.of(context)!.watchLater
          : playlist.title;
    }
    return _bookmarkDisplayTitle(
        item.bookmark!, MusicLibraryService.forProfile(db, db.profileId));
  }

  String _libraryOrderSetting(_LibraryFilter filter) =>
      'music-collection-library-order:${filter.name}';

  List<_LibraryItem> _sortedLibraryItems(
          List<_LibraryItem> items, MusicCollectionOrder order) =>
      [
        for (final index
            in order.orderIndices(items, sortValue: _libraryItemSortValue))
          items[index],
      ];

  Object? _libraryItemSortValue(
          _LibraryItem item, MusicCollectionSortField field) =>
      switch (field) {
        MusicCollectionSortField.source => null,
        MusicCollectionSortField.title => _itemTitle(item),
        MusicCollectionSortField.artist => switch (item.bookmark) {
            final entry? => MusicLibraryService.forProfile(db, db.profileId)
                .catalogArtistByline(entry.subtitle, entry.artistCredits),
            _ => null,
          },
        MusicCollectionSortField.album => item.bookmark?.album,
        MusicCollectionSortField.duration => switch (
              item.bookmark?.durationSeconds) {
            final int seconds when seconds > 0 => seconds,
            _ => null,
          },
        MusicCollectionSortField.listeningTime => null,
      };

  bool _isCollection(_LibraryItem item) =>
      item.playlist != null || item.bookmark?.kind == MusicLibraryKind.playlist;

  bool? _collectionSelected(_LibraryItem item) => _isCollection(item)
      ? _collectionSelection?.contains(_itemKey(item).value)
      : null;

  bool? _itemSelected(_LibraryItem item) =>
      item.bookmark?.kind == MusicLibraryKind.song
          ? _savedSongsSelection?.contains(item.bookmark!.id)
          : _collectionSelected(item);

  VoidCallback? _itemLongPress(_LibraryItem item) {
    if (_librarySelection != null) return null;
    if (_isCollection(item)) {
      return () => _startLibrarySelection(_filter, rowId: _itemKey(item).value);
    }
    if (item.bookmark case final song?
        when song.kind == MusicLibraryKind.song) {
      return () =>
          _startLibrarySelection(_filter, rowId: song.id, savedSongs: true);
    }
    return null;
  }

  Future<void> _openItem(_LibraryItem item, List<_LibraryItem> items,
      {bool songTap = false,
      Future<void> Function(_LibraryItem)? onOpenSong}) async {
    if (_collectionSelection != null) {
      if (_isCollection(item)) _toggleLibrarySelection(_itemKey(item).value);
      return;
    }
    if (_savedSongsSelection != null) {
      if (item.bookmark?.kind == MusicLibraryKind.song) {
        _toggleLibrarySelection(item.bookmark!.id);
      }
      return;
    }
    if (item.playlist case final playlist?) {
      setState(() {
        _resetPlaylistSearch();
        _playlistId = playlist.playlistId;
      });
    } else if (onOpenSong != null) {
      await onOpenSong(item);
    } else {
      await _openBookmark(item.bookmark!, items, songTap: songTap);
    }
  }

  String _shortcutTitle(_LibraryFilter shortcut, AppLocalizations locals) =>
      shortcut == _LibraryFilter.songs
          ? locals.musicSavedSongs
          : locals.downloads;

  IconData _shortcutIcon(_LibraryFilter shortcut) =>
      shortcut == _LibraryFilter.songs
          ? Icons.bookmark_rounded
          : Icons.cloud_download_rounded;

  void _openAutomaticCollections({bool showLikes = false}) {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return;
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => MusicAutomaticCollectionsPage(
            session: session, showLikes: showLikes))));
  }

  ValueKey<String> _shortcutKey(_LibraryFilter shortcut) =>
      ValueKey('music-library-shortcut-${shortcut.name}');

  void _selectFilter(_LibraryFilter filter) => setState(() {
        _filter = filter;
        _playlistId = null;
        _folderId = null;
        _resetPlaylistSearch();
        _resetLibraryFind();
      });

  Widget _collection(
      List<_LibraryItem> items,
      List<_LibraryFilter> shortcuts,
      MusicLibraryService library,
      MusicCollectionOrder order,
      MusicLayout presentation,
      {List<_LibraryItem>? playbackItems,
      Map<String, Video> offlineSongs = const {},
      Future<void> Function(_LibraryItem)? onOpenSong,
      Set<String> pinnedPlaylistIds = const {},
      Widget? searchToolbar,
      Widget? emptyResults,
      List<MusicPlaylistFolder> folders = const [],
      Widget Function(MusicPlaylistFolder)? folderMenu,
      Widget? Function(_LibraryItem)? movePlaylist}) {
    // Both lazy layouts retain an item's element when sorting or removing an
    // earlier row. This also keeps keyboard/TV focus on the surviving item.
    final indices = <Key, int>{
      for (var index = 0; index < shortcuts.length; index++)
        _shortcutKey(shortcuts[index]): index,
      for (var index = 0; index < folders.length; index++)
        _folderKey(folders[index]): index + shortcuts.length,
      for (var index = 0; index < items.length; index++)
        _itemKey(items[index]): index + shortcuts.length + folders.length,
    };
    final itemStart = shortcuts.length + folders.length;
    final count = items.length + itemStart;
    final locals = AppLocalizations.of(context)!;
    final allItems = playbackItems ?? items;
    final covers = MusicPlaylistCovers.forProfile(db, library.profileId);
    final layout = _grid ? 'grid' : 'list';
    final collectionKey = PageStorageKey(
        ('music-library', layout, _filter, library.profileId, _folderId));
    Widget fastScroll(Widget child) => MusicFastScroll(
          scope: (
            library.profileId,
            _filter,
            _folderId,
            order,
            _libraryQuery.text
          ),
          leadingItems: itemStart,
          sections: musicFastScrollSectionsFor<_LibraryItem>(context, items,
              sortValue: order.field == MusicCollectionSortField.source
                  ? null
                  : (item) => MusicCollectionOrder.normalizeSortValue(
                      _libraryItemSortValue(item, order.field))),
          child: child,
        );
    Widget searchResults(Widget toolbar, Widget results) => _libraryFindView(
          key: const ValueKey('music-saved-songs-results'),
          toolbar: toolbar,
          results: emptyResults == null
              ? results
              : SliverFillRemaining(hasScrollBody: false, child: emptyResults),
          count: count,
          pinned: _savedSongsSelection != null,
        );

    if (!_grid) {
      final minHeight =
          presentation.compactRows ? kMinInteractiveDimension : null;
      final minPadding = presentation.compactRows ? 4.0 : null;
      final rows = SliverChildBuilderDelegate((_, index) {
        if (index < shortcuts.length) {
          final shortcut = shortcuts[index];
          return ListTile(
              key: _shortcutKey(shortcut),
              enabled: _librarySelection == null,
              minTileHeight: minHeight,
              minVerticalPadding: minPadding,
              leading: Icon(_shortcutIcon(shortcut)),
              title: Text(_shortcutTitle(shortcut, locals)),
              onTap: _librarySelection == null
                  ? () => _selectFilter(shortcut)
                  : null);
        }
        if (index < itemStart) {
          final folder = folders[index - shortcuts.length];
          return ListTile(
            key: _folderKey(folder),
            enabled: _librarySelection == null,
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.name),
            trailing:
                _librarySelection == null ? folderMenu?.call(folder) : null,
            onTap: _librarySelection == null
                ? () => setState(() => _folderId = folder.id)
                : null,
          );
        }
        final item = items[index - itemStart];
        final move =
            _librarySelection == null ? movePlaylist?.call(item) : null;
        Future<void> open() =>
            _openItem(item, allItems, onOpenSong: onOpenSong);
        if (item.bookmark != null) {
          return _bookmark(
              item,
              () => _openItem(item, allItems,
                  songTap: true, onOpenSong: onOpenSong),
              open,
              presentation,
              library,
              movePlaylist: move,
              offlineSong: offlineSongs[item.bookmark!.id]);
        }
        final playlistId = item.playlist!.playlistId;
        final pin = pinnedPlaylistIds.contains(playlistId)
            ? Icon(Icons.push_pin, semanticLabel: locals.musicPlaylistPinned)
            : null;
        final selected = _collectionSelected(item);
        return ListTile(
            key: _itemKey(item),
            enabled: _savedSongsSelection == null,
            minTileHeight: minHeight,
            minVerticalPadding: minPadding,
            selected: selected ?? false,
            leading: MusicPlaylistCoverImage(
              encoded: covers.encodedCover(playlistId),
              fallback: const Icon(Icons.queue_music),
              size: 40,
            ),
            title: Text(_itemTitle(item)),
            subtitle: Text(locals.onDevice),
            trailing: selected == null
                ? _playlistRowActions(
                    move, pin ?? const Icon(Icons.chevron_right))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (pin != null) pin,
                    ExcludeSemantics(
                        child: Icon(selected
                            ? Icons.check_box
                            : Icons.check_box_outline_blank)),
                  ]),
            onLongPress: _itemLongPress(item),
            onTap: _savedSongsSelection == null ? open : null);
      }, childCount: count, findChildIndexCallback: (key) => indices[key]);
      return fastScroll(searchToolbar == null
          ? ListView.custom(
              key: collectionKey,
              childrenDelegate: rows,
              semanticChildCount: count)
          : searchResults(searchToolbar, SliverList(delegate: rows)));
    }
    final savedCovers = library.coversBySongId;
    return LayoutBuilder(builder: (context, constraints) {
      final theme = Theme.of(context).textTheme;
      final scaler = MediaQuery.textScalerOf(context);
      const padding = 12.0;
      const spacing = 18.0;
      final minimumWidth = math.max(
          presentation.gridSize.minimumWidth,
          scaler
              .scale(presentation.gridSize == MusicGridSize.small ? 96 : 112));
      final columns = math.min(
          6,
          math.max(
              1,
              ((constraints.maxWidth - 2 * padding + spacing) /
                      (minimumWidth + spacing))
                  .floor()));
      final width =
          (constraints.maxWidth - 2 * padding - (columns - 1) * spacing) /
              columns;
      final titleHeight = scaler.scale(theme.titleMedium!.fontSize!) *
          (theme.titleMedium!.height ?? 1.5);
      final subtitleHeight = scaler.scale(theme.bodyMedium!.fontSize!) *
          (theme.bodyMedium!.height ?? 1.4);
      const gridPadding = EdgeInsets.fromLTRB(padding, 12, padding, 16);
      final titleLines =
          _filter == _LibraryFilter.songs ? presentation.titleLines(2) : 2;
      final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 14,
          mainAxisExtent:
              width + titleHeight * titleLines + subtitleHeight + 10);
      final cards = SliverChildBuilderDelegate((_, index) {
        if (index < shortcuts.length) {
          return _gridShortcut(shortcuts[index], locals);
        }
        if (index < itemStart) {
          final folder = folders[index - shortcuts.length];
          final colors = Theme.of(context).colorScheme;
          return _gridCard(
            key: _folderKey(folder),
            title: folder.name,
            subtitle: locals.musicPlaylistFolder,
            artwork: ColoredBox(
                color: colors.surfaceContainerHighest,
                child: Icon(Icons.folder_outlined,
                    size: 64, color: colors.onSurfaceVariant)),
            artworkRadius: 7,
            action: _librarySelection == null ? folderMenu?.call(folder) : null,
            onOpen: _librarySelection == null
                ? () => setState(() => _folderId = folder.id)
                : null,
          );
        }
        final item = items[index - itemStart];
        return _gridItem(item, savedCovers, covers, library, allItems,
            onOpenSong: onOpenSong,
            offlineSong: offlineSongs[item.bookmark?.id],
            songTitleLines: presentation.titleLines(2),
            pinned: pinnedPlaylistIds.contains(item.playlist?.playlistId),
            movePlaylist:
                _librarySelection == null ? movePlaylist?.call(item) : null);
      }, childCount: count, findChildIndexCallback: (key) => indices[key]);
      return searchToolbar == null
          ? GridView.custom(
              key: collectionKey,
              padding: gridPadding,
              gridDelegate: gridDelegate,
              childrenDelegate: cards,
              semanticChildCount: count)
          : searchResults(
              searchToolbar,
              SliverPadding(
                padding: gridPadding,
                sliver: SliverGrid(delegate: cards, gridDelegate: gridDelegate),
              ),
            );
    });
  }

  Widget _gridShortcut(_LibraryFilter shortcut, AppLocalizations locals) {
    final colors = Theme.of(context).colorScheme;
    return _gridCard(
      key: _shortcutKey(shortcut),
      title: _shortcutTitle(shortcut, locals),
      artwork: ColoredBox(
          color: colors.surfaceContainerHighest,
          child: Icon(_shortcutIcon(shortcut),
              size: 64, color: colors.onSurfaceVariant)),
      artworkRadius: 25,
      onOpen: _librarySelection == null ? () => _selectFilter(shortcut) : null,
    );
  }

  Widget _gridItem(
      _LibraryItem item,
      Map<String, List<ImageObject>> savedCovers,
      MusicPlaylistCovers covers,
      MusicLibraryService library,
      List<_LibraryItem> items,
      {required bool pinned,
      required int songTitleLines,
      Widget? movePlaylist,
      Future<void> Function(_LibraryItem)? onOpenSong,
      Video? offlineSong}) {
    final entry = item.bookmark;
    Future<void> play() => _openItem(item, items, onOpenSong: onOpenSong);
    final local = item.playlist;
    final song = local?.videos.firstOrNull;
    final music = song?.musicMetadata;
    final images = entry?.displayThumbnails ??
        (song == null
            ? const <ImageObject>[]
            : displaySongThumbnails(
                song.videoId,
                savedCovers[song.videoId] ?? music?.thumbnails ?? const [],
                song.videoThumbnails,
                artTrack: music?.isArtTrack ?? false,
                instanceUrl: context.read<AppCubit>().state.server?.url));
    final artist = entry?.kind == MusicLibraryKind.artist;
    final playlist = local != null || entry?.kind == MusicLibraryKind.playlist;
    final plays = entry?.kind == MusicLibraryKind.song;
    final selected = _itemSelected(item);
    final enabled = _librarySelection == null || selected != null;
    final colors = Theme.of(context).colorScheme;
    final defaultArtwork = _bookmarkArtwork(
        entry,
        images.isEmpty
            ? ColoredBox(
                color: colors.surfaceContainerHighest,
                child: Icon(
                    artist
                        ? Icons.person_rounded
                        : playlist
                            ? Icons.queue_music_rounded
                            : Icons.music_note_rounded,
                    size: 48,
                    color: colors.onSurfaceVariant))
            : Thumbnail(
                musicArtwork: true,
                images: images,
                instanceOnly: true,
                decoration: const BoxDecoration()));
    final title = entry == null
        ? _itemTitle(item)
        : _bookmarkDisplayTitle(entry, library);
    return _gridCard(
      key: _itemKey(item),
      title: title,
      bookmark: entry,
      titleLines: plays ? songTitleLines : 2,
      subtitle: entry == null
          ? AppLocalizations.of(context)!.onDevice
          : _bookmarkDisplaySubtitle(entry, title, library),
      artworkRadius: artist ? 300 : 7,
      artwork: local == null
          ? defaultArtwork
          : MusicPlaylistCoverImage(
              encoded: covers.encodedCover(local.playlistId),
              fallback: defaultArtwork,
            ),
      action: !enabled || selected != null
          ? null
          : entry == null
              ? movePlaylist
              : _playlistRowActions(movePlaylist,
                  _bookmarkActions(entry, play, offlineSong: offlineSong)),
      plays: plays,
      selected: selected,
      pinned: pinned,
      onOpen: enabled
          ? () => _openItem(item, items, songTap: true, onOpenSong: onOpenSong)
          : null,
      onLongPress: _itemLongPress(item),
    );
  }

  Widget _gridCard({
    required Key key,
    required String title,
    required Widget artwork,
    required double artworkRadius,
    required VoidCallback? onOpen,
    VoidCallback? onLongPress,
    String subtitle = '',
    MusicLibraryEntry? bookmark,
    int titleLines = 2,
    Widget? action,
    bool plays = false,
    bool? selected,
    bool pinned = false,
  }) {
    final theme = Theme.of(context);
    return Material(
      key: key,
      type: MaterialType.transparency,
      child: Semantics(
          selected: selected,
          child: Builder(builder: (context) {
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onOpen,
              onLongPress: onLongPress,
              onFocusChange: (focused) {
                if (focused) Scrollable.ensureVisible(context, alignment: 0.5);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: Stack(fit: StackFit.expand, children: [
                      ExcludeSemantics(
                          child: ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(artworkRadius),
                              child: artwork)),
                      if (plays || selected != null)
                        PositionedDirectional(
                            end: 7,
                            bottom: 7,
                            child: ExcludeSemantics(
                                child: CircleAvatar(
                                    radius: 17,
                                    backgroundColor: Colors.black54,
                                    foregroundColor: Colors.white,
                                    child: Icon(selected == null
                                        ? Icons.play_arrow_rounded
                                        : selected
                                            ? Icons.check_box
                                            : Icons.check_box_outline_blank)))),
                      if (pinned)
                        PositionedDirectional(
                            start: selected == null ? null : 7,
                            end: selected == null ? 7 : null,
                            bottom: 7,
                            child: CircleAvatar(
                              radius: 17,
                              backgroundColor: Colors.black54,
                              foregroundColor: Colors.white,
                              child: Icon(Icons.push_pin,
                                  semanticLabel: AppLocalizations.of(context)!
                                      .musicPlaylistPinned),
                            )),
                      if (action != null)
                        PositionedDirectional(
                            end: 4,
                            top: 4,
                            child: Material(
                                shape: const StadiumBorder(),
                                color: Colors.black54,
                                child: Theme(
                                    data: theme.copyWith(
                                        iconTheme: theme.iconTheme
                                            .copyWith(color: Colors.white),
                                        iconButtonTheme: IconButtonThemeData(
                                            style: IconButton.styleFrom(
                                                foregroundColor:
                                                    Colors.white))),
                                    child: action))),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  _bookmarkTitle(
                      bookmark,
                      Text(title,
                          maxLines: titleLines,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600))),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            );
          })),
    );
  }

  Future<void> _downloadAction(DownloadedVideo video,
      Future<void> Function(DownloadManagerCubit) action) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || video.profileId != session.library.profileId) {
      return;
    }
    try {
      await action(context.read<DownloadManagerCubit>());
    } catch (_) {
      if (mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicDownloadError)));
      }
    }
  }

  Iterable<DownloadedVideo> _musicDownloads(
          DownloadManagerState state, String profileId) =>
      state.videos.where((video) =>
          video.profileId == profileId &&
          video.audioOnly &&
          video.musicMetadata != null &&
          DownloadedVideo.isSafeFileId(video.videoId));

  MusicDownloadOrder get _musicDownloadOrder =>
      context.read<SettingsCubit?>()?.state.musicDownloadOrder ??
      const MusicDownloadOrder();

  DownloadedVideo? _currentMusicDownload(DownloadedVideo selected) {
    if (!mounted || selected.profileId != db.profileId) return null;
    final state = context.read<DownloadManagerCubit>().state;
    return _musicDownloads(state, selected.profileId)
        .where((video) =>
            video.videoId == selected.videoId && _downloadReady(video))
        .firstOrNull;
  }

  Future<void> _playMusicDownload(DownloadedVideo selected,
          {bool songTap = false}) =>
      _downloadAction(selected, (manager) async {
        // A track menu may outlive progress, removal or reordering events.
        final completed = _musicDownloadOrder.sort(
            _musicDownloads(manager.state, selected.profileId)
                .where(_downloadReady));
        final index =
            completed.indexWhere((video) => video.videoId == selected.videoId);
        if (index < 0) return;
        if (_findFilter == _LibraryFilter.downloads) {
          _libraryQueryFocus.unfocus();
        }
        await context.read<PlayerCubit>().playOfflineVideos(completed,
            fromMusic: true, startIndex: index, songTap: songTap);
      });

  Video _downloadSong(DownloadedVideo video) {
    final music = video.musicMetadata!;
    return Video(
      videoId: video.videoId,
      title: music.title,
      author: music.artist,
      lengthSeconds: video.lengthSeconds,
      musicMetadata: music,
      videoThumbnails: music.thumbnails,
    );
  }

  bool _downloadReady(DownloadedVideo video) =>
      video.downloadComplete &&
      !video.downloadFailed &&
      !video.storageFailed &&
      !video.authenticationRequired;

  Widget _downloadsSelectionBar(List<DownloadedVideo> visible,
      List<DownloadedVideo> all, Set<String> scope) {
    final locals = AppLocalizations.of(context)!;
    final selected =
        all.where((video) => scope.contains(video.videoId)).toList();
    final ids = selected.map((video) => video.videoId).toList();
    final visibleIds = [for (final video in visible) video.videoId];
    final allSelected = selected.isNotEmpty && visibleIds.every(scope.contains);
    final session = MusicLibrarySession(context.read<AppCubit>());
    final manager = context.read<DownloadManagerCubit>();
    final order = _musicDownloadOrder;

    bool ownerCurrent() =>
        mounted &&
        session.isCurrent &&
        identical(_downloadsSelection, scope) &&
        !manager.isClosed &&
        identical(context.read<DownloadManagerCubit>(), manager);
    Iterable<DownloadedVideo> liveSelection() =>
        order.sort(_musicDownloads(manager.state, session.library.profileId)
            .where((video) => scope.contains(video.videoId)));
    bool isCurrent() =>
        ownerCurrent() &&
        _musicDownloadOrder == order &&
        listEquals(ids, liveSelection().map((video) => video.videoId).toList());

    List<DownloadedVideo>? resolveDownloads(List<Video> tracks) {
      if (!isCurrent()) return null;
      final ready = {
        for (final video in liveSelection())
          if (_downloadReady(video)) video.videoId: video,
      };
      final files = [
        for (final track in tracks)
          if (ready[track.videoId] case final file?) file,
      ];
      return files.length == tracks.length ? files : null;
    }

    Future<void> remove() async {
      if (!isCurrent()) return;
      final removed = await confirmMusicDownloadRemoval(
        context,
        manager,
        selected,
        isCurrent: ownerCurrent,
        revalidate: (_) async => isCurrent(),
      );
      if (removed != null &&
          removed > 0 &&
          ownerCurrent() &&
          liveSelection().isEmpty) {
        _exitLibrarySelection();
      }
    }

    return MusicSongSelectionBar(
      selected: selected.where(_downloadReady).map(_downloadSong).toList(),
      selectedCount: selected.length,
      allSelected: allSelected,
      onToggleAll: allSelected || visibleIds.isNotEmpty
          ? () => setState(() {
                scope.clear();
                if (!allSelected) scope.addAll(visibleIds);
              })
          : null,
      onClose: _exitLibrarySelection,
      closeFocus: _libraryExitSelectionFocus,
      isCurrent: isCurrent,
      resolveDownloads: resolveDownloads,
      onRemoveDownloads: selected.isEmpty ? null : remove,
      onPlay: (tracks) async {
        final files = resolveDownloads(tracks);
        if (files == null || files.isEmpty) return;
        await context
            .read<PlayerCubit>()
            .playOfflineVideos(files, fromMusic: true);
      },
    );
  }

  SliverChildBuilderDelegate _downloadRows(DownloadManagerState state,
      List<DownloadedVideo> videos, MusicLibraryService library) {
    final locals = AppLocalizations.of(context)!;
    ValueKey<(String, String)> rowKey(DownloadedVideo video) =>
        ValueKey((video.profileId, video.videoId));
    final positions = {
      for (final (index, video) in videos.indexed) rowKey(video): index,
    };
    return SliverChildBuilderDelegate((context, index) {
      final video = videos[index];
      final selected = _downloadsSelection?.contains(video.videoId);
      final paused = state.pausedVideoIds.contains(video.videoId);
      final ready = _downloadReady(video);
      final retry = video.downloadFailed ||
          video.authenticationRequired ||
          video.storageFailed;
      final progress = state.downloadProgresses[video.videoId];
      final status = ready
          ? library.catalogArtistByline(
              video.musicMetadata!.artist, video.musicMetadata!.artistCredits)
          : video.authenticationRequired
              ? locals.downloadSignInRequired
              : video.storageFailed
                  ? locals.downloadFolderError
                  : video.downloadFailed
                      ? locals.videoFailedDownloadRetry
                      : paused
                          ? locals.downloadPaused
                          : state.waitingForWifiFor(video)
                              ? locals.downloadsWaitingForWifi
                              : locals.downloadQueued;
      final tile = ListTile(
          key: ValueKey('music-download-${video.videoId}'),
          selected: selected ?? false,
          leading: Icon(ready ? Icons.audio_file_outlined : Icons.downloading),
          title: MusicStatusTitle.download(
              file: video, child: Text(video.musicMetadata!.title)),
          subtitle: Text(status),
          onLongPress: selected == null
              ? () => _startLibrarySelection(_LibraryFilter.downloads,
                  rowId: video.videoId)
              : null,
          onTap: selected != null
              ? () => _toggleLibrarySelection(video.videoId)
              : ready
                  ? () => _playMusicDownload(video, songTap: true)
                  : null,
          trailing: selected != null
              ? ExcludeSemantics(
                  child: Icon(selected
                      ? Icons.check_box
                      : Icons.check_box_outline_blank))
              : ready
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      MusicDownloadExportAction(video: video, compact: true),
                      IconButton(
                        key:
                            ValueKey('music-download-actions-${video.videoId}'),
                        tooltip: locals.musicLibraryActions,
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => MusicLibraryActions.showSongMenu(
                            context, _downloadSong(video),
                            downloads: [video],
                            resolveDownload: () => _currentMusicDownload(video),
                            onPlay: () => _playMusicDownload(video)),
                      ),
                    ])
                  : video.downloadComplete
                      ? null
                      : IconButton(
                          tooltip: retry
                              ? locals.retry
                              : paused
                                  ? locals.resumeDownload
                                  : locals.pauseDownload,
                          icon: Icon(retry
                              ? Icons.refresh
                              : paused
                                  ? Icons.play_arrow
                                  : Icons.pause),
                          onPressed: () => _downloadAction(
                              video,
                              (manager) => retry || paused
                                  ? manager.retryDownload(video)
                                  : manager.pauseDownload(video))));
      return Column(key: rowKey(video), children: [
        MusicSongRowSwipe(
          trailingInset: 112,
          onAction: selected == null && ready
              ? (action) async {
                  final current = _currentMusicDownload(video);
                  if (current == null) return;
                  await MusicLibraryActions.queueSong(
                      context, _downloadSong(current), action,
                      download: current);
                }
              : null,
          child: tile,
        ),
        if (!video.downloadComplete && progress != null && !paused)
          LinearProgressIndicator(
              value:
                  progress.total > 0 ? progress.count / progress.total : null),
      ]);
    },
        childCount: videos.length,
        findChildIndexCallback: (key) => positions[key]);
  }

  Widget _downloadsActionsButton({required bool hasCompletedSongs}) {
    final locals = AppLocalizations.of(context)!;
    final player = context.read<PlayerCubit?>();
    final manager = context.read<DownloadManagerCubit>();
    return PopupMenuButton<Future<void> Function()>(
      key: const ValueKey('music-downloads-actions'),
      enabled: hasCompletedSongs && player != null,
      onSelected: (command) => unawaited(command()),
      itemBuilder: (_) {
        final session = MusicLibrarySession(context.read<AppCubit>());
        bool isCurrent() =>
            mounted &&
            TickerMode.of(context) &&
            session.isCurrent &&
            _filter == _LibraryFilter.downloads &&
            _downloadsSelection == null &&
            !manager.isClosed &&
            identical(context.read<DownloadManagerCubit>(), manager) &&
            player != null &&
            !player.isClosed &&
            identical(context.read<PlayerCubit?>(), player);

        Future<void> apply({required bool enqueue}) async {
          if (player == null || !isCurrent()) return;
          if (enqueue && !player.canAddMusicDownloadsToQueue) return;
          final files = _musicDownloadOrder.sort(
              _musicDownloads(manager.state, session.library.profileId)
                  .where(_downloadReady));
          if (files.isEmpty) return;
          if (_findFilter == _LibraryFilter.downloads) {
            _libraryQueryFocus.unfocus();
          }
          try {
            if (enqueue) {
              if (!await player.addMusicDownloadsToQueue(files,
                  isCurrent: isCurrent)) {
                throw StateError('The current queue is unavailable.');
              }
            } else {
              await player.shuffleMusicDownloads(files, isCurrent: isCurrent);
            }
          } catch (_) {
            if (mounted && isCurrent()) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(locals.musicLibraryActionError)));
            }
          }
        }

        return [
          PopupMenuItem(
              value: () => apply(enqueue: false),
              child: Text(locals.musicShuffleAll)),
          PopupMenuItem(
              value: () => apply(enqueue: true),
              enabled: player?.canAddMusicDownloadsToQueue ?? false,
              child: Text(locals.musicAddAllToQueue)),
        ];
      },
    );
  }

  Widget _downloadsSortButton(MusicDownloadOrder order, SettingsCubit? settings,
      {required bool compact}) {
    final locals = AppLocalizations.of(context)!;
    String label(MusicDownloadSortField field) => switch (field) {
          MusicDownloadSortField.defaultOrder =>
            locals.musicDownloadsDefaultOrder,
          MusicDownloadSortField.title => locals.musicLibraryTitleOrder,
          MusicDownloadSortField.artist => locals.localMusicSortArtist,
          MusicDownloadSortField.album => locals.localMusicSortAlbum,
          MusicDownloadSortField.duration => locals.searchDuration,
        };
    return PopupMenuButton<Future<void> Function()>(
      key: const ValueKey('music-downloads-sort'),
      enabled: settings != null,
      tooltip: locals.searchSortBy,
      onSelected: (command) => unawaited(command()),
      itemBuilder: (_) {
        final session = MusicLibrarySession(context.read<AppCubit>());
        Future<void> change({
          MusicDownloadSortField? field,
          bool? descending,
        }) async {
          if (!mounted ||
              !session.isCurrent ||
              _filter != _LibraryFilter.downloads ||
              _downloadsSelection != null ||
              !identical(context.read<SettingsCubit?>(), settings) ||
              settings == null ||
              settings.isClosed) {
            return;
          }
          try {
            await settings.updateMusicDownloadOrder(
                field: field, descending: descending);
            if (mounted &&
                session.isCurrent &&
                _findFilter == _LibraryFilter.downloads) {
              _jumpToLibraryFindStart();
            }
          } catch (_) {
            if (mounted && session.isCurrent) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(locals.musicLibraryActionError)));
            }
          }
        }

        return [
          for (final field in MusicDownloadSortField.values)
            CheckedPopupMenuItem(
              checked: field == order.field,
              value: () => change(field: field),
              child: Text(label(field)),
            ),
          const PopupMenuDivider(),
          for (final descending in [false, true])
            CheckedPopupMenuItem(
              checked: descending == order.descending,
              value: () => change(descending: descending),
              child: Text(descending
                  ? locals.localMusicDescending
                  : locals.localMusicAscending),
            ),
        ];
      },
      icon: compact ? const Icon(Icons.sort) : null,
      child: compact
          ? null
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(label(order.field),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                const SizedBox(width: 8),
                Icon(
                    order.descending
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_upward_rounded,
                    size: 16),
              ]),
            ),
    );
  }

  Widget _downloads() =>
      BlocBuilder<DownloadManagerCubit, DownloadManagerState>(
          builder: (context, state) {
        final locals = AppLocalizations.of(context)!;
        final profileId = db.profileId;
        final library = MusicLibraryService.forProfile(db, profileId);
        final settings = context.watch<SettingsCubit?>();
        final order =
            settings?.state.musicDownloadOrder ?? const MusicDownloadOrder();
        final videos = order.sort(_musicDownloads(state, profileId));
        final selection = _downloadsSelection;
        selection?.retainAll(videos.map((video) => video.videoId));
        final search = _libraryFindButton(
            const ValueKey('music-downloads-search'),
            _LibraryFilter.downloads,
            locals.musicSearchDownloads);
        final select = _librarySelectButton(
            const ValueKey('music-downloads-select'), _LibraryFilter.downloads);
        final actions = _downloadsActionsButton(
            hasCompletedSongs: videos.any(_downloadReady));
        Widget content() {
          if (_findFilter != _LibraryFilter.downloads) {
            if (videos.isEmpty && selection == null) return _empty();
            final duration = musicDurationLabel(
                locals,
                videos
                    .where(_downloadReady)
                    .map((video) => video.lengthSeconds));
            return Column(children: [
              if (selection == null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 18, end: 8),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: _downloadsSortButton(order, settings,
                                  compact: false),
                            ),
                          ),
                          actions,
                          select,
                          search,
                        ]),
                        if (duration != null)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(duration,
                                  key: const ValueKey(
                                      'music-downloads-duration'),
                                  style:
                                      Theme.of(context).textTheme.bodySmall)),
                      ]),
                )
              else
                _downloadsSelectionBar(videos, videos, selection),
              Expanded(
                child: videos.isEmpty
                    ? _empty()
                    : MusicFastScroll(
                        scope: (profileId, order),
                        sections: musicFastScrollSectionsFor(context, videos,
                            sortValue: order.field ==
                                    MusicDownloadSortField.defaultOrder
                                ? null
                                : order.sortValue),
                        child: ListView.custom(
                          key: PageStorageKey(('music-downloads', profileId)),
                          childrenDelegate:
                              _downloadRows(state, videos, library),
                          semanticChildCount: videos.length,
                        ),
                      ),
              ),
            ]);
          }

          Widget toolbar({Widget? saveResults}) => Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: Row(children: [
                  Expanded(
                    child: _collectionSearchField(
                      key: const ValueKey('music-downloads-query'),
                      label: locals.musicSearchDownloads,
                      controller: _libraryQuery,
                      focusNode: _libraryQueryFocus,
                      onQueryChanged: _jumpToLibraryFindStart,
                      compact: true,
                    ),
                  ),
                  if (saveResults != null) saveResults,
                  _downloadsSortButton(order, settings, compact: true),
                  actions,
                  if (videos.isNotEmpty) select,
                  search,
                ]),
              );
          return ValueListenableBuilder(
            valueListenable: _libraryQuery,
            builder: (context, input, _) {
              final terms = musicSearchTerms(input.text);
              final matches = terms.isEmpty
                  ? videos
                  : videos.where((video) {
                      final music = video.musicMetadata!;
                      final text = _downloadSearchText[video] ??=
                          normalizeMusicSearchText([
                        music.title,
                        music.artist,
                        for (final credit in music.artistCredits) credit.name,
                      ].join(' '));
                      return musicSearchMatchesWithArtistAliases(
                          terms,
                          text,
                          catalogArtistSearchAliases(
                              library, music.artistCredits));
                    }).toList();
              final readyMatches = matches.where(_downloadReady);
              return MusicFastScroll(
                scope: (profileId, order, input.text),
                sections: musicFastScrollSectionsFor(context, matches,
                    sortValue:
                        order.field == MusicDownloadSortField.defaultOrder
                            ? null
                            : order.sortValue),
                child: _libraryFindView(
                  key: const ValueKey('music-downloads-results'),
                  toolbar: selection == null
                      ? toolbar(
                          saveResults: terms.isNotEmpty &&
                                  readyMatches.isNotEmpty
                              ? _saveFilteredPlaylistButton(
                                  readyMatches.map(_downloadSong), profileId)
                              : null)
                      : _downloadsSelectionBar(matches, videos, selection),
                  count: matches.length,
                  pinned: selection != null,
                  results: matches.isEmpty
                      ? SliverFillRemaining(
                          hasScrollBody: false,
                          child: terms.isEmpty
                              ? _empty()
                              : Center(child: Text(locals.musicNoResults)),
                        )
                      : SliverList(
                          delegate: _downloadRows(state, matches, library)),
                ),
              );
            },
          );
        }

        return Column(children: [
          if (selection == null && videos.isNotEmpty)
            Container(
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsetsDirectional.fromSTEB(18, 6, 8, 4),
              child: MusicDownloadStorageSummary(
                key: ValueKey(('music-downloads-storage-summary', profileId)),
                profileId: profileId,
                downloads: videos.toSet(),
                transferring: videos.any((video) =>
                    state.downloadProgresses.containsKey(video.videoId)),
              ),
            ),
          Expanded(child: content()),
        ]);
      });

  @override
  Widget build(BuildContext context) => MusicScreenPrivacySurface(
        active: widget.source != null,
        child: _buildWithCategories(context),
      );

  Widget _buildWithCategories(BuildContext context) {
    if (widget.source != null || context.read<SettingsCubit?>() == null) {
      return _buildLibrary(_categoryFilters(null), canCustomize: false);
    }
    return BlocConsumer<SettingsCubit, SettingsState>(
      listenWhen: _categoriesChanged,
      buildWhen: _categoriesChanged,
      listener: (_, state) {
        final filters = _categoryFilters(state.musicLayout);
        final fallback = _defaultFilter(filters);
        if (_filter != fallback && !filters.contains(_filter)) {
          _selectFilter(fallback);
        }
      },
      builder: (_, state) => _buildLibrary(_categoryFilters(state.musicLayout),
          canCustomize: true),
    );
  }

  bool _categoriesChanged(SettingsState before, SettingsState after) =>
      !listEquals(_categoryFilters(before.musicLayout),
          _categoryFilters(after.musicLayout));

  Widget _buildLibrary(List<_LibraryFilter> filters,
          {required bool canCustomize}) =>
      BlocConsumer<AppCubit, AppState>(
        listenWhen: (before, after) =>
            before.profileId != after.profileId ||
            before.sessionRevision != after.sessionRevision ||
            before.server != after.server ||
            before.sessionRecoveryRequired != after.sessionRecoveryRequired ||
            before.globalLoading != after.globalLoading,
        listener: (context, state) => setState(() {
          _playlistId = null;
          _folderId = null;
          _resetPlaylistSearch();
          _resetLibraryFind();
        }),
        builder: (context, state) {
          final layout = context.select((SettingsCubit? cubit) =>
              cubit?.state.musicLayout ?? const MusicLayout.defaults());
          // Retained home pages rebuild when visible again, including changes
          // made through the application's existing local playlist screens.
          final active = TickerMode.of(context);
          if (widget.source case final source?) {
            return _sourcePlaylist(source, layout, active: active);
          }
          final locals = AppLocalizations.of(context)!;
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final library = MusicLibraryService.forProfile(db, db.profileId);
          final playlistFolders =
              MusicPlaylistFolderService.forProfile(db, library.profileId);
          final showLibraryChrome = !_playlistSearching &&
              !_playlistSelecting &&
              _findFilter == null &&
              _librarySelection == null;
          return PopScope(
            canPop: (_playlistId == null &&
                    _folderId == null &&
                    _findFilter == null &&
                    _librarySelection == null) ||
                !active,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop || !active) return;
              if (_playlistId != null) {
                _backFromLocalPlaylist();
              } else if (_librarySelection != null) {
                _exitLibrarySelection();
              } else if (_findFilter case final filter?) {
                _toggleLibraryFind(filter);
              } else if (_folderId != null) {
                _backFromFolder(playlistFolders);
              }
            },
            child: ListenableBuilder(
                listenable: Listenable.merge(
                    [library.changes, playlistFolders.changes]),
                builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showLibraryChrome)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                                start: 16, end: 6),
                            child:
                                LayoutBuilder(builder: (context, constraints) {
                              final actions = <Widget>[
                                if (canCustomize)
                                  IconButton(
                                    key:
                                        const ValueKey('music-library-arrange'),
                                    tooltip:
                                        locals.musicLayoutLibraryCategories,
                                    icon: const Icon(Icons.tune),
                                    onPressed: state.globalLoading ||
                                            state.sessionRecoveryRequired
                                        ? null
                                        : () => MusicLayoutEditor.open(context,
                                            libraryCategoriesOnly: true),
                                  ),
                                if (context.read<PlayerCubit?>() != null)
                                  IconButton(
                                    key: const ValueKey(
                                        'music-library-saved-queues'),
                                    tooltip: locals.musicSavedQueues,
                                    onPressed: state.globalLoading ||
                                            state.sessionRecoveryRequired
                                        ? null
                                        : () => showMusicSavedQueues(context),
                                    icon: const Icon(Icons.bookmarks_outlined),
                                  ),
                                IconButton(
                                  key: const ValueKey(
                                      'music-library-automatic-collections'),
                                  tooltip: locals.musicAutomaticCollections,
                                  icon: const Icon(Icons.auto_awesome_outlined),
                                  onPressed: state.globalLoading ||
                                          state.sessionRecoveryRequired
                                      ? null
                                      : _openAutomaticCollections,
                                ),
                                IconButton(
                                  key: const ValueKey('music-library-history'),
                                  tooltip: locals.musicPlaybackHistory,
                                  icon: const Icon(Icons.history),
                                  onPressed: state.globalLoading ||
                                          state.sessionRecoveryRequired
                                      ? null
                                      : () => Navigator.of(context).push<void>(
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  const MusicScreenPrivacySurface(
                                                      child:
                                                          MusicHistoryScreen()))),
                                ),
                                IconButton(
                                  key: const ValueKey(
                                      'music-library-statistics'),
                                  tooltip: locals.musicListeningStatistics,
                                  icon: const Icon(Icons.bar_chart_outlined),
                                  onPressed: state.globalLoading ||
                                          state.sessionRecoveryRequired
                                      ? null
                                      : () => Navigator.of(context).push<void>(
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  const MusicScreenPrivacySurface(
                                                      child:
                                                          MusicListeningStatisticsPage()))),
                                ),
                                IconButton(
                                    tooltip: locals.takeoutImport,
                                    icon:
                                        const Icon(Icons.file_upload_outlined),
                                    onPressed: state.globalLoading ||
                                            state.sessionRecoveryRequired
                                        ? null
                                        : () async {
                                            final imported =
                                                await showTakeoutImport(
                                                    context);
                                            if (!mounted) return;
                                            if (imported ==
                                                TakeoutImportDestination
                                                    .likes) {
                                              _openAutomaticCollections(
                                                  showLikes: true);
                                            } else if (imported ==
                                                TakeoutImportDestination
                                                    .savedSongs) {
                                              final layout = this
                                                  .context
                                                  .read<SettingsCubit?>()
                                                  ?.state
                                                  .musicLayout;
                                              final songsVisible =
                                                  _categoryFilters(layout)
                                                      .contains(
                                                          _LibraryFilter.songs);
                                              _selectFilter(songsVisible
                                                  ? _LibraryFilter.songs
                                                  : _filter);
                                            }
                                          }),
                              ];
                              final titleWidth = math.max(96.0,
                                  MediaQuery.textScalerOf(context).scale(96));
                              return _libraryControlsRow(
                                leading: Semantics(
                                  header: true,
                                  child: Text(locals.musicLibrary,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleLarge),
                                ),
                                actions: actions,
                                actionWidth: math.max(
                                    0.0, constraints.maxWidth - titleWidth),
                              );
                            }),
                          ),
                        if (showLibraryChrome && filters.isNotEmpty)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(children: [
                              for (final filter in filters)
                                Padding(
                                    key: ValueKey(filter),
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                        key: ValueKey(
                                            'music-library-tab-${filter.name}'),
                                        label: Text(
                                            filter.category!.label(locals)),
                                        labelStyle: theme.textTheme.labelLarge
                                            ?.copyWith(
                                                color: _filter == filter
                                                    ? colors.onInverseSurface
                                                    : colors.onSurfaceVariant),
                                        labelPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 9),
                                        showCheckmark: false,
                                        shape: const StadiumBorder(),
                                        side: BorderSide.none,
                                        backgroundColor:
                                            colors.surfaceContainerHighest,
                                        selectedColor: colors.inverseSurface,
                                        selected: _filter == filter,
                                        onSelected: (selected) => _selectFilter(
                                            selected || isTv
                                                ? filter
                                                : _LibraryFilter.all))),
                            ]),
                          ),
                        Expanded(
                          child: switch (_filter) {
                            _LibraryFilter.onDevice => LocalMusicFolder.library(
                                library: widget.deviceLibrary),
                            _
                                when state.globalLoading ||
                                    state.sessionRecoveryRequired =>
                              const Center(child: CircularProgressIndicator()),
                            _LibraryFilter.cachedSongs => CachedMusicLibrary(
                                key: ValueKey((
                                  state.profileId,
                                  state.sessionRevision,
                                  state.server?.accountId,
                                )),
                                active: active,
                                server: state.server,
                              ),
                            _LibraryFilter.podcasts => PodcastLibraryPage(
                                key: ValueKey(
                                    'podcasts-${db.profileId}-${state.sessionRevision}')),
                            _LibraryFilter.downloads when !isTv => _downloads(),
                            _ => _catalogLibrary(context, library, filters,
                                playlistFolders, layout),
                          },
                        ),
                      ],
                    )),
          );
        },
      );
}
