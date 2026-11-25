import 'dart:async';
import 'dart:math' as math;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_download_order.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist_selection.dart';
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_collection_panes.dart';
import 'package:clipious/music/views/components/music_details_dialog.dart';
import 'package:clipious/music/views/components/music_download_storage_summary.dart';
import 'package:clipious/music/views/components/music_duration_label.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/music/views/components/music_playlist_resume.dart';
import 'package:clipious/music/views/components/music_song_selection_bar.dart';
import 'package:clipious/music/views/components/takeout_import_dialog.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/views/podcast_library.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/views/components/playlist_information.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/history.dart';
import 'package:clipious/videos/views/tv/screens/history.dart';
import 'package:clipious/videos/views/components/video_watch_progress.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum _LibraryFilter {
  all,
  playlists,
  songs,
  onDevice,
  channels,
  downloads,
  podcasts
}

enum _LibrarySort { saved, title }

typedef _LibraryItem = ({Playlist? playlist, MusicLibraryEntry? bookmark});
typedef _LibrarySelection = ({
  _LibraryFilter filter,
  Set<String> ids,
  double? offset,
});

/// The Music home's Library body, or a standalone detail for a local source.
class MusicLibraryPage extends StatefulWidget {
  final PlaylistReference? source;

  const MusicLibraryPage({super.key, this.source});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  _LibraryFilter _filter = isTv ? _LibraryFilter.playlists : _LibraryFilter.all;
  _LibrarySort _sort = _LibrarySort.saved;
  bool _grid = !isTv;
  String? _playlistId;
  MusicLibrarySession? _sourceSession;
  final _playlistQuery = TextEditingController();
  final _playlistQueryFocus = FocusNode(debugLabel: 'Music playlist query');
  final _playlistSearchFocus = FocusNode(debugLabel: 'Search Music playlist');
  final _playlistSelectFocus = FocusNode(debugLabel: 'Select playlist songs');
  final _playlistExitSelectionFocus =
      FocusNode(debugLabel: 'Close playlist selection');
  final _playlistSelection = MusicPlaylistSelection();
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
  Set<String>? get _savedSongsSelection => _selectionIn(_LibraryFilter.songs);
  Set<String>? get _downloadsSelection =>
      _selectionIn(_LibraryFilter.downloads);

  Set<String>? _selectionIn(_LibraryFilter filter) {
    final selection = _librarySelection;
    return selection != null && selection.filter == filter
        ? selection.ids
        : null;
  }

  @override
  void didUpdateWidget(MusicLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _sourceSession = null;
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

  void _startLibrarySelection(_LibraryFilter filter, [String? songId]) {
    if (_filter != filter || _librarySelection != null) return;
    final ids = <String>{if (songId != null) songId};
    _libraryQueryFocus.unfocus();
    setState(() {
      _librarySelection = (
        filter: filter,
        ids: ids,
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
      if ((_findFilter != selection.filter || offset == 0) &&
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
    });
  }

  void _resetPlaylistSearch() {
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
      setState(() => _playlistId = null);
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
      Duration startAt = Duration.zero}) async {
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
          startAt: startAt);
    } catch (_) {
      if (mounted && session.isCurrent) _error();
    }
  }

