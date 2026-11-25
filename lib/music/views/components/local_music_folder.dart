import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../player/states/player.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../settings/models/db/settings.dart';
import '../../../settings/states/settings.dart';
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_browse.dart';
import '../../models/local_music_track.dart';
import '../../models/music_search_text.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/local_music_library.dart';
import '../../services/on_device_music_downloads.dart';
import '../screens/music.dart';
import '../screens/music_device_artist.dart';
import 'local_music_albums.dart';
import 'local_music_exclusions.dart';
import 'local_music_locations.dart';
import 'local_music_summary.dart';

bool get supportsLocalMusicFolders =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Renames a file still owned by the selected device library.
Future<void> renameLocalMusicTrack(
    BuildContext context, LocalMusicLibrary library, LocalMusicTrack track,
    {bool inPlayer = false, bool Function()? isCurrent}) async {
  final fileName = track.fileName;
  final selection = library.selectionId;
  bool canRename() {
    final current = library.trackById(track.playbackId);
    return !library.busy &&
        library.acceptsSessionSelection(selection) &&
        current != null &&
        current.canRename &&
        current.uri == track.uri &&
        current.fileName == fileName &&
        (isCurrent?.call() ?? true);
  }

  if (!context.mounted || fileName == null || !canRename()) return;
  final name = await showDialog<String>(
      context: context,
      useRootNavigator: !inPlayer,
      builder: (_) {
        final dialog =
            _withSelectKeys(_RenameLocalFile(track: track, fileName: fileName));
        return inPlayer
            ? PlayerModalBackHandler(priority: 5, child: dialog)
            : dialog;
      });
  if (!context.mounted || name == null || name == fileName || !canRename()) {
    return;
  }
  final renamed = await library.renameTrack(track, name);
  if (!context.mounted ||
      renamed ||
      !library.acceptsSessionSelection(selection) ||
      !(isCurrent?.call() ?? true)) {
    return;
  }
  final locals = AppLocalizations.of(context)!;
  final message = switch (library.error) {
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

/// The Settings switch and Library page share the active device music source.
class LocalMusicFolder extends StatefulWidget {
  const LocalMusicFolder.settings({super.key, this.library})
      : downloads = null,
        _settings = true;
  const LocalMusicFolder.library({super.key, this.library, this.downloads})
      : _settings = false;

  final LocalMusicLibrary? library;
  final OnDeviceMusicDownloads? downloads;
  final bool _settings;

  @override
  State<LocalMusicFolder> createState() => _LocalMusicFolderState();
}

class _LocalMusicFolderState extends State<LocalMusicFolder>
    with WidgetsBindingObserver {
  static const _sortSetting = 'local-music-sort';

  LocalMusicLibrary get _library =>
      widget.library ?? LocalMusicLibrary.instance;
  late final OnDeviceMusicDownloads _downloads =
      widget.downloads ?? OnDeviceMusicDownloads();
  DownloadManagerCubit? _manager;
  StreamSubscription<DownloadManagerState>? _downloadUpdates;
  List<DownloadedVideo> _lastCandidates = const [];
  Object? _lastDownloadOwner;
  Object? _lastDeviceSource;
  List<LocalMusicTrack>? _lastDeviceTracks;
  bool _wasScanning = false;
  bool _ready = false;
  bool? _routeCurrent;

  @override
  void initState() {
    super.initState();
    if (!widget._settings) {
      _library.addListener(_deviceCatalogChanged);
      WidgetsBinding.instance.addObserver(this);
    }
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget._settings) {
      final manager = context.read<DownloadManagerCubit?>();
      if (!identical(_manager, manager)) {
        unawaited(_downloadUpdates?.cancel());
        _manager = manager;
        _downloadUpdates = manager?.stream.listen((_) => _refreshDownloads());
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _refreshDownloads(recheck: true);
        });
      }
    }
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current && _routeCurrent == false) {
      // A covered library route stays mounted while Settings or Now Playing is open.
      _load(recheckDownloads: true);
    }
    _routeCurrent = current;
  }

  Future<void> _load({bool recheckDownloads = false}) async {
    await _library.initialize();
    if (!mounted) return;
    await _library.revalidate();
    if (!mounted) return;
    setState(() => _ready = true);
    if (recheckDownloads) _refreshDownloads(recheck: true);
    if (!widget._settings &&
        _library.enabled &&
        !_library.unavailable &&
        !_library.loaded) {
      await _library.refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshDownloads(recheck: true);
  }

  void _deviceCatalogChanged() {
    final source = (
      _library.selectionId,
      _library.folderName,
      _library.enabled,
      _library.unavailable
    );
    final scanning = _library.scanning;
    final recheck = source != _lastDeviceSource ||
        (!scanning &&
            (_wasScanning || !identical(_lastDeviceTracks, _library.tracks)));
    _lastDeviceSource = source;
    if (!scanning) _lastDeviceTracks = _library.tracks;
    _wasScanning = scanning;
    _refreshDownloads(recheck: recheck);
  }

  void _refreshDownloads({bool recheck = false}) {
    final manager = _manager;
    if (!mounted || manager == null || manager.isClosed) return;
    final profile = db.profileId;
    final owner = (_library.visibilityProfile, profile);
    final candidates = [
      for (final file in manager.state.videos)
        if (file.profileId == profile &&
            file.audioOnly &&
            file.musicMetadata != null &&
            file.downloadComplete &&
            !file.downloadFailed &&
            !file.storageFailed &&
            !file.authenticationRequired)
          file,
    ];
    if (!recheck &&
        owner == _lastDownloadOwner &&
        listEquals(candidates, _lastCandidates)) {
      return;
    }
    _lastDownloadOwner = owner;
    _lastCandidates = candidates;
    unawaited(_downloads.refresh(_library, profile, candidates));
  }

  List<OnDeviceMusicEntry> _currentEntries() {
    if (_manager != null) return _downloads.entries(_library, db.profileId);
    return [
      if (_library.enabled && !_library.unavailable)
        for (final track in _library.visibleTracks)
          OnDeviceMusicEntry.device(track),
    ];
  }

  Future<void> _refreshSource() async {
    if (_library.enabled && !_library.unavailable) {
      await _library.refresh();
    } else {
      _refreshDownloads(recheck: true);
    }
  }

  @override
  void dispose() {
    if (!widget._settings) {
      _library.removeListener(_deviceCatalogChanged);
      WidgetsBinding.instance.removeObserver(this);
      unawaited(_downloadUpdates?.cancel());
      if (widget.downloads == null) _downloads.dispose();
    }
    super.dispose();
  }

  Map<String, OnDeviceMusicEntry> _entriesById() =>
      {for (final row in _currentEntries()) row.id: row};

  Future<void> _play(List<OnDeviceMusicEntry> entries, int index) async {
    final requested = entries[index].id;
    final current = _entriesById();
    final visible = [
      for (final entry in entries)
        if (current[entry.id] case final row?) row,
    ];
    final startIndex = visible.indexWhere((entry) => entry.id == requested);
    if (startIndex < 0) return;
    try {
      final locals = AppLocalizations.of(context)!;
      if (visible.every((entry) => entry.deviceTrack != null)) {
        final source = _library.roots.length > 1
            ? locals.onDevice
            : _library.isSystem
                ? locals.localMusicAndroidLibrary
                : _library.folderName;
        await MusicScreen.playLocalTracks(
            context, visible.map((entry) => entry.deviceTrack!).toList(),
            startIndex: startIndex, queueTitle: source);
      } else {
        final profile = _library.visibilityProfile;
        final selection = _library.selectionId;
        final requiresSource =
            visible.any((entry) => entry.deviceTrack != null);
        await MusicScreen.playOnDeviceTracks(context, visible,
            startIndex: startIndex,
            queueTitle: locals.onDevice,
            isCurrent: () =>
                mounted &&
                _library.visibilityProfile == profile &&
                (!requiresSource ||
                    _library.acceptsSessionSelection(selection)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  Future<void> _enqueue(OnDeviceMusicEntry requested,
      {required bool next}) async {
    final entry = _entriesById()[requested.id];
    if (entry == null) return;
    final player = context.read<PlayerCubit?>();
    if (player == null) {
      if (isTv) await _play([entry], 0);
      return;
    }

    final selection = _library.selectionId;
    final profile = _library.visibilityProfile;
    bool currentSource() =>
        mounted &&
        _library.visibilityProfile == profile &&
        (entry.deviceTrack == null ||
            _library.acceptsSessionSelection(selection));
    if ((entry.download != null || player.state.offlineVideos.isNotEmpty) &&
        player.canEnqueueOnDeviceMusic([entry])) {
      await player
          .enqueueOnDeviceMusic([entry], next: next, isCurrent: currentSource);
      return;
    }

    if (player.isOtherPlaybackSession) {
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
          !currentSource()) {
        return;
      }
      await _play([entry], 0);
      return;
    }

    if (isTv && !player.isLocalMusicSession || entry.download != null) {
      await _play([entry], 0);
    } else if (entry.deviceTrack case final track?) {
      await player.enqueueLocalMusic(track, playNext: next);
    }
  }

  Future<void> _chooseSort(LocalMusicTrackSort sort,
      {required bool hasFirstSeen}) async {
    final settings = context.read<SettingsCubit>();
    final choice = await showModalBottomSheet<LocalMusicTrackSort>(
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

  Future<void> _hide(LocalMusicTrack track) async {
    final library = _library;
    final profile = library.visibilityProfile;
    final messenger = ScaffoldMessenger.of(context);
    final locals = AppLocalizations.of(context)!;
    final hidden = await library.hideTrack(track,
        storageProof: _downloads.aliasProof(track));
    if (!mounted ||
        !messenger.mounted ||
        library.visibilityProfile != profile) {
      return;
    }
    if (hidden == null) {
      messenger
          .showSnackBar(SnackBar(content: Text(locals.localMusicHideError)));
      return;
    }

    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(locals.localMusicFileHidden(hidden.title)),
        action: SnackBarAction(
          label: locals.localMusicUndoHide,
          onPressed: () => _restore(library, hidden, profile, messenger),
        ),
      ));
  }

  Future<void> _restore(LocalMusicLibrary library, HiddenLocalMusicTrack hidden,
      Object? profile, ScaffoldMessengerState messenger) async {
    if (library.visibilityProfile != profile) return;
    try {
      await library.restoreTrack(hidden);
    } catch (_) {
      if (!messenger.mounted || library.visibilityProfile != profile) return;
      final locals = AppLocalizations.of(messenger.context)!;
      messenger
          .showSnackBar(SnackBar(content: Text(locals.localMusicRestoreError)));
    }
  }

  Future<void> _showHiddenFiles() async {
    final library = _library;
    final profile = library.visibilityProfile;
    final messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _withSelectKeys(ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final locals = AppLocalizations.of(context)!;
          final files = library.visibilityProfile == profile
              ? library.hiddenTracks
              : const <HiddenLocalMusicTrack>[];
          return SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                title: Semantics(
                    header: true,
                    child: Text(locals.localMusicHiddenFiles,
                        style: Theme.of(context).textTheme.titleLarge)),
                trailing: CloseButton(
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              if (files.isEmpty)
                ListTile(title: Text(locals.localMusicNoHiddenFiles))
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      final subtitle = [
                        file.artist,
                        if (file.fileName != file.title) file.fileName,
                      ]
                          .nonNulls
                          .where((value) => value.trim().isNotEmpty)
                          .join(' • ');
                      return ListTile(
                        key: ValueKey(file.id),
                        title: Text(file.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        isThreeLine: subtitle.isNotEmpty && !file.isAvailable,
                        subtitle: subtitle.isEmpty && file.isAvailable
                            ? null
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (subtitle.isNotEmpty)
                                    Text(subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                  if (!file.isAvailable)
                                    Text(
                                        locals.localMusicHiddenFileUnavailable),
                                ],
                              ),
                        trailing: Tooltip(
                          message:
                              locals.localMusicRestoreFileTooltip(file.title),
                          child: TextButton(
                            autofocus: isTv && index == 0,
                            onPressed: () =>
                                _restore(library, file, profile, messenger),
                            child: Text(locals.localMusicRestoreFile),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ]),
          );
        },
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final savedSort = context.select(
        (SettingsCubit? settings) => settings?.state.settings[_sortSetting]);
    final canSort = context.read<SettingsCubit?>() != null;
    final sort = LocalMusicTrackSort.fromValue(savedSort?.value);
    final catalogChanges =
        widget._settings ? _library : Listenable.merge([_library, _downloads]);
    return _withSelectKeys(ListenableBuilder(
        listenable: catalogChanges,
        builder: (context, _) {
          final sourceAvailable = _ready && !_library.busy;
          final enabled = _library.enabled;
          final system = _library.isSystem;
          final roots = _library.roots;
          final singleRoot = roots.length == 1 ? roots.single : null;
          final systemRoot = roots.where((root) => root.isSystem).firstOrNull;
          final reconnectFolder = singleRoot != null &&
                  !singleRoot.isSystem &&
                  _library.isRootUnavailable(singleRoot)
              ? singleRoot
              : null;
          final name = roots.length > 1
              ? locals.localMusicLocationCount(roots.length)
              : system
                  ? locals.localMusicAndroidLibrary
                  : _library.folderName;
          final status = localMusicSourceStatus(_library, locals);
          if (widget._settings) {
            return _buildSettings(locals,
                sourceAvailable: sourceAvailable, name: name, status: status);
          }

          final tracks = _ready
              ? sort.order(_currentEntries())
              : const <OnDeviceMusicEntry>[];
          final showEmpty = enabled &&
              _library.loaded &&
              tracks.isEmpty &&
              sourceAvailable &&
              !_library.unavailable;
          final canBrowse =
              _ready && (tracks.isNotEmpty || enabled && !_library.unavailable);
          final profile = _library.visibilityProfile;
          final selection = _library.selectionId;
          final controls = Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: locals.searchSortBy,
                icon: const Icon(Icons.sort),
                onPressed: tracks.isEmpty || !canSort
                    ? null
                    : () => _chooseSort(sort,
                        hasFirstSeen: tracks.any((track) => track.firstSeen))),
            IconButton(
              tooltip: locals.refresh,
              icon: const Icon(Icons.refresh),
              onPressed:
                  sourceAvailable && (!_library.unavailable || _manager != null)
                      ? _refreshSource
                      : null,
            ),
          ]);
          final hiddenFiles = _ready && _library.hiddenTracks.isNotEmpty
              ? TextButton.icon(
                  onPressed: _showHiddenFiles,
                  icon: const Icon(Icons.visibility_off_outlined),
                  label: Text(locals.localMusicHiddenFiles),
                )
              : null;
          final exclusions = TextButton.icon(
            onPressed: _ready
                ? () => showLocalMusicExclusions(context, _library)
                : null,
            icon: const Icon(Icons.filter_alt_outlined),
            label: Text(locals.localMusicExclusions),
          );
          return _LocalTrackBrowser(
            key: ValueKey(
                (profile, selection, name, system, _library.unavailable)),
            library: _library,
            catalogChanges: catalogChanges,
            currentEntries: _currentEntries,
            tracks: tracks,
            canBrowse: canBrowse,
            complete: !_library.scanning &&
                (!_library.enabled || _library.loaded) &&
                _library.error == null,
            row: (visible, index) => _buildTrack(context, visible[index], sort,
                profile, selection, () => _play(visible, index)),
            header:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (enabled) ...[
                ListTile(
                  leading: Icon(system
                      ? Icons.library_music_outlined
                      : Icons.folder_outlined),
                  title: Text(name ?? locals.onDevice),
                  trailing: controls,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(children: [
                    TextButton.icon(
                      onPressed: sourceAvailable
                          ? () =>
                              _library.chooseFolder(reconnect: reconnectFolder)
                          : null,
                      icon: const Icon(Icons.folder_open),
                      label: Text(reconnectFolder == null
                          ? locals.localMusicAddFolder
                          : locals.localMusicChooseFolder),
                    ),
                    if (systemRoot == null ||
                        _library.isRootUnavailable(systemRoot))
                      TextButton.icon(
                        onPressed:
                            sourceAvailable ? _library.chooseSystem : null,
                        icon: const Icon(Icons.library_music_outlined),
                        label: Text(locals.localMusicUseAndroidLibrary),
                      ),
                    if (singleRoot != null)
                      TextButton(
                        onPressed: _ready ? _library.disable : null,
                        child: Text(system
                            ? locals.localMusicForgetAndroidLibrary
                            : locals.localMusicForgetFolder),
                      ),
                    TextButton.icon(
                      onPressed: _ready
                          ? () => showLocalMusicLocations(context, _library)
                          : null,
                      icon: const Icon(Icons.folder_copy_outlined),
                      label: Text(locals.localMusicManageLocations),
                    ),
                    exclusions,
                    TextButton.icon(
                      onPressed: sourceAvailable && !_library.unavailable
                          ? () => showLocalMusicAlbums(context, _library)
                          : null,
                      icon: const Icon(Icons.album_outlined),
                      label: Text(locals.localMusicBrowseAlbums),
                    ),
                    if (hiddenFiles != null) hiddenFiles,
                    if (canBrowse && _library.visibleTracks.isNotEmpty)
                      TextButton.icon(
                        onPressed: () {
                          if (!_library.acceptsSessionSelection(selection)) {
                            return;
                          }
                          MusicScreen.openDeviceCollection(
                            context,
                            MusicDeviceArtistIndexPage(
                              selectionId: selection,
                              library: _library,
                            ),
                          );
                        },
                        icon: const Icon(Icons.people_outline),
                        label: Text(locals.localMusicBrowseArtists),
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(children: [
                    exclusions,
                    if (hiddenFiles != null) hiddenFiles,
                  ]),
                ),
                if (tracks.isNotEmpty || _lastCandidates.isNotEmpty)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: controls,
                  ),
              ],
              if (!sourceAvailable) const LinearProgressIndicator(),
              if (status != null || showEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(status ??
                      (_library.tracks.isNotEmpty
                          ? locals.localMusicNoVisibleFiles
                          : roots.length > 1
                              ? locals.localMusicLocationsEmpty
                              : system
                                  ? locals.localMusicAndroidLibraryEmpty
                                  : locals.localMusicFolderEmpty)),
                ),
            ]),
          );
        }));
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
    if (!_library.enabled) return toggle;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      toggle,
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 16),
        child: TextButton(
          onPressed:
              _ready ? () => showLocalMusicLocations(context, _library) : null,
          child: Text(locals.localMusicManageLocations),
        ),
      ),
    ]);
  }

  Widget _buildTrack(
      BuildContext context,
      OnDeviceMusicEntry entry,
      LocalMusicTrackSort sort,
      Object? profile,
      String? selection,
      VoidCallback play) {
    final locals = AppLocalizations.of(context)!;
    final track = entry.deviceTrack;
    bool currentSource() =>
        mounted &&
        _library.visibilityProfile == profile &&
        (track == null || _library.acceptsSessionSelection(selection));
    final date = switch (sort.field) {
      LocalMusicTrackSortField.dateAdded => entry.dateAdded,
      LocalMusicTrackSortField.dateModified => entry.dateModified,
      _ => null,
    };
    final dateLabel =
        sort.field == LocalMusicTrackSortField.dateAdded && entry.firstSeen
            ? locals.localMusicFirstSeen
            : sort.field.label(locals);
    final description = [
      if (entry.download != null) locals.localMusicDownloadedFile,
      entry.artist,
      entry.album,
      if (date != null)
        '$dateLabel · ${MaterialLocalizations.of(context).formatMediumDate(date.toLocal())}',
    ].nonNulls.where((s) => s.isNotEmpty).join(' • ');
    final placeholder = Icon(entry.download == null
        ? Icons.music_note_outlined
        : Icons.offline_pin_outlined);
    return ListTile(
      key: ValueKey(entry.id),
      leading: SizedBox.square(
        dimension: 48,
        child: track?.artPath == null
            ? placeholder
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(File(track!.artPath!),
                    fit: BoxFit.cover,
                    cacheWidth: 144,
                    errorBuilder: (_, __, ___) => placeholder),
              ),
      ),
      title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: description.isEmpty
          ? null
          : Text(description,
              maxLines: date == null ? 1 : 2, overflow: TextOverflow.ellipsis),
      onTap: () {
        if (currentSource()) play();
      },
      trailing: PopupMenuButton<_TrackAction>(
        tooltip: locals.localMusicSongActions(entry.title),
        onSelected: (action) async {
          if (!currentSource()) return;
          try {
            switch (action) {
              case _TrackAction.playNext:
                await _enqueue(entry, next: true);
              case _TrackAction.addToQueue:
                await _enqueue(entry, next: false);
              case _TrackAction.rename:
                if (track != null) {
                  await renameLocalMusicTrack(context, _library, track);
                }
              case _TrackAction.hide:
                if (track != null) await _hide(track);
              case _TrackAction.removeKeep:
                if (track != null) {
                  await updateLocalMusicExclusions(
                      this.context,
                      _library,
                      profile,
                      () => _library.setExclusionOverride(track, false));
                }
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
          if (track != null && track.canRename && track.fileName != null)
            PopupMenuItem(
                value: _TrackAction.rename,
                enabled: !_library.busy,
                child: _withSelectKeys(Text(locals.localMusicRename))),
          if (track != null && currentSource() && _library.canHideTrack(track))
            PopupMenuItem(
                value: _TrackAction.hide,
                child: _withSelectKeys(Text(locals.localMusicHideFile))),
          if (track != null &&
              currentSource() &&
              _library.hasExclusionOverride(track))
            PopupMenuItem(
                value: _TrackAction.removeKeep,
                child:
                    _withSelectKeys(Text(locals.localMusicRemoveKeepOverride))),
        ],
      ),
    );
  }
}

