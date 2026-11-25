import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../../videos/models/video.dart';
import '../screens/music.dart';

enum _CollectionAction { play, shuffle, append }

class MusicCollectionSelectionBar extends StatefulWidget {
  const MusicCollectionSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onToggleAll,
    required this.onClose,
    required this.closeFocus,
    required this.isCurrent,
    required this.loadTracks,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback? onToggleAll;
  final VoidCallback onClose;
  final FocusNode closeFocus;
  final bool Function() isCurrent;
  final Future<List<Video>> Function() loadTracks;

  @override
  State<MusicCollectionSelectionBar> createState() =>
      _MusicCollectionSelectionBarState();
}

class _MusicCollectionSelectionBarState
    extends State<MusicCollectionSelectionBar> {
  bool _busy = false;

  bool _canAppend(PlayerCubit? player) =>
      player != null &&
      !player.isClosed &&
      identical(context.read<PlayerCubit?>(), player) &&
      player.state.isAudio &&
      (player.state.currentlyPlaying?.musicMetadata ??
              player.state.offlineCurrentlyPlaying?.musicMetadata) !=
          null;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Row(children: [
      IconButton(
        focusNode: widget.closeFocus,
        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
        icon: const Icon(Icons.close),
        onPressed: widget.onClose,
      ),
      Expanded(
        child: Text(locals.musicQueueSelected(widget.selectedCount),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      IconButton(
        tooltip: widget.allSelected
            ? locals.musicQueueDeselectAll
            : locals.musicQueueSelectAll,
        icon: Icon(widget.allSelected ? Icons.deselect : Icons.select_all),
        onPressed: widget.onToggleAll,
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      else
        PopupMenuButton<Future<void> Function()>(
          key: const ValueKey('music-collection-selection-actions'),
          tooltip: locals.musicCollectionSelectionActions,
          enabled: widget.selectedCount > 0,
          onSelected: (run) => unawaited(run()),
          itemBuilder: (_) {
            final source = widget;
            final player = context.read<PlayerCubit?>();
            final generation =
                _canAppend(player) ? player!.playlistGeneration : null;
            PopupMenuItem<Future<void> Function()> item(
                    _CollectionAction action, String label,
                    {bool enabled = true}) =>
                PopupMenuItem(
                  value: () => _run(action, source, player, generation),
                  enabled: enabled,
                  child: Text(label),
                );
            return [
              item(_CollectionAction.play, locals.musicPlayAll),
              item(_CollectionAction.shuffle, locals.musicShuffle),
              item(_CollectionAction.append, locals.addToQueueList,
                  enabled: generation != null),
            ];
          },
        ),
    ]);
  }

  Future<void> _run(
      _CollectionAction action,
      MusicCollectionSelectionBar source,
      PlayerCubit? player,
      int? generation) async {
    bool current() => mounted && source.isCurrent();
    bool queueCurrent() =>
        generation != null &&
        _canAppend(player) &&
        player!.playlistGeneration == generation;
    if (_busy || !current()) return;
    final locals = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    void show(String message) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    try {
      if (action == _CollectionAction.append && !queueCurrent()) {
        show(locals.musicCollectionSelectionError);
        return;
      }
      final tracks = await source.loadTracks();
      if (!current()) return;
      if (tracks.isEmpty) {
        show(locals.musicEmptyCollection);
        return;
      }
      if (action == _CollectionAction.append) {
        if (!queueCurrent() ||
            !player!.canEnqueueMusicSongs(tracks) ||
            !await player.enqueueMusicSongs(tracks, next: false)) {
          if (current()) show(locals.musicCollectionSelectionError);
          return;
        }
      } else {
        await MusicScreen.playCollectionTracks(context, tracks,
            queueTitle: locals.musicSelectedCollections,
            shuffle: action == _CollectionAction.shuffle,
            isCurrent: current);
      }
      if (current()) source.onClose();
    } catch (_) {
      if (current()) show(locals.musicCollectionSelectionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