  void _error() => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.musicPlaybackError)));

  Future<void> _openBookmark(
      MusicLibraryEntry entry, List<_LibraryItem> items) async {
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
            queueTitle: AppLocalizations.of(context)!.musicSavedSongs);
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
      MusicLibraryEntry entry, Future<void> Function() onOpen) {
    final locals = AppLocalizations.of(context)!;
    final removeLabel = switch (entry.kind) {
      MusicLibraryKind.song => locals.musicRemoveSong,
      MusicLibraryKind.album => locals.musicRemoveAlbum,
      MusicLibraryKind.artist => locals.musicRemoveArtist,
      MusicLibraryKind.playlist => locals.musicRemovePlaylist,
    };
    return entry.kind == MusicLibraryKind.song
        ? MusicLibraryActions(videos: [entry.toVideo()], onPlay: onOpen)
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

  VoidCallback? _bookmarkLongPress(
      MusicLibraryEntry? entry, Future<void> Function() onOpen) {
    if (entry == null || entry.kind != MusicLibraryKind.song) return null;
    if (_filter == _LibraryFilter.songs) {
      return _savedSongsSelection == null
          ? () => _startLibrarySelection(_LibraryFilter.songs, entry.id)
          : null;
    }
    return () => MusicLibraryActions.showSongMenu(context, entry.toVideo(),
        onPlay: onOpen);
  }

  Widget _bookmark(MusicLibraryEntry entry, Future<void> Function() onOpen) {
    final selected = _savedSongsSelection?.contains(entry.id);
    return ListTile(
        key: ValueKey('music-saved-${entry.kind.name}-${entry.id}'),
        selected: selected ?? false,
        leading: entry.kind == MusicLibraryKind.artist
            ? ChannelAvatar(
                musicArtwork: true,
                name: entry.title,
                images: entry.thumbnails,
                size: 52,
                instanceOnly: true)
            : SizedBox.square(
                dimension: 52,
                child:
                    _bookmarkArtwork(entry, _artwork(entry.displayThumbnails))),
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: entry.subtitle.isEmpty
            ? null
            : Text(entry.subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: selected == null
            ? _bookmarkActions(entry, onOpen)
            : ExcludeSemantics(
                child: Icon(selected
                    ? Icons.check_box
                    : Icons.check_box_outline_blank)),
        onLongPress: _bookmarkLongPress(entry, onOpen),
        onTap: onOpen);
  }

  String _label(_LibraryFilter filter, AppLocalizations locals) =>
      switch (filter) {
        _LibraryFilter.all => locals.musicLibrary,
        _LibraryFilter.playlists => locals.musicPlaylists,
        _LibraryFilter.songs => locals.musicSongs,
        _LibraryFilter.onDevice => locals.onDevice,
        _LibraryFilter.podcasts => locals.podcasts,
        _LibraryFilter.channels => locals.channels,
        _LibraryFilter.downloads => locals.downloads,
      };

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

  Widget _librarySelectButton(Key key, _LibraryFilter filter) => IconButton(
        key: key,
        focusNode: _librarySelectFocus,
        tooltip: AppLocalizations.of(context)!.musicQueueSelect,
        icon: const Icon(Icons.checklist_rounded),
        onPressed: () => _startLibrarySelection(filter),
      );

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

  Widget _playlistSelectionBar(
      List<String> visible, List<Video> selected, String title,
      {required bool Function() isCurrent}) {
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
      onPlay: (tracks) =>
          MusicScreen.playTracks(context, tracks, queueTitle: title),
    );
  }

  Widget _savedSongsSelectionBar(
      List<_LibraryItem> visible, List<_LibraryItem> all, Set<String> scope) {
    final title = AppLocalizations.of(context)!.musicSavedSongs;
    final session = MusicLibrarySession(context.read<AppCubit>());
    final sort = _sort;
    final selected = [
      for (final item in all)
        if (scope.contains(item.bookmark!.id)) item.bookmark!,
    ];
    final selectedIds = selected.map((entry) => entry.id).toList();
    final visibleIds = [for (final item in visible) item.bookmark!.id];
    final allSelected = selected.isNotEmpty && visibleIds.every(scope.contains);
    bool isCurrent() {
      if (!mounted ||
          !session.isCurrent ||
          !identical(_savedSongsSelection, scope) ||
          _sort != sort) {
        return false;
      }
      final live = <_LibraryItem>[
        for (final entry in session.library.entries)
          if (entry.kind == MusicLibraryKind.song && scope.contains(entry.id))
            (playlist: null, bookmark: entry),
      ];
      _sortLibraryItems(live);
      return listEquals(
          selectedIds, [for (final item in live) item.bookmark!.id]);
    }

    return MusicSongSelectionBar(
      selected: [for (final entry in selected) entry.toVideo()],
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
      onPlay: (tracks) =>
          MusicScreen.playTracks(context, tracks, queueTitle: title),
    );
  }

  Widget _localPlaylist(Playlist playlist, MusicLibraryService library) {
    final locals = AppLocalizations.of(context)!;
    final title = playlist.playlistId == localWatchLaterId
        ? locals.watchLater
        : playlist.title;
    final savedCovers = library.coversBySongId;
    final instanceUrl = context.read<AppCubit>().state.server?.url;
    final songs = <Video>[];
    final keys = <ValueKey<String>>[];
    final assignedEntries = _playlistSelection.reconcile(playlist.videos);
    for (final (index, video) in playlist.videos.indexed) {
      final music = video.musicMetadata;
      if (music == null) continue;
      final covers = savedCovers[video.videoId];
      // Identify rows by their source occurrence. Playback and saved progress
      // still use the same Music-only queue IDs used before filtering by text.
      keys.add(ValueKey(assignedEntries[index].queueEntryId!));
      songs.add(covers == null
          ? video
          : video.copyWith(musicMetadata: music.withThumbnails(covers)));
    }
    final reference = PlaylistReference.forPlaylist(
        playlist, db.forProfile(library.profileId));
    final searchable = _playlistSearching
        ? [
            for (final song in songs)
              normalizeMusicSearchText(
                  '${song.musicMetadata!.title} ${song.musicMetadata!.artist}'),
          ]
        : const <String>[];
    Future<void> playSong(int index) {
      _playlistQueryFocus.unfocus();
      return _play(songs, reference: reference, startIndex: index);
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
          !identical(_playlistSelectionScope, selectionScope)) {
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
          if (_playlistSelection.selected.contains(song.queueEntryId))
            song.queueEntryId!,
      ]);
    }

    Widget details({bool showHeading = false}) => Column(children: [
          if (showHeading && widget.source == null)
            ListTile(
              title: Semantics(header: true, child: Text(title)),
              subtitle: Text(locals.onDevice),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PlaylistInformation(
              playlist: playlist,
              reference: reference,
              showServerCopy: !_playlistSearching,
            ),
          ),
          if (songs.isNotEmpty && !_playlistSelecting && !_playlistSearching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                    onPressed: () => _play(songs, reference: reference),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(locals.musicPlayAll)),
                MusicPlaylistResume(
                    reference: reference,
                    videos: songs,
                    onPlay: (index, position) => _play(songs,
                        reference: reference,
                        startIndex: index,
                        startAt: position)),
                MusicLibraryActions(videos: songs, compact: false),
              ]),
            ),
        ]);

    Widget tracks(BuildContext context, bool split) => ValueListenableBuilder(
          valueListenable: _playlistQuery,
          builder: (_, input, __) {
            final terms = musicSearchTerms(input.text);
            final visible = [
              for (var index = 0; index < songs.length; index++)
                if (terms.isEmpty || terms.every(searchable[index].contains))
                  index,
            ];
            final positions = {
              for (final (position, index) in visible.indexed)
                keys[index]: position,
            };
            return CustomScrollView(
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
                          ? _playlistSelectionBar([
                              for (final index in visible) keys[index].value
                            ], [
                              for (final (index, song) in songs.indexed)
                                if (selection.contains(keys[index].value)) song,
                            ], playlist.title, isCurrent: selectionIsCurrent)
                          : _playlistSearching
                              ? Row(children: [
                                  Expanded(child: _playlistSearchField()),
                                  if (widget.source == null)
                                    _playlistSelectButton(),
                                  if (widget.source == null)
                                    _playlistSearchButton(),
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
                                        if (songs.isNotEmpty)
                                          _playlistSelectButton(),
                                        _playlistSearchButton(),
                                      ]),
                                ),
                    ),
                  ),
                if (!split && !_playlistSearching)
                  SliverToBoxAdapter(child: details()),
                if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: terms.isEmpty
                        ? _empty()
                        : Center(child: Text(locals.musicNoResults)),
                  )
                else
                  SliverList.builder(
                      itemCount: visible.length,
                      findChildIndexCallback: (key) => positions[key],
                      itemBuilder: (_, position) {
                        final index = visible[position];
                        final song = songs[index];
                        final music = song.musicMetadata!;
                        final id = keys[index].value;
                        final picked = selection.contains(id);
                        return ListTile(
                            key: keys[index],
                            selected: picked,
                            leading: SizedBox.square(
                              dimension: 52,
                              child: Stack(fit: StackFit.expand, children: [
                                CommunityMusicArtwork(
                                    videoId: song.videoId,
                                    music: music,
                                    durationSeconds: song.lengthSeconds,
                                    fallback: _artwork(displaySongThumbnails(
                                        song.videoId,
                                        music.thumbnails,
                                        song.videoThumbnails,
                                        artTrack: music.isArtTrack,
                                        instanceUrl: instanceUrl))),
                                VideoWatchProgress(videoId: song.videoId),
                              ]),
                            ),
                            title: Text(music.title),
                            subtitle: Text(music.artist),
                            trailing: _playlistSelecting
                                ? ExcludeSemantics(
                                    child: Icon(picked
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank))
                                : MusicLibraryActions(
                                    videos: [song],
                                    localPlaylistId: playlist.playlistId,
                                    onPlay: () => playSong(index)),
                            onLongPress: _playlistSelecting
                                ? null
                                : () => _startPlaylistSelection(id),
                            onTap: _playlistSelecting
                                ? () => setState(
                                    () => _playlistSelection.toggle(id))
                                : () => playSong(index));
                      }),
              ],
            );
          },
        );
    return MusicCollectionPanes(
      details: details(showHeading: true),
      buildTracks: tracks,
      detailsKey: PageStorageKey((library.profileId, playlist.playlistId)),
    );
  }

  Widget _sourcePlaylist(PlaylistReference source, {required bool active}) {
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
                ],
              ],
            ),
            body: playlist == null
                ? Center(child: Text(locals.musicSourceUnavailable))
                : _localPlaylist(playlist, library),
          ),
        );
      },
    );
  }

  Widget _catalogLibrary(MusicLibraryService library) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final playlists = service
        .getLocalPlaylists(database: db.forProfile(library.profileId))
        .where(library.isMusicPlaylist)
        .toList();
    final selected = playlists
        .where((playlist) => playlist.playlistId == _playlistId)
        .firstOrNull;
    if (selected != null) return _localPlaylist(selected, library);
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
    final kind = switch (_filter) {
      _LibraryFilter.all => null,
      _LibraryFilter.playlists => MusicLibraryKind.playlist,
      _LibraryFilter.songs => MusicLibraryKind.song,
      _LibraryFilter.channels => MusicLibraryKind.artist,
      _LibraryFilter.downloads => MusicLibraryKind.song,
      _LibraryFilter.podcasts => MusicLibraryKind.song,
      _LibraryFilter.onDevice => null,
    };
    final entries = library.entries
        .where((entry) =>
            entry.kind != MusicLibraryKind.album &&
            (kind == null || entry.kind == kind))
        .toList();
    final hasPlaylists =
        _filter == _LibraryFilter.playlists || _filter == _LibraryFilter.all;
    final items = <_LibraryItem>[
      if (hasPlaylists)
        for (final playlist in playlists) (playlist: playlist, bookmark: null),
      for (final entry in entries) (playlist: null, bookmark: entry),
    ];
    final shortcuts = <_LibraryFilter>[
      if (_filter == _LibraryFilter.all) _LibraryFilter.songs,
      if (_filter == _LibraryFilter.all &&
          context.watch<DownloadManagerCubit?>() != null)
        _LibraryFilter.downloads,
    ];
    _sortLibraryItems(items);
    final selection = _savedSongsSelection;
    selection?.retainAll(entries.map((entry) => entry.id));
    final finding = _savedSongsFinding;
    final searchButton = _libraryFindButton(
        const ValueKey('music-saved-songs-search'),
        _LibraryFilter.songs,
        locals.musicSearchSavedSongs);
    final sortMenu = PopupMenuButton<_LibrarySort>(
      key: const ValueKey('music-library-sort'),
      tooltip: locals.searchSortBy,
      initialValue: _sort,
      onSelected: (value) {
        if (_sort == value) return;
        setState(() => _sort = value);
        if (finding) _jumpToLibraryFindStart();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
            value: _LibrarySort.saved,
            child: Text(locals.musicLibrarySavedOrder)),
        PopupMenuItem(
            value: _LibrarySort.title,
            child: Text(locals.musicLibraryTitleOrder)),
      ],
      icon: finding ? const Icon(Icons.sort) : null,
      child: finding
          ? null
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(
                      _sort == _LibrarySort.saved
                          ? locals.musicLibrarySavedOrder
                          : locals.musicLibraryTitleOrder,
                      style: theme.textTheme.titleSmall),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_downward_rounded, size: 16),
              ]),
            ),
    );
    final selectButton = _librarySelectButton(
        const ValueKey('music-saved-songs-select'), _LibraryFilter.songs);
    final toolbar = Padding(
      padding: EdgeInsetsDirectional.only(start: finding ? 0 : 18, end: 8),
      child: Row(children: [
        Expanded(
          child: finding
              ? _collectionSearchField(
                  key: const ValueKey('music-saved-songs-query'),
                  label: locals.musicSearchSavedSongs,
                  controller: _libraryQuery,
                  focusNode: _libraryQueryFocus,
                  onQueryChanged: _jumpToLibraryFindStart,
                  compact: true)
              : Align(
                  alignment: AlignmentDirectional.centerStart, child: sortMenu),
        ),
        if (finding) sortMenu,
        if (hasPlaylists)
          IconButton(
              tooltip: locals.createNewPlaylist,
              onPressed: () => MusicLibraryActions.createPlaylist(context),
              icon: const Icon(Icons.playlist_add_rounded)),
        if (_filter == _LibraryFilter.songs && !finding) searchButton,
        if (_filter == _LibraryFilter.songs && items.isNotEmpty) selectButton,
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
      ]),
    );
    if (finding) {
      final searchable = [
        for (final item in items)
          normalizeMusicSearchText(
              '${item.bookmark!.title} ${item.bookmark!.subtitle}'),
      ];
      return ValueListenableBuilder(
        valueListenable: _libraryQuery,
        builder: (_, input, __) {
          final terms = musicSearchTerms(input.text);
          final matches = [
            for (final (index, item) in items.indexed)
              if (terms.every(searchable[index].contains)) item,
          ];
          return _collection(matches, const [], library,
              playbackItems: items,
              searchToolbar: selection == null
                  ? toolbar
                  : _savedSongsSelectionBar(matches, items, selection),
              emptyResults: matches.isEmpty
                  ? terms.isEmpty
                      ? _empty()
                      : Center(child: Text(locals.musicNoResults))
                  : null);
        },
      );
    }
    return Column(children: [
      selection == null
          ? toolbar
          : _savedSongsSelectionBar(items, items, selection),
      if (selection == null &&
          _filter == _LibraryFilter.songs &&
          entries.any((entry) => entry.needsSongDetails))
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => showMusicDetailsDialog(context, entries),
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: Text(locals.musicLoadSongDetails),
            ),
          ),
        ),
      Expanded(
        child: items.isEmpty && shortcuts.isEmpty
            ? _empty()
            : _collection(items, shortcuts, library),
      ),
    ]);
  }

  ValueKey<String> _itemKey(_LibraryItem item) => item.playlist != null
      ? ValueKey('music-local-${item.playlist!.playlistId}')
      : ValueKey(
          'music-saved-${item.bookmark!.kind.name}-${item.bookmark!.id}');

  String _itemTitle(_LibraryItem item) =>
      item.playlist?.playlistId == localWatchLaterId
          ? AppLocalizations.of(context)!.watchLater
          : item.playlist?.title ?? item.bookmark!.title;

  void _sortLibraryItems(List<_LibraryItem> items) {
    if (_sort != _LibrarySort.title) return;
    items.sort((first, second) {
      final title = _itemTitle(first)
          .toLowerCase()
          .compareTo(_itemTitle(second).toLowerCase());
      return title != 0
          ? title
          : _itemKey(first).value.compareTo(_itemKey(second).value);
    });
  }

  Future<void> _openItem(_LibraryItem item, List<_LibraryItem> items) async {
    if (_savedSongsSelection != null &&
        item.bookmark?.kind == MusicLibraryKind.song) {
      _toggleLibrarySelection(item.bookmark!.id);
      return;
    }
    if (item.playlist case final playlist?) {
      setState(() {
        _resetPlaylistSearch();
        _playlistId = playlist.playlistId;
      });
    } else {
      await _openBookmark(item.bookmark!, items);
    }
  }

  String _shortcutTitle(_LibraryFilter shortcut, AppLocalizations locals) =>
      shortcut == _LibraryFilter.songs
          ? locals.musicSavedSongs
          : locals.downloads;

  IconData _shortcutIcon(_LibraryFilter shortcut) =>
      shortcut == _LibraryFilter.songs
          ? Icons.favorite_rounded
          : Icons.cloud_download_rounded;

  ValueKey<String> _shortcutKey(_LibraryFilter shortcut) =>
      ValueKey('music-library-shortcut-${shortcut.name}');

  void _selectFilter(_LibraryFilter filter) => setState(() {
        _filter = filter;
        _playlistId = null;
        _resetPlaylistSearch();
        _resetLibraryFind();
      });

  Widget _collection(List<_LibraryItem> items, List<_LibraryFilter> shortcuts,
      MusicLibraryService library,
      {List<_LibraryItem>? playbackItems,
      Widget? searchToolbar,
      Widget? emptyResults}) {
    // Both lazy layouts retain an item's element when sorting or removing an
    // earlier row. This also keeps keyboard/TV focus on the surviving item.
    final indices = <Key, int>{
      for (var index = 0; index < shortcuts.length; index++)
        _shortcutKey(shortcuts[index]): index,
      for (var index = 0; index < items.length; index++)
        _itemKey(items[index]): index + shortcuts.length,
    };
    final count = items.length + shortcuts.length;
    final locals = AppLocalizations.of(context)!;
    final allItems = playbackItems ?? items;
    final layout = _grid ? 'grid' : 'list';
    final collectionKey = PageStorageKey(_filter == _LibraryFilter.songs
        ? 'music-library-$layout-songs-${library.profileId}'
        : 'music-library-$layout-${_filter.name}');
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
      final rows = SliverChildBuilderDelegate((_, index) {
        if (index < shortcuts.length) {
          final shortcut = shortcuts[index];
          return ListTile(
              key: _shortcutKey(shortcut),
              leading: Icon(_shortcutIcon(shortcut)),
              title: Text(_shortcutTitle(shortcut, locals)),
              onTap: () => _selectFilter(shortcut));
        }
        final item = items[index - shortcuts.length];
        if (item.bookmark case final bookmark?) {
          return _bookmark(bookmark, () => _openItem(item, allItems));
        }
        return ListTile(
            key: _itemKey(item),
            leading: const Icon(Icons.queue_music),
            title: Text(_itemTitle(item)),
            subtitle: Text(AppLocalizations.of(context)!.onDevice),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openItem(item, allItems));
      }, childCount: count, findChildIndexCallback: (key) => indices[key]);
      return searchToolbar == null
          ? ListView.custom(
              key: collectionKey,
              childrenDelegate: rows,
              semanticChildCount: count)
          : searchResults(searchToolbar, SliverList(delegate: rows));
    }
    final savedCovers = library.coversBySongId;
    return LayoutBuilder(builder: (context, constraints) {
      final theme = Theme.of(context).textTheme;
      final scaler = MediaQuery.textScalerOf(context);
      const padding = 12.0;
      const spacing = 18.0;
      final minimumWidth = math.max(140.0, scaler.scale(112));
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
      final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 14,
          mainAxisExtent: width + titleHeight * 2 + subtitleHeight + 10);
      final cards = SliverChildBuilderDelegate(
          (_, index) => index < shortcuts.length
              ? _gridShortcut(shortcuts[index], locals)
              : _gridItem(items[index - shortcuts.length], savedCovers,
                  () => _openItem(items[index - shortcuts.length], allItems)),
          childCount: count,
          findChildIndexCallback: (key) => indices[key]);
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
      onOpen: () => _selectFilter(shortcut),
    );
  }

  Widget _gridItem(
      _LibraryItem item,
      Map<String, List<ImageObject>> savedCovers,
      Future<void> Function() onOpen) {
    final entry = item.bookmark;
    final song = item.playlist?.videos.firstOrNull;
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
    final playlist =
        item.playlist != null || entry?.kind == MusicLibraryKind.playlist;
    final plays = entry?.kind == MusicLibraryKind.song;
    final selected =
        entry == null ? null : _savedSongsSelection?.contains(entry.id);
    final colors = Theme.of(context).colorScheme;
    return _gridCard(
      key: _itemKey(item),
      title: _itemTitle(item),
      subtitle: entry?.subtitle ?? AppLocalizations.of(context)!.onDevice,
      artworkRadius: artist ? 300 : 7,
      artwork: _bookmarkArtwork(
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
                  decoration: const BoxDecoration())),
      action: entry == null || selected != null
          ? null
          : _bookmarkActions(entry, onOpen),
      plays: plays,
      selected: selected,
      onOpen: onOpen,
      onLongPress: _bookmarkLongPress(entry, onOpen),
    );
  }

  Widget _gridCard({
    required Key key,
    required String title,
    required Widget artwork,
    required double artworkRadius,
    required VoidCallback onOpen,
    VoidCallback? onLongPress,
    String subtitle = '',
    Widget? action,
    bool plays = false,
    bool? selected,
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
                      if (action != null)
                        PositionedDirectional(
                            end: 4,
                            top: 4,
                            child: Material(
                                shape: const CircleBorder(),
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
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
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

  Future<void> _playMusicDownload(DownloadedVideo selected) =>
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
        await context
            .read<PlayerCubit>()
            .playOfflineVideos(completed, fromMusic: true, startIndex: index);
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
      final approval = manager.captureMusicDeletion(selected);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title:
              Text(locals.musicRemoveSelectedDownloadsConfirm(selected.length)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(locals.cancel)),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(locals.musicRemoveSelectedDownloads)),
          ],
        ),
      );
      if (confirmed != true || !isCurrent()) return;
      final removed =
          await manager.deleteMusicSelection(approval, isCurrent: ownerCurrent);
      if (!mounted || !ownerCurrent()) return;
      if (liveSelection().isEmpty) {
        _exitLibrarySelection();
      } else if (removed < selected.length) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(locals.musicLibraryActionError)));
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

  SliverChildBuilderDelegate _downloadRows(
      DownloadManagerState state, List<DownloadedVideo> videos) {
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
          ? video.musicMetadata!.artist
          : video.authenticationRequired
              ? locals.downloadSignInRequired
              : video.storageFailed
                  ? locals.downloadFolderError
                  : video.downloadFailed
                      ? locals.videoFailedDownloadRetry
                      : paused
                          ? locals.downloadPaused
                          : state.waitingForWifi
                              ? locals.downloadsWaitingForWifi
                              : locals.downloadQueued;
      return Column(key: rowKey(video), children: [
        ListTile(
            key: ValueKey('music-download-${video.videoId}'),
            selected: selected ?? false,
            leading: Icon(ready ? Icons.offline_pin : Icons.downloading),
            title: Text(video.musicMetadata!.title),
            subtitle: Text(status),
            onLongPress: selected == null
                ? () => _startLibrarySelection(
                    _LibraryFilter.downloads, video.videoId)
                : null,
            onTap: selected != null
                ? () => _toggleLibrarySelection(video.videoId)
                : ready
                    ? () => _playMusicDownload(video)
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
                          key: ValueKey(
                              'music-download-actions-${video.videoId}'),
                          tooltip: locals.musicLibraryActions,
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => MusicLibraryActions.showSongMenu(
                              context, _downloadSong(video),
                              downloads: [video],
                              resolveDownload: () =>
                                  _currentMusicDownload(video),
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
                                    : manager.pauseDownload(video)))),
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
                    : ListView.custom(
                        key: PageStorageKey(('music-downloads', profileId)),
                        childrenDelegate: _downloadRows(state, videos),
                        semanticChildCount: videos.length,
                      ),
              ),
            ]);
          }

          final toolbar = Padding(
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
                          normalizeMusicSearchText(
                              '${music.title} ${music.artist}');
                      return terms.every(text.contains);
                    }).toList();
              return _libraryFindView(
                key: const ValueKey('music-downloads-results'),
                toolbar: selection == null
                    ? toolbar
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
                    : SliverList(delegate: _downloadRows(state, matches)),
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
  Widget build(BuildContext context) => BlocConsumer<AppCubit, AppState>(
        listenWhen: (before, after) =>
            before.profileId != after.profileId ||
            before.sessionRevision != after.sessionRevision ||
            before.server != after.server ||
            before.sessionRecoveryRequired != after.sessionRecoveryRequired ||
            before.globalLoading != after.globalLoading,
        listener: (context, state) => setState(() {
          _playlistId = null;
          _resetPlaylistSearch();
          _resetLibraryFind();
        }),
        builder: (context, state) {
          // Retained home pages rebuild when visible again, including changes
          // made through the application's existing local playlist screens.
          final active = TickerMode.of(context);
          if (widget.source case final source?) {
            return _sourcePlaylist(source, active: active);
          }
          final locals = AppLocalizations.of(context)!;
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final library = MusicLibraryService.forProfile(db, db.profileId);
          final showLibraryChrome = !_playlistSearching &&
              !_playlistSelecting &&
              _findFilter == null &&
              _librarySelection == null;
          return PopScope(
            canPop: (_playlistId == null &&
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
              }
            },
            child: ListenableBuilder(
                listenable: library.changes,
                builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showLibraryChrome)
                          Padding(
                              padding: const EdgeInsetsDirectional.only(
                                  start: 16, end: 6),
                              child: Row(children: [
                                Expanded(
                                    child: Semantics(
                                        header: true,
                                        child: Text(locals.musicLibrary,
                                            style:
                                                theme.textTheme.titleLarge))),
                                IconButton(
                                  key: const ValueKey('music-library-history'),
                                  tooltip: locals.musicPlaybackHistory,
                                  icon: const Icon(Icons.history),
                                  onPressed: state.globalLoading ||
                                          state.sessionRecoveryRequired
                                      ? null
                                      : () => Navigator.of(context).push<void>(
                                          MaterialPageRoute(
                                              builder: (context) => isTv
                                                  ? const TvHistoryScreen(
                                                      music: true)
                                                  : Scaffold(
                                                      appBar: AppBar(
                                                          title: Text(locals
                                                              .musicPlaybackHistory)),
                                                      body: const HistoryView(
                                                          music: true),
                                                    ))),
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
                                            if (mounted && imported == true) {
                                              setState(() {
                                                _filter = _LibraryFilter.songs;
                                                _playlistId = null;
                                                _resetPlaylistSearch();
                                                _resetLibraryFind();
                                              });
                                            }
                                          }),
                              ])),
                        if (showLibraryChrome)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(children: [
                              for (final filter in _LibraryFilter.values)
                                if (filter != _LibraryFilter.all &&
                                    (filter != _LibraryFilter.onDevice ||
                                        supportsLocalMusicFolders) &&
                                    (!isTv ||
                                        filter != _LibraryFilter.downloads))
                                  Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: ChoiceChip(
                                          key: ValueKey(
                                              'music-library-tab-${filter.name}'),
                                          label: Text(_label(filter, locals)),
                                          labelStyle: theme.textTheme.labelLarge
                                              ?.copyWith(
                                                  color: _filter == filter
                                                      ? colors.onInverseSurface
                                                      : colors
                                                          .onSurfaceVariant),
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
                                          onSelected: (selected) =>
                                              _selectFilter(selected || isTv
                                                  ? filter
                                                  : _LibraryFilter.all))),
                            ]),
                          ),
                        Expanded(
                            child: _filter == _LibraryFilter.onDevice
                                ? const LocalMusicFolder.library()
                                : state.globalLoading ||
                                        state.sessionRecoveryRequired
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : _filter == _LibraryFilter.podcasts
                                        ? PodcastLibraryPage(
                                            key: ValueKey(
                                                'podcasts-${db.profileId}-${state.sessionRevision}'))
                                        : _filter == _LibraryFilter.downloads &&
                                                !isTv
                                            ? _downloads()
                                            : _catalogLibrary(library)),
                      ],
                    )),
          );
        },
      );
}
