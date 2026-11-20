import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../player/states/player.dart';
import '../../../settings/models/db/settings.dart';
import '../../../settings/states/settings.dart';
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';
import '../screens/music.dart';

bool get supportsLocalMusicFolders =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The Settings switch and Library page share the active device music source.
class LocalMusicFolder extends StatefulWidget {
  const LocalMusicFolder.settings({super.key, this.library}) : _settings = true;
  const LocalMusicFolder.library({super.key, this.library}) : _settings = false;

  final LocalMusicLibrary? library;
  final bool _settings;

  @override
  State<LocalMusicFolder> createState() => _LocalMusicFolderState();
}

class _LocalMusicFolderState extends State<LocalMusicFolder> {
  static const _sortSetting = 'local-music-sort';

  LocalMusicLibrary get _library =>
      widget.library ?? LocalMusicLibrary.instance;
  bool _ready = false;
  bool? _routeCurrent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current && _routeCurrent == false) {
      // A covered library route stays mounted while Settings or Now Playing is open.
      _load();
    }
    _routeCurrent = current;
  }

  Future<void> _load() async {
    await _library.initialize();
    if (!mounted) return;
    await _library.revalidate();
    if (!mounted) return;
    setState(() => _ready = true);
    if (!widget._settings &&
        _library.enabled &&
        !_library.unavailable &&
        !_library.loaded) {
      await _library.refresh();
    }
  }

  Future<void> _play(List<LocalMusicTrack> tracks, int index) async {
    try {
      await MusicScreen.playLocalTracks(context, tracks, startIndex: index);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  Future<void> _enqueue(LocalMusicTrack track, {required bool next}) async {
    final player = context.read<PlayerCubit?>();
    if (player == null) {
      if (isTv) await _play([track], 0);
      return;
    }

    if (player.isOtherPlaybackSession) {
      final selection = _library.selectionId;
      final current = player.state.currentQueueId;
      final locals = AppLocalizations.of(context)!;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => _withSelectKeys(AlertDialog(
                title: Text(locals.localMusicStartQueue),
                content: Text(locals.localMusicReplaceQueue),
                actions: [
                  TextButton(
                      autofocus: isTv,
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(locals.cancel)),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(locals.localMusicStartQueue)),
                ],
              )));
      if (!mounted ||
          confirmed != true ||
          player.isClosed ||
          player.state.currentQueueId != current ||
          !_library.acceptsSessionSelection(selection)) {
        return;
      }
      final updated = _library.trackById(track.playbackId);
      if (updated != null) await _play([updated], 0);
      return;
    }

    if (isTv && !player.isLocalMusicSession) {
      await _play([track], 0);
    } else {
      await player.enqueueLocalMusic(track, playNext: next);
    }
  }

  Future<void> _rename(LocalMusicTrack track) async {
    final fileName = track.fileName;
    if (fileName == null || _library.busy) return;
    final selection = _library.selectionId;
    final name = await showDialog<String>(
        context: context,
        builder: (context) => _withSelectKeys(
            _RenameLocalFile(track: track, fileName: fileName)));
    if (!mounted ||
        name == null ||
        name == fileName ||
        !_library.acceptsSessionSelection(selection)) {
      return;
    }
    final renamed = await _library.renameTrack(track, name);
    if (!mounted || renamed) return;
    final locals = AppLocalizations.of(context)!;
    final message = switch (_library.error) {
      'RENAME_COLLISION' => locals.localMusicRenameConflict,
      'RENAME_INVALID_NAME' => locals.localMusicRenameInvalid,
      'RENAME_UNSUPPORTED' => locals.localMusicRenameUnsupported,
      'RENAME_FAILED' ||
      'RENAME_CHANGED' ||
      'RENAME_ACCESS' =>
        locals.localMusicRenameError,
      _ => null,
    };
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _chooseSort(_LocalMusicSort sort,
      {required bool hasFirstSeen}) async {
    final settings = context.read<SettingsCubit>();
    final choice = await showModalBottomSheet<_LocalMusicSort>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => _withSelectKeys(
            _LocalMusicSortSheet(sort: sort, hasFirstSeen: hasFirstSeen)));
    if (choice == null || choice == sort || !mounted || settings.isClosed) {
      return;
    }
    try {
      await settings.saveSetting(SettingsValue(_sortSetting, choice.value));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(AppLocalizations.of(context)!.musicLibraryActionError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final savedSort = context.select(
        (SettingsCubit? settings) => settings?.state.settings[_sortSetting]);
    final canSort = context.read<SettingsCubit?>() != null;
    final sort = _LocalMusicSort.fromValue(savedSort?.value);
    return _withSelectKeys(ListenableBuilder(
        listenable: _library,
        builder: (context, _) {
          final sourceAvailable = _ready && !_library.busy;
          final enabled = _library.enabled;
          final system = _library.isSystem;
          final name =
              system ? locals.localMusicAndroidLibrary : _library.folderName;
          final status = _sourceStatus(locals);
          if (widget._settings) {
            return _buildSettings(locals,
                sourceAvailable: sourceAvailable, name: name, status: status);
          }

          final tracks = _ready && enabled && !_library.unavailable
              ? sort.order(_library.tracks)
              : const <LocalMusicTrack>[];
          final trackIndexes = {
            for (final (index, track) in tracks.indexed)
              ValueKey(track.playbackId): index,
          };
          final showEmpty = enabled &&
              _library.loaded &&
              tracks.isEmpty &&
              sourceAvailable &&
              !_library.unavailable;
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (enabled) ...[
                      ListTile(
                        leading: Icon(system
                            ? Icons.library_music_outlined
                            : Icons.folder_outlined),
                        title: Text(name ?? locals.onDevice),
                        trailing:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                              tooltip: locals.searchSortBy,
                              icon: const Icon(Icons.sort),
                              onPressed: tracks.isEmpty || !canSort
                                  ? null
                                  : () => _chooseSort(sort,
                                      hasFirstSeen: tracks
                                          .any((track) => track.firstSeen))),
                          IconButton(
                            tooltip: locals.refresh,
                            icon: const Icon(Icons.refresh),
                            onPressed: sourceAvailable && !_library.unavailable
                                ? _library.refresh
                                : null,
                          ),
                        ]),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Wrap(children: [
                          TextButton.icon(
                            onPressed:
                                sourceAvailable ? _library.chooseFolder : null,
                            icon: const Icon(Icons.folder_open),
                            label: Text(system || _library.unavailable
                                ? locals.localMusicChooseFolder
                                : locals.localMusicChangeFolder),
                          ),
                          if (!system || _library.unavailable)
                            TextButton.icon(
                              onPressed: sourceAvailable
                                  ? _library.chooseSystem
                                  : null,
                              icon: const Icon(Icons.library_music_outlined),
                              label: Text(locals.localMusicUseAndroidLibrary),
                            ),
                          TextButton(
                            onPressed: _ready ? _library.disable : null,
                            child: Text(system
                                ? locals.localMusicForgetAndroidLibrary
                                : locals.localMusicForgetFolder),
                          ),
                        ]),
                      ),
                    ] else ...[
                      ListTile(
                        leading: const Icon(Icons.folder_open),
                        title: Text(locals.localMusicChooseFolder),
                        subtitle: Text(locals.localMusicFolderAccess),
                        onTap: sourceAvailable ? _library.chooseFolder : null,
                      ),
                      ListTile(
                        leading: const Icon(Icons.library_music_outlined),
                        title: Text(locals.localMusicUseAndroidLibrary),
                        subtitle: Text(locals.localMusicAndroidLibraryAccess),
                        onTap: sourceAvailable ? _library.chooseSystem : null,
                      ),
                    ],
                    if (!sourceAvailable) const LinearProgressIndicator(),
                    if (status != null || showEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(status ??
                            (system
                                ? locals.localMusicAndroidLibraryEmpty
                                : locals.localMusicFolderEmpty)),
                      ),
                  ]),
            ),
            SliverList.builder(
              itemCount: tracks.length,
              findChildIndexCallback: (key) => trackIndexes[key],
              itemBuilder: (context, index) => _buildTrack(
                  context, tracks[index], sort, () => _play(tracks, index)),
            ),
          ]);
        }));
  }

  String? _sourceStatus(AppLocalizations locals) {
    if (_library.unavailable) {
      return _library.isSystem
          ? locals.localMusicAndroidLibraryUnavailable
          : locals.localMusicFolderUnavailable;
    }
    return switch (_library.error) {
      'AUDIO_PERMISSION_DENIED' => locals.localMusicAndroidLibraryUnavailable,
      'PICKER_UNAVAILABLE' => locals.localMusicPickerUnavailable,
      'RENAME_FAILED' ||
      'RENAME_CHANGED' ||
      'RENAME_ACCESS' ||
      'RENAME_INVALID_NAME' ||
      'RENAME_UNSUPPORTED' ||
      'RENAME_COLLISION' ||
      'SCAN_CANCELLED' ||
      null =>
        null,
      _ => _library.isSystem
          ? locals.localMusicAndroidLibraryError
          : locals.localMusicFolderError,
    };
  }

  Widget _buildSettings(AppLocalizations locals,
      {required bool sourceAvailable, String? name, String? status}) {
    final toggle = SwitchListTile(
        key: const ValueKey('local-music-setting'),
        secondary: const Icon(Icons.library_music_outlined),
        title: Text(locals.localMusicSetting),
        subtitle: Text(status ?? name ?? locals.localMusicFolderAccess),
        value: _library.enabled,
        onChanged: _ready && (_library.enabled || sourceAvailable)
            ? (enabled) async {
                if (enabled) {
                  await _library.chooseFolder();
                } else {
                  await _library.disable();
                }
              }
            : null);
    if (!_library.unavailable) return toggle;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      toggle,
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 16),
        child: TextButton(
          onPressed: sourceAvailable
              ? (_library.isSystem
                  ? _library.chooseSystem
                  : _library.chooseFolder)
              : null,
          child: Text(_library.isSystem
              ? locals.localMusicUseAndroidLibrary
              : locals.localMusicChooseFolder),
        ),
      ),
    ]);
  }

  Widget _buildTrack(BuildContext context, LocalMusicTrack track,
      _LocalMusicSort sort, VoidCallback play) {
    final locals = AppLocalizations.of(context)!;
    final date = switch (sort.field) {
      _SortField.dateAdded => track.dateAdded,
      _SortField.dateModified => track.dateModified,
      _ => null,
    };
    final dateLabel = sort.field == _SortField.dateAdded && track.firstSeen
        ? locals.localMusicFirstSeen
        : sort.field.label(locals);
    final description = [
      track.artist,
      track.album,
      if (date != null)
        '$dateLabel · ${MaterialLocalizations.of(context).formatMediumDate(date.toLocal())}',
    ].nonNulls.where((s) => s.isNotEmpty).join(' • ');
    const placeholder = Icon(Icons.music_note_outlined);
    return ListTile(
      key: ValueKey(track.playbackId),
      leading: SizedBox.square(
        dimension: 48,
        child: track.artPath == null
            ? placeholder
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(File(track.artPath!),
                    fit: BoxFit.cover,
                    cacheWidth: 144,
                    errorBuilder: (_, __, ___) => placeholder),
              ),
      ),
      title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: description.isEmpty
          ? null
          : Text(description,
              maxLines: date == null ? 1 : 2, overflow: TextOverflow.ellipsis),
      onTap: play,
      trailing: PopupMenuButton<_TrackAction>(
        tooltip: locals.localMusicSongActions(track.title),
        onSelected: (action) async {
          try {
            switch (action) {
              case _TrackAction.playNext:
                await _enqueue(track, next: true);
              case _TrackAction.addToQueue:
                await _enqueue(track, next: false);
              case _TrackAction.rename:
                await _rename(track);
            }
          } catch (_) {
            if (!mounted) return;
            ScaffoldMessenger.of(this.context).showSnackBar(
                SnackBar(content: Text(locals.musicLibraryActionError)));
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
              value: _TrackAction.playNext,
              child: _withSelectKeys(Text(locals.playNext))),
          PopupMenuItem(
              value: _TrackAction.addToQueue,
              child: _withSelectKeys(Text(locals.addToQueueList))),
          if (track.canRename && track.fileName != null)
            PopupMenuItem(
                value: _TrackAction.rename,
                enabled: !_library.busy,
                child: _withSelectKeys(Text(locals.localMusicRename))),
        ],
      ),
    );
  }
}

