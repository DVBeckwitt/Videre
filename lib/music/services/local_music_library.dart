import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../downloads/services/download_rename.dart';
import '../../downloads/services/download_storage.dart';
import '../../globals.dart';
import '../../utils/interfaces/db.dart';
import '../models/local_music_indexed_playlist.dart';
import '../models/device_playlist_track.dart';
import '../models/device_music_artwork_preferences.dart';
import '../models/local_music_repair.dart';
import '../models/local_music_root.dart';
import '../models/local_music_scan_report.dart';
import '../models/local_music_track.dart';
import '../models/music_file_audio_format.dart';
import 'local_music_album_editions.dart';
import 'local_music_visibility.dart';
import 'm3u_playlist.dart';

export '../models/local_music_root.dart';
export '../models/local_music_repair.dart'
    show LocalMusicMissingTrack, LocalMusicMoveCandidate, LocalMusicMoveReason;
export 'local_music_visibility.dart' show HiddenLocalMusicTrack;

typedef _Selection = ({List<LocalMusicRoot> roots, String? id});
typedef OpenedMusicFile = ({
  Uri uri,
  String title,
  LocalMusicTrack? indexedTrack
});

class _LocalMusicScan {
  _LocalMusicScan({required this.force});

  final bool force;
  int? rootScanId;
  bool cancelled = false;
}

typedef _RootScan = ({LocalMusicRootScanReport? report, bool partial});

/// Original embedded values and the file revision they came from.
class LocalMusicTags {
  static const _textFields = {'title', 'artist', 'album', 'albumArtist'};
  static const _numberPairs = {
    'trackNumber': 'trackTotal',
    'discNumber': 'discTotal',
  };
  static const numberFields = {
    'trackNumber',
    'trackTotal',
    'discNumber',
    'discTotal',
  };
  static const _genreAndDateFields = {'genre', 'releaseDate'};
  static const fields = {
    ..._textFields,
    ...numberFields,
    ..._genreAndDateFields
  };
  static final _datePattern =
      RegExp(r'^([0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2}))?)?$');
  static final _numberPattern = RegExp(r'^[0-9]{1,5}$');

  final Map<String, String?> values;
  final Set<String> editableFields;
  final String revision;
  final bool canEditArtwork;
  final bool canRemoveArtwork;
  final bool hasArtwork;
  final bool allowsMonthReleaseDate;
  final LocalMusicRoot _root;
  final String _uri;

  LocalMusicTags._(
    this.values,
    this.editableFields,
    this.revision,
    this._root,
    this._uri, {
    required this.canEditArtwork,
    required this.canRemoveArtwork,
    required this.hasArtwork,
    required this.allowsMonthReleaseDate,
  });

  static String? normalizeChange(String field, String? value) {
    if (_genreAndDateFields.contains(field)) value = value?.trim();
    return value == '' ? null : value;
  }

  bool acceptsReleaseDate(String? value) {
    if (value == null) return true;
    final date = _datePattern.firstMatch(value);
    if (date == null || date.end != value.length) return false;
    final year = int.parse(date[1]!);
    if (year < 1) return false;
    final month = date[2];
    if (month == null) return true;
    final monthNumber = int.parse(month);
    if (monthNumber < 1 || monthNumber > 12) return false;
    final day = date[3];
    if (day == null) return allowsMonthReleaseDate;
    final dayNumber = int.parse(day);
    return dayNumber > 0 &&
        DateTime.utc(year, monthNumber, dayNumber).month == monthNumber;
  }

  /// Returns the first invalid or unavailable number field, if any.
  ///
  /// Omitted fields retain their original values. Null removes a value.
  /// An edited total requires a number and must be at least that number.
  String? validateNumberChanges(Map<String, String?> changes) {
    for (final field in changes.keys) {
      if (numberFields.contains(field) && !editableFields.contains(field)) {
        return field;
      }
    }
    String? value(String field) =>
        changes.containsKey(field) ? changes[field] : values[field];
    for (final pair in _numberPairs.entries) {
      final number = value(pair.key);
      final total = value(pair.value);
      if (number == values[pair.key] && total == values[pair.value]) continue;
      final numberValue = _parseNumber(number);
      if (number != null && numberValue == null) return pair.key;
      final totalValue = _parseNumber(total);
      if (total != null &&
          (numberValue == null ||
              totalValue == null ||
              totalValue < numberValue)) {
        return pair.value;
      }
    }
    return null;
  }

  static int? _parseNumber(String? text) {
    if (text == null || !_numberPattern.hasMatch(text)) return null;
    final value = int.parse(text);
    return value >= 1 && value <= 0xffff ? value : null;
  }
}

/// A staged change to the front cover in the file's tags.
class LocalMusicArtworkEdit {
  const LocalMusicArtworkEdit.remove() : image = null;

  LocalMusicArtworkEdit.replace(Uint8List bytes)
      : image = Uint8List.fromList(bytes).asUnmodifiableView();

  final Uint8List? image;
}

/// Library for the Android music sources the listener has approved.
class LocalMusicLibrary extends ChangeNotifier with WidgetsBindingObserver {
  static final instance = LocalMusicLibrary(visibilityDatabase: () => db);
  static const _channel =
      MethodChannel('com.github.dvbeckwitt.videre/local_music');
  static const _files = MethodChannel('videre/files');
  static const _maxTagArtworkBytes = 4 * 1024 * 1024;
  static final _batchCallbacks = <int, void Function(List<dynamic>)>{};
  static final _watchCallbacks = <int, void Function(String)>{};
  static const _watchDebounce = Duration(seconds: 1);
  static const _folderRefreshInterval = Duration(minutes: 2);
  static int _nextScanId = 0;
  static int _nextWatchId = 0;
  static int _nextShareId = 0;

  LocalMusicLibrary({IDbClient Function()? visibilityDatabase})
      : _visibilityDatabase = visibilityDatabase;

  final IDbClient Function()? _visibilityDatabase;
  LocalMusicVisibility? _profileVisibility;
  _Selection _selection = (roots: const [], id: null);
  bool _usesMultipleRoots = false;
  final _unavailableRoots = <Uri>{};
  final _unreachableProviders = <Uri>{};
  final _rootRevisions = <Uri, int>{};
  final _loadedRoots = <Uri>{};
  final _tracksByRoot = <Uri, Map<String, LocalMusicTrack>>{};
  final _repairsByRoot = <Uri, LocalMusicRepairSnapshot>{};
  final _unavailableRepairRoots = <Uri>{};
  List<LocalMusicTrack> _tracks = const [];
  List<LocalMusicIndexedPlaylist> _indexedPlaylists = const [];
  Map<String, LocalMusicTrack> _byId = const {};
  Map<String, LocalMusicTrack> _byVisibilityKey = const {};
  Map<String, LocalMusicTrack> _representativeByUri = const {};
  Map<(String, String), List<LocalMusicTrack>> _documents = const {};
  Future<void>? _initialization;
  Future<bool>? _choosing;
  Future<dynamic>? _picker;
  Future<void>? _scanning;
  ({Object? owner, LocalMusicScanReport value})? _scanReport;
  int _scanReportEpoch = 0;
  Future<bool>? _removing;
  _LocalMusicScan? _activeScan;
  Future<bool>? _renaming;
  Future<bool>? _repairing;
  Future<bool>? _editingTags;
  Future<void> _downloadRenameSync = Future.value();
  Future<void>? _disabling;
  bool _lastCoverLoading = true;
  int _coverPolicyRevision = 0;
  int _revision = 0;
  bool _disposed = false;
  String? _error;
  bool _automaticScan = false;
  bool _foreground = false;
  bool _automaticRefreshPending = false;
  int? _watchId;
  Timer? _automaticRefresh;
  Timer? _folderRefresh;
  Future<bool>? _savingScanPreference;
  String _tagSeparators = '';
  bool _savingTagSeparators = false;

  List<LocalMusicRoot> get roots => _selection.roots;
  Iterable<LocalMusicRoot> get _localRootsFirst => [
        ...roots.where((root) => !root.isDocumentProvider),
        ...roots.where((root) => root.isDocumentProvider),
      ];
  bool get enabled => roots.isNotEmpty;
  bool get busy =>
      _choosing != null ||
      scanning ||
      _savingTagSeparators ||
      _renaming != null ||
      _repairing != null ||
      _removing != null ||
      _editingTags != null ||
      _disabling != null;
  bool get scanning => _scanning != null;
  bool get canCancelScan => _activeScan?.cancelled == false;
  bool get automaticScan => _automaticScan;
  bool get savingScanPreference => _savingScanPreference != null;
  bool get loaded => _loadedRoots.isNotEmpty;
  bool get unavailable => enabled && roots.every(isRootUnavailable);
  bool isRootUnavailable(LocalMusicRoot root) =>
      _unavailableRoots.contains(root.uri);
  bool isProviderUnreachable(LocalMusicRoot root) =>
      _unreachableProviders.contains(root.uri);
  bool get isSystem => roots.length == 1 && roots.single.isSystem;
  String? get folderName => roots.firstOrNull?.name;
  String? get selectionId => _selection.id;
  bool acceptsSessionSelection(String? id) =>
      enabled && !unavailable && id == selectionId;
  String? get error => _error;
  LocalMusicScanReport? get scanReport {
    final report = _scanReport;
    return report != null && report.owner == visibilityProfile
        ? report.value
        : null;
  }

