import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../downloads/models/music_offline_policy.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist.dart';
import '../../../videos/views/components/download_modal_sheet.dart'
    show MusicOfflinePolicyFields;

class MusicPlaylistOffline extends StatefulWidget {
  const MusicPlaylistOffline({super.key, required this.playlist});

  final Playlist playlist;

  @override
  State<MusicPlaylistOffline> createState() => _MusicPlaylistOfflineState();
}

class _MusicPlaylistOfflineState extends State<MusicPlaylistOffline> {
  bool _busy = false;

  Future<void> _update(DownloadManagerCubit manager,
      {bool? keepOffline}) async {
    if (_busy) return;
    final database = db;
    final profileId = database.profileId;
    final playlistId = widget.playlist.playlistId;
    final locals = AppLocalizations.of(context)!;

    bool isCurrent() =>
        identical(database, db) &&
        profileId == db.profileId &&
        playlistId == widget.playlist.playlistId;

    setState(() => _busy = true);
    try {
      if (keepOffline == true) {
        var policy = MusicOfflinePolicy(wifiOnly: manager.state.wifiOnly);
        final choice = await showDialog<MusicOfflinePolicy>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: Text(locals.musicPlaylistKeepOffline),
              content: SingleChildScrollView(
                child: MusicOfflinePolicyFields(
                  policy: policy,
                  onChanged: (value) => update(() => policy = value),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(locals.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, policy),
                  child: Text(locals.musicPlaylistKeepOffline),
                ),
              ],
            ),
          ),
        );
        if (choice != null && mounted && isCurrent()) {
          await manager.setPlaylistKeptOffline(playlistId, true,
              policy: choice);
        }
      } else if (keepOffline == false) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(locals.musicPlaylistStopKeepingOffline),
            content: Text(locals.musicPlaylistStopKeepingOfflineHelp),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(locals.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(locals.musicPlaylistStopKeepingOffline),
              ),
            ],
          ),
        );
        if (confirmed == true && mounted && isCurrent()) {
          await manager.setPlaylistKeptOffline(playlistId, false);
        }
      } else {
        await manager.retryPlaylistOffline(playlistId);
      }
    } catch (_) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(locals.musicLibraryActionError)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.read<DownloadManagerCubit?>();
    if (manager == null) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    return BlocBuilder<DownloadManagerCubit, DownloadManagerState>(
      bloc: manager,
      builder: (context, _) => ListenableBuilder(
        listenable: manager.playlistOfflineChanges,
        builder: (context, _) {
          final status = manager.playlistOfflineProgress(widget.playlist);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('music-playlist-keep-offline'),
                    onPressed: _busy
                        ? null
                        : () => _update(manager, keepOffline: status == null),
                    icon: Icon(
                        status == null ? Icons.download : Icons.offline_pin),
                    label: Text(status == null
                        ? locals.musicPlaylistKeepOffline
                        : locals.musicPlaylistStopKeepingOffline),
                  ),
                  if (status != null && status.needsAttention > 0)
                    TextButton(
                      key: const ValueKey('music-playlist-offline-retry'),
                      onPressed: _busy ? null : () => _update(manager),
                      child: Text(locals.retry),
                    ),
                ],
              ),
              if (status != null) ...[
                const SizedBox(height: 8),
                Text(
                  status.total == 0
                      ? locals.musicPlaylistOfflineEmpty
                      : locals.musicPlaylistOfflineProgress(
                          status.complete, status.total),
                  key: const ValueKey('music-playlist-offline-progress'),
                ),
                if (status.progress case final value? when value < 1) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: value),
                ],
                if (status.waitingForWifi) ...[
                  const SizedBox(height: 4),
                  Text(locals.downloadsWaitingForWifi),
                ],
                if (status.needsAttention > 0) ...[
                  const SizedBox(height: 4),
                  Text(locals
                      .musicPlaylistOfflineAttention(status.needsAttention)),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}