Widget _withSelectKeys(Widget child) => Shortcuts(shortcuts: {
      for (final key in selectKeys)
        SingleActivator(key): const ActivateIntent(),
    }, child: child);

enum _TrackAction { playNext, addToQueue, rename }

enum _SortField {
  title,
  artist,
  album,
  dateAdded,
  dateModified;

  String label(AppLocalizations locals) => switch (this) {
        title => locals.musicLibraryTitleOrder,
        artist => locals.localMusicSortArtist,
        album => locals.localMusicSortAlbum,
        dateAdded => locals.localMusicSortDateAdded,
        dateModified => locals.localMusicSortDateModified,
      };
}

class _LocalMusicSort {
  const _LocalMusicSort(this.field, this.descending);

  factory _LocalMusicSort.fromValue(String? value) {
    final parts = value?.split(':');
    final field = _SortField.values.firstWhere(
        (field) => field.name == parts?.first,
        orElse: () => _SortField.title);
    return _LocalMusicSort(field, parts?.last == 'descending');
  }

  final _SortField field;
  final bool descending;

  String get value =>
      '${field.name}:${descending ? 'descending' : 'ascending'}';

  List<LocalMusicTrack> order(List<LocalMusicTrack> tracks) =>
      [...tracks]..sort(_compare);

