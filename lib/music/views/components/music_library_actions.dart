import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// A dialog or collection operation may outlive its original profile.
class MusicLibrarySession {
  final AppCubit app;
  final AppState _initial;
  final String _profileId;
  final Service _service;
  final MusicLibraryService library;

  MusicLibrarySession(this.app)
      : _initial = app.state,
        _profileId = db.profileId,
        _service = service,
        library = MusicLibraryService.forProfile(db, db.profileId);

  bool get isCurrent =>
      !app.isClosed &&
      !app.state.globalLoading &&
      !app.state.sessionRecoveryRequired &&
      db.profileId == _profileId &&
      app.state.profileId == _initial.profileId &&
      app.state.sessionRevision == _initial.sessionRevision &&
      app.state.server == _initial.server;

  void _requireCurrent() {
    if (!isCurrent) throw StateError('The active profile changed.');
  }

  List<Playlist> get playlists {
    _requireCurrent();
    return _service.getLocalPlaylists();
  }

  Future<void> saveToPlaylist(String playlistId, List<Video> videos) async {
    _requireCurrent();
    if (!playlistId.startsWith('local:')) {
      throw ArgumentError('Choose a local playlist');
    }
    for (final video in _unique(videos)) {
      _requireCurrent();
      // Each existing service mutation captures its owner before yielding.
      await _service.addVideoToPlaylist(playlistId, video.videoId,
          video: video);
    }
    _requireCurrent();
    library.notifyChanged();
  }

  Future<void> createPlaylist(String name, List<Video> videos) async {
    _requireCurrent();
    final id = await _service.createPlayList(name, 'local');
    _requireCurrent();
    if (id == null) throw StateError('Could not create playlist');
    await library.markLocalPlaylist(id);
    _requireCurrent();
    await saveToPlaylist(id, videos);
  }

  Future<void> setBookmark(MusicLibraryEntry entry,
      {required bool saved}) async {
    _requireCurrent();
    if (saved) {
      await library.save(entry);
    } else {
      await library.remove(entry.kind, entry.id);
    }
    _requireCurrent();
  }

  Future<int> download(DownloadManagerCubit manager, List<Video> videos) async {
    _requireCurrent();
    if (isTv) return 0;
    var added = 0;
    for (final video in _unique(videos)) {
      _requireCurrent();
      if (await manager.addDownload(video.videoId,
          audioOnly: true, video: video)) {
        added++;
      }
    }
    _requireCurrent();
    return added;
  }

  static List<Video> _unique(List<Video> videos) {
    final byId = <String, Video>{};
    for (final video in videos) {
      byId.putIfAbsent(video.videoId, () => video);
    }
    return byId.values.toList();
  }
}

enum _LibraryAction { saveBookmark, removeBookmark, save, download }

class MusicLibraryActions extends StatefulWidget {
  final List<Video> videos;
  final bool compact;

  const MusicLibraryActions(
      {super.key, required this.videos, this.compact = true});

  static Future<void> save(BuildContext context, List<Video> videos) async {
    if (videos.isEmpty) return;
    await _showSave(context, videos);
  }

  static Future<void> createPlaylist(BuildContext context) =>
      _showSave(context, const [], creating: true);

  static Future<void> _showSave(BuildContext context, List<Video> videos,
      {bool creating = false}) async {
    final app = context.read<AppCubit>();
    final session = MusicLibrarySession(app);
    if (!session.isCurrent) return;
    final locals = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: false);
    final route = DialogRoute<bool>(
        context: context,
        builder: (_) => _SaveMusicDialog(
            session: session, videos: videos, creating: creating));
    final changes = app.stream.listen((_) {
      if (!session.isCurrent && route.isActive && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
    try {
      final saved = await navigator.push(route);
      if (saved == true && !creating && context.mounted && session.isCurrent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.musicSavedToPlaylist)));
      }
    } finally {
      await changes.cancel();
    }
  }

  static Future<int> download(BuildContext context, List<Video> videos) async {
    if (isTv || videos.isEmpty) return 0;
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return 0;
    final locals = AppLocalizations.of(context)!;
    try {
      final count =
          await session.download(context.read<DownloadManagerCubit>(), videos);
      if (context.mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('${locals.downloadQueued}: ${locals.nVideos(count)}')));
      }
      return count;
    } catch (_) {
      if (context.mounted && session.isCurrent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.musicDownloadError)));
      }
      return 0;
    }
  }

  @override
  State<MusicLibraryActions> createState() => _MusicLibraryActionsState();
}

