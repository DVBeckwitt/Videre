import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:videre_proxy/videre_proxy.dart';

import '../../../app/states/app.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../../settings/models/db/server.dart';
import '../../../utils.dart' show prettyDurationCustom;
import '../../../utils/motion.dart';
import '../../models/music_song_selection.dart';
import '../../services/cached_music.dart';
import 'music_song_selection_bar.dart';

class CachedMusicLibrary extends StatefulWidget {
  const CachedMusicLibrary({
    super.key,
    required this.active,
    required this.server,
    this.onPlay,
  });

  final bool active;
  final Server? server;
  final Future<void> Function(
    List<CachedMusicSong> songs, {
    required int startIndex,
    required Server server,
    required String queueTitle,
  })? onPlay;

  @override
  State<CachedMusicLibrary> createState() => _CachedMusicLibraryState();
}

class _CachedMusicLibraryState extends State<CachedMusicLibrary>
    with WidgetsBindingObserver {
  final _selection = MusicSongSelection<(String, String)>();
  List<CachedMusicSong>? _songs;
  int _request = 0;
  bool _checking = false;
  bool _keeping = false;
  bool _failed = false;
  bool _songEvicted = false;
  bool _visible = false;
  late bool _foreground;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateVisibility();
  }

  @override
  void didUpdateWidget(CachedMusicLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateVisibility(ownerChanged: oldWidget.server != widget.server);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _updateVisibility({bool ownerChanged = false}) {
    final visible = widget.active && _foreground;
    if (!ownerChanged && visible == _visible) return;
    _visible = visible;
    final request = ++_request;
    _selection.clear();
    _songs = null;
    _checking = false;
    _failed = false;
    _songEvicted = false;
    if (!visible) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _visible && request == _request) {
        unawaited(_refresh());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool Function() _captureCurrentView(Server server) {
    final app = context.read<AppCubit>();
    final session = app.state;
    final database = db;
    return () {
      if (!mounted || !_visible || app.isClosed || !identical(db, database)) {
        return false;
      }
      final state = app.state;
      return !state.globalLoading &&
          !state.sessionRecoveryRequired &&
          state.profileId == database.profileId &&
          state.profileId == server.profileId &&
          state.sessionRevision == session.sessionRevision &&
          state.server == server;
    };
  }

  Future<void> _keepSong(CachedMusicSong song, Server server,
      DownloadManagerCubit manager, bool Function() viewIsCurrent) async {
    bool current() =>
        viewIsCurrent() &&
        !manager.isClosed &&
        identical(context.read<DownloadManagerCubit?>(), manager);

    if (_checking || _keeping || !current()) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final locals = AppLocalizations.of(context)!;
    setState(() => _keeping = true);
    KeepCachedMusicResult result;
    try {
      result = await manager.keepCachedMusicSong(server, song);
    } catch (_) {
      result = KeepCachedMusicResult.failed;
    } finally {
      if (mounted) setState(() => _keeping = false);
    }
    if (!current()) return;
    if (messenger?.mounted == true) {
      final message = switch (result) {
        KeepCachedMusicResult.saved => locals.musicCachedSongKept,
        KeepCachedMusicResult.alreadySaved => locals.musicCachedSongAlreadyKept,
        KeepCachedMusicResult.unavailable => locals.musicCachedSongEvicted,
        KeepCachedMusicResult.conflictingDownload =>
          locals.musicCachedSongDownloadConflict,
        KeepCachedMusicResult.failed => locals.musicCachedSongKeepFailed,
      };
      messenger!.showSnackBar(SnackBar(content: Text(message)));
    }
    if (result == KeepCachedMusicResult.unavailable && !_checking) {
      await _refresh();
    }
  }

  (String, String) _songId(CachedMusicSong song) =>
      (song.videoId, song.rendition);

  Future<void> _refresh({
    CachedMusicSong? selected,
    List<CachedMusicSong>? playInOrder,
    List<CachedMusicSong> remove = const [],
  }) async {
    final server = widget.server;
    if (!_visible || server == null) return;
    final onPlay = widget.onPlay;
    final player = remove.isNotEmpty || (selected != null && onPlay == null)
        ? context.read<PlayerCubit?>()
        : null;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final locals = AppLocalizations.of(context)!;
    final viewIsCurrent = _captureCurrentView(server);
    final request = ++_request;
    bool current() => request == _request && viewIsCurrent();

    if (!current()) return;
    setState(() {
      _checking = true;
      _failed = false;
      _songEvicted = false;
    });
    final messages = <String>{};
    for (final song in remove) {
      if (!current()) return;
      final playing = player?.state.currentlyPlaying;
      final cached = CachedMusicPlayback.of(playing);
      String message;
      try {
        final result = cached != null &&
                playing?.videoId == song.videoId &&
                cached.rendition == song.rendition &&
                cached.owner == cachedMusicOwner(server)
            ? CachedMusicRemoval.inUse
            : await removeCachedMusicSong(server, song);
        message = switch (result) {
          CachedMusicRemoval.removed => locals.musicCachedSongRemoved,
          CachedMusicRemoval.missing => locals.musicCachedSongEvicted,
          CachedMusicRemoval.inUse => locals.musicCachedSongInUse,
        };
      } catch (_) {
        message = locals.musicRemoveCachedSongError;
      }
      messages.add(message);
    }
    if (!current()) return;
    for (final message in messages) {
      if (messenger?.mounted == true) {
        messenger!.showSnackBar(SnackBar(content: Text(message)));
      }
    }

    final List<CachedMusicSong> songs;
    try {
      songs = await listCachedMusicSongs(server);
    } catch (_) {
      if (current()) {
        setState(() {
          _songs = null;
          _selection.clear();
          _checking = false;
          _failed = true;
        });
      }
      return;
    }
    if (!current()) return;
    final byId = {for (final song in songs) _songId(song): song};
    final queue = playInOrder == null
        ? songs
        : [
            for (final song in playInOrder)
              if (byId[_songId(song)] case final current?) current,
          ];
    final index = selected == null ||
            (playInOrder != null && queue.length != playInOrder.length)
        ? -1
        : queue.indexWhere((song) => _songId(song) == _songId(selected));
    setState(() {
      _songs = songs;
      _selection.retain(byId.keys);
      if (remove.isNotEmpty && !byId.keys.any(_selection.contains)) {
        _selection.clear();
      }
      _checking = index >= 0;
      _songEvicted = selected != null && index < 0;
    });
    if (index < 0) return;
    try {
      if (onPlay != null) {
        await onPlay(
          queue,
          startIndex: index,
          server: server,
          queueTitle: locals.musicCachedSongs,
        );
      } else {
        await player!.playCachedMusicSongs(
          queue,
          startIndex: index,
          server: server,
          queueTitle: locals.musicCachedSongs,
          isCurrent: current,
        );
      }
    } catch (_) {
      if (current() && messenger?.mounted == true) {
        messenger!.showSnackBar(
          SnackBar(content: Text(locals.musicPlaybackError)),
        );
      }
    }
    if (current()) await _refresh();
  }

  Widget _songActions(
    CachedMusicSong song,
    AppLocalizations locals,
    Server server,
    DownloadManagerCubit? manager,
    bool Function() viewIsCurrent,
  ) {
    final busy = _checking || _keeping;
    return _CachedMusicSongMenu(
      enabled: !_checking,
      items: [
        MenuItemButton(
          onPressed: busy ? null : () => _startSelection(song),
          leadingIcon: const Icon(Icons.check_box_outline_blank),
          child: Text(locals.musicSelectSong),
        ),
        if (manager != null)
          MenuItemButton(
            onPressed: busy
                ? null
                : () =>
                    unawaited(_keepSong(song, server, manager, viewIsCurrent)),
            leadingIcon: const Icon(Icons.download),
            child: Text(locals.musicCachedSongKeep),
          ),
        MenuItemButton(
          onPressed: busy ? null : () => unawaited(_refresh(remove: [song])),
          leadingIcon: const Icon(Icons.delete_outline),
          child: Text(locals.musicRemoveCachedSong),
        ),
      ],
    );
  }

  void _startSelection(CachedMusicSong song) =>
      setState(() => _selection.start(_songId(song)));

  Future<void> _confirmCacheRemoval(
    List<CachedMusicSong> songs,
    bool Function() isCurrent,
    AppLocalizations locals,
  ) async {
    if (_checking || _keeping || !isCurrent()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: Text(locals.musicRemoveCachedSong),
        content: Text(locals.musicRemoveCachedSongsConfirm(songs.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.musicRemoveCachedSong)),
        ],
      ),
    );
    if (confirmed == true && isCurrent()) await _refresh(remove: songs);
  }

  Widget _selectionBar(List<CachedMusicSong> songs, Server server,
      AppLocalizations locals, bool Function() viewIsCurrent) {
    final owner = cachedMusicOwner(server)!;
    final selected = _selection.selectedRows(songs, _songId);
    final ids = songs.map(_songId);
    final byId = {for (final song in selected) _songId(song): song};
    bool current() =>
        viewIsCurrent() &&
        _selection.active &&
        selected.every((song) => _selection.contains(_songId(song)));

    return MusicSongSelectionBar(
      selected: [for (final song in selected) song.playbackEntry(owner)],
      allSelected: _selection.allSelected(ids),
      onToggleAll: _checking || songs.isEmpty
          ? null
          : () => setState(() => _selection.toggleAll(ids)),
      onClose: () => setState(_selection.clear),
      isCurrent: current,
      onPlay: (tracks) async {
        if (_checking || _keeping) return;
        final queue = [
          for (final track in tracks)
            byId[(track.videoId, CachedMusicPlayback.of(track)!.rendition)]!,
        ];
        await _refresh(selected: queue.first, playInOrder: queue);
      },
      removal: selected.isEmpty || _checking || _keeping
          ? null
          : (
              label: locals.musicRemoveCachedSong,
              run: () => _confirmCacheRemoval(selected, current, locals),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final server = widget.server;
    if (server == null || server.profileId != db.profileId) {
      return Center(child: Text(locals.playbackCacheUnavailable));
    }
    final manager = context.read<DownloadManagerCubit?>();
    final viewIsCurrent = _captureCurrentView(server);
    final songs = _songs;
    final selecting = _selection.active;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) setState(_selection.clear);
      },
      child: Column(
        children: [
          if (selecting)
            _selectionBar(songs ?? const [], server, locals, viewIsCurrent)
          else
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, end: 6),
              child: Row(
                children: [
                  Expanded(child: Text(locals.musicCachedSongsHint)),
                  IconButton(
                    key: const ValueKey('music-cached-songs-refresh'),
                    tooltip: locals.refresh,
                    onPressed: _checking ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
          if (_songEvicted)
            Semantics(
              liveRegion: true,
              child: Text(locals.musicCachedSongEvicted),
            ),
          Expanded(
            child: switch (songs) {
              null when _failed =>
                Center(child: Text(locals.musicCachedSongsError)),
              null => const Center(child: CircularProgressIndicator()),
              [] => Center(child: Text(locals.musicCachedSongsEmpty)),
              _ => ListView.builder(
                  itemCount: songs.length,
                  findChildIndexCallback: (key) {
                    final index = songs.indexWhere(
                      (song) => ValueKey((song.videoId, song.rendition)) == key,
                    );
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    final id = _songId(song);
                    final selected = _selection.contains(id);
                    void toggle() => setState(() => _selection.toggle(id));
                    return ListTile(
                      key: ValueKey(id),
                      selected: selected,
                      leading: selecting
                          ? MusicSongSelectButton(
                              selected: selected, onPressed: toggle)
                          : const Icon(Icons.music_note),
                      title: Text(song.title),
                      subtitle: song.artist.isEmpty ? null : Text(song.artist),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (song.lengthSeconds > 0)
                            Text(prettyDurationCustom(
                                Duration(seconds: song.lengthSeconds))),
                          if (!selecting)
                            _songActions(
                                song, locals, server, manager, viewIsCurrent),
                        ],
                      ),
                      onTap: _checking
                          ? null
                          : selecting
                              ? toggle
                              : () => unawaited(_refresh(selected: song)),
                      onLongPress: selecting || _checking || _keeping
                          ? null
                          : () => _startSelection(song),
                    );
                  },
                ),
            },
          ),
        ],
      ),
    );
  }
}

class _CachedMusicSongMenu extends StatefulWidget {
  const _CachedMusicSongMenu({required this.enabled, required this.items});

  final bool enabled;
  final List<Widget> items;

  @override
  State<_CachedMusicSongMenu> createState() => _CachedMusicSongMenuState();
}

class _CachedMusicSongMenuState extends State<_CachedMusicSongMenu> {
  final _focus = FocusNode(debugLabel: 'Cached song actions');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
        childFocusNode: _focus,
        consumeOutsideTap: true,
        crossAxisUnconstrained: false,
        menuChildren: widget.items,
        builder: (context, controller, _) => IconButton(
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          focusNode: _focus,
          onPressed: widget.enabled
              ? (controller.isOpen ? controller.close : controller.open)
              : null,
          icon: const Icon(Icons.more_vert),
        ),
      );
}
