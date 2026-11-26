import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_album.dart';
import '../../models/local_music_album_editions.dart';
import '../../services/local_music_library.dart';

Future<String?> showLocalMusicAlbumEditions(
  BuildContext context, {
  required LocalMusicLibrary library,
  required String anchorKey,
  required LocalMusicAlbumEditionGroup? group,
  required bool Function() isCurrent,
}) =>
    showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (context) => Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: _AlbumEditionsDialog(
          library: library,
          anchorKey: anchorKey,
          group: group,
          isCurrent: isCurrent,
        ),
      ),
    );

class _AlbumEditionsDialog extends StatefulWidget {
  const _AlbumEditionsDialog({
    required this.library,
    required this.anchorKey,
    required this.group,
    required this.isCurrent,
  });

  final LocalMusicLibrary library;
  final String anchorKey;
  final LocalMusicAlbumEditionGroup? group;
  final bool Function() isCurrent;

  @override
  State<_AlbumEditionsDialog> createState() => _AlbumEditionsDialogState();
}

class _AlbumEditionsDialogState extends State<_AlbumEditionsDialog> {
  late final _originalKeys = widget.group?.albumKeys ?? [widget.anchorKey];
  late final _originalPreference =
      widget.group?.preferredKey ?? widget.anchorKey;
  late List<String> _keys = List.of(_originalKeys);
  late String _preferred = _originalPreference;
  bool _adding = false;
  bool _saving = false;
  bool _saveFailed = false;
  String _query = '';

  bool get _dirty =>
      !listEquals(_keys, _originalKeys) || _preferred != _originalPreference;

  void _remove(String key, Map<String, LocalMusicAlbum> albums) {
    setState(() {
      _keys.remove(key);
      if (_preferred == key) {
        _preferred = _keys.where(albums.containsKey).firstOrNull ?? _keys.first;
      }
    });
  }

