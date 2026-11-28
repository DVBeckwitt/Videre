import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../player/states/player.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../settings/states/settings.dart';
import '../../../utils.dart' show selectKeys;
import '../../../videos/models/video.dart';
import '../../models/local_music_browse.dart';
import '../../models/device_playlist_track.dart';
import '../../models/local_music_track.dart';
import '../../models/music_search_text.dart';
import '../../models/music_song_row_swipe_action.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/local_music_library.dart';
import '../../services/music_library_search.dart';
import '../../services/music_library_service.dart';
import '../../services/local_music_lyrics_authoring.dart';
import '../../services/on_device_music_downloads.dart';
import '../screens/music.dart';
import '../screens/music_device_artist.dart';
import '../screens/music_device_collections.dart';
import 'device_music_artwork.dart';
import 'local_music_albums.dart';
import 'local_music_exclusions.dart';
import 'local_music_folder_browser.dart';
import 'local_music_locations.dart';
import 'local_music_scan_report.dart';
import 'local_music_summary.dart';
import 'local_music_tag_editor.dart';
import 'music_fast_scroll.dart';
import 'local_music_repair.dart';
import 'music_library_actions.dart';
import 'music_download_removal.dart';
import 'music_track_details.dart';
import 'music_file_sharing.dart';
import 'music_song_selection_bar.dart';
import 'music_song_row_swipe.dart';
import 'music_ringtone.dart';

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

  Future<void> _play(List<OnDeviceMusicEntry> entries, int index,
      {BuildContext? routeContext,
      LocalMusicFolderLocation? folder,
      bool songTap = false}) async {
    final context = routeContext ?? this.context;
    if (!context.mounted) return;
    final requested = entries[index].id;
    final current = _entriesById();
    final visible = [
      for (final entry in entries)
        if (current[entry.id] case final row?)
          if (folder == null ||
              row.deviceTrack?.folderLocations.lastOrNull?.key == folder.key)
            row,
    ];
    final startIndex = visible.indexWhere((entry) => entry.id == requested);
    if (startIndex < 0) return;
    try {
      final locals = AppLocalizations.of(context)!;
      if (visible.every((entry) => entry.deviceTrack != null)) {
        final source = folder?.label ??
            (_library.roots.length > 1
                ? locals.onDevice
                : _library.isSystem
                    ? locals.localMusicAndroidLibrary
                    : _library.folderName);
        await MusicScreen.playLocalTracks(
            context, visible.map((entry) => entry.deviceTrack!).toList(),
            startIndex: startIndex, queueTitle: source, songTap: songTap);
      } else {
        final profile = _library.visibilityProfile;
        final selection = _library.selectionId;
        final requiresSource =
            visible.any((entry) => entry.deviceTrack != null);
        await MusicScreen.playOnDeviceTracks(context, visible,
            startIndex: startIndex,
            queueTitle: locals.onDevice,
            songTap: songTap,
            isCurrent: () =>
                mounted &&
                _library.visibilityProfile == profile &&
                (!requiresSource ||
                    _library.acceptsSessionSelection(selection)));
      }
    } catch (_) {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  void _browseFolders(LocalMusicTrackSort sort) {
    final library = _library;
    final profile = library.visibilityProfile;
    final locals = AppLocalizations.of(context)!;
    bool isCurrent() =>
        mounted &&
        identical(_library, library) &&
        library.visibilityProfile == profile &&
        library.enabled &&
        !library.unavailable;

    if (!isCurrent()) return;
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => _withSelectKeys(LocalMusicFolderBrowser(
              library: library,
              catalogChanges: Listenable.merge([library, _downloads]),
              currentEntries: () => isCurrent() ? _currentEntries() : null,
              sourceScope: _preferenceScope,
              order: sort.order,
              refresh: () =>
                  isCurrent() && !library.busy ? library.refresh : null,
              unavailableMessage: () =>
                  localMusicSourceStatus(library, locals) ??
                  locals.localMusicLocationsUnavailable,
              row: (context, tracks, index, folder, autofocus,
                      {required selected,
                      required onToggleSelection,
                      required onStartSelection}) =>
                  _buildTrack(context, tracks[index], sort, profile,
                      library.selectionId, () {
                if (isCurrent()) {
                  unawaited(_play(tracks, index,
                      routeContext: context, folder: folder, songTap: true));
                }
              },
                      showFileName: true,
                      autofocus: autofocus,
                      selected: selected,
                      onToggleSelection: onToggleSelection,
                      onStartSelection: onStartSelection),
            ))));
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
        !player.isClosed &&
        identical(context.read<PlayerCubit?>(), player) &&
        _library.visibilityProfile == profile &&
        (entry.deviceTrack == null ||
            _library.acceptsSessionSelection(selection));
    if (!currentSource()) return;
    bool hasActiveMusic() =>
        !player.state.isHidden &&
        !player.state.isClosing &&
        player.isMusicAudio;
    final activeMusic = hasActiveMusic();
    if (activeMusic ||
        entry.download != null ||
        player.state.offlineVideos.isNotEmpty) {
      final tracks = [entry];
      if (player.canEnqueueOnDeviceMusic(tracks)) {
        final queued = await player.enqueueOnDeviceMusic(tracks,
            next: next, isCurrent: currentSource);
        if (queued || !currentSource()) return;
        throw StateError('The active music queue changed.');
      }
      if (activeMusic) {
        throw StateError('The active music queue is unavailable.');
      }
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
      if (confirmed != true ||
          !currentSource() ||
          hasActiveMusic() ||
          player.state.currentQueueId != current) {
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

  Object? _preferenceScope() {
    final app = context.read<AppCubit?>()?.state;
    final database = db;
    final profile = database.profileId;
    if (app != null &&
        (app.profileId != profile ||
            app.globalLoading ||
            app.sessionRecoveryRequired)) {
      return null;
    }
    return (
      database,
      profile,
      app?.sessionRevision,
      _library.visibilityProfile,
      _library.selectionId,
      _library.folderName,
      _library.isSystem,
      _library.unavailable,
    );
  }

  MusicLibraryService? get _activeArtistAliases {
    if (_preferenceScope() == null) return null;
    final database = db;
    return MusicLibraryService.forProfile(database, database.profileId);
  }

  Future<void> _savePreference(
      SettingsCubit settings, Object scope, String key, String value) async {
    if (!mounted || settings.isClosed || _preferenceScope() != scope) return;
    try {
      await settings.setMusicCollectionPreference(key, value);
    } catch (_) {
      if (!mounted || _preferenceScope() != scope) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(AppLocalizations.of(context)!.musicLibraryActionError)));
    }
  }

  Future<void> _chooseSort(LocalMusicTrackSort sort,
      {required bool hasFirstSeen,
      required Future<void> Function(LocalMusicTrackSort) save}) async {
    final choice = await showModalBottomSheet<LocalMusicTrackSort>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => _withSelectKeys(
            _LocalMusicSortSheet(sort: sort, hasFirstSeen: hasFirstSeen)));
    if (choice != null && choice.value != sort.value) await save(choice);
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
    if (!widget._settings) {
      context.select((AppCubit? app) {
        final state = app?.state;
        return (
          state?.profileId,
          state?.sessionRevision,
          state?.globalLoading,
          state?.sessionRecoveryRequired,
        );
      });
    }
    final artistAliases = widget._settings ? null : _activeArtistAliases;
    final catalogChanges = widget._settings
        ? _library
        : Listenable.merge([_library, _downloads, artistAliases?.changes]);
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

          final settings = context.read<SettingsCubit?>();
          final scope = _preferenceScope();
          final selection = _library.selectionId;
          final identity = localMusicBrowseSourceKey(
              enabled: enabled, selectionId: selection, system: system);
          final sortKey = localMusicSortSetting(identity);
          final filterKey = 'music-collection-device-filter-v1:$identity';
          final (savedSort, savedFilters) =
              context.select((SettingsCubit? settings) {
            final saved = scope == null ? null : settings?.state.settings;
            return (
              (saved?[sortKey] ?? saved?[legacyLocalMusicSortSetting])?.value,
              saved?[filterKey]?.value,
            );
          });
          final sort = LocalMusicTrackSort.fromValue(savedSort);
          final filters = _decodeLocalMusicFilters(savedFilters);
          final Future<void> Function(String, String)? savePreference =
              scope == null || settings == null
                  ? null
                  : (key, value) =>
                      _savePreference(settings, scope, key, value);
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
          final controls = Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: locals.searchSortBy,
                icon: const Icon(Icons.sort),
                onPressed: tracks.isEmpty || savePreference == null
                    ? null
                    : () => _chooseSort(sort,
                        hasFirstSeen: tracks.any((track) => track.firstSeen),
                        save: (choice) =>
                            savePreference(sortKey, choice.value))),
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
            key: ValueKey(scope),
            library: _library,
            catalogChanges: catalogChanges,
            artistAliases: artistAliases,
            currentEntries: _currentEntries,
            tracks: tracks,
            sort: sort,
            canBrowse: canBrowse,
            filters: filters,
            saveFilters: savePreference == null
                ? null
                : (choice) => savePreference(
                    filterKey,
                    jsonEncode({
                      'artist': choice.artist,
                      'album': choice.album?.label,
                      if (choice.album case final album? when album.exact)
                        'albumKey': album.key,
                    })),
            preferenceScopeIsCurrent: () =>
                mounted && _preferenceScope() == scope,
            complete: !_library.scanning &&
                (!_library.enabled || _library.loaded) &&
                !roots.any(_library.isProviderUnreachable) &&
                _library.error == null,
            row: (visible, index,
                    {selected, onToggleSelection, onStartSelection}) =>
                _buildTrack(context, visible[index], sort, profile, selection,
                    () => _play(visible, index, songTap: true),
                    selected: selected,
                    onToggleSelection: onToggleSelection,
                    onStartSelection: onStartSelection),
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
                    if (_ready &&
                        !_library.unavailable &&
                        _library.visibleTracks
                            .any((track) => track.genres.isNotEmpty))
                      TextButton.icon(
                        onPressed: () => openMusicDeviceCollections(
                            context, _library, MusicDeviceCollection.genres),
                        icon: const Icon(Icons.category_outlined),
                        label: Text(locals.localMusicGenres),
                      ),
                    if (_library.indexedPlaylists.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => openMusicDeviceCollections(
                            context, _library, MusicDeviceCollection.playlists),
                        icon: const Icon(Icons.playlist_play),
                        label: Text(locals.localMusicDevicePlaylists),
                      ),
                    if (tracks.any((entry) =>
                        entry.deviceTrack?.folderLocations.isNotEmpty == true))
                      TextButton.icon(
                        onPressed: () => _browseFolders(sort),
                        icon: const Icon(Icons.folder_outlined),
                        label: Text(locals.localMusicBrowseFolders),
                      ),
                    TextButton.icon(
                      onPressed: sourceAvailable
                          ? () =>
                              _library.chooseFolder(reconnect: reconnectFolder)
                          : null,
                      icon: Icon(reconnectFolder?.isDocumentProvider == true
                          ? Icons.folder_shared_outlined
                          : Icons.folder_open),
                      label: Text(switch (reconnectFolder) {
                        LocalMusicRoot(isDocumentProvider: true) =>
                          locals.localMusicReconnectLocation,
                        LocalMusicRoot() => locals.localMusicChooseFolder,
                        null => locals.localMusicAddFolder,
                      }),
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
                    if (_library.scanning)
                      _cancelScanButton(locals)
                    else
                      TextButton.icon(
                        key: const ValueKey('local-music-force-rescan'),
                        onPressed: sourceAvailable && !_library.unavailable
                            ? () => _library.refresh(force: true)
                            : null,
                        icon: const Icon(Icons.manage_search),
                        label: Text(locals.localMusicForceRescan),
                      ),
                    TextButton.icon(
                      onPressed: _ready && scope != null
                          ? () => showLocalMusicScanReport(context, _library)
                          : null,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(locals.localMusicScanReport),
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
                    if (_library.movedFileRepairs.isNotEmpty)
                      TextButton.icon(
                        onPressed: sourceAvailable && !_library.unavailable
                            ? () => showLocalMusicRepair(context, _library)
                            : null,
                        icon: const Icon(Icons.link),
                        label: Text(locals.localMusicRepairMovedFiles),
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
                ListTile(
                  leading: const Icon(Icons.folder_copy_outlined),
                  title: Text(locals.localMusicManageLocations),
                  onTap: _ready
                      ? () => showLocalMusicLocations(context, _library)
                      : null,
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      toggle,
      if (_library.enabled)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 16),
          child: TextButton(
            onPressed: _ready
                ? () => showLocalMusicLocations(context, _library)
                : null,
            child: Text(locals.localMusicManageLocations),
          ),
        ),
      if (_library.scanning)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 16),
          child: _cancelScanButton(locals),
        ),
      SwitchListTile(
        key: const ValueKey('local-music-automatic-scan'),
        secondary: const Icon(Icons.sync),
        title: Text(locals.localMusicAutomaticScan),
        subtitle: Text(locals.localMusicAutomaticScanDescription),
        value: _library.automaticScan,
        onChanged: _ready && !_library.savingScanPreference
            ? (value) async {
                if (await _library.setAutomaticScan(value) || !mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(locals.localMusicScanSaveFailed)));
              }
            : null,
      ),
    ]);
  }

  Widget _cancelScanButton(AppLocalizations locals) => TextButton.icon(
        key: const ValueKey('local-music-cancel-scan'),
        onPressed: _library.canCancelScan ? _library.cancelScan : null,
        icon: const Icon(Icons.close),
        label: Text(locals.localMusicCancelScan),
      );

  Widget _buildTrack(
    BuildContext context,
    OnDeviceMusicEntry entry,
    LocalMusicTrackSort sort,
    Object? profile,
    String? selection,
    VoidCallback play, {
    bool showFileName = false,
    bool autofocus = false,
    bool? selected,
    VoidCallback? onToggleSelection,
    VoidCallback? onStartSelection,
  }) {
    final locals = AppLocalizations.of(context)!;
    final track = entry.deviceTrack;
    ({PlayerCubit player, int generation, String profile})? requestTarget;
    final download = entry.download;
    final canSaveDevice = track != null && devicePlaylistVideo(track) != null;
    bool currentSource() =>
        mounted &&
        _library.visibilityProfile == profile &&
        (track == null || _library.acceptsSessionSelection(selection));
    MusicRingtoneSource? ringtoneSource() {
      if (track != null) {
        return MusicRingtoneSource.local(_library, track,
            isCurrent: currentSource);
      }
      final file = entry.download;
      return file == null
          ? null
          : MusicRingtoneSource.download(file,
              expectedIdentity: entry.downloadFileProof,
              isCurrent: currentSource);
    }

    Future<void> runAction(_TrackAction action) async {
      if (!currentSource()) return;
      try {
        switch (action) {
          case _TrackAction.select:
            onStartSelection?.call();
          case _TrackAction.playNext:
            await _enqueue(entry, next: true);
          case _TrackAction.addToQueue:
            await _enqueue(entry, next: false);
          case _TrackAction.addToRequests:
            final target = requestTarget;
            final current = _entriesById()[entry.id];
            if (target == null ||
                current == null ||
                current.deviceTrack?.uri != track?.uri ||
                target.profile != db.profileId ||
                !identical(this.context.read<PlayerCubit?>(), target.player) ||
                target.player.isClosed ||
                target.player.playlistGeneration != target.generation ||
                !target.player.addDeviceMusicRequest(current)) {
              throw StateError('The active music queue changed.');
            }
            ScaffoldMessenger.of(this.context)
              ..removeCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(locals.musicRequestAdded)));
          case _TrackAction.saveToPlaylist:
            if (track != null) {
              await MusicLibraryActions.saveDeviceTrack(
                  context, _library, track,
                  isCurrent: currentSource);
            }
          case _TrackAction.managePlaylists:
            if (track != null) {
              await MusicLibraryActions.manageDeviceTrackPlaylists(
                  context, _library, track,
                  isCurrent: currentSource);
            } else if (download != null) {
              await MusicLibraryActions.manageDownloadedTrackPlaylists(
                  context, download,
                  isCurrent: currentSource);
            }
          case _TrackAction.editTags:
            if (track != null) {
              await editLocalMusicTags(
                this.context,
                _library,
                track,
                isCurrent: currentSource,
                authoring: LocalMusicLyricsAuthoring.forTrack(
                  database: db,
                  track: track,
                  isCurrent: currentSource,
                ),
              );
            }
          case _TrackAction.rename:
            if (track != null) {
              await renameLocalMusicTrack(context, _library, track);
            }
          case _TrackAction.details:
            final latest = _currentEntries()
                .where((row) => row.id == entry.id)
                .firstOrNull;
            if (latest?.deviceTrack case final device?) {
              await showMusicTrackDetails(context,
                  device: device, library: _library);
            } else if (latest?.download case final download?) {
              await showMusicTrackDetails(context,
                  download: download,
                  downloadFileProof: latest!.downloadFileProof);
            }
          case _TrackAction.shareFile:
            final current = _entriesById()[entry.id];
            if (current?.deviceTrack case final file?
                when file.uri == track?.uri) {
              await shareLocalMusicFile(context, _library, file,
                  isCurrent: currentSource);
            } else if (current?.download case final file?) {
              await shareDownloadedMusicFile(context, file,
                  expectedIdentity: current?.downloadFileProof,
                  isCurrent: currentSource);
            }
          case _TrackAction.setRingtone:
            await ringtoneSource()?.set(context);
          case _TrackAction.hide:
            if (track != null) await _hide(track);
          case _TrackAction.removeKeep:
            if (track != null) {
              await updateLocalMusicExclusions(this.context, _library, profile,
                  () => _library.setExclusionOverride(track, false));
            }
        }
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(this.context).showSnackBar(
            SnackBar(content: Text(locals.musicLibraryActionError)));
      }
    }

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
      if (showFileName && entry.fileName != entry.title) entry.fileName,
      musicFileArtistByline(_activeArtistAliases, entry),
      entry.album,
      if (date != null)
        '$dateLabel · ${MaterialLocalizations.of(context).formatMediumDate(date.toLocal())}',
    ].nonNulls.where((s) => s.isNotEmpty).join(' • ');
    final title =
        Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis);
    final subtitle = description.isEmpty
        ? null
        : Text(description,
            maxLines: date == null ? 1 : 2, overflow: TextOverflow.ellipsis);
    if (selected != null) {
      return CheckboxListTile(
        key: ValueKey(entry.id),
        value: selected,
        controlAffinity: ListTileControlAffinity.leading,
        title: title,
        subtitle: subtitle,
        onChanged:
            onToggleSelection == null ? null : (_) => onToggleSelection(),
      );
    }
    final placeholder = Icon(entry.download == null
        ? Icons.music_note_outlined
        : Icons.offline_pin_outlined);
    final tile = ListTile(
      autofocus: autofocus,
      leading: SizedBox.square(
        dimension: 48,
        child: track == null
            ? placeholder
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: DeviceMusicArtwork(
                    track: track, placeholder: placeholder, thumbnail: true),
              ),
      ),
      title: title,
      subtitle: subtitle,
      onTap: () {
        if (currentSource()) play();
      },
      onLongPress: onStartSelection,
      trailing: PopupMenuButton<_TrackAction>(
        tooltip: locals.localMusicSongActions(entry.title),
        onSelected: runAction,
        itemBuilder: (context) {
          final player = context.read<PlayerCubit?>();
          requestTarget = currentSource() &&
                  player != null &&
                  !player.isClosed &&
                  player.canAddDeviceMusicRequest(entry)
              ? (
                  player: player,
                  generation: player.playlistGeneration,
                  profile: db.profileId,
                )
              : null;
          return [
            PopupMenuItem(
                value: _TrackAction.playNext,
                child: _withSelectKeys(Text(locals.playNext))),
            PopupMenuItem(
                value: _TrackAction.addToQueue,
                child: _withSelectKeys(Text(locals.addToQueueList))),
            if (onStartSelection != null)
              PopupMenuItem(
                  value: _TrackAction.select,
                  child: _withSelectKeys(Text(locals.musicSelectSong))),
            if (requestTarget != null)
              PopupMenuItem(
                  value: _TrackAction.addToRequests,
                  child: _withSelectKeys(Text(locals.musicAddToRequests))),
            if (canSaveDevice)
              PopupMenuItem(
                  value: _TrackAction.saveToPlaylist,
                  child: _withSelectKeys(Text(locals.musicSaveToPlaylist))),
            if (canSaveDevice || download != null)
              PopupMenuItem(
                  value: _TrackAction.managePlaylists,
                  child:
                      _withSelectKeys(Text(locals.musicManageSongPlaylists))),
            PopupMenuItem(
                value: _TrackAction.details,
                child: _withSelectKeys(Text(locals.musicTrackFileDetails))),
            if (track != null && track.canRename && track.fileName != null)
              PopupMenuItem(
                  value: _TrackAction.rename,
                  enabled: !_library.busy,
                  child: _withSelectKeys(Text(locals.localMusicRename))),
            if (track != null && currentSource() && _library.canEditTags(track))
              PopupMenuItem(
                  value: _TrackAction.editTags,
                  enabled: !_library.busy,
                  child: _withSelectKeys(Text(locals.localMusicEditTags))),
            if (supportsMusicFileSharing && track?.isCueTrack != true)
              PopupMenuItem(
                  value: _TrackAction.shareFile,
                  enabled: track == null || !_library.busy,
                  child: _withSelectKeys(Text(locals.musicShareAudioFile))),
            if (ringtoneSource() case final ringtone?)
              MusicRingtoneMenuItem(
                  source: ringtone, value: _TrackAction.setRingtone),
            if (track != null &&
                currentSource() &&
                _library.canHideTrack(track))
              PopupMenuItem(
                  value: _TrackAction.hide,
                  child: _withSelectKeys(Text(locals.localMusicHideFile))),
            if (track != null &&
                currentSource() &&
                _library.hasExclusionOverride(track))
              PopupMenuItem(
                  value: _TrackAction.removeKeep,
                  child: _withSelectKeys(
                      Text(locals.localMusicRemoveKeepOverride))),
          ];
        },
      ),
    );
    return MusicSongRowSwipe(
      key: ValueKey(entry.id),
      onAction: (action) => switch (action) {
        MusicSongRowSwipeAction.playNext => runAction(_TrackAction.playNext),
        MusicSongRowSwipeAction.addToQueue =>
          runAction(_TrackAction.addToQueue),
        MusicSongRowSwipeAction.off => Future<void>.value(),
      },
      child: tile,
    );
  }
}

