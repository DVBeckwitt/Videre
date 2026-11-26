import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../models/local_music_track.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/local_music_library.dart';
import 'device_music_song_selection.dart';

/// Browses only the verified ancestry of the current profile's playable rows.
class LocalMusicFolderBrowser extends StatefulWidget {
  const LocalMusicFolderBrowser({
    super.key,
    required this.library,
    required this.catalogChanges,
    required this.currentEntries,
    required this.sourceScope,
    required this.order,
    required this.refresh,
    required this.unavailableMessage,
    required this.row,
  });

  final LocalMusicLibrary library;
  final Listenable catalogChanges;
  final List<OnDeviceMusicEntry>? Function() currentEntries;
  final Object? Function() sourceScope;
  final List<OnDeviceMusicEntry> Function(List<OnDeviceMusicEntry>) order;
  final VoidCallback? Function() refresh;
  final String Function() unavailableMessage;
  final Widget Function(
    BuildContext context,
    List<OnDeviceMusicEntry> tracks,
    int index,
    LocalMusicFolderLocation folder,
    bool autofocus, {
    required bool? selected,
    required VoidCallback? onToggleSelection,
    required VoidCallback? onStartSelection,
  }) row;

  @override
  State<LocalMusicFolderBrowser> createState() =>
      _LocalMusicFolderBrowserState();
}

class _LocalMusicFolderBrowserState extends State<LocalMusicFolderBrowser> {
  List<String> _path = const [];
  String? _focusFolder;

  void _goUp() {
    if (_path.isNotEmpty) {
      setState(() {
        _focusFolder = _path.last;
        _path = _path.sublist(0, _path.length - 1);
      });
    }
  }

  bool _isInFolder(List<LocalMusicFolderLocation> locations) {
    if (locations.length < _path.length) return false;
    for (var i = 0; i < _path.length; i++) {
      if (locations[i].key != _path[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.catalogChanges,
      builder: (context, _) {
        final entries = widget.currentEntries();
        final depth = _path.length;
        final children = <String, LocalMusicFolderLocation>{};
        final directTracks = <OnDeviceMusicEntry>[];
        LocalMusicFolderLocation? current;
        for (final entry in entries ?? const <OnDeviceMusicEntry>[]) {
          final locations = entry.deviceTrack?.folderLocations;
          if (locations == null ||
              locations.isEmpty ||
              !_isInFolder(locations)) {
            continue;
          }
          if (depth > 0) current ??= locations[depth - 1];
          if (depth == locations.length) {
            directTracks.add(entry);
          } else {
            final child = locations[depth];
            children.putIfAbsent(child.key, () => child);
          }
        }

        final folders = children.values.toList()
          ..sort((a, b) {
            final label =
                a.label.toLowerCase().compareTo(b.label.toLowerCase());
            return label == 0 ? a.key.compareTo(b.key) : label;
          });
        final tracks = widget.order(directTracks);
        final indexes = {
          for (final (i, folder) in folders.indexed) ValueKey(folder.key): i,
          for (final (i, track) in tracks.indexed)
            ValueKey(track.id): folders.length + i,
        };
        final folder = current;
        final breadcrumb = folder?.label.split(' / ');
        final canPop = depth == 0 || entries == null;
        final focusIndex = switch (_focusFolder) {
          final key? => indexes[ValueKey(key)] ?? 0,
          null => 0,
        };
        final emptyMessage = entries == null
            ? widget.unavailableMessage()
            : depth == 0
                ? locals.localMusicNoIndexedFolders
                : locals.localMusicNoVisibleFiles;
        final scope = widget.sourceScope();
        final path = _path;
        return DeviceMusicSongSelection(
          library: widget.library,
          tracks: [for (final track in tracks) track.deviceTrack!],
          source: (scope, path),
          currentTracks: () {
            if (scope == null ||
                scope != widget.sourceScope() ||
                !identical(_path, path)) {
              return null;
            }
            final live = widget.currentEntries();
            if (live == null) return null;
            return [
              for (final entry in widget.order([
                for (final entry in live)
                  if (entry.deviceTrack?.folderLocations case final locations?)
                    if (locations.isNotEmpty &&
                        locations.length == depth &&
                        _isInFolder(locations))
                      entry,
              ]))
                entry.deviceTrack!,
            ];
          },
          builder: (context, selection) {
            final selecting = selection.active;
            return PopScope<void>(
              canPop: canPop,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && !canPop && !selecting) _goUp();
              },
              child: Scaffold(
                appBar: AppBar(
                  leading: canPop
                      ? null
                      : BackButton(
                          onPressed: selecting ? selection.close : _goUp),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(breadcrumb?.last ?? locals.localMusicBrowseFolders,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (breadcrumb != null && breadcrumb.length > 1)
                        Text(breadcrumb.take(breadcrumb.length - 1).join(' / '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                  actions: [
                    if (selection.selectButton case final button?) button,
                    IconButton(
                      tooltip: locals.refresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: widget.refresh(),
                    ),
                  ],
                ),
                body: SafeArea(
                  child: Column(children: [
                    if (selection.toolbar case final toolbar?) toolbar,
                    Expanded(
                      child: folders.isEmpty && tracks.isEmpty
                          ? Center(
                              child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(emptyMessage,
                                  textAlign: TextAlign.center),
                            ))
                          : FocusScope(
                              key: ValueKey(_path.lastOrNull),
                              child: ListView.builder(
                                key: PageStorageKey(_path.lastOrNull),
                                itemCount: folders.length + tracks.length,
                                findChildIndexCallback: (key) => indexes[key],
                                itemBuilder: (context, index) {
                                  final autofocus = isTv && index == focusIndex;
                                  if (index >= folders.length) {
                                    final songIndex = index - folders.length;
                                    return widget.row(
                                      context,
                                      tracks,
                                      songIndex,
                                      folder!,
                                      autofocus,
                                      selected: selecting
                                          ? selection.contains(songIndex)
                                          : null,
                                      onToggleSelection: selecting
                                          ? () => selection.toggle(songIndex)
                                          : null,
                                      onStartSelection: () =>
                                          selection.start(songIndex),
                                    );
                                  }
                                  final child = folders[index];
                                  final label = child.label.split(' / ');
                                  return ListTile(
                                    key: ValueKey(child.key),
                                    autofocus: autofocus,
                                    leading: const Icon(Icons.folder_outlined),
                                    title: Text(label.last,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    subtitle: depth == 0 && label.length > 1
                                        ? Text(
                                            label
                                                .take(label.length - 1)
                                                .join(' / '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)
                                        : null,
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => setState(() {
                                      _focusFolder = null;
                                      _path = [..._path, child.key];
                                    }),
                                  );
                                },
                              ),
                            ),
                    ),
                  ]),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