  List<LocalMusicTrack> get tracks => _tracks;
  String get tagSeparators => _tagSeparators;

  Future<bool> setTagSeparators(String separators) async {
    await initialize();
    if (_disposed || busy) return false;
    if (separators == _tagSeparators) return true;
    _savingTagSeparators = true;
    _notify();
    try {
      final saved = await _channel
          .invokeMethod<bool>('setTagSeparators', {'separators': separators});
      if (saved != true || _disposed) return false;
      _tagSeparators = separators;
      // A playback or lifecycle refresh may have started while saving.
      // Reload once with the new preference after any earlier scan settles.
      await _scanning;
      await refresh();
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } finally {
      _savingTagSeparators = false;
      _notify();
    }
  }

  List<LocalMusicIndexedPlaylist> get indexedPlaylists => _indexedPlaylists;
  bool containsUri(String uri) => _representativeByUri.containsKey(uri);
  LocalMusicTrack? trackById(String id) => _byId[id] ?? _repairAlias(id);

  bool get repairCatalogUnavailable => _unavailableRepairRoots.isNotEmpty;

  List<LocalMusicMissingTrack> get movedFileRepairs => List.unmodifiable(
      _repairsByRoot.values.expand((repair) => repair.missing.values));

  LocalMusicMissingTrack? missingTrackById(String id) {
    final proof = devicePlaylistFileProof(id);
    if (proof == null ? trackById(id) != null : playlistTrackById(id) != null) {
      return null;
    }
    for (final snapshot in _repairsByRoot.values) {
      final missing = proof == null
          ? snapshot.missingTrack(id)
          : snapshot.missing[snapshot.missingPlaylistIds[proof]];
      if (missing != null) return missing;
    }
    return null;
  }

  LocalMusicTrack? _repairAlias(String id, {bool playlist = false}) {
    for (final entry in _repairsByRoot.entries) {
      if (_unavailableRepairRoots.contains(entry.key)) continue;
      final targets =
          playlist ? entry.value.playlistAliases : entry.value.aliases;
      final track = _tracksByRoot[entry.key]?[targets[id]];
      if (track != null) return track;
    }
    return null;
  }

  List<LocalMusicTrack> indexedPlaylistTracks(
      LocalMusicIndexedPlaylist playlist) {
    final tracks = _tracksByRoot[LocalMusicTrack.systemSource];
    if (tracks == null) return const [];
    // The Android index can only refer to rows from the approved MediaStore root.
    final indexed = tracks.values.toList(growable: false);
    final visible = _visibility?.visible(indexed) ?? indexed;
    final byUri = {
      for (final track in visible)
        if (!track.isCueTrack) track.uri: track,
    };
    return [
      for (final uri in playlist.memberUris)
        if (byUri[uri] case final track?) track,
    ];
  }

  /// Resolve the exact current grant owning a track in an approved catalog.
  LocalMusicRoot? approvedRootForTrack(LocalMusicTrack track) {
    if (_disposed || _disabling != null) return null;
    final current = _byId[track.playbackId];
    if (current == null ||
        current.uri != track.uri ||
        current.sourceUri != track.sourceUri) {
      return null;
    }
    return roots
        .where(
            (root) => root.uri == current.sourceUri && !isRootUnavailable(root))
        .firstOrNull;
  }

  /// Returns an empty result for readable audio without supported lyrics.
  Future<({String? sidecar, String? embedded, Object? timedSidecar})?>
      readTrackLyrics(LocalMusicTrack track) async {
    final result = await _readTrackMetadata<Object?>('readTrackLyrics', track);
    if (result == null) return null;
    return (
      sidecar: result['sidecar'] as String?,
      embedded: result['embedded'] as String?,
      timedSidecar: result['timedSidecar'],
    );
  }

  /// Reads stream properties on demand from the verified backing file.
  Future<MusicFileAudioFormat?> readTrackAudioFormat(
      LocalMusicTrack track) async {
    var file = track;
    if (track.isCueTrack) {
      final root = approvedRootForTrack(track);
      if (root == null) return null;
      final backing = _tracksByRoot[root.uri]
          ?.values
          .where((candidate) =>
              !candidate.isCueTrack && candidate.uri == track.uri)
          .firstOrNull;
      if (backing == null) return null;
      file = backing;
    }
    final value =
        await _readTrackMetadata<Object>('readTrackAudioFormat', file);
    return approvedRootForTrack(track) == null
        ? null
        : MusicFileAudioFormat.fromChannel(value);
  }

