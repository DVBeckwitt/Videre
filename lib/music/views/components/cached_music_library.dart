import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
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
  });

  final bool active;
  final Server? server;

  @override
  State<CachedMusicLibrary> createState() => _CachedMusicLibraryState();
}

class _CachedMusicLibraryState extends State<CachedMusicLibrary>
    with WidgetsBindingObserver {
  List<CachedMusicSong>? _songs;
  int _request = 0;
  bool _checking = false;
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

  Future<void> _refresh({CachedMusicSong? selected}) async {
    final server = widget.server;
    if (!_visible || server == null) return;
    final app = context.read<AppCubit>();
    final player = selected == null ? null : context.read<PlayerCubit>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final locals = AppLocalizations.of(context)!;
    final session = app.state;
    final database = db;
    final request = ++_request;
    bool current() {
      if (!mounted ||
          !_visible ||
          request != _request ||
          !identical(db, database)) {
        return false;
      }
      final state = app.state;
      return !state.globalLoading &&
          !state.sessionRecoveryRequired &&
          state.profileId == database.profileId &&
          state.profileId == server.profileId &&
          state.sessionRevision == session.sessionRevision &&
          state.server == server;
    }

    if (!current()) return;
    setState(() {
      _checking = true;
      _failed = false;
      _songEvicted = false;
    });
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
      await player!.playCachedMusicSongs(
        songs,
        startIndex: index,
        server: server,
        queueTitle: locals.musicCachedSongs,
        isCurrent: current,
      );
    } catch (_) {
      if (current() && messenger?.mounted == true) {
        messenger!.showSnackBar(
          SnackBar(content: Text(locals.musicPlaybackError)),
        );
      }
    }
    if (current()) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    if (widget.server?.profileId != db.profileId) {
      return Center(child: Text(locals.playbackCacheUnavailable));
    }
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
                    (song) => ValueKey(song.videoId) == key,
                  );
                  return index < 0 ? null : index;
                },
                itemBuilder: (context, index) {
                  final song = songs[index];
                  return ListTile(
                    key: ValueKey(song.videoId),
                    leading: const Icon(Icons.music_note),
                    title: Text(song.title),
                    subtitle: song.artist.isEmpty ? null : Text(song.artist),
                    trailing: song.lengthSeconds > 0
                        ? Text(prettyDurationCustom(
                            Duration(seconds: song.lengthSeconds)))
                        : null,
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
