import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../main.dart' show isTv;
import '../../../videos/models/video.dart';
import '../../models/music_song_selection.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/local_music_library.dart';
import 'music_song_selection_bar.dart';

/// Selection for a generated list whose rows have stable, unique keys.
class MusicDerivedSongSelection extends StatefulWidget {
  const MusicDerivedSongSelection({
    super.key,
    required this.songs,
    required this.isCurrent,
    required this.builder,
    this.deviceLibrary,
    this.resolveOnDevice,
    this.removal,
  });

  final Map<String, Video?> songs;
  final bool Function() isCurrent;
  final Widget Function(BuildContext, MusicDerivedSongSelectionState) builder;
  final LocalMusicLibrary? deviceLibrary;
  final List<OnDeviceMusicEntry>? Function(List<String>)? resolveOnDevice;
  final ({
    String label,
    Future<bool> Function(List<String>, bool Function()) run,
  })? removal;

  @override
  State<MusicDerivedSongSelection> createState() =>
      MusicDerivedSongSelectionState();
}

class MusicDerivedSongSelectionState extends State<MusicDerivedSongSelection> {
  final _selection = MusicSongSelection<String>();
  final _closeFocus = FocusNode();
  int _revision = 0;

  bool get active => _selection.active;

  bool? selected(String id) => active ? _selection.contains(id) : null;

  void start(String id) {
    if (!widget.isCurrent() || !widget.songs.containsKey(id)) return;
    final entering = !active;
    setState(() {
      _revision++;
      _selection.start(id);
    });
    if (entering && isTv) _closeFocus.requestFocus();
  }

  void toggle(String id) {
    if (!active) {
      start(id);
      return;
    }
    if (!widget.isCurrent() || !widget.songs.containsKey(id)) return;
    setState(() {
      _revision++;
      _selection.toggle(id);
    });
  }

  void _close() => setState(() {
        _revision++;
        _selection.clear();
      });

  @override
  void didUpdateWidget(MusicDerivedSongSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selection.retain(widget.songs.keys);
  }

  @override
  void dispose() {
    _closeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.songs.keys;
    final chosen = ids.where(_selection.contains).toList();
    final songs = widget.songs;
    final revision = _revision;
    final isCurrent = widget.isCurrent;
    bool sameSelection() =>
        mounted && isCurrent() && widget.isCurrent() && _revision == revision;
    bool current() =>
        sameSelection() &&
        listEquals(
            chosen, widget.songs.keys.where(_selection.contains).toList()) &&
        chosen.every((id) =>
            songs[id]?.videoId == widget.songs[id]?.videoId &&
            songs[id]?.explicitMusicDownload ==
                widget.songs[id]?.explicitMusicDownload);
    final removal = widget.removal;
    final resolveOnDevice = widget.resolveOnDevice;

    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && active) _close();
      },
      child: Column(
        children: [
          if (active)
            MusicSongSelectionBar(
              selected: [
                for (final id in chosen)
                  if (songs[id] case final song?) song
              ],
              selectedCount: chosen.length,
              allSelected: _selection.allSelected(ids),
              onToggleAll: ids.isEmpty
                  ? null
                  : () => setState(() {
                        _revision++;
                        _selection.toggleAll(ids);
                      }),
              onClose: _close,
              closeFocus: _closeFocus,
              isCurrent: current,
              deviceLibrary: widget.deviceLibrary,
              resolveOnDevice: resolveOnDevice == null
                  ? null
                  : () => current() ? resolveOnDevice(chosen) : null,
              removal: removal == null || chosen.isEmpty
                  ? null
                  : (
                      label: removal.label,
                      run: () async {
                        if (current() &&
                            await removal.run(chosen, current) &&
                            sameSelection()) {
                          _close();
                        }
                      },
                    ),
            ),
          Expanded(child: widget.builder(context, this)),
        ],
      ),
    );
  }
}
