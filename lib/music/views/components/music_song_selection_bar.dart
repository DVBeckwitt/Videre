import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
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
    this.closeFocus,
    required this.isCurrent,
    this.onPlay,
    this.closeOnPlay = true,
    this.recommendationSource,
    this.selectedCount,
    this.resolveDownloads,
    this.resolveOnDevice,
    this.deviceLibrary,
    this.onRemoveDownloads,
    this.onRemoveFromPlaylist,
    this.removal,
  });

  final List<Video> selected;
  final bool allSelected;
  final VoidCallback? onToggleAll;
  final VoidCallback onClose;
  final FocusNode? closeFocus;
  final bool Function() isCurrent;
  final Future<void> Function(List<Video> tracks)? onPlay;
  final bool closeOnPlay;
  final PlaylistReference? recommendationSource;
  final int? selectedCount;
  final MusicSelectionDownloadResolver? resolveDownloads;
  final List<OnDeviceMusicEntry>? Function()? resolveOnDevice;
  final LocalMusicLibrary? deviceLibrary;
  final Future<void> Function()? onRemoveDownloads;
  final Future<void> Function()? onRemoveFromPlaylist;
  final MusicSelectionRemoval? removal;

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
        child: Semantics(
          liveRegion: true,
          child: Text(
            locals.musicQueueSelected(selectedCount ?? selected.length),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
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
        resolveOnDevice: resolveOnDevice,
        deviceLibrary: deviceLibrary,
        onRemoveDownloads: onRemoveDownloads,
        onRemoveFromPlaylist: onRemoveFromPlaylist,
        removal: removal,
        isCurrent: isCurrent,
        onCompleted: onClose,
        closeOnPlay: closeOnPlay,
        onPlay: onPlay == null
            ? null
            : (shuffle) {
                final tracks = [
                  for (final song in selected)
                    if (!song.filtered &&
                        !song.filterHide &&
                        song.isUpcoming != true)
                      song,
                ];
                if (shuffle) tracks.shuffle();
                return onPlay!(tracks);
              },
      ),
    ]);
  }
}

/// Focusable selection entry point for screens without a song action menu.
class MusicSongSelectButton extends StatelessWidget {
  const MusicSongSelectButton({
    super.key,
    required this.selected,
    required this.onPressed,
  });

  final bool? selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context)!.musicSelectSong;
    final checked = selected;
    if (checked != null) {
      return Semantics(
        label: label,
        child: Checkbox(value: checked, onChanged: (_) => onPressed()),
      );
    }
    return IconButton(
      tooltip: label,
      icon: const Icon(Icons.check_box_outline_blank),
      onPressed: onPressed,
    );
  }
}