  int _compare(LocalMusicTrack a, LocalMusicTrack b) {
    final comparison = switch (field) {
      _SortField.title => _compareText(a.title, b.title),
      _SortField.artist => _compareText(a.artist, b.artist),
      _SortField.album => _compareText(a.album, b.album),
      _SortField.dateAdded => _compareValue(a.dateAdded, b.dateAdded),
      _SortField.dateModified => _compareValue(a.dateModified, b.dateModified),
    };
    if (comparison != 0) return comparison;
    final title = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return title != 0 ? title : a.playbackId.compareTo(b.playbackId);
  }

  int _compareText(String? first, String? second) {
    final a = first?.trim().toLowerCase();
    final b = second?.trim().toLowerCase();
    return _compareValue(a == '' ? null : a, b == '' ? null : b);
  }

  int _compareValue<T extends Comparable<T>>(T? a, T? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return descending ? b.compareTo(a) : a.compareTo(b);
  }
}

class _LocalMusicSortSheet extends StatefulWidget {
  const _LocalMusicSortSheet({required this.sort, required this.hasFirstSeen});

  final _LocalMusicSort sort;
  final bool hasFirstSeen;

  @override
  State<_LocalMusicSortSheet> createState() => _LocalMusicSortSheetState();
}

class _LocalMusicSortSheetState extends State<_LocalMusicSortSheet> {
  late _LocalMusicSort _sort = widget.sort;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final heading = Theme.of(context).textTheme.titleLarge;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .9),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(locals.searchSortBy, style: heading),
              for (final field in _SortField.values)
                ListTile(
                  selected: field == _sort.field,
                  autofocus: isTv && field == widget.sort.field,
                  title: Text(field.label(locals)),
                  subtitle: field == _SortField.dateAdded && widget.hasFirstSeen
                      ? Text(locals.localMusicFirstSeenHelp)
                      : null,
                  trailing:
                      field == _sort.field ? const Icon(Icons.check) : null,
                  onTap: () => setState(
                      () => _sort = _LocalMusicSort(field, _sort.descending)),
                ),
              Text(locals.localMusicSortDirection, style: heading),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: Text(locals.localMusicAscending),
                    selected: !_sort.descending,
                    onSelected: (_) => setState(
                        () => _sort = _LocalMusicSort(_sort.field, false))),
                ChoiceChip(
                    label: Text(locals.localMusicDescending),
                    selected: _sort.descending,
                    onSelected: (_) => setState(
                        () => _sort = _LocalMusicSort(_sort.field, true))),
              ]),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(locals.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(context, _sort),
                    child: Text(locals.ok)),
              ])
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameLocalFile extends StatefulWidget {
  const _RenameLocalFile({required this.track, required this.fileName});

  final LocalMusicTrack track;
  final String fileName;

  @override
  State<_RenameLocalFile> createState() => _RenameLocalFileState();
}

class _RenameLocalFileState extends State<_RenameLocalFile> {
  final _form = GlobalKey<FormState>();
  late final _dot = widget.fileName.lastIndexOf('.');
  late final _extension = _dot > 0 ? widget.fileName.substring(_dot) : '';
  late final _base =
      _dot > 0 ? widget.fileName.substring(0, _dot) : widget.fileName;
  late final _text = TextEditingController(text: _base);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, '${_text.text.trim()}$_extension');
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(locals.localMusicRename),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.track.title != _base) Text(widget.track.title),
            TextFormField(
              controller: _text,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: locals.localMusicFileName, suffixText: _extension),
              validator: (value) {
                final name = value?.trim() ?? '';
                if (name.isEmpty ||
                    name == '.' ||
                    name == '..' ||
                    name.contains(RegExp(r'[/\\\x00-\x1f]'))) {
                  return locals.localMusicRenameInvalid;
                }
                return null;
              },
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(locals.cancel)),
        FilledButton(onPressed: _submit, child: Text(locals.save)),
      ],
    );
  }
}
