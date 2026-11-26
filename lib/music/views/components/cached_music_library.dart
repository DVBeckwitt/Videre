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
import '../../services/cached_music.dart';

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
  List<CachedMusicSong>? _songs;
  int _request = 0;
  bool _checking = false;
  bool _keeping = false;
  bool _failed = false;
  bool _songEvicted = false;
  bool _currentRoute = false;
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
    _currentRoute = ModalRoute.isCurrentOf(context) ?? true;
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
    final visible = widget.active && _currentRoute && _foreground;
    if (!ownerChanged && visible == _visible) return;
    _visible = visible;
    final request = ++_request;
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

  Future<void> _refresh({
    CachedMusicSong? selected,
    CachedMusicSong? remove,
  }) async {
    final server = widget.server;
    if (!_visible || server == null) return;
    final onPlay = widget.onPlay;
    final player = remove != null || (selected != null && onPlay == null)
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
    if (remove != null) {
      final playing = player?.state.currentlyPlaying;
      final cached = CachedMusicPlayback.of(playing);
      String message;
      try {
        final result = cached != null &&
                playing?.videoId == remove.videoId &&
                cached.rendition == remove.rendition &&
                cached.owner == cachedMusicOwner(server)
            ? CachedMusicRemoval.inUse
            : await removeCachedMusicSong(server, remove);
        message = switch (result) {
          CachedMusicRemoval.removed => locals.musicCachedSongRemoved,
          CachedMusicRemoval.missing => locals.musicCachedSongEvicted,
          CachedMusicRemoval.inUse => locals.musicCachedSongInUse,
        };
      } catch (_) {
        message = locals.musicRemoveCachedSongError;
      }
      if (!current()) return;
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
          _checking = false;
          _failed = true;
        });
      }
      return;
    }
    if (!current()) return;
    final index = selected == null
        ? -1
        : songs.indexWhere((song) =>
            song.videoId == selected.videoId &&
            song.rendition == selected.rendition);
    setState(() {
      _songs = songs;
      _checking = index >= 0;
      _songEvicted = selected != null && index < 0;
    });
    if (index < 0) return;
    try {
      if (onPlay != null) {
        await onPlay(
          songs,
          startIndex: index,
          server: server,
          queueTitle: locals.musicCachedSongs,
        );
      } else {
        await player!.playCachedMusicSongs(
          songs,
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
          onPressed: busy ? null : () => unawaited(_refresh(remove: song)),
          leadingIcon: const Icon(Icons.delete_outline),
          child: Text(locals.musicRemoveCachedSong),
        ),
      ],
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
    return Column(
      children: [
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
                  return ListTile(
                    key: ValueKey((song.videoId, song.rendition)),
                    leading: const Icon(Icons.music_note),
                    title: Text(song.title),
                    subtitle: song.artist.isEmpty ? null : Text(song.artist),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (song.lengthSeconds > 0)
                          Text(prettyDurationCustom(
                              Duration(seconds: song.lengthSeconds))),
                        _songActions(
                            song, locals, server, manager, viewIsCurrent),
                      ],
                    ),
                    onTap: () {
                      if (!_checking) unawaited(_refresh(selected: song));
                    },
                  );
                },
              ),
          },
        ),
      ],
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