typedef _LocalAlbumFilter = ({String? key, String label, bool exact});
typedef _LocalMusicFilters = ({String? artist, _LocalAlbumFilter? album});

_LocalMusicFilters _decodeLocalMusicFilters(String? value) {
  if (value != null) {
    try {
      if (jsonDecode(value) case final Map data) {
        final artist = data['artist'];
        final album = data['album'];
        final albumKey = data['albumKey'];
        return (
          artist: artist is String && artist.isNotEmpty ? artist : null,
          album: album is String && album.isNotEmpty
              ? (
                  key: albumKey is String ? albumKey : null,
                  label: album,
                  exact: data.containsKey('albumKey'),
                )
              : null,
        );
      }
    } on FormatException {
      // Invalid display preferences fall back to showing all tracks.
    }
  }
  return (artist: null, album: null);
}

class _LocalTrackBrowser extends StatefulWidget {
  const _LocalTrackBrowser({
    super.key,
    required this.library,
    required this.catalogChanges,
    required this.artistAliases,
    required this.currentEntries,
    required this.tracks,
    required this.sort,
    required this.canBrowse,
    required this.filters,
    required this.saveFilters,
    required this.preferenceScopeIsCurrent,
    required this.complete,
    required this.header,
    required this.row,
  });

  final LocalMusicLibrary library;
  final Listenable catalogChanges;
  final MusicLibraryService? artistAliases;
  final List<OnDeviceMusicEntry> Function() currentEntries;
  final List<OnDeviceMusicEntry> tracks;
  final LocalMusicTrackSort sort;
  final bool canBrowse;
  final _LocalMusicFilters filters;
  final Future<void> Function(_LocalMusicFilters)? saveFilters;
  final bool Function() preferenceScopeIsCurrent;
  final bool complete;
  final Widget header;
  final Widget Function(List<OnDeviceMusicEntry>, int,
      {bool? selected,
      VoidCallback? onToggleSelection,
      VoidCallback? onStartSelection}) row;