  Future<void> _save() async {
    if (!widget.isCurrent() || _saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    var saved = false;
    try {
      saved = await widget.library.saveAlbumEditionGroup(
        previous: widget.group,
        albumKeys: List.of(_keys),
        preferredKey: _preferred,
        isCurrent: () => mounted && widget.isCurrent(),
      );
    } on Exception {
      // Keep the draft available if persisting the group fails.
    } on StateError {
      // The profile may have been deleted while the write was queued.
    }
    if (!mounted) return;
    if (saved && widget.isCurrent()) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _saveFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        final current = widget.isCurrent();
        final albums = current
            ? {
                for (final album
                    in groupLocalMusicAlbums(widget.library.visibleTracks))
                  album.key: album,
              }
            : const <String, LocalMusicAlbum>{};
        final groupedElsewhere = current
            ? {
                for (final group in widget.library.albumEditionGroups)
                  if (group != widget.group) ...group.albumKeys,
              }
            : const <String>{};
        final candidates = albums.values
            .where((album) =>
                !_keys.contains(album.key) &&
                !groupedElsewhere.contains(album.key))
            .toList()
          ..sort((first, second) {
            final title =
                first.title.toLowerCase().compareTo(second.title.toLowerCase());
            return title == 0 ? first.key.compareTo(second.key) : title;
          });
        final savedKeys = widget.group?.albumKeys ?? const <String>[];
        final maySave = !_saving &&
            _dirty &&
            _keys.every(
                (key) => savedKeys.contains(key) || albums.containsKey(key)) &&
            (_keys.length < 2 ||
                _preferred == widget.group?.preferredKey ||
                albums.containsKey(_preferred));
        return PopScope(
          canPop: !_saving,
          child: AlertDialog(
            title: Text(_adding
                ? locals.localMusicAddEdition
                : locals.localMusicManageEditions),
            content: SizedBox(
              width: 480,
              child: !current
                  ? Text(locals.musicSourceUnavailable)
                  : _adding
                      ? _buildPicker(locals, candidates)
                      : _buildGroup(locals, albums, candidates.isNotEmpty),
            ),
            actions: [
              TextButton(
                onPressed: _saving
                    ? null
                    : _adding && current
                        ? () => setState(() => _adding = false)
                        : () => Navigator.of(context).pop(),
                child: Text(locals.cancel),
              ),
              if (current && !_adding)
                FilledButton(
                  onPressed: maySave ? _save : null,
                  child: Text(locals.save),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGroup(
    AppLocalizations locals,
    Map<String, LocalMusicAlbum> albums,
    bool canAdd,
  ) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(locals.localMusicChoosePreferredEdition),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final key in _keys) _editionTile(locals, key, albums),
              ],
            ),
          ),
          Wrap(children: [
            if (canAdd)
              TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => setState(() {
                          _query = '';
                          _adding = true;
                        }),
                icon: const Icon(Icons.add),
                label: Text(locals.localMusicAddEdition),
              ),
            if (_keys.length > 1)
              TextButton(
                onPressed: _saving
                    ? null
                    : () => setState(() {
                          _keys = [widget.anchorKey];
                          _preferred = widget.anchorKey;
                        }),
                child: Text(locals.localMusicUngroupEditions),
              ),
          ]),
          if (_saveFailed) Text(locals.localMusicEditionsSaveFailed),
        ],
      );

  Widget _editionTile(AppLocalizations locals, String key,
      Map<String, LocalMusicAlbum> albums) {
    final album = albums[key];
    final selected = key == _preferred;
    return ListTile(
      key: ValueKey(key),
      autofocus: isTv && key == widget.anchorKey,
      selected: selected,
      leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(album?.title ?? locals.localMusicUnavailableEdition),
      subtitle: Text([
        if (album != null)
          localMusicAlbumDetails(locals, widget.library, album,
              includeLocation: true),
        if (selected) locals.localMusicPreferredEdition,
      ].join(' · ')),
      onTap: _saving || album == null
          ? null
          : () => setState(() => _preferred = key),
      trailing: Wrap(children: [
        if (album != null && !_dirty)
          IconButton(
            tooltip: locals.localMusicOpenEdition,
            icon: const Icon(Icons.open_in_new),
            onPressed: () {
              if (widget.isCurrent()) Navigator.of(context).pop(key);
            },
          ),
        if (_keys.length > 1)
          IconButton(
            tooltip: locals.localMusicRemoveEdition,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _saving ? null : () => _remove(key, albums),
          ),
      ]),
    );
  }

  Widget _buildPicker(
      AppLocalizations locals, List<LocalMusicAlbum> candidates) {
    final entries = [
      for (final album in candidates)
        (
          album: album,
          details: localMusicAlbumDetails(locals, widget.library, album,
              includeLocation: true),
        ),
    ]
        .where((entry) => '${entry.album.title} ${entry.details}'
            .toLowerCase()
            .contains(_query))
        .toList();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(
        decoration: InputDecoration(
          labelText: locals.localMusicFindEdition,
          prefixIcon: const Icon(Icons.search),
        ),
        onChanged: (value) =>
            setState(() => _query = value.trim().toLowerCase()),
      ),
      Flexible(
        child: entries.isEmpty
            ? ListTile(title: Text(locals.musicNoResults))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return ListTile(
                    key: ValueKey(entry.album.key),
                    autofocus: isTv && index == 0,
                    title: Text(entry.album.title),
                    subtitle: Text(entry.details),
                    onTap: () => setState(() {
                      _keys.add(entry.album.key);
                      _adding = false;
                    }),
                  );
                },
              ),
      ),
    ]);
  }
}

String localMusicAlbumDetails(
  AppLocalizations locals,
  LocalMusicLibrary library,
  LocalMusicAlbum album, {
  required bool includeLocation,
}) {
  final first = album.tracks.first;
  final folders = first.folderLocations;
  final lastFolder = folders.lastOrNull;
  final commonFolder = includeLocation &&
      lastFolder != null &&
      album.tracks.every(
          (track) => track.folderLocations.lastOrNull?.key == lastFolder.key);
  final source =
      library.roots.where((root) => root.uri == first.sourceUri).firstOrNull;
  return [
    album.albumArtist,
    album.releaseDate,
    if (includeLocation) ...[
      if (!commonFolder || source?.name != folders.firstOrNull?.label)
        source?.name,
      if (commonFolder)
        folders.map((folder) => folder.label).join(' / ')
      else
        first.fileName,
    ],
    locals.musicTrackCount(album.tracks.length),
  ].nonNulls.join(' · ');
}
