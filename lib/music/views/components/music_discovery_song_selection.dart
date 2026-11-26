import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../videos/models/video.dart';
import '../../models/music_song_selection.dart';
import 'music_song_selection_bar.dart';

/// Keeps one active selection across the independently rebuilt Home shelves.
class MusicDiscoverySelectionOwner extends ValueNotifier<Object?> {
  MusicDiscoverySelectionOwner() : super(null);

  bool _disposed = false;

  void release(Object owner) {
    if (!_disposed && identical(value, owner)) value = null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class MusicDiscoverySelectionScope
    extends InheritedNotifier<MusicDiscoverySelectionOwner> {
  const MusicDiscoverySelectionScope({
    super.key,
    required MusicDiscoverySelectionOwner owner,
    required super.child,
  }) : super(notifier: owner);

  static MusicDiscoverySelectionOwner? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MusicDiscoverySelectionScope>()
      ?.notifier;
}

class MusicDiscoverySelectionRows {
  const MusicDiscoverySelectionRows(
      this._selecting, this._selected, this._toggle);

  final bool _selecting;
  final bool Function(int) _selected;
  final void Function(int) _toggle;

  bool? selected(int index) => _selecting ? _selected(index) : null;
  VoidCallback toggle(int index) => () => _toggle(index);
}

typedef _RowId = (String, int);

class MusicDiscoverySongSelection extends StatefulWidget {
  const MusicDiscoverySongSelection({
    super.key,
    required this.source,
    required this.songs,
    required this.isCurrent,
    required this.builder,
    this.removeSavedSongs,
    this.fill = false,
  });

  final Object source;
  final List<Video> songs;
  final bool Function() isCurrent;
  final Widget Function(BuildContext, MusicDiscoverySelectionRows) builder;
  final Future<bool> Function(List<String>, bool Function())? removeSavedSongs;
  final bool fill;

  @override
  State<MusicDiscoverySongSelection> createState() =>
      _MusicDiscoverySongSelectionState();
}

class _MusicDiscoverySongSelectionState
    extends State<MusicDiscoverySongSelection> {
  final _selection = MusicSongSelection<_RowId>();
  final _owner = Object();
  final _closeFocus = FocusNode();
  MusicDiscoverySelectionOwner? _home;
  int _revision = 0;

  Map<_RowId, Video> _rows(List<Video> songs) {
    final counts = <String, int>{};
    return {
      for (final song in songs)
        (
          song.videoId,
          counts.update(song.videoId, (count) => count + 1, ifAbsent: () => 0)
        ): song,
    };
  }

  void _retire() {
    _selection.clear();
    _revision++;
    final home = _home;
    if (home != null && identical(home.value, _owner)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_selection.active) home.release(_owner);
      });
    }
  }

  void _close() {
    setState(() {
      _selection.clear();
      _revision++;
    });
    _home?.release(_owner);
  }

  @override
  void didUpdateWidget(MusicDiscoverySongSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _retire();
  }

  @override
  void dispose() {
    _retire();
    _closeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _home = MusicDiscoverySelectionScope.maybeOf(context);
    final home = _home;
    final enabled = TickerMode.of(context) && widget.isCurrent();
    if (!enabled || (home?.value != null && home?.value != _owner)) {
      if (_selection.active) _retire();
    }
    final rows = _rows(widget.songs);
    final ids = rows.keys.toList();
    _selection.retain(ids);
    final active = _selection.active;
    final source = widget.source;
    final revision = _revision;
    final chosen = ids.where(_selection.contains).toList();
    final selecting = enabled && (active || home?.value != null);

    bool sameSelection() =>
        mounted &&
        TickerMode.of(context) &&
        widget.isCurrent() &&
        widget.source == source &&
        _revision == revision &&
        (home == null || home.value == _owner);
    bool current() =>
        sameSelection() &&
        listEquals(chosen,
            _rows(widget.songs).keys.where(_selection.contains).toList());
    final removeSavedSongs = widget.removeSavedSongs;
    final removal = removeSavedSongs == null || chosen.isEmpty
        ? null
        : (
            label: AppLocalizations.of(context)!.musicRemoveSelectedSavedSongs,
            run: () async {
              if (!current()) return;
              if (await removeSavedSongs(
                      [for (final id in chosen) rows[id]!.videoId], current) &&
                  sameSelection()) {
                _close();
              }
            },
          );

    void toggle(int index) {
      if (!mounted ||
          !TickerMode.of(context) ||
          !widget.isCurrent() ||
          widget.source != source ||
          !_rows(widget.songs).containsKey(ids[index])) {
        return;
      }
      final entering = !_selection.active;
      setState(() {
        _revision++;
        _selection.toggle(ids[index]);
      });
      home?.value = _owner;
      if (entering && isTv) _closeFocus.requestFocus();
    }

    final content = widget.builder(
        context,
        MusicDiscoverySelectionRows(
            selecting, (i) => _selection.contains(ids[i]), toggle));
    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selection.active && TickerMode.of(context)) _close();
      },
      child: Column(
        mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (active)
            MusicSongSelectionBar(
              selected: [for (final id in chosen) rows[id]!],
              allSelected: _selection.allSelected(ids),
              onToggleAll: ids.isEmpty
                  ? null
                  : () => setState(() {
                        _selection.toggleAll(ids);
                        _revision++;
                      }),
              onClose: _close,
              closeFocus: _closeFocus,
              isCurrent: current,
              removal: removal,
            ),
          if (widget.fill) Expanded(child: content) else content,
        ],
      ),
    );
  }
}