  Future<Map<String, T>?> _readTrackMetadata<T>(
    String method,
    LocalMusicTrack track,
  ) async {
    if (track.isCueTrack) return null;
    final root = approvedRootForTrack(track);
    if (root == null) return null;
    final revision = _revision;
    bool isCurrent() {
      final current = approvedRootForTrack(track);
      return _current(revision) &&
          current?.uri == root.uri &&
          current?.selectionId == root.selectionId;
    }

    try {
      final result = await _channel.invokeMapMethod<String, T>(method, {
        'treeUri': root.uri.toString(),
        'selectionId': root.selectionId,
        'trackUri': track.uri,
        'trackId': track.playbackId,
      });
      return isCurrent() ? result : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  LocalMusicVisibility? get _visibility {
    final database = _visibilityDatabase?.call();
    if (database == null) return null;
    final owner = (database: database, profileId: database.profileId);
    final current = _profileVisibility;
    if (current?.owner == owner) return current;
    return _profileVisibility = LocalMusicVisibility(owner, _copies);
  }

  Iterable<LocalMusicTrack> _copies(LocalMusicTrack track) =>
      _documents[track.documentIdentity] ?? [track];

  Object? get visibilityProfile => _visibility?.owner;

  bool get canManageAlbumEditions => _visibility != null;

  List<LocalMusicAlbumEditionGroup> get albumEditionGroups {
    final owner = _visibility?.owner;
    if (owner == null) return const [];
    return LocalMusicAlbumEditions(owner.database, owner.profileId).groups;
  }

  Future<bool> saveAlbumEditionGroup({
    required LocalMusicAlbumEditionGroup? previous,
    required List<String> albumKeys,
    required String preferredKey,
    required bool Function() isCurrent,
  }) async {
    final visibility = _visibility;
    if (visibility == null) return false;
    final selection = selectionId;
    bool active() =>
        !_disposed &&
        identical(_visibility, visibility) &&
        acceptsSessionSelection(selection);
    bool current() => active() && isCurrent();

    if (!current()) return false;
    await revalidate();
    final owner = visibility.owner;
    if (!current()) return false;
    final changed =
        await LocalMusicAlbumEditions(owner.database, owner.profileId).save(
      previous: previous,
      albumKeys: albumKeys,
      preferredKey: preferredKey,
      isCurrent: () {
        if (!current()) return false;
        final available = {
          for (final track in visibleTracks)
            if (track.albumKey case final key?)
              if (track.album?.trim().isNotEmpty == true) key,
        };
        final original = previous?.albumKeys ?? const <String>[];
        return albumKeys
                .where((key) => !original.contains(key))
                .every(available.contains) &&
            (albumKeys.length < 2 ||
                preferredKey == previous?.preferredKey ||
                available.contains(preferredKey));
      },
    );
    if (changed && active()) _notify();
    return changed;
  }

  /// Session publication refreshes listeners even if the device source stayed
  /// the same across a profile switch.
  void visibilityProfileChanged() {
    _updateCoverLoading();
    _scanReport = null;
    ++_scanReportEpoch;
    _notify();
    unawaited(_rememberDocumentProofs());
  }

  bool get _loadCovers {
    final database = _visibilityDatabase?.call();
    return database == null ||
        DeviceMusicArtworkPreferences.loadsCovers(database);
  }

  void _coverPreferenceChanged() {
    if (_updateCoverLoading()) _notify();
  }

  bool _updateCoverLoading() {
    if (_initialization == null || _disposed) return false;
    final enabled = _loadCovers;
    if (_lastCoverLoading == enabled) return false;
    _lastCoverLoading = enabled;
    final revision = ++_coverPolicyRevision;
    final scanId = _activeScan?.rootScanId;
    if (scanId != null) unawaited(_cancelTrackScan(scanId));
    if (enabled && loaded && !scanning) {
      unawaited(_refreshCovers(revision));
    }
    return true;
  }

  Future<void> _refreshCovers(int revision) async {
    final choosing = _choosing;
    if (choosing != null && await choosing) return;
    final pending = _removing ?? _renaming ?? _editingTags ?? _repairing;
    if (pending != null) await pending;
    if (!_disposed && _coverPolicyRevision == revision) await refresh();
  }

  Future<void> _cancelTrackScan(int id) async {
    try {
      await _channel.invokeMethod<void>('cancelTrackScan', {'scanId': id});
    } on Exception {
      // The listing may have finished. Its old batches are ignored either way.
    }
  }

  Future<void> _rememberDocumentProofs() async {
    final visibility = _visibility;
    if (visibility == null || _byVisibilityKey.isEmpty) return;
    try {
      await visibility.rememberDocumentProofs(() =>
          !_disposed && identical(_visibility, visibility)
              ? _byVisibilityKey
              : const {});
    } on Exception {
      // The original, tree-scoped hide remains in force if saving fails.
    }
  }

  List<LocalMusicTrack> get visibleTracks =>
      _visibility?.visible(_tracks) ?? _tracks;

  LocalMusicTrack? visibleTrackById(String id) {
    final track = trackById(id);
    return track != null && _visibility?.isVisible(track) == false
        ? null
        : track;
  }

  /// Finds the browse row for a visible file, including overlapping grants.
  LocalMusicTrack? visibleCatalogTrack(String id) {
    final track = devicePlaylistFileProof(id) == null
        ? visibleTrackById(id)
        : playlistTrackById(id, visibleOnly: true);
    if (track == null || track.documentIdentity == null) return track;
    final representative = _representativeByUri[track.uri];
    if (representative == null ||
        representative.documentIdentity != track.documentIdentity) {
      return track;
    }
    return visibleTrackById(representative.playbackId);
  }

  /// Resolve a durable playlist reference against the currently chosen source.
  /// A different file at a reused URI cannot satisfy the stored proof.
  LocalMusicTrack? playlistTrackById(String id,
      {bool visibleOnly = false, bool excludeExplicit = false}) {
    if (!enabled || unavailable) return null;
    final proof = devicePlaylistFileProof(id);
    final track = proof == null
        ? null
        : _repairAlias(proof, playlist: true) ?? _byVisibilityKey[proof];
    if (track == null ||
        (visibleOnly && _visibility?.isVisible(track) == false) ||
        (excludeExplicit && isExplicitTrackHidden(track))) {
      return null;
    }
    return track;
  }

  /// Resolves an Android Files grant and reuses the current catalog row when
  /// Android identifies the same document. A temporary file stays off-index.
  Future<OpenedMusicFile?> resolveOpenedAudio(Uri uri,
      {required bool Function() isCurrent}) async {
    await initialize();
    if (_disposed || !isCurrent()) return null;
    final catalogAvailable = enabled && !unavailable && !busy;
    final catalogSelection = selectionId;
    final availableRoots = roots
        .where((root) => !root.isDocumentProvider && !isRootUnavailable(root));
    final root = catalogAvailable && availableRoots.length == 1
        ? availableRoots.single
        : null;
    final revision = _revision;
    final profile = visibilityProfile;
    try {
      final result = await _channel
          .invokeMapMethod<String, Object?>('resolveOpenedAudio', {
        'uri': uri.toString(),
        if (!catalogAvailable) 'allowIndexed': false,
        if (root != null) 'treeUri': root.uri.toString(),
        if (root != null) 'selectionId': root.selectionId,
      });
      bool current() =>
          !_disposed &&
          isCurrent() &&
          revision == _revision &&
          profile == visibilityProfile;
      if (result == null ||
          !current() ||
          result['uri'] != uri.toString() ||
          result['title'] is! String) {
        return null;
      }
      final title = (result['title'] as String).trim();
      if (title.isEmpty) return null;
      if (result['indexedUri'] case final String indexedUri) {
        if (!catalogAvailable) return null;
        LocalMusicTrack? indexed() => _representativeByUri[indexedUri];
        await _waitForTracks(() => indexed() != null);
        if (!current() || !acceptsSessionSelection(catalogSelection)) {
          return null;
        }
        final row = indexed();
        if (row == null ||
            row.isCueTrack ||
            approvedRootForTrack(row) == null ||
            visibleTrackById(row.playbackId)?.uri != indexedUri) {
          return null;
        }
        return (uri: uri, title: title, indexedTrack: row);
      }
      return (uri: uri, title: title, indexedTrack: null);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  bool isPlaylistTrackHiddenByAdvisory(String id) {
    final track = playlistTrackById(id);
    return track != null && isExplicitTrackHidden(track);
  }

  bool isExplicitTrackHidden(LocalMusicTrack track) =>
      _visibility?.isExplicitTrackHidden(track) ?? false;

  List<HiddenLocalMusicTrack> get hiddenTracks =>
      _visibility?.records(_byVisibilityKey) ?? const [];

  bool get excludesRecordings => _visibility?.excludesRecordings ?? false;

  bool get hideExplicitTracks => _visibility?.hideExplicitTracks ?? false;

  Future<bool> setHideExplicitTracks(bool value) => _changeExclusion(
      (visibility, active) => visibility.setHideExplicitTracks(value, active));

  List<LocalMusicTrack> get excludedTracks =>
      _visibility?.excluded(_tracks) ?? const [];

  List<LocalMusicFolderLocation> get inclusionFolders => List.unmodifiable(
      _visibility?.savedInclusions ?? const <LocalMusicFolderLocation>[]);

  List<LocalMusicFolderLocation> get exclusionFolders {
    final folders = {
      for (final folder
          in _visibility?.savedFolders ?? const <LocalMusicFolderLocation>[])
        folder.key: folder,
      for (final folder in inclusionFolders) folder.key: folder,
      for (final track in _byId.values)
        for (final folder in track.folderLocations) folder.key: folder,
    }.values.toList();
    return folders
      ..sort((first, second) =>
          first.label.toLowerCase().compareTo(second.label.toLowerCase()));
  }

  bool isFolderExcluded(LocalMusicFolderLocation folder) =>
      _visibility?.isFolderExcluded(folder.key) ?? false;

  bool isFolderIncluded(LocalMusicFolderLocation folder) =>
      _visibility?.isFolderIncluded(folder.key) ?? false;

  bool isExcludedByInclusion(LocalMusicTrack track) =>
      _visibility?.isExcludedByInclusion(track) ?? false;

  bool hasExclusionOverride(LocalMusicTrack track) =>
      _visibility?.hasOverride(track) ?? false;

  bool canKeepExcludedTrack(LocalMusicTrack track) {
    final current = _eligibleForHiding(track);
    return current != null && _visibility?.isExcluded(current) == true;
  }

  Future<bool> setExcludeRecordings(bool value) => _changeExclusion(
      (visibility, active) => visibility.setExcludeRecordings(value, active));

  Future<bool> setFolderExcluded(LocalMusicFolderLocation folder, bool value) =>
      _changeExclusion((visibility, active) => visibility.setFolderExcluded(
          folder, value, () => active() && (!value || _hasFolder(folder))));

  Future<bool> setFolderIncluded(LocalMusicFolderLocation folder, bool value) =>
      _changeExclusion((visibility, active) => visibility.setFolderIncluded(
          folder, value, () => active() && (!value || _hasFolder(folder))));

  bool _hasFolder(LocalMusicFolderLocation folder) =>
      _byId.values.any((track) => track.folderLocations
          .any((candidate) => candidate.key == folder.key));

  Future<bool> setExclusionOverride(LocalMusicTrack track, bool value) =>
      _changeExclusion((visibility, active) => visibility.setOverride(
          value, () => active() ? _eligibleForHiding(track) : null));

  Future<bool> _changeExclusion(
      Future<bool> Function(LocalMusicVisibility, bool Function())
          change) async {
    final visibility = _visibility;
    if (visibility == null || _disposed) return false;
    bool active() => !_disposed && identical(_visibility, visibility);
    final changed = await change(visibility, active);
    if (changed && active()) _notify();
    return changed;
  }

  bool canHideTrack(LocalMusicTrack track) {
    final visibility = _visibility;
    return visibility != null &&
        _eligibleForHiding(track) != null &&
        !visibility.isHidden(track);
  }

  LocalMusicTrack? _eligibleForHiding(LocalMusicTrack track) {
    final current = _byId[track.playbackId];
    return !_disposed &&
            enabled &&
            !unavailable &&
            _choosing == null &&
            _renaming == null &&
            _removing == null &&
            _disabling == null &&
            track.visibilityKey != null &&
            current?.visibilityKey == track.visibilityKey
        ? current
        : null;
  }

  Future<HiddenLocalMusicTrack?> hideTrack(LocalMusicTrack track,
      {String? storageProof}) async {
    final visibility = _visibility;
    if (visibility == null) return null;
    final record = await visibility.hide(
      () =>
          identical(_visibility, visibility) ? _eligibleForHiding(track) : null,
      storageProof: storageProof,
    );
    if (record != null && identical(_visibility, visibility)) _notify();
    return record;
  }

  Set<String> get hiddenDownloadProofs =>
      _visibility?.hiddenStorageProofs ?? const {};

  Future<void> rememberHiddenDownloadAliases(
      Map<LocalMusicTrack, String> aliases,
      {bool Function()? isCurrent}) async {
    final visibility = _visibility;
    if (visibility == null ||
        aliases.isEmpty ||
        _disposed ||
        isCurrent?.call() == false) {
      return;
    }
    bool current() =>
        !_disposed &&
        identical(_visibility, visibility) &&
        isCurrent?.call() != false;
    final changed = await visibility.rememberDownloadAliases(() => {
          if (current())
            for (final entry in aliases.entries)
              if (identical(trackById(entry.key.playbackId), entry.key))
                if (entry.key.visibilityKey case final String key)
                  key: entry.value,
        });
    if (changed && current()) _notify();
  }

  Future<Map<String, List<LocalMusicTrack>>?> verifiedDownloadAliases(
      List<MusicFileProbe> files,
      {bool Function()? isCurrent}) async {
    final selection = _selection;
    if (!acceptsSessionSelection(selection.id) ||
        !loaded ||
        scanning ||
        isCurrent?.call() == false) {
      return null;
    }
    final snapshot = _tracks;
    final documents = files
        .where((file) => file.download.storageUri != null)
        .toList(growable: false);
    if (documents.isEmpty || snapshot.isEmpty) return {};

    final indexed = _representativeByUri;
    final matches = <String, Set<LocalMusicTrack>>{};
    try {
      for (final root in selection.roots) {
        if (root.isDocumentProvider || isRootUnavailable(root)) continue;
        if (!_loadedRoots.contains(root.uri)) return null;
        for (var start = 0; start < documents.length; start += 64) {
          final result = await _channel
              .invokeMapMethod<String, dynamic>('matchDownloadTracks', {
            'treeUri': root.uri.toString(),
            'selectionId': root.selectionId,
            'files': [
              for (final file in documents.skip(start).take(64))
                {
                  'key': file.download.videoId,
                  'uri': file.uri,
                  'folderUri': file.download.folderUri,
                  'identity': file.identity,
                  'byteLength': file.byteLength,
                },
            ],
          });
          if (result == null ||
              !identical(selection.roots, roots) ||
              !identical(snapshot, _tracks) ||
              !acceptsSessionSelection(selection.id) ||
              isCurrent?.call() == false) {
            return null;
          }
          for (final entry in result.entries) {
            if (entry.value is! List) continue;
            matches.putIfAbsent(entry.key, () => {}).addAll([
              for (final uri in entry.value as List)
                if (indexed[uri] case final track?) track,
            ]);
          }
        }
      }
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    return {
      for (final entry in matches.entries) entry.key: entry.value.toList()
    };
  }

  Future<bool> restoreTrack(HiddenLocalMusicTrack record) async {
    final visibility = _visibility;
    if (visibility == null || _disposed) return false;
    bool active() => !_disposed && identical(_visibility, visibility);
    final restored = await visibility.restore(record, active);
    if (restored && active()) _notify();
    return restored;
  }

  // The Android side reads only its stored selection here. It never queries
  // documents, opens audio or invokes the picker when initializing settings.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _foreground = binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    _lastCoverLoading = _loadCovers;
    if (_visibilityDatabase != null) {
      DeviceMusicArtworkPreferences.revision
          .addListener(_coverPreferenceChanged);
    }
    final revision = _revision;
    try {
      final saved = await _channel
          .invokeMethod<dynamic>('getFolder', {'includeScanPreference': true});
      if (!_current(revision) || _disabling != null) return;
      final folder =
          saved is Map && saved.containsKey('folder') ? saved['folder'] : saved;
      final selection = _parseSelection(folder);
      if (folder case {'tagSeparators': final String separators}) {
        _tagSeparators = separators;
      }
      _automaticScan = saved is Map && saved['automaticScan'] == true;
      _applySelection(selection);
      _scheduleAutomaticRefresh();
    } catch (e) {
      if (_revision == revision) _recordError(e);
    } finally {
      _notify();
    }
    unawaited(_reconcileDownloadRenames());
  }

  Future<_Selection> _readSelection() async {
    final result = await _channel.invokeMethod<dynamic>('getFolder');
    final selection = _parseSelection(result);
    if (result case {'tagSeparators': final String separators}) {
      _tagSeparators = separators;
    }
    return selection;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_resume());
    } else {
      _syncWatcher();
    }
  }

  Future<void> _resume() async {
    await revalidate();
    if (!_foreground || _disposed) return;
    _syncWatcher();
    _scheduleAutomaticRefresh();
  }

  Future<bool> setAutomaticScan(bool enabled) async {
    await initialize();
    if (_disposed) return false;
    if (_savingScanPreference case final saving?) return saving;
    if (_automaticScan == enabled) return true;
    final saving = _savingScanPreference = _saveAutomaticScan(enabled);
    _notify();
    try {
      return await saving;
    } finally {
      _savingScanPreference = null;
      _notify();
    }
  }

  Future<bool> _saveAutomaticScan(bool enabled) async {
    try {
      await _channel
          .invokeMethod<void>('setAutomaticScan', {'enabled': enabled});
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
    if (_disposed) return false;
    _automaticScan = enabled;
    _syncWatcher();
    _scheduleAutomaticRefresh();
    return true;
  }

  bool get _canWatch =>
      _automaticScan && _foreground && enabled && !unavailable && !_disposed;

  void _syncWatcher() {
    final previous = _watchId;
    if (_canWatch && previous == null) {
      _watchCallbacks.remove(previous);
      final id = _watchId = ++_nextWatchId;
      _watchCallbacks[id] = (source) {
        if (roots.any((root) =>
            root.uri.toString() == source && !isRootUnavailable(root))) {
          _scheduleAutomaticRefresh();
        }
      };
      _channel.setMethodCallHandler(_handleNativeCall);
      unawaited(_setNativeWatcher(id));
    } else if (!_canWatch && previous != null) {
      _watchCallbacks.remove(previous);
      _watchId = null;
      _clearAutomaticRefresh();
      unawaited(_setNativeWatcher(null));
    }
    if (_canWatch &&
        roots.any((root) => !root.isSystem && !isRootUnavailable(root))) {
      // Filesystem providers may stop watching as soon as their cursors close.
      _folderRefresh ??= Timer.periodic(
          _folderRefreshInterval, (_) => _scheduleAutomaticRefresh());
    } else {
      _folderRefresh?.cancel();
      _folderRefresh = null;
    }
  }

  Future<void> _setNativeWatcher(int? watchId) async {
    try {
      await _channel.invokeMethod<void>('watchLibrary', {'watchId': watchId});
    } on PlatformException {
      // Foreground and resume refresh remain available if observing fails.
    } on MissingPluginException {
      // This platform does not expose Android change notifications.
    }
  }

  void _scheduleAutomaticRefresh() {
    if (!_canWatch) return;
    _automaticRefreshPending = true;
    if (busy || _automaticRefresh != null) return;
    _automaticRefresh = Timer(_watchDebounce, () {
      _automaticRefresh = null;
      if (!_canWatch || busy || !_automaticRefreshPending) return;
      _automaticRefreshPending = false;
      unawaited(refresh());
    });
  }

  void _clearAutomaticRefresh() {
    _automaticRefreshPending = false;
    _automaticRefresh?.cancel();
    _automaticRefresh = null;
  }

  /// Android can revoke a grant while the Activity is in the background.
  /// A negative result removes this root's tracks and notifies the player.
  Future<void> revalidate() async {
    final picker = _picker;
    if (picker != null) {
      try {
        await picker;
      } on Exception {
        // If the chooser failed, the previous source still needs checking.
      }
    }
    if (_disposed || !enabled || _removing != null || _disabling != null) {
      return;
    }
    final revision = _revision;
    await Future.wait(roots.map((root) => _revalidateRoot(root, revision)));
  }

  Future<void> _revalidateRoot(LocalMusicRoot root, int revision) async {
    bool? available;
    try {
      available = await _channel.invokeMethod<bool>(
          'checkFolderAccess', {'treeUri': root.uri.toString()});
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (!_current(revision)) return;
    if (available == null) {
      if (root.isDocumentProvider &&
          !isRootUnavailable(root) &&
          _unreachableProviders.add(root.uri)) {
        _notify();
      }
      return;
    }
    if (available) {
      if (_unavailableRoots.remove(root.uri)) {
        if (_error == 'FOLDER_UNAVAILABLE') _error = null;
        _syncWatcher();
        _notify();
      }
      return;
    }
    if (_picker != null) {
      // The pending picker may reconnect this tree.
      await revalidate();
      return;
    }
    _loseAccess(root);
  }

  bool _current(int revision) => _revision == revision && !_disposed;

  void _loseAccess(LocalMusicRoot root) {
    if (!_unavailableRoots.add(root.uri)) return;
    _unreachableProviders.remove(root.uri);
    _rootRevisions.update(root.uri, (value) => value + 1, ifAbsent: () => 1);
    _loadedRoots.remove(root.uri);
    _tracksByRoot.remove(root.uri);
    if (root.isSystem) _indexedPlaylists = const [];
    _repairsByRoot.remove(root.uri);
    _unavailableRepairRoots.remove(root.uri);
    if (_scanReport case final report?) {
      final remaining = report.value.locations
          .where((location) => location.root.uri != root.uri)
          .toList();
      if (remaining.length != report.value.locations.length) {
        _scanReport = remaining.isEmpty
            ? null
            : (
                owner: report.owner,
                value: LocalMusicScanReport(locations: remaining, partial: true)
              );
      }
    }
    if (unavailable) _error = 'FOLDER_UNAVAILABLE';
    _publish();
    _syncWatcher();
    _notify();
  }

  _Selection _parseSelection(dynamic result) {
    if (result == null) return (roots: const [], id: null);
    if (result is Map && result['roots'] is List) {
      final selected = (result['roots'] as List).map(_parseRoot).toList();
      if (selected.map((root) => root.uri).toSet().length != selected.length) {
        throw const FormatException('Duplicate local music location');
      }
      final id = result['selectionId'] as String?;
      _usesMultipleRoots = true;
      return (roots: List.unmodifiable(selected), id: id);
    }
    final root = _parseRoot(result);
    return (roots: List.unmodifiable([root]), id: root.selectionId);
  }

  static LocalMusicRoot _parseRoot(dynamic result) {
    if (result is Map && result['uri'] is String && result['name'] is String) {
      final uri = Uri.tryParse(result['uri'] as String);
      if (uri != null &&
          uri.scheme == 'content' &&
          uri.authority.isNotEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          (uri == LocalMusicTrack.systemSource ||
              (uri.pathSegments.length == 2 &&
                  uri.pathSegments.first == 'tree' &&
                  uri.pathSegments.last.isNotEmpty))) {
        return LocalMusicRoot(
          uri: uri,
          name: result['name'] as String,
          selectionId: result['selectionId'] as String?,
          needsReapproval: result['needsReapproval'] == true,
          isDocumentProvider: uri != LocalMusicTrack.systemSource &&
              result['isDocumentProvider'] == true,
        );
      }
    }
    throw const FormatException('Invalid local music folder');
  }

  void _applySelection(_Selection selection) {
    _scanReport = null;
    final previous = {for (final root in roots) root.uri: root};
    final retained = {
      for (final root in selection.roots)
        if (previous[root.uri]?.selectionId == root.selectionId &&
            previous[root.uri]?.isDocumentProvider == root.isDocumentProvider &&
            !root.needsReapproval)
          root.uri,
    };
    _loadedRoots.retainAll(retained);
    _unreachableProviders.retainAll(retained);
    _tracksByRoot.removeWhere((uri, _) => !retained.contains(uri));
    if (!retained.contains(LocalMusicTrack.systemSource)) {
      _indexedPlaylists = const [];
    }
    _repairsByRoot.removeWhere((uri, _) => !retained.contains(uri));
    _unavailableRepairRoots.retainAll(retained);
    _unavailableRoots
      ..clear()
      ..addAll(selection.roots
          .where((root) => root.needsReapproval)
          .map((root) => root.uri));
    _selection = selection;
    _publish();
    _syncWatcher();
  }

  Future<bool> chooseFolder({LocalMusicRoot? reconnect}) => _select(
      reconnect?.isDocumentProvider == true
          ? 'pickProviderFolder'
          : 'pickFolder',
      initialUri: reconnect?.uri);
  Future<bool> chooseProviderFolder() => _select('pickProviderFolder');
  Future<bool> chooseSystem() => _select('pickSystem');

  /// Checks the current provider stream before attempting to seek in it.
  Future<bool> canSeekProviderTrack(LocalMusicTrack track) async {
    final root = roots.where((root) => root.uri == track.sourceUri).firstOrNull;
    if (root == null || !root.isDocumentProvider || isRootUnavailable(root)) {
      return false;
    }
    final revision = _revision;
    bool currentTrack() =>
        _current(revision) &&
        !isRootUnavailable(root) &&
        _byId[track.playbackId]?.uri == track.uri;
    if (!currentTrack()) return false;
    try {
      final seekable =
          await _channel.invokeMethod<bool>('canSeekProviderTrack', {
        'treeUri': root.uri.toString(),
        'selectionId': root.selectionId,
        'uri': track.uri,
      });
      return seekable == true && currentTrack();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Cancellation leaves the approved sources and their tracks intact.
  Future<bool> _select(String method, {Uri? initialUri}) {
    if (_disabling != null ||
        _renaming != null ||
        _repairing != null ||
        _editingTags != null ||
        _removing != null) {
      return Future.value(false);
    }
    if (_choosing != null) return _choosing!;
    final result = _choosing = _choose(method, initialUri).whenComplete(() {
      _choosing = null;
      _notify();
      if (_automaticRefreshPending) _scheduleAutomaticRefresh();
    });
    _notify();
    return result;
  }

  Future<bool> _choose(String method, Uri? initialUri) async {
    final revision = _revision;
    await initialize();
    if (!_current(revision)) return false;
    try {
      final folder = roots
          .where((root) =>
              !root.isSystem &&
              root.isDocumentProvider == (method == 'pickProviderFolder'))
          .firstOrNull;
      _picker = _channel.invokeMethod<dynamic>(
          method, {'initialUri': (initialUri ?? folder?.uri)?.toString()});
      final result = await _picker;
      _picker = null;
      if (!_current(revision) || result == null) return false;
      _applySelection(_parseSelection(result));
      _error = null;
      final newRevision = ++_revision;
      await _startScan(newRevision);
      return _current(newRevision);
    } catch (e) {
      _picker = null;
      if (_revision == revision) _recordError(e);
      return false;
    }
  }

  Future<void> refresh({bool force = false}) async {
    await initialize();
    if (_disposed ||
        !enabled ||
        _disabling != null ||
        _renaming != null ||
        _repairing != null ||
        _editingTags != null ||
        _removing != null) {
      return;
    }
    if (_choosing != null) {
      await _choosing;
      return;
    }
    if (_scanning case final current?) {
      if (!force || _activeScan?.force == true) return current;
      final revision = _revision;
      await current;
      if (!_current(revision) || unavailable) return;
      // A requested forced pass must still reread tags after an incremental one.
      if (_scanning != null) return refresh(force: true);
      if (busy) return;
    }
    await _startScan(_revision, force: force);
  }

  /// Resolve paths only from roots which Android affirmatively authorized
  /// after a scan. The paths are never used to open an audio file.
  Future<M3uIndexSnapshot?> m3uIndex() async {
    await initialize();
    final revision = _revision;
    final owner = visibilityProfile;
    bool acceptsContext() =>
        _current(revision) &&
        visibilityProfile == owner &&
        enabled &&
        _choosing == null &&
        _renaming == null &&
        _repairing == null &&
        _editingTags == null &&
        _removing == null &&
        _disabling == null;

    if (!acceptsContext()) return null;
    await revalidate();
    await refresh();
    if (!acceptsContext()) return null;
    final checked = <Uri, int?>{};
    final locations = <Uri, Map>{};
    final rootsByVolume = <String, String>{};
    for (final root in roots) {
      if (isRootUnavailable(root) || !_loadedRoots.contains(root.uri)) continue;
      final rootRevision = _rootRevisions[root.uri];
      final data =
          await _channel.invokeMapMethod<String, Object?>('playlistLocations', {
        'treeUri': root.uri.toString(),
        'selectionId': root.selectionId,
      });
      if (!acceptsContext()) return null;
      if (_rootRevisions[root.uri] != rootRevision ||
          isRootUnavailable(root) ||
          data?['locations'] is! Map ||
          data?['roots'] is! Map) {
        continue;
      }
      locations[root.uri] = data!['locations'] as Map;
      rootsByVolume.addAll(Map<String, String>.from(data['roots'] as Map));
      checked[root.uri] = rootRevision;
    }
    bool isCurrent() =>
        acceptsContext() &&
        checked.entries.every((root) => _rootRevisions[root.key] == root.value);

    if (checked.isEmpty || !isCurrent()) return null;
    return (
      index: M3uTrackIndex(
        [
          for (final track in visibleTracks)
            if (!track.isCueTrack && devicePlaylistVideo(track) != null)
              if (m3uLocation(locations[track.sourceUri]?[track.uri])
                  case final location?)
                (track: track, location: location),
        ],
        rootsByVolume,
      ),
      isCurrent: isCurrent,
    );
  }

  /// Start with a complete catalog of the available, selected locations.
  Future<void> loadForShuffle() async {
    await initialize();
    await revalidate();
    if (scanning ||
        roots.any((root) =>
            !isRootUnavailable(root) && !_loadedRoots.contains(root.uri))) {
      await refresh();
    }
  }

  Future<void> _startScan(int revision, {bool force = false}) async {
    _clearAutomaticRefresh();
    _scanReport = null;
    final active = _activeScan = _LocalMusicScan(force: force);
    final scan = _scanning = _scanRoots(revision, active);
    _notify();
    try {
      await scan;
    } finally {
      if (identical(_scanning, scan)) {
        _scanning = null;
        _activeScan = null;
        _notify();
        if (_automaticRefreshPending) _scheduleAutomaticRefresh();
      }
    }
  }

  Future<void> cancelScan() async {
    final active = _activeScan;
    if (active == null || active.cancelled || _disposed) return;
    _clearAutomaticRefresh();
    active.cancelled = true;
    _notify();
    final scanId = active.rootScanId;
    if (scanId == null) return;
    try {
      await _channel.invokeMethod<void>('cancelScan', {'scanId': scanId});
    } on PlatformException {
      // Late results are ignored even if the provider could not be interrupted.
    } on MissingPluginException {
      // This platform cannot interrupt Android scans.
    }
  }

  /// Resume as soon as the selected source has delivered the needed tracks.
  Future<void> loadForPlayback(Iterable<String> trackIds) async {
    await initialize();
    final requested = trackIds.toSet();
    await _waitForTracks(() => requested
        .every((id) => trackById(id) != null || playlistTrackById(id) != null));
  }

  Future<void> _waitForTracks(bool Function() ready) async {
    if (ready() || !enabled || unavailable || _disposed) return;
    final revision = _revision;
    final arrived = Completer<void>();
    void onChange() {
      if (!arrived.isCompleted && (ready() || _revision != revision)) {
        arrived.complete();
      }
    }

    addListener(onChange);
    try {
      await Future.any([refresh(), arrived.future]);
    } finally {
      if (!_disposed) removeListener(onChange);
    }
  }

  Future<void> _scanRoots(int revision, _LocalMusicScan scan) async {
    final reportOwner = visibilityProfile;
    final reportEpoch = _scanReportEpoch;
    final observed = <LocalMusicRootScanReport>[];
    final rootRevisions = Map.of(_rootRevisions);
    var partial = false;
    if (!unavailable) _error = null;
    int coverRevision;
    do {
      observed.clear();
      partial = false;
      coverRevision = _coverPolicyRevision;
      final loadCovers = _loadCovers;
      for (final root in _localRootsFirst) {
        if (!_current(revision) || scan.cancelled) return;
        if (coverRevision != _coverPolicyRevision) break;
        if (!isRootUnavailable(root)) {
          final result =
              await _scan(root, revision, scan, coverRevision, loadCovers);
          if (result?.report case final report?) observed.add(report);
          partial = partial || result?.partial == true;
        }
      }
    } while (_current(revision) &&
        !scan.cancelled &&
        coverRevision != _coverPolicyRevision);
    if (_current(revision) && !scan.cancelled) {
      if (reportEpoch == _scanReportEpoch && reportOwner == visibilityProfile) {
        final locations = observed.where((location) {
          final root = location.root;
          return !isRootUnavailable(root) &&
              rootRevisions[root.uri] == _rootRevisions[root.uri];
        }).toList();
        if (locations.isNotEmpty) {
          _scanReport = (
            owner: reportOwner,
            value: LocalMusicScanReport(
                locations: locations,
                partial: partial || locations.length < roots.length),
          );
        }
      }
      unawaited(_rememberDocumentProofs());
      unawaited(_reconcileDownloadRenames());
    }
  }

  Future<_RootScan?> _scan(LocalMusicRoot root, int revision,
      _LocalMusicScan scan, int coverRevision, bool loadCovers) async {
    final rootRevision = _rootRevisions[root.uri];
    final previous = _tracksByRoot[root.uri];
    bool currentRoot() =>
        _current(revision) && _rootRevisions[root.uri] == rootRevision;
    bool active() => currentRoot() && _coverPolicyRevision == coverRevision;
    final scanId = scan.rootScanId = ++_nextScanId;
    var published = false;
    _channel.setMethodCallHandler(_handleNativeCall);
    _batchCallbacks[scanId] = (documents) {
      // Provider listings can report a partial directory before an outage.
      // Publish the new membership only when the listing completes.
      if (!active() || scan.cancelled || root.isDocumentProvider) return;
      final merged =
          Map<String, LocalMusicTrack>.of(_tracksByRoot[root.uri] ?? const {});
      _collectTracks(documents, root, merged);
      _tracksByRoot[root.uri] = merged;
      _publish();
      _notify();
    };
    try {
      final result = await _channel.invokeMethod<dynamic>('listTracks', {
        'treeUri': root.uri.toString(),
        'scanId': scanId,
        'force': scan.force,
        'detailed': true,
        'loadCovers': loadCovers,
      });
      if (!active() || scan.cancelled) return null;
      final documents = result is Map ? result['tracks'] : result;
      if (documents is! List) throw const FormatException('No scan result');
      final tracks = <String, LocalMusicTrack>{};
      _collectTracks(documents, root, tracks);
      final partial = result is Map && result['partial'] == true;
      if (root.isSystem && !partial) {
        final playlists = await _readIndexedPlaylists(root);
        if (!active() || scan.cancelled) return null;
        _indexedPlaylists = playlists;
      }
      if (!partial && !root.isDocumentProvider) {
        final repairs = await _readMovedFileRepairs(root);
        if (!active() || scan.cancelled) return null;
        if (repairs == null) {
          _unavailableRepairRoots.add(root.uri);
        } else {
          _unavailableRepairRoots.remove(root.uri);
          _repairsByRoot[root.uri] =
              LocalMusicRepairSnapshot.fromChannel(repairs, tracks.containsKey);
        }
      }
      _tracksByRoot[root.uri] = tracks;
      _loadedRoots.add(root.uri);
      if (partial) _error ??= 'SCAN_PARTIAL';
      _unreachableProviders.remove(root.uri);
      _publish();
      published = true;
      _notify();
      return (
        report: LocalMusicRootScanReport.fromResult(root, result),
        partial: result is Map && result['partial'] == true,
      );
    } catch (e) {
      if (!active()) return null;
      if (e is PlatformException && e.code == 'FOLDER_UNAVAILABLE') {
        _loseAccess(root);
      } else if (!scan.cancelled &&
          root.isDocumentProvider &&
          e is PlatformException &&
          e.code == 'SCAN_UNAVAILABLE') {
        _unreachableProviders.add(root.uri);
      } else if (!scan.cancelled) {
        _recordError(e);
      }
      return null;
    } finally {
      _batchCallbacks.remove(scanId);
      scan.rootScanId = null;
      if (currentRoot() &&
          !published &&
          !identical(_tracksByRoot[root.uri], previous)) {
        if (previous == null) {
          _tracksByRoot.remove(root.uri);
        } else {
          _tracksByRoot[root.uri] = previous;
        }
        _publish();
      }
    }
  }

  Future<List<LocalMusicIndexedPlaylist>> _readIndexedPlaylists(
      LocalMusicRoot root) async {
    try {
      final playlists =
          await _channel.invokeMethod<Object?>('listIndexedPlaylists', {
        'treeUri': root.uri.toString(),
        'selectionId': root.selectionId,
      });
      return LocalMusicIndexedPlaylist.parse(playlists);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final data = call.arguments;
    if (call.method == 'trackBatch' && data is Map && data['tracks'] is List) {
      _batchCallbacks[data['scanId']]?.call(data['tracks'] as List);
    } else if (call.method == 'libraryChanged' &&
        data is Map &&
        data['treeUri'] is String) {
      _watchCallbacks[data['watchId']]?.call(data['treeUri'] as String);
    }
  }

  static void _collectTracks(Iterable<dynamic> documents, LocalMusicRoot root,
      Map<String, LocalMusicTrack> tracks) {
    for (final document in documents) {
      final track = LocalMusicTrack.fromDocument(document, root.uri,
          isDocumentProvider: root.isDocumentProvider);
      if (track != null) tracks[track.playbackId] = track;
    }
  }

  void _publish() {
    final tracks = <String, LocalMusicTrack>{};
    for (final root in _localRootsFirst) {
      // Prefer a device copy when both picker modes expose the same document.
      for (final track
          in _tracksByRoot[root.uri]?.values ?? const <LocalMusicTrack>[]) {
        tracks.putIfAbsent(track.playbackId, () => track);
      }
    }
    final displayed = <LocalMusicTrack>[];
    final byUri = <String, LocalMusicTrack>{};
    final documents = <(String, String), List<LocalMusicTrack>>{};
    for (final track in tracks.values) {
      if (track.isCueTrack) {
        displayed.add(track);
        continue;
      }
      final identity = track.documentIdentity;
      if (identity == null) {
        displayed.add(track);
        byUri[track.uri] = track;
      } else {
        final copies = documents.putIfAbsent(identity, () {
          displayed.add(track);
          return [];
        });
        copies.add(track);
        byUri[track.uri] = copies.first;
      }
    }
    _byId = tracks;
    _tracks = List.unmodifiable(displayed);
    _documents = documents;
    _representativeByUri = byUri;
    _byVisibilityKey = {
      for (final track in tracks.values) ...{
        if (track.visibilityKey case final String key) key: track,
        if (!track.isCueTrack)
          if (track.documentVisibilityKey case final String key) key: track,
      },
    };
  }

  Map<String, Object?>? trackShareArguments(LocalMusicTrack track) {
    if (busy || track.isCueTrack) return null;
    final root = approvedRootForTrack(track);
    if (root == null) return null;
    return {
      'treeUri': root.uri.toString(),
      'selectionId': root.selectionId,
      'uri': track.uri,
      'trackId': track.playbackId,
    };
  }

  Future<bool> shareTrack(LocalMusicTrack track) async {
    final arguments = trackShareArguments(track);
    if (arguments == null) return false;
    return await _channel.invokeMethod<bool>('shareTrack', arguments) ?? false;
  }

  Future<bool> shareTracks(List<Map<String, Object?>> tracks,
      {required Future<void> cancelled}) async {
    if (_disposed || tracks.length < 2) return false;
    final requestId = _nextShareId = (_nextShareId % 0x7fffffff) + 1;
    final launched = _channel.invokeMethod<bool>(
        'shareTracks', {'tracks': tracks, 'requestId': requestId});
    var pending = true;
    unawaited(cancelled.then((_) async {
      if (!pending) return;
      try {
        await _channel
            .invokeMethod<void>('cancelShareTracks', {'requestId': requestId});
      } on PlatformException {
        // The launch result reports native failure.
      } on MissingPluginException {
        // The activity or engine may already be detached.
      }
    }));
    try {
      return await launched ?? false;
    } finally {
      pending = false;
    }
  }

  Future<Map<String, dynamic>?> _readMovedFileRepairs(
      LocalMusicRoot root) async {
    try {
      return await _channel
          .invokeMapMethod<String, dynamic>('listMovedFileRepairs', {
        'treeUri': root.uri.toString(),
        'selectionId': root.selectionId,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return const {};
    }
  }

  Future<bool> confirmMovedFileRepair(
      LocalMusicMissingTrack missing, LocalMusicMoveCandidate candidate,
      {bool Function()? isCurrent}) async {
    if (busy ||
        isCurrent?.call() == false ||
        !missing.candidates.contains(candidate)) {
      return false;
    }
    final root = roots
        .where((root) =>
            identical(_repairsByRoot[root.uri]?.missing[missing.id], missing))
        .firstOrNull;
    if (root == null ||
        isRootUnavailable(root) ||
        _unavailableRepairRoots.contains(root.uri) ||
        _tracksByRoot[root.uri]?.containsKey(candidate.id) != true) {
      return false;
    }
    final repair = _repairing = _confirmMove(root, missing, candidate);
    _notify();
    try {
      return await repair && isCurrent?.call() != false;
    } finally {
      _repairing = null;
      _notify();
    }
  }

  Future<bool> _confirmMove(LocalMusicRoot root, LocalMusicMissingTrack missing,
      LocalMusicMoveCandidate candidate) async {
    final revision = _revision;
    final rootRevision = _rootRevisions[root.uri];
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('confirmMovedFileRepair', {
        'treeUri': root.uri.toString(),
        'selectionId': root.selectionId,
        'missingId': missing.id,
        'candidateId': candidate.id,
      });
      final tracks = _tracksByRoot[root.uri];
      if (result == null ||
          tracks == null ||
          !_current(revision) ||
          _rootRevisions[root.uri] != rootRevision ||
          isRootUnavailable(root)) {
        return false;
      }
      final repairs =
          LocalMusicRepairSnapshot.fromChannel(result, tracks.containsKey);
      if (repairs.aliases[missing.id] != candidate.id) return false;
      _repairsByRoot[root.uri] = repairs;
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  bool canEditTags(LocalMusicTrack track) {
    final current = _byId[track.playbackId];
    return !_disposed &&
        !busy &&
        current != null &&
        current.canEditTags &&
        current.uri == track.uri &&
        current.sourceUri == track.sourceUri &&
        current.visibilityKey == track.visibilityKey &&
        _tagRoot(current) != null;
  }

  Future<LocalMusicTags?> readTags(LocalMusicTrack track) async {
    final root = _tagRoot(track);
    if (root == null || !canEditTags(track)) return null;
    final revision = _revision;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'readTrackTags',
      _tagTarget(root, track.uri),
    );
    if (!_current(revision) || isRootUnavailable(root)) return null;
    final fileRevision = result?['revision'];
    final values = result?['values'];
    final supported = result?['editableFields'];
    if (fileRevision is! String ||
        fileRevision.length != 64 ||
        values is! Map ||
        !LocalMusicTags._textFields.every(values.containsKey) ||
        LocalMusicTags.fields.any(
          (field) => values[field] != null && values[field] is! String,
        ) ||
        (supported != null && supported is! List)) {
      throw PlatformException(code: 'TAGS_FAILED');
    }
    return LocalMusicTags._(
      Map.unmodifiable({
        for (final field in LocalMusicTags.fields)
          field: values[field] as String?,
      }),
      Set.unmodifiable({
        for (final field in LocalMusicTags.fields)
          if (values.containsKey(field) &&
              (supported is! List || supported.contains(field)))
            field,
      }),
      fileRevision,
      root,
      track.uri,
      canEditArtwork: result?['artworkEditable'] == true,
      canRemoveArtwork: result?['artworkRemovable'] == true,
      hasArtwork: result?['hasArtwork'] == true,
      allowsMonthReleaseDate: result?['id3Version'] == 4,
    );
  }

  Future<Uint8List?> pickTagArtwork() async {
    final image = await _files.invokeMethod<Uint8List>('openPlaylistCover');
    if (image != null && image.length > _maxTagArtworkBytes) {
      throw PlatformException(code: 'TAGS_ARTWORK_INVALID');
    }
    return image;
  }

  Future<bool> editTags(
    LocalMusicTrack track,
    LocalMusicTags original,
    Map<String, String?> changes, {
    LocalMusicArtworkEdit? artwork,
  }) =>
      _editTags(track, original, changes, artwork: artwork);

  Future<bool> embedPlainLyrics(
    LocalMusicTrack track,
    LocalMusicTags original, {
    required String language,
    required String descriptor,
    required String text,
  }) =>
      _editTags(track, original, const {}, lyrics: {
        'language': language,
        'descriptor': descriptor,
        'text': text,
      });

  Future<bool> _editTags(
    LocalMusicTrack track,
    LocalMusicTags original,
    Map<String, String?> changes, {
    LocalMusicArtworkEdit? artwork,
    Map<String, String>? lyrics,
  }) async {
    final root = _tagRoot(track);
    if (root == null ||
        root.uri != original._root.uri ||
        root.selectionId != original._root.selectionId ||
        track.uri != original._uri ||
        !canEditTags(track)) {
      throw PlatformException(code: 'TAGS_CHANGED');
    }
    if (!changes.keys.every(original.editableFields.contains) ||
        (artwork != null && !original.canEditArtwork)) {
      throw PlatformException(code: 'TAGS_UNSUPPORTED');
    }
    if (original.validateNumberChanges(changes) != null) {
      throw PlatformException(code: 'TAGS_INVALID_NUMBER');
    }
    final edited = {
      for (final entry in changes.entries)
        entry.key: LocalMusicTags._genreAndDateFields.contains(entry.key)
            ? LocalMusicTags.normalizeChange(entry.key, entry.value)
            : entry.value,
    }..removeWhere((field, value) => value == original.values[field]);
    if (!original.acceptsReleaseDate(edited['releaseDate'])) {
      throw PlatformException(code: 'TAGS_INVALID_RELEASE_DATE');
    }
    if (edited.isEmpty && artwork == null && lyrics == null) return false;
    final operation = _editingTags = _saveTags(
        root, track, original.revision, edited, _revision,
        artwork: artwork, lyrics: lyrics);
    _notify();
    try {
      return await operation;
    } finally {
      _editingTags = null;
      _notify();
      if (_automaticRefreshPending) _scheduleAutomaticRefresh();
    }
  }

  Future<bool> _saveTags(
    LocalMusicRoot root,
    LocalMusicTrack current,
    String fileRevision,
    Map<String, String?> changes,
    int revision, {
    LocalMusicArtworkEdit? artwork,
    Map<String, String>? lyrics,
  }) async {
    final result = await _channel.invokeMethod<dynamic>('editTrackTags', {
      ..._tagTarget(root, current.uri),
      'revision': fileRevision,
      'changes': changes,
      if (!_loadCovers) 'loadCovers': false,
      if (artwork != null) 'artwork': artwork.image,
      if (lyrics != null) 'lyrics': lyrics,
    });
    if (result == null) return false;
    if (!_current(revision) || isRootUnavailable(root)) return true;
    final track = LocalMusicTrack.fromDocument(result, root.uri);
    if (track == null ||
        track.uri != current.uri ||
        track.playbackId != current.playbackId) {
      throw PlatformException(code: 'TAGS_SAVED_REFRESH_REQUIRED');
    }
    _tracksByRoot[root.uri]?[track.playbackId] = track;
    _publish();
    return true;
  }

  LocalMusicRoot? _tagRoot(LocalMusicTrack track) {
    return roots
        .where((root) =>
            root.uri == track.sourceUri &&
            !root.needsReapproval &&
            !isRootUnavailable(root))
        .firstOrNull;
  }

  static Map<String, String?> _tagTarget(LocalMusicRoot root, String uri) => {
        'treeUri': root.uri.toString(),
        'selectionId': root.selectionId,
        'uri': uri,
      };

  Future<bool> canSetTrackRingtone(LocalMusicTrack track) async =>
      await _trackRingtone<bool>('canSetTrackRingtone', track) ?? false;

  Future<String?> setTrackRingtone(LocalMusicTrack track) =>
      _trackRingtone<String>('setTrackRingtone', track);

  Future<T?> _trackRingtone<T>(String method, LocalMusicTrack track) async {
    if (busy || track.isCueTrack) return null;
    final root = approvedRootForTrack(track);
    if (root == null) return null;
    return _channel.invokeMethod<T>(method, {
      'treeUri': root.uri.toString(),
      'selectionId': root.selectionId,
      'uri': track.uri,
      'trackId': track.playbackId,
      'title': track.title,
    });
  }

  Future<bool> renameTrack(LocalMusicTrack track, String fullName) async {
    final current = _byId[track.playbackId];
    if (current == null || !current.canRename || busy) {
      return false;
    }
    final root =
        roots.where((root) => root.uri == current.sourceUri).firstOrNull;
    if (root == null || isRootUnavailable(root)) return false;
    final revision = _revision;
    final rename = _renaming = _rename(root, current, fullName, revision);
    _notify();
    try {
      return await rename;
    } finally {
      _renaming = null;
      _notify();
      if (_automaticRefreshPending) _scheduleAutomaticRefresh();
    }
  }

  Future<bool> _rename(LocalMusicRoot root, LocalMusicTrack current,
      String name, int revision) async {
    _error = null;
    try {
      final result = await _channel.invokeMethod<dynamic>('renameTrack', {
        'treeUri': root.uri.toString(),
        'uri': current.uri,
        'name': name,
        'loadCovers': _loadCovers,
      });
      if (result == null) return false;
      final reconcile = _reconcileDownloadRenames();
      if (!_current(revision) || isRootUnavailable(root)) {
        await reconcile;
        return false;
      }
      final track = LocalMusicTrack.fromDocument(result, root.uri);
      if (track == null || track.playbackId != current.playbackId) {
        throw const FormatException('Invalid rename result');
      }
      if (track.uri != current.uri) {
        for (final copy in _copies(current)) {
          if (copy.sourceUri != root.uri) {
            _tracksByRoot[copy.sourceUri]?.remove(copy.playbackId);
          }
        }
      }
      _tracksByRoot[root.uri]?[track.playbackId] = track;
      _publish();
      _notify();
      await reconcile;
      return true;
    } catch (error) {
      unawaited(_reconcileDownloadRenames());
      if (_revision == revision) _recordError(error);
      return false;
    }
  }

  Future<void> _reconcileDownloadRenames() {
    if (!identical(this, instance)) return Future.value();
    return _downloadRenameSync = _downloadRenameSync.then((_) async {
      try {
        final pending =
            await _channel.invokeListMethod<dynamic>('pendingRenames');
        for (final record in pending ?? const []) {
          if (record
              case {
                'id': final String id,
                'oldUri': final String oldUri,
                'newUri': final String newUri,
              }) {
            await reconcileLocalMusicDownloadRename(oldUri, newUri);
            await _channel.invokeMethod<void>('acknowledgeRename', {
              'id': id,
              'oldUri': oldUri,
              'newUri': newUri,
            });
          }
        }
      } on Exception {
        // Android keeps unacknowledged changes so startup can retry them.
      }
    });
  }

  /// Forget one grant while keeping the other locations and their tracks.
  Future<bool> removeRoot(LocalMusicRoot root) {
    if (!roots.contains(root) ||
        _choosing != null ||
        _renaming != null ||
        _editingTags != null ||
        _disabling != null ||
        _removing != null) {
      return Future.value(false);
    }
    if (!_usesMultipleRoots) return disable().then((_) => error == null);
    final result = _removing = _remove(root).whenComplete(() {
      _removing = null;
      _notify();
      if (_automaticRefreshPending) _scheduleAutomaticRefresh();
    });
    _notify();
    return result;
  }

  Future<bool> _remove(LocalMusicRoot root) async {
    final revision = _revision;
    try {
      await _rememberDocumentProofs();
      if (!_current(revision)) return false;
      final result = await _channel.invokeMethod<dynamic>(
          'forgetFolder', {'treeUri': root.uri.toString()});
      if (!_current(revision)) return false;
      final selection = _parseSelection(result);
      if (selection.roots.any((selected) => selected.uri == root.uri)) {
        throw const FormatException('Music location was not removed');
      }
      ++_revision;
      _applySelection(selection);
      _error = unavailable ? 'FOLDER_UNAVAILABLE' : null;
      if (scanning) await _startScan(_revision);
      return true;
    } catch (error) {
      if (_current(revision)) _recordError(error);
      return false;
    }
  }

  /// Drop membership before waiting on a picker, scan or Android grant release.
  Future<void> disable() {
    if (_disabling != null) return _disabling!;
    ++_revision;
    _applySelection((roots: const [], id: null));
    _error = null;
    final result = _disabling = _forget().whenComplete(() {
      _disabling = null;
      _notify();
    });
    _notify();
    return result;
  }

  Future<void> _forget() async {
    try {
      if (_usesMultipleRoots) {
        await _channel.invokeMethod<void>('forgetFolders');
        return;
      }
      // A picker can finish after opt-out and already hold a new native grant.
      try {
        await _picker;
      } on PlatformException {
        // The old grant may still exist when the pending picker failed.
      }
      final saved = await _readSelection();
      if (_usesMultipleRoots) {
        await _channel.invokeMethod<void>('forgetFolders');
      } else if (saved.roots.isNotEmpty) {
        await _channel.invokeMethod<void>(
            'forgetFolder', {'treeUri': saved.roots.single.uri.toString()});
      }
    } catch (e) {
      _recordError(e);
    }
  }

  void _recordError(Object e) {
    _error = e is PlatformException ? e.code : 'LOCAL_MUSIC_ERROR';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanReport = null;
    _syncWatcher();
    if (_initialization != null) {
      WidgetsBinding.instance.removeObserver(this);
      if (_visibilityDatabase != null) {
        DeviceMusicArtworkPreferences.revision
            .removeListener(_coverPreferenceChanged);
      }
    }
    super.dispose();
  }
}
