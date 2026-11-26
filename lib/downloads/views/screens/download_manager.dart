import 'package:auto_route/annotations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_song_selection.dart';
import 'package:clipious/music/views/components/music_download_removal.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_song_selection_bar.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/downloaded_video.dart';
import '../../services/explicit_music_download.dart';
import '../../states/download_manager.dart';
import '../components/download_folder.dart';

@RoutePage()
class DownloadManagerScreen extends StatelessWidget {
  const DownloadManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final owner = context.select((AppCubit app) {
      final state = app.state;
      return (state.profileId, state.sessionRevision, state.server);
    });
    final manager = context.watch<DownloadManagerCubit>();
    return _DownloadManagerView(
      key: ValueKey((db, owner, manager)),
      profileId: owner.$1,
      manager: manager,
      state: manager.state,
    );
  }
}

class _DownloadManagerView extends StatefulWidget {
  const _DownloadManagerView({
    super.key,
    required this.profileId,
    required this.manager,
    required this.state,
  });

  final String profileId;
  final DownloadManagerCubit manager;
  final DownloadManagerState state;

  @override
  State<_DownloadManagerView> createState() => _DownloadManagerViewState();
}

class _DownloadManagerViewState extends State<_DownloadManagerView> {
  final _selection = MusicSongSelection<String>();
  final _selectFocus = FocusNode();
  final _closeFocus = FocusNode();

  @override
  void didUpdateWidget(_DownloadManagerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selection.active &&
        !listEquals(oldWidget.state.videos, widget.state.videos)) {
      _selection.retain(
        _songDownloads(widget.state).map(musicDownloadFingerprint),
      );
    }
  }

  @override
  void dispose() {
    _selectFocus.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  Iterable<DownloadedVideo> _songDownloads(DownloadManagerState state) =>
      state.videos.where(
        (file) =>
            file.profileId == widget.profileId &&
            file.audioOnly &&
            file.musicMetadata?.title.trim().isNotEmpty == true &&
            file.downloadComplete &&
            !file.downloadFailed &&
            !file.storageFailed &&
            !file.authenticationRequired,
      );

  void _focus(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.context != null) node.requestFocus();
    });
  }

  void _start([String? fileId]) {
    setState(() {
      if (fileId == null) {
        _selection.begin();
      } else {
        _selection.start(fileId);
      }
    });
    _focus(_closeFocus);
  }

  void _close() {
    setState(_selection.clear);
    _focus(_selectFocus);
  }

  Widget _selectionBar(Map<DownloadedVideo, String> songIds) {
    final selected = _selection.selectedRows(
      songIds.keys,
      (file) => songIds[file]!,
    );
    final selectedIds = selected.map((file) => songIds[file]!).toList();
    final manager = widget.manager;
    final database = db;
    final session = MusicLibrarySession(context.read<AppCubit>());
    final route = ModalRoute.of(context);

    bool ownerCurrent() =>
        mounted &&
        session.isCurrent &&
        identical(db, database) &&
        database.profileId == widget.profileId &&
        identical(context.read<DownloadManagerCubit?>(), manager) &&
        !manager.isClosed;
    List<DownloadedVideo> liveSelection() => _selection.selectedRows(
          _songDownloads(manager.state),
          musicDownloadFingerprint,
        );
    bool isCurrent() =>
        ownerCurrent() &&
        _selection.active &&
        listEquals(
          selectedIds,
          liveSelection().map(musicDownloadFingerprint).toList(),
        );

    List<DownloadedVideo>? resolveDownloads(List<Video> tracks) {
      if (!isCurrent()) return null;
      final files = [
        for (final track in tracks)
          if (readyMusicDownload(
            database,
            track.videoId,
            fingerprint: track.explicitMusicDownload,
          )
              case final file?)
            file.copyWith(explicitMusicDownload: track.explicitMusicDownload),
      ];
      return files.length == tracks.length ? files : null;
    }

    Future<void> remove() async {
      if (!isCurrent()) return;
      final removed = await confirmMusicDownloadRemoval(
        context,
        manager,
        selected,
        isCurrent: () => ownerCurrent() && route?.isCurrent != false,
      );
      if (removed != null &&
          removed > 0 &&
          ownerCurrent() &&
          _selection.active &&
          liveSelection().isEmpty) {
        _close();
      }
    }

    return MusicSongSelectionBar(
      selected: selected.map(musicDownloadSelectionEntry).toList(),
      allSelected: _selection.allSelected(songIds.values),
      onToggleAll: songIds.isEmpty
          ? null
          : () => setState(() => _selection.toggleAll(songIds.values)),
      onClose: _close,
      closeFocus: _closeFocus,
      isCurrent: isCurrent,
      resolveDownloads: resolveDownloads,
      onRemoveDownloads: selected.isEmpty ? null : remove,
      onPlay: (tracks) async {
        final files = resolveDownloads(tracks);
        final player = context.read<PlayerCubit?>();
        if (files == null || files.isEmpty || player == null) return;
        await player.playOfflineVideos(files, fromMusic: true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final state = widget.state;
    final manager = widget.manager;
    final songIds = {
      for (final file in _songDownloads(state))
        file: musicDownloadFingerprint(file),
    };
    final selecting = _selection.active;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selection.active) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(locals.downloads),
          actions: [
            if (!selecting) ...[
              if (songIds.isNotEmpty)
                IconButton(
                  focusNode: _selectFocus,
                  tooltip: locals.musicQueueSelect,
                  icon: const Icon(Icons.checklist_rounded),
                  onPressed: _start,
                ),
              IconButton(
                tooltip: locals.downloadFolder,
                icon: const Icon(Icons.folder_open),
                onPressed: () => showDownloadFolder(context),
              ),
              IconButton(
                tooltip: locals.downloadsWifiOnly,
                isSelected: state.wifiOnly,
                icon: const Icon(Icons.wifi),
                selectedIcon: const Icon(Icons.wifi_lock),
                onPressed: () => manager.setWifiOnly(!state.wifiOnly),
              ),
            ],
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
            child: Column(
              children: [
                if (selecting)
                  _selectionBar(songIds)
                else if (state.videos.isNotEmpty) ...[
                  if (state.wifiOnly)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(state.waitingForWifi
                          ? locals.downloadsWaitingForWifi
                          : locals.downloadsWifiOnly),
                    ),
                  FilledButton.tonalIcon(
                    onPressed: manager.canPlayAll() ? manager.playAll : null,
                    icon: const Icon(Icons.playlist_play),
                    label: Text(locals.downloadsPlayAll),
                  ),
                ],
                Expanded(
                  child: state.videos.isEmpty
                      ? Center(child: Text(locals.noDownloadedVideos))
                      : ListView.builder(
                          itemCount: state.videos.length,
                          itemBuilder: (context, index) {
                            final file = state.videos[index];
                            final id = songIds[file];
                            return DownloadedVideoView(
                              key: ValueKey((file.profileId, file.videoId)),
                              video: file,
                              selectionMode: selecting,
                              selected: id != null && _selection.contains(id),
                              onSelect: id == null
                                  ? null
                                  : selecting
                                      ? () =>
                                          setState(() => _selection.toggle(id))
                                      : () => _start(id),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
