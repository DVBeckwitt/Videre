import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';

import 'music_library_actions.dart';

class MusicSongSelectionBar extends StatelessWidget {
  const MusicSongSelectionBar({
    super.key,
    required this.selected,
    required this.allSelected,
    required this.onToggleAll,
    required this.onClose,
    required this.closeFocus,
    required this.isCurrent,
    required this.onPlay,
    this.recommendationSource,
    this.selectedCount,
    this.resolveDownloads,
    this.onRemoveDownloads,
    this.onRemoveFromPlaylist,
  });

  final List<Video> selected;
  final bool allSelected;
  final VoidCallback? onToggleAll;
  final VoidCallback onClose;
  final FocusNode closeFocus;
  final bool Function() isCurrent;
  final Future<void> Function(List<Video> tracks) onPlay;
  final PlaylistReference? recommendationSource;
  final int? selectedCount;
  final MusicSelectionDownloadResolver? resolveDownloads;
  final Future<void> Function()? onRemoveDownloads;
  final Future<void> Function()? onRemoveFromPlaylist;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Row(children: [
      IconButton(
        focusNode: closeFocus,
        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
        icon: const Icon(Icons.close),
        onPressed: onClose,
      ),
      Expanded(
        child: Text(locals.musicQueueSelected(selectedCount ?? selected.length),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      IconButton(
        tooltip: allSelected
            ? locals.musicQueueDeselectAll
            : locals.musicQueueSelectAll,
        icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
        onPressed: onToggleAll,
      ),
      MusicPlaylistSelectionActions(
        videos: selected,
        recommendationSource: recommendationSource,
        selectedCount: selectedCount,
        resolveDownloads: resolveDownloads,
        onRemoveDownloads: onRemoveDownloads,
        onRemoveFromPlaylist: onRemoveFromPlaylist,
        isCurrent: isCurrent,
        onCompleted: onClose,
        onPlay: (shuffle) {
          final tracks = [
            for (final song in selected)
              if (!song.filtered && !song.filterHide && song.isUpcoming != true)
                song,
          ];
          if (shuffle) tracks.shuffle();
          return onPlay(tracks);
        },
      ),
    ]);
  }
}
