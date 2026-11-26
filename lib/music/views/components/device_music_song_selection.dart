import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../models/device_playlist_track.dart';
import '../../models/local_music_track.dart';
import '../../models/music_song_selection.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/local_music_library.dart';
import 'music_song_selection_bar.dart';

typedef _FileId = (String playbackId, String uri);
typedef _SongId = ({_FileId file, int? occurrence});
typedef _SongRow = ({LocalMusicTrack track, _SongId id});

List<_SongRow> _identifyRows(List<LocalMusicTrack> tracks) {
  final counts = <_FileId, int>{};
  _FileId file(LocalMusicTrack track) => (track.playbackId, track.uri);
  for (final track in tracks) {
    counts.update(file(track), (count) => count + 1, ifAbsent: () => 1);
  }
  return [
    for (final (index, track) in tracks.indexed)
      (
        track: track,
        id: (
          file: file(track),
          occurrence: counts[file(track)] == 1 ? null : index,
        ),
      ),
  ];
}

/// Selection for a device drill-down that can re-resolve its current tracks.
class DeviceMusicSongSelection extends StatefulWidget {
  const DeviceMusicSongSelection({
    super.key,
    required this.library,
    required this.tracks,
    required this.source,
    required this.currentTracks,
    required this.builder,
  });

  final LocalMusicLibrary library;
  final List<LocalMusicTrack> tracks;
  final Object source;
  final List<LocalMusicTrack>? Function() currentTracks;
  final Widget Function(BuildContext, DeviceMusicSongSelectionState) builder;

  @override
  State<DeviceMusicSongSelection> createState() =>
      DeviceMusicSongSelectionState();
}

class DeviceMusicSongSelectionState extends State<DeviceMusicSongSelection> {
  final _selection = MusicSongSelection<_SongId>();
  final _selectFocus = FocusNode();
  final _closeFocus = FocusNode();
  late List<_SongRow> _rows = _identifyRows(widget.tracks);

  bool get active => _selection.active;
  bool contains(int index) => _selection.contains(_rows[index].id);

  static List<_SongId> _ids(List<_SongRow> rows) =>
      rows.map((row) => row.id).toList(growable: false);

  @override
  void didUpdateWidget(DeviceMusicSongSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _identifyRows(widget.tracks);
    if (widget.source != oldWidget.source || next.isEmpty) {
      _selection.clear();
    } else if (active) {
      final sameOrder = listEquals(_ids(_rows), _ids(next));
      final hadSelection = _rows.any((row) => _selection.contains(row.id));
      _selection.retain([
        for (final row in next)
          if (sameOrder || row.id.occurrence == null) row.id,
      ]);
      if (hadSelection && !next.any((row) => _selection.contains(row.id))) {
        _selection.clear();
      }
    }
    _rows = next;
  }

  @override
  void dispose() {
    _selectFocus.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  void _focus(FocusNode control, {required bool selecting}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && active == selecting && TickerMode.of(context)) {
        if (control.context != null) control.requestFocus();
      }
    });
  }

  void start(int index) {
    if (contains(index) || widget.currentTracks() == null) return;
    final entering = !active;
    setState(() => _selection.start(_rows[index].id));
    if (entering) _focus(_closeFocus, selecting: true);
  }

  void toggle(int index) {
    if (active) setState(() => _selection.toggle(_rows[index].id));
  }

  void close() {
    if (!active) return;
    setState(_selection.clear);
    _focus(_selectFocus, selecting: false);
  }

  Widget? get selectButton {
    if (active || _rows.isEmpty) return null;
    final locals = AppLocalizations.of(context)!;
    return IconButton(
      focusNode: _selectFocus,
      tooltip: locals.musicQueueSelect,
      icon: const Icon(Icons.checklist),
      onPressed: () {
        if (widget.currentTracks() == null) return;
        setState(_selection.begin);
        _focus(_closeFocus, selecting: true);
      },
    );
  }

  Widget? get toolbar {
    if (!active) return null;
    final source = widget.source;
    final ids = _ids(_rows);
    final rows = _selection.selectedRows(_rows, (row) => row.id);
    final selectedIds = _ids(rows);
    List<OnDeviceMusicEntry>? resolve() {
      if (!mounted ||
          !active ||
          source != widget.source ||
          !listEquals(
            selectedIds,
            _ids(_selection.selectedRows(_rows, (row) => row.id)),
          )) {
        return null;
      }
      final tracks = widget.currentTracks();
      if (tracks == null) return null;
      final current = _identifyRows(tracks);
      if (selectedIds.any((id) => id.occurrence != null) &&
          !listEquals(ids, _ids(current))) {
        return null;
      }
      final live = _selection.selectedRows(current, (row) => row.id);
      if (!listEquals(selectedIds, _ids(live))) return null;
      return [for (final row in live) OnDeviceMusicEntry.device(row.track)];
    }

    return MusicSongSelectionBar(
      selected: [
        for (final row in rows)
          if (devicePlaylistVideo(row.track) case final video?) video,
      ],
      selectedCount: rows.length,
      allSelected: _selection.allSelected(ids),
      onToggleAll: () => setState(() => _selection.toggleAll(ids)),
      onClose: close,
      closeFocus: _closeFocus,
      isCurrent: () => resolve() != null,
      resolveOnDevice: resolve,
      deviceLibrary: widget.library,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selecting = active && TickerMode.of(context);
    return PlayerModalBackHandler(
      active: selecting,
      priority: 6,
      onBack: close,
      child: PopScope<void>(
        canPop: !selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && selecting) close();
        },
        child: widget.builder(context, this),
      ),
    );
  }
}