class _LocalTrackBrowser extends StatefulWidget {
  const _LocalTrackBrowser({
    super.key,
    required this.library,
    required this.catalogChanges,
    required this.currentEntries,
    required this.tracks,
    required this.canBrowse,
    required this.complete,
    required this.header,
    required this.row,
  });

  final LocalMusicLibrary library;
  final Listenable catalogChanges;
  final List<OnDeviceMusicEntry> Function() currentEntries;
  final List<OnDeviceMusicEntry> tracks;
  final bool canBrowse;
  final bool complete;
  final Widget header;
  final Widget Function(List<OnDeviceMusicEntry>, int) row;

  @override
  State<_LocalTrackBrowser> createState() => _LocalTrackBrowserState();
}

typedef _LocalAlbumFilter = ({String? key, String label});

bool _matchesAlbum(OnDeviceMusicEntry track, _LocalAlbumFilter album) {
  final key = track.deviceTrack?.albumKey;
  return album.key == null
      ? key == null && track.album?.trim() == album.label
      : key == album.key;
}

class _LocalTrackBrowserState extends State<_LocalTrackBrowser> {
  final _search = TextEditingController();
  // Scan updates replace immutable track objects. Updated tags get a fresh key.
  final _searchText = Expando<String>();
  String? _artist;
  _LocalAlbumFilter? _album;