  @override
  State<_LocalTrackBrowser> createState() => _LocalTrackBrowserState();
}

bool _matchesAlbum(OnDeviceMusicEntry track, _LocalAlbumFilter album) {
  final key = track.deviceTrack?.albumKey;
  if (!album.exact) return track.album?.trim() == album.label;
  if (album.key != null) return key == album.key;
  return key == null && track.album?.trim() == album.label;
}

class _LocalTrackBrowserState extends State<_LocalTrackBrowser> {
  final _search = TextEditingController();
  // Scan updates replace immutable track objects. Updated tags get a fresh key.
  final _searchText = Expando<String>();
  bool _savingFilters = false;
  final _selectFocus = FocusNode();
  final _closeSelectionFocus = FocusNode();
  Map<String, OnDeviceMusicEntry>? _selected;
  Completer<void>? _shareCancellation;

  void _startSelection([OnDeviceMusicEntry? entry]) {
    if (_selected != null || !widget.preferenceScopeIsCurrent()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _selected = {if (entry != null) entry.id: entry});
    _focusSelectionControl(_closeSelectionFocus, selecting: true);
  }

  void _closeSelection() {
    if (_selected == null) return;
    _cancelShare();
    setState(() => _selected = null);
    _focusSelectionControl(_selectFocus, selecting: false);
  }

