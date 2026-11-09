import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
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

  MusicLibrarySession(this.app)
      : _initial = app.state,
        _profileId = db.profileId,
        _service = service;

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
  }

  Future<void> createPlaylist(String name, List<Video> videos) async {
    _requireCurrent();
    final id = await _service.createPlayList(name, 'local');
    _requireCurrent();
    if (id == null) throw StateError('Could not create playlist');
    await saveToPlaylist(id, videos);
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

enum _LibraryAction { save, download }

class MusicLibraryActions extends StatefulWidget {
  final List<Video> videos;
  final bool compact;

  const MusicLibraryActions(
      {super.key, required this.videos, this.compact = true});

  static Future<void> save(BuildContext context, List<Video> videos) async {
    if (videos.isEmpty) return;
    final app = context.read<AppCubit>();
    final session = MusicLibrarySession(app);
    if (!session.isCurrent) return;
    final locals = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: false);
    final route = DialogRoute<bool>(
        context: context,
        builder: (_) => _SaveMusicDialog(session: session, videos: videos));
    final changes = app.stream.listen((_) {
      if (!session.isCurrent && route.isActive && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
    try {
      final saved = await navigator.push(route);
      if (saved == true && context.mounted && session.isCurrent) {
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

  Future<void> _act(_LibraryAction action) async {
    final menuSession = _menuSession;
    _menuSession = null;
    if (menuSession != null && !menuSession.isCurrent) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (action == _LibraryAction.save) {
        await MusicLibraryActions.save(context, widget.videos);
      } else {
        await MusicLibraryActions.download(context, widget.videos);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final enabled = !_busy && widget.videos.isNotEmpty;
    if (widget.compact) {
      return PopupMenuButton<_LibraryAction>(
        key: ValueKey(
            'music-library-menu-${widget.videos.firstOrNull?.videoId}'),
        tooltip: locals.musicLibraryActions,
        enabled: enabled,
        onOpened: () =>
            _menuSession = MusicLibrarySession(context.read<AppCubit>()),
        onCanceled: () => _menuSession = null,
        onSelected: _act,
        itemBuilder: (_) => [
          PopupMenuItem(
              value: _LibraryAction.save,
              child: Text(locals.musicSaveToPlaylist)),
          if (!isTv)
            PopupMenuItem(
                value: _LibraryAction.download,
                child: Text(locals.musicDownloadAudio)),
        ],
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [
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

  const _SaveMusicDialog({required this.session, required this.videos});

  @override
  State<_SaveMusicDialog> createState() => _SaveMusicDialogState();
}

class _SaveMusicDialogState extends State<_SaveMusicDialog> {
  final _name = TextEditingController();
  bool _creating = false;
  bool _saving = false;
  bool _failed = false;

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
      title: Text(locals.musicSaveToPlaylist),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final playlist in widget.session.playlists)
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