  @override
  void didUpdateWidget(covariant _LocalTrackBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    final library = widget.library;
    // A partial or failed scan cannot establish that a tag has disappeared.
    if (library.enabled &&
        !library.unavailable &&
        (!library.loaded || library.scanning || library.error != null)) {
      return;
    }
    final artist = _artist;
    if (artist != null && !_hasArtist(artist)) {
      _artist = null;
      _album = null;
    } else if (_album case final album?) {
      final current = widget
          .currentEntries()
          .where(
              (track) => _matchesArtist(track) && _matchesAlbum(track, album))
          .firstOrNull;
      final title = current?.album?.trim();
      _album = title == null ? null : (key: album.key, label: title);
    }
  }

  bool _hasArtist(String credit) =>
      widget.currentEntries().any((track) => track.artist?.trim() == credit);

  bool _matchesArtist(OnDeviceMusicEntry track) =>
      _artist == null || track.artist?.trim() == _artist;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _chooseTag({required bool artist}) async {
    final library = widget.library;
    final selection = library.selectionId;
    final profile = library.visibilityProfile;
    final locals = AppLocalizations.of(context)!;
    final label =
        artist ? locals.localMusicSortArtist : locals.localMusicSortAlbum;
    final value = await showModalBottomSheet<_LocalAlbumFilter>(
      context: context,
      useSafeArea: true,
      builder: (context) => _withSelectKeys(ListenableBuilder(
        listenable: widget.catalogChanges,
        builder: (context, _) {
          final values = <Object, ({
            _LocalAlbumFilter filter,
            String? credit,
            List<String?> tags,
          })>{};
          if (library.visibilityProfile == profile &&
              library.selectionId == selection) {
            for (final track in widget.currentEntries()) {
              if (!artist && !_matchesArtist(track)) continue;
              final tag = (artist ? track.artist : track.album)?.trim();
              if (tag == null || tag.isEmpty) continue;
              final key = artist ? null : track.deviceTrack?.albumKey;
              final option = values.putIfAbsent(
                key ?? (label: tag),
                () => (
                  filter: (key: key, label: tag),
                  credit: key == null ? null : track.deviceTrack?.albumArtist,
                  tags: <String?>[],
                ),
              );
              option.tags.add(artist
                  ? track.deviceTrack?.artistSort
                  : track.deviceTrack?.albumSort);
            }
          }
          final sortNames = values.map((key, option) => MapEntry(
              key, localMusicGroupSortName(option.filter.label, option.tags)));
          final options = (values.entries.toList()
                ..sort((a, b) {
                  final byName = compareLocalMusicSortNames(
                      sortNames[a.key], sortNames[b.key]);
                  if (byName != 0) return byName;
                  final byLabel = a.value.filter.label.compareTo(
                      b.value.filter.label);
                  return byLabel != 0
                      ? byLabel
                      : (a.value.filter.key ?? '')
                          .compareTo(b.value.filter.key ?? '');
                }))
              .map((entry) => entry.value)
              .toList();
          return Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                title:
                    Text(label, style: Theme.of(context).textTheme.titleLarge)),
            if (options.isEmpty) ListTile(title: Text(locals.musicNoResults)),
            Flexible(
                child: ListView.builder(
              shrinkWrap: true,
              itemCount: options.length,
              itemBuilder: (context, index) {
                final option = options[index];
                return ListTile(
                    title: Text(option.filter.label),
                    subtitle:
                        option.credit == null ? null : Text(option.credit!),
                    selected: artist
                        ? option.filter.label == _artist
                        : option.filter == _album,
                    onTap: () => Navigator.of(context).pop(option.filter));
              },
            )),
          ]);
        },
      )),
    );
    if (!mounted ||
        value == null ||
        library.visibilityProfile != profile ||
        library.selectionId != selection ||
        !(artist
            ? _hasArtist(value.label)
            : widget.currentEntries().any((track) =>
                _matchesArtist(track) && _matchesAlbum(track, value)))) {
      return;
    }
    setState(() {
      if (artist) {
        if (_artist != value.label) _album = null;
        _artist = value.label;
      } else {
        _album = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final terms = musicSearchTerms(_search.text);
    final visible = terms.isEmpty && _artist == null && _album == null
        ? widget.tracks
        : widget.tracks.where((track) {
            if (!_matchesArtist(track)) return false;
            if (_album case final album? when !_matchesAlbum(track, album)) {
              return false;
            }
            if (terms.isEmpty) return true;
            final input = track.deviceTrack ?? track.download!;
            final text = _searchText[input] ??= normalizeMusicSearchText([
              track.title,
              track.fileName,
              track.artist,
              track.album,
              track.deviceTrack?.albumArtist,
            ].nonNulls.join(' '));
            return terms.every(text.contains);
          }).toList(growable: false);
    final indexes = {
      for (final (index, track) in visible.indexed) ValueKey(track.id): index
    };
    Widget tagFilter(String label, String? selected, {required bool artist}) =>
        InputChip(
          label: Text(selected == null ? label : '$label · $selected',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          selected: selected != null,
          onPressed: () => _chooseTag(artist: artist),
          onDeleted: selected == null
              ? null
              : () => setState(() {
                    if (artist) {
                      _artist = null;
                    } else {
                      _album = null;
                    }
                  }),
          deleteButtonTooltipMessage: material.clearButtonTooltip,
        );
    return CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(child: widget.header),
          if (widget.canBrowse &&
              (widget.tracks.isNotEmpty || _search.text.isNotEmpty))
            SliverToBoxAdapter(
                child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                          labelText: locals.search,
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: material.clearButtonTooltip,
                                  icon: const Icon(Icons.clear),
                                  onPressed: () => setState(_search.clear))),
                    ),
                    if (widget.tracks.isNotEmpty)
                      Wrap(spacing: 8, children: [
                        tagFilter(locals.localMusicSortArtist, _artist,
                            artist: true),
                        tagFilter(locals.localMusicSortAlbum, _album?.label,
                            artist: false),
                      ]),
                    if (visible.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: LocalMusicSummary(
                          totals: LocalMusicTotals.fromEntries(visible,
                              complete: widget.complete),
                        ),
                      ),
                    if (widget.tracks.isNotEmpty && visible.isEmpty)
                      Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(locals.musicNoResults)),
                  ]),
            )),
          SliverList.builder(
            itemCount: visible.length,
            findChildIndexCallback: (key) => indexes[key],
            itemBuilder: (context, index) => widget.row(visible, index),
          ),
        ]);
  }
}