  void _focusSelectionControl(FocusNode focus, {required bool selecting}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          (_selected != null) == selecting &&
          TickerMode.of(context) &&
          focus.context != null) {
        focus.requestFocus();
      }
    });
  }

  void _toggleSelection(OnDeviceMusicEntry entry) {
    final selected = _selected;
    if (selected == null || !widget.preferenceScopeIsCurrent()) return;
    _cancelShare();
    setState(() {
      if (selected.remove(entry.id) == null) selected[entry.id] = entry;
    });
  }

  void _cancelShare() {
    final cancellation = _shareCancellation;
    _shareCancellation = null;
    cancellation?.complete();
  }

  List<OnDeviceMusicEntry>? _resolveSelection(
      List<OnDeviceMusicEntry> selected) {
    final current = {
      for (final entry in widget.currentEntries()) entry.id: entry,
    };
    final entries = <OnDeviceMusicEntry>[];
    for (final entry in selected) {
      final live = current[entry.id];
      final selectedTrack = entry.deviceTrack;
      final liveTrack = live?.deviceTrack;
      if (live == null ||
          liveTrack?.uri != selectedTrack?.uri ||
          liveTrack?.visibilityKey != selectedTrack?.visibilityKey ||
          liveTrack?.documentVisibilityKey !=
              selectedTrack?.documentVisibilityKey) {
        return null;
      }
      entries.add(live);
    }
    return entries;
  }

  Future<void> _shareSelection(List<OnDeviceMusicEntry> selected) async {
    if (selected.length < 2 ||
        _shareCancellation != null ||
        !widget.preferenceScopeIsCurrent()) {
      return;
    }
    final entries = _resolveSelection(selected);
    if (entries == null) {
      final locals = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(locals.musicShareSelectedAudioError)),
      );
      return;
    }
    final cancellation = Completer<void>();
    setState(() => _shareCancellation = cancellation);
    bool isCurrent() =>
        mounted &&
        identical(_shareCancellation, cancellation) &&
        widget.preferenceScopeIsCurrent() &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.of(context);
    try {
      await shareSelectedMusicFiles(
        context,
        widget.library,
        entries,
        isCurrent: isCurrent,
        cancelled: cancellation.future,
      );
    } finally {
      if (mounted && identical(_shareCancellation, cancellation)) {
        setState(() => _shareCancellation = null);
      }
    }
  }

  Video? _playlistSong(OnDeviceMusicEntry entry) {
    if (entry.deviceTrack case final track?) return devicePlaylistVideo(track);
    return MusicLibraryActions.downloadedPlaylistSong(entry.download!);
  }

  Widget _selectionBar(
    AppLocalizations locals,
    Map<String, OnDeviceMusicEntry> selection,
    List<OnDeviceMusicEntry> visible,
  ) {
    final selected = [
      for (final entry in widget.tracks)
        if (selection[entry.id] case final selected?) selected,
    ];
    final allSelected = visible.isNotEmpty &&
        visible.every((entry) => selection.containsKey(entry.id));
    List<OnDeviceMusicEntry>? resolve() {
      if (!mounted ||
          !identical(_selected, selection) ||
          !widget.preferenceScopeIsCurrent() ||
          selected.length != selection.length ||
          !selected.every((entry) => identical(selection[entry.id], entry))) {
        return null;
      }
      return _resolveSelection(selected);
    }

    final manager = context.read<DownloadManagerCubit?>();
    final downloads = [
      for (final entry in selected)
        if (entry.download case final file?) file,
    ];
    Future<void> deleteDownloads(DownloadManagerCubit manager) async {
      final profile = db.profileId;
      bool ownerCurrent() =>
          mounted &&
          identical(_selected, selection) &&
          widget.preferenceScopeIsCurrent() &&
          identical(context.read<DownloadManagerCubit?>(), manager) &&
          !manager.isClosed;

      final removed = await confirmMusicDownloadRemoval(
        context,
        manager,
        downloads,
        isCurrent: ownerCurrent,
        revalidate: (files) async {
          final expected = {
            for (final entry in selected)
              entry.download!.videoId: entry.downloadFileProof,
          };
          final live = await manager.storage.probeMusicFiles(profile, files);
          return resolve() != null &&
              live.length == files.length &&
              live.every(
                (file) => expected[file.download.videoId] == file.identity,
              );
        },
      );
      if (removed != null &&
          removed > 0 &&
          ownerCurrent() &&
          !downloads.any(manager.state.videos.contains)) {
        _closeSelection();
      }
    }

    return Row(children: [
      Expanded(
        child: MusicSongSelectionBar(
          selected: [
            for (final entry in selected)
              if (_playlistSong(entry) case final song?) song,
          ],
          selectedCount: selected.length,
          allSelected: allSelected,
          onToggleAll: visible.isEmpty
              ? null
              : () {
                  _cancelShare();
                  setState(() {
                    selection.clear();
                    if (!allSelected) {
                      selection.addEntries(
                          visible.map((entry) => MapEntry(entry.id, entry)));
                    }
                  });
                },
          closeFocus: _closeSelectionFocus,
          onClose: _closeSelection,
          isCurrent: () => resolve() != null,
          resolveOnDevice: resolve,
          deviceLibrary: widget.library,
          removal: manager == null ||
                  downloads.isEmpty ||
                  downloads.length != selected.length
              ? null
              : (
                  label: locals.musicRemoveSelectedDownloads,
                  run: () => deleteDownloads(manager),
                ),
        ),
      ),
      if (supportsMusicFileSharing)
        IconButton(
          tooltip: locals.musicShareSelectedAudio,
          icon: const Icon(Icons.share_outlined),
          onPressed: selected.length >= 2 && _shareCancellation == null
              ? () => _shareSelection(selected)
              : null,
        ),
    ]);
  }

  _LocalMusicFilters get _activeFilters {
    final saved = widget.filters;
    final library = widget.library;
    // A partial or failed scan cannot establish that a tag has disappeared.
    if (library.enabled &&
        !library.unavailable &&
        (!library.loaded || library.scanning || library.error != null)) {
      return saved;
    }
    final (artist: artist, album: album) = saved;
    if (artist != null && !_hasArtist(artist)) {
      return (artist: null, album: null);
    }
    if (album == null) return saved;
    final title = _findAlbum(album, artist)?.album?.trim();
    return (
      artist: artist,
      album: title == null
          ? null
          : (key: album.key, label: title, exact: album.exact),
    );
  }

  bool _hasArtist(String credit) =>
      widget.currentEntries().any((track) => track.artist?.trim() == credit);

  OnDeviceMusicEntry? _findAlbum(_LocalAlbumFilter album, String? withArtist) =>
      widget
          .currentEntries()
          .where((track) =>
              (withArtist == null || track.artist?.trim() == withArtist) &&
              _matchesAlbum(track, album))
          .firstOrNull;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final active = TickerMode.of(context);
    if (!routeCurrent || !active) _cancelShare();
  }

  @override
  void dispose() {
    _cancelShare();
    _selectFocus.dispose();
    _closeSelectionFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _saveFilters(_LocalMusicFilters choice) async {
    final save = widget.saveFilters;
    if (save == null || _savingFilters || !widget.preferenceScopeIsCurrent()) {
      return;
    }
    setState(() => _savingFilters = true);
    try {
      await save(choice);
    } finally {
      if (mounted) setState(() => _savingFilters = false);
    }
  }

  Future<void> _chooseTag({required bool artist}) async {
    final isCurrent = widget.preferenceScopeIsCurrent;
    final filters = _activeFilters;
    final locals = AppLocalizations.of(context)!;
    final label =
        artist ? locals.localMusicSortArtist : locals.localMusicSortAlbum;
    final value = await showModalBottomSheet<_LocalAlbumFilter>(
      context: context,
      useSafeArea: true,
      builder: (context) => _withSelectKeys(ListenableBuilder(
        listenable: widget.catalogChanges,
        builder: (context, _) {
          final values = <Object,
              ({
            _LocalAlbumFilter filter,
            String? credit,
            List<String?> tags,
          })>{};
          if (isCurrent()) {
            for (final track in widget.currentEntries()) {
              if (!artist &&
                  filters.artist != null &&
                  track.artist?.trim() != filters.artist) {
                continue;
              }
              final tag = (artist ? track.artist : track.album)?.trim();
              if (tag == null || tag.isEmpty) continue;
              final key = artist ? null : track.deviceTrack?.albumKey;
              final option = values.putIfAbsent(
                key ?? (label: tag),
                () => (
                  filter: (key: key, label: tag, exact: true),
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
                  final byLabel =
                      a.value.filter.label.compareTo(b.value.filter.label);
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
                        ? option.filter.label == filters.artist
                        : option.filter == filters.album,
                    onTap: () => Navigator.of(context).pop(option.filter));
              },
            )),
          ]);
        },
      )),
    );
    if (!mounted || value == null || !isCurrent()) return;
    final current = _activeFilters;
    if (artist
        ? !_hasArtist(value.label)
        : _findAlbum(value, current.artist) == null) {
      return;
    }
    if (artist && current.artist != value.label) {
      await _saveFilters((artist: value.label, album: null));
    } else if (!artist && current.album != value) {
      await _saveFilters((artist: current.artist, album: value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final terms = musicSearchTerms(_search.text);
    final (artist: artist, album: album) = _activeFilters;
    final selected = _selected;
    final canFilter =
        selected == null && widget.saveFilters != null && !_savingFilters;
    final visible = terms.isEmpty && artist == null && album == null
        ? widget.tracks
        : widget.tracks.where((track) {
            if (artist != null && artist != track.artist?.trim()) {
              return false;
            }
            if (album != null && !_matchesAlbum(track, album)) return false;
            if (terms.isEmpty) return true;
            final input = track.deviceTrack ?? track.download!;
            final text = _searchText[input] ??= normalizeMusicSearchText([
              track.title,
              track.fileName,
              track.artist,
              track.album,
              track.deviceTrack?.albumArtist,
              ...fileArtistCreditNames(track),
            ].nonNulls.join(' '));
            return musicSearchMatchesWithArtistAliases(terms, text,
                fileArtistSearchAliases(widget.artistAliases, track));
          }).toList(growable: false);
    final indexes = {
      for (final (index, track) in visible.indexed) ValueKey(track.id): index
    };
    if (selected != null) {
      final trackIds = widget.tracks.map((entry) => entry.id).toSet();
      selected.removeWhere((id, _) => !trackIds.contains(id));
    }
    Widget tagFilter(String label, String? selected,
            {required bool isArtist}) =>
        InputChip(
          label: Text(selected == null ? label : '$label · $selected',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          selected: selected != null,
          onPressed: canFilter ? () => _chooseTag(artist: isArtist) : null,
          onDeleted: selected == null || !canFilter
              ? null
              : () => _saveFilters(isArtist
                  ? (artist: null, album: album)
                  : (artist: artist, album: null)),
          deleteButtonTooltipMessage: material.clearButtonTooltip,
        );
    final view = CustomScrollView(
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
                      enabled: selected == null,
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
                        tagFilter(locals.localMusicSortArtist, artist,
                            isArtist: true),
                        tagFilter(locals.localMusicSortAlbum, album?.label,
                            isArtist: false),
                        if (selected == null && visible.isNotEmpty)
                          TextButton.icon(
                            focusNode: _selectFocus,
                            onPressed: _startSelection,
                            icon: const Icon(Icons.checklist),
                            label: Text(locals.musicQueueSelect),
                          ),
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
            itemBuilder: (context, index) {
              final entry = visible[index];
              return widget.row(visible, index,
                  selected: selected?.containsKey(entry.id),
                  onToggleSelection:
                      selected == null ? null : () => _toggleSelection(entry),
                  onStartSelection:
                      selected == null ? () => _startSelection(entry) : null);
            },
          ),
        ]);
    final sort = widget.sort;
    final scroll = MusicFastScroll(
      scope: (sort.value, _search.text, artist, album),
      sections: musicFastScrollSectionsFor(context, visible, sortValue: (row) {
        final value = sort.sortValueFor(row);
        return switch ((sort.field, value)) {
          (LocalMusicTrackSortField.duration, final int milliseconds) =>
            Duration(milliseconds: milliseconds),
          (LocalMusicTrackSortField.size, final int bytes) => (bytes: bytes),
          _ => value,
        };
      }),
      child: view,
    );
    final selecting = selected != null && TickerMode.of(context);
    return PlayerModalBackHandler(
      priority: 6,
      active: selecting,
      onBack: _closeSelection,
      child: PopScope(
        canPop: !selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && selecting) _closeSelection();
        },
        child: Column(children: [
          if (selected != null) _selectionBar(locals, selected, visible),
          Expanded(child: scroll),
        ]),
      ),
    );
  }
}

Widget _withSelectKeys(Widget child) => Shortcuts(shortcuts: {
      for (final key in selectKeys)
        SingleActivator(key): const ActivateIntent(),
    }, child: child);

enum _TrackAction {
  select,
  playNext,
  addToQueue,
  addToRequests,
  saveToPlaylist,
  details,
  shareFile,
  setRingtone,
  managePlaylists,
  rename,
  editTags,
  hide,
  removeKeep
}

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