class _MusicLibraryActionsState extends State<MusicLibraryActions> {
  bool _busy = false;
  MusicLibrarySession? _menuSession;
  List<Video>? _menuVideos;
  ModalRoute<dynamic>? _menuRoute;
  StreamSubscription<AppState>? _sessionChanges;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sessionChanges?.cancel();
    _sessionChanges = context.read<AppCubit>().stream.listen((_) {
      if (!mounted) return;
      if (_menuSession?.isCurrent == false) {
        final route = _menuRoute;
        _menuSession = null;
        _menuVideos = null;
        _menuRoute = null;
        if (route != null && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _sessionChanges?.cancel();
    super.dispose();
  }

  MusicLibraryEntry? _song(List<Video> videos) =>
      videos.length == 1 && videos.single.musicMetadata != null
          ? MusicLibraryEntry.song(videos.single)
          : null;

  Future<void> _act(_LibraryAction action) async {
    final menuSession = _menuSession;
    final videos = _menuVideos ?? List<Video>.unmodifiable(widget.videos);
    _menuSession = null;
    _menuVideos = null;
    _menuRoute = null;
    final session =
        menuSession ?? MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (action == _LibraryAction.saveBookmark ||
          action == _LibraryAction.removeBookmark) {
        final song = _song(videos);
        if (song != null) {
          await session.setBookmark(song,
              saved: action == _LibraryAction.saveBookmark);
        }
      } else if (action == _LibraryAction.save) {
        await MusicLibraryActions.save(context, videos);
      } else {
        await MusicLibraryActions.download(context, videos);
      }
    } catch (_) {
      if (mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.musicLibraryActionError)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = MusicLibraryService.forProfile(db, db.profileId);
    return ListenableBuilder(
      listenable: library.changes,
      builder: (context, _) => _buildActions(context, library),
    );
  }

  Widget _buildActions(BuildContext context, MusicLibraryService library) {
    final locals = AppLocalizations.of(context)!;
    final enabled = !_busy && widget.videos.isNotEmpty;
    final song = _song(widget.videos);
    final saved = song != null && library.contains(song.kind, song.id);
    final bookmarkLabel = saved ? locals.musicRemoveSong : locals.musicSaveSong;
    final bookmarkAction =
        saved ? _LibraryAction.removeBookmark : _LibraryAction.saveBookmark;
    if (widget.compact) {
      return PopupMenuButton<_LibraryAction>(
        tooltip: locals.musicLibraryActions,
        enabled: enabled,
        onOpened: () {
          _menuSession = MusicLibrarySession(context.read<AppCubit>());
          _menuVideos = List<Video>.unmodifiable(widget.videos);
        },
        onCanceled: () {
          _menuSession = null;
          _menuVideos = null;
          _menuRoute = null;
        },
        onSelected: _act,
        itemBuilder: (_) => [
          if (song != null)
            PopupMenuItem(
                value: bookmarkAction,
                child: Builder(builder: (context) {
                  _menuRoute = ModalRoute.of(context);
                  return Text(bookmarkLabel);
                })),
          PopupMenuItem(
              value: _LibraryAction.save,
              child: Builder(builder: (context) {
                _menuRoute = ModalRoute.of(context);
                return Text(locals.musicSaveToPlaylist);
              })),
          if (!isTv)
            PopupMenuItem(
                value: _LibraryAction.download,
                child: Text(locals.musicDownloadAudio)),
        ],
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (song != null)
        OutlinedButton.icon(
            onPressed: enabled ? () => _act(bookmarkAction) : null,
            icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
            label: Text(bookmarkLabel)),
      OutlinedButton.icon(
          onPressed: enabled ? () => _act(_LibraryAction.save) : null,
          icon: const Icon(Icons.playlist_add),
          label: Text(locals.musicSaveToPlaylist)),
      if (!isTv)
        OutlinedButton.icon(
            onPressed: enabled ? () => _act(_LibraryAction.download) : null,
            icon: const Icon(Icons.download),
            label: Text(locals.musicDownloadAudio)),
    ]);
  }
}

class _SaveMusicDialog extends StatefulWidget {
  final MusicLibrarySession session;
  final List<Video> videos;
  final bool creating;

  const _SaveMusicDialog(
      {required this.session, required this.videos, this.creating = false});

  @override
  State<_SaveMusicDialog> createState() => _SaveMusicDialogState();
}

/// A bookmark saves only this public catalog identity and display metadata.
class MusicBookmarkButton extends StatefulWidget {
  final MusicLibraryEntry entry;

  const MusicBookmarkButton({super.key, required this.entry});

  @override
  State<MusicBookmarkButton> createState() => _MusicBookmarkButtonState();
}

class _MusicBookmarkButtonState extends State<MusicBookmarkButton> {
  bool _busy = false;

  Future<void> _setSaved(bool saved) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (_busy || !session.isCurrent) return;
    setState(() => _busy = true);
    try {
      await session.setBookmark(widget.entry, saved: saved);
    } catch (_) {
      if (mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.musicLibraryActionError)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<AppCubit, AppState>(
        builder: (context, state) {
          final library = MusicLibraryService.forProfile(db, db.profileId);
          return ListenableBuilder(
            listenable: library.changes,
            builder: (context, _) {
              final saved =
                  library.contains(widget.entry.kind, widget.entry.id);
              final locals = AppLocalizations.of(context)!;
              final label = switch (widget.entry.kind) {
                MusicLibraryKind.song =>
                  saved ? locals.musicRemoveSong : locals.musicSaveSong,
                MusicLibraryKind.album =>
                  saved ? locals.musicRemoveAlbum : locals.musicSaveAlbum,
                MusicLibraryKind.artist =>
                  saved ? locals.musicRemoveArtist : locals.musicSaveArtist,
                MusicLibraryKind.playlist =>
                  saved ? locals.musicRemovePlaylist : locals.musicSavePlaylist,
              };
              return OutlinedButton.icon(
                  onPressed: _busy ||
                          state.globalLoading ||
                          state.sessionRecoveryRequired
                      ? null
                      : () => _setSaved(!saved),
                  icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                  label: Text(label));
            },
          );
        },
      );
}

class _SaveMusicDialogState extends State<_SaveMusicDialog> {
  final _name = TextEditingController();
  bool _creating = false;
  bool _saving = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _creating = widget.creating;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save([String? playlistId]) async {
    if (_saving || !widget.session.isCurrent) return;
    if (playlistId == null && _name.text.trim().isEmpty) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      if (playlistId == null) {
        await widget.session.createPlaylist(_name.text, widget.videos);
      } else {
        await widget.session.saveToPlaylist(playlistId, widget.videos);
      }
      if (mounted && widget.session.isCurrent) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted && widget.session.isCurrent) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    if (!widget.session.isCurrent) return const SizedBox.shrink();
    return AlertDialog(
      title: Text(widget.creating
          ? locals.createNewPlaylist
          : locals.musicSaveToPlaylist),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final playlist
                in widget.creating ? <Playlist>[] : widget.session.playlists)
              ListTile(
                enabled: !_saving &&
                    !widget.videos.every((video) => playlist.videos
                        .any((saved) => saved.videoId == video.videoId)),
                title: Text(playlist.playlistId == localWatchLaterId
                    ? locals.watchLater
                    : playlist.title),
                subtitle: Text(locals.onDevice),
                onTap: () => _save(playlist.playlistId),
              ),
            if (_creating)
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                decoration: InputDecoration(labelText: locals.playListName),
                onSubmitted: (_) => _save(),
              )
            else
              TextButton.icon(
                  onPressed:
                      _saving ? null : () => setState(() => _creating = true),
                  icon: const Icon(Icons.add),
                  label: Text(locals.createNewPlaylist)),
            if (_failed) Text(locals.musicLibraryActionError),
            if (_saving) const LinearProgressIndicator(),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(locals.cancel)),
        if (_creating)
          TextButton(
              onPressed: _saving ? null : () => _save(),
              child: Text(locals.add)),
      ],
    );
  }
}