Widget _withSelectKeys(Widget child) => Shortcuts(shortcuts: {
      for (final key in selectKeys)
        SingleActivator(key): const ActivateIntent(),
    }, child: child);

enum _TrackAction { playNext, addToQueue, rename, hide, removeKeep }

extension on LocalMusicTrackSortField {
  String label(AppLocalizations locals) => switch (this) {
        LocalMusicTrackSortField.title => locals.musicLibraryTitleOrder,
        LocalMusicTrackSortField.artist => locals.localMusicSortArtist,
        LocalMusicTrackSortField.album => locals.localMusicSortAlbum,
        LocalMusicTrackSortField.dateAdded => locals.localMusicSortDateAdded,
        LocalMusicTrackSortField.dateModified =>
          locals.localMusicSortDateModified,
        LocalMusicTrackSortField.duration => locals.searchDuration,
        LocalMusicTrackSortField.size => locals.localMusicFileSize,
      };
}

class _LocalMusicSortSheet extends StatefulWidget {
  const _LocalMusicSortSheet({required this.sort, required this.hasFirstSeen});

  final LocalMusicTrackSort sort;
  final bool hasFirstSeen;

  @override
  State<_LocalMusicSortSheet> createState() => _LocalMusicSortSheetState();
}

class _LocalMusicSortSheetState extends State<_LocalMusicSortSheet> {
  late LocalMusicTrackSort _sort = widget.sort;

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
              for (final field in LocalMusicTrackSortField.values)
                ListTile(
                  selected: field == _sort.field,
                  autofocus: isTv && field == widget.sort.field,
                  title: Text(field.label(locals)),
                  subtitle: field == LocalMusicTrackSortField.dateAdded &&
                          widget.hasFirstSeen
                      ? Text(locals.localMusicFirstSeenHelp)
                      : null,
                  trailing:
                      field == _sort.field ? const Icon(Icons.check) : null,
                  onTap: () => setState(() =>
                      _sort = LocalMusicTrackSort(field, _sort.descending)),
                ),
              Text(locals.localMusicSortDirection, style: heading),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: Text(locals.localMusicAscending),
                    selected: !_sort.descending,
                    onSelected: (_) => setState(
                        () => _sort = LocalMusicTrackSort(_sort.field, false))),
                ChoiceChip(
                    label: Text(locals.localMusicDescending),
                    selected: _sort.descending,
                    onSelected: (_) => setState(
                        () => _sort = LocalMusicTrackSort(_sort.field, true))),
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
