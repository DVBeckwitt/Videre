import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../downloads/services/download_rename.dart';
import '../../downloads/services/download_storage.dart';
import '../../globals.dart';
import '../../utils/interfaces/db.dart';
import '../models/local_music_root.dart';
import '../models/local_music_track.dart';
import 'local_music_visibility.dart';

export '../models/local_music_root.dart';
export 'local_music_visibility.dart' show HiddenLocalMusicTrack;

typedef _Selection = ({List<LocalMusicRoot> roots, String? id});

/// Library for the Android music sources the listener has approved.
class LocalMusicLibrary extends ChangeNotifier with WidgetsBindingObserver {
  static final instance = LocalMusicLibrary(visibilityDatabase: () => db);
  static const _channel =
      MethodChannel('com.github.dvbeckwitt.videre/local_music');
  static final _batchCallbacks = <int, void Function(List<dynamic>)>{};
  static int _nextScanId = 0;

  LocalMusicLibrary({IDbClient Function()? visibilityDatabase})
      : _visibilityDatabase = visibilityDatabase;

  final IDbClient Function()? _visibilityDatabase;
  LocalMusicVisibility? _profileVisibility;
  _Selection _selection = (roots: const [], id: null);
  bool _usesMultipleRoots = false;
  final _unavailableRoots = <Uri>{};
  final _rootRevisions = <Uri, int>{};
  final _loadedRoots = <Uri>{};
  final _tracksByRoot = <Uri, Map<String, LocalMusicTrack>>{};
  List<LocalMusicTrack> _tracks = const [];
  Map<String, LocalMusicTrack> _byId = const {};
  Map<String, LocalMusicTrack> _byVisibilityKey = const {};
  Map<String, LocalMusicTrack> _representativeByUri = const {};
  Map<(String, String), List<LocalMusicTrack>> _documents = const {};
  Future<void>? _initialization;
  Future<bool>? _choosing;
  Future<dynamic>? _picker;
  Future<void>? _scanning;
  Future<bool>? _removing;
  Future<bool>? _renaming;
  Future<void> _downloadRenameSync = Future.value();
  Future<void>? _disabling;
  int _revision = 0;
  bool _disposed = false;
  String? _error;

  List<LocalMusicRoot> get roots => _selection.roots;
  bool get enabled => roots.isNotEmpty;
  bool get busy =>
      _choosing != null ||
      scanning ||
      _renaming != null ||
      _removing != null ||
      _disabling != null;
  bool get scanning => _scanning != null;
  bool get loaded => _loadedRoots.isNotEmpty;
  bool get unavailable => enabled && roots.every(isRootUnavailable);
  bool isRootUnavailable(LocalMusicRoot root) =>
      _unavailableRoots.contains(root.uri);
  bool get isSystem => roots.length == 1 && roots.single.isSystem;
  String? get folderName => roots.firstOrNull?.name;
  String? get selectionId => _selection.id;
  bool acceptsSessionSelection(String? id) =>
      enabled && !unavailable && id == selectionId;
  String? get error => _error;
  List<LocalMusicTrack> get tracks => _tracks;
  bool containsUri(String uri) => _representativeByUri.containsKey(uri);
  LocalMusicTrack? trackById(String id) => _byId[id];

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

  /// Session publication refreshes listeners even if the device source stayed
  /// the same across a profile switch.
  void visibilityProfileChanged() {
    _notify();
    unawaited(_rememberDocumentProofs());
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

  List<HiddenLocalMusicTrack> get hiddenTracks =>
      _visibility?.records(_byVisibilityKey) ?? const [];

  bool get excludesRecordings => _visibility?.excludesRecordings ?? false;

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
      for (final root in selection.roots.where((r) => !isRootUnavailable(r))) {
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
    WidgetsBinding.instance.addObserver(this);
    final revision = _revision;
    try {
      final selection = await _readSelection();
      if (_revision == revision && _disabling == null) {
        _applySelection(selection);
      }
    } catch (e) {
      if (_revision == revision) _recordError(e);
    } finally {
      _notify();
    }
    unawaited(_reconcileDownloadRenames());
  }

  Future<_Selection> _readSelection() async =>
      _parseSelection(await _channel.invokeMethod<dynamic>('getFolder'));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(revalidate());
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
    if (available == null || !_current(revision)) return;
    if (available) {
      if (_unavailableRoots.remove(root.uri)) {
        if (_error == 'FOLDER_UNAVAILABLE') _error = null;
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
    _rootRevisions.update(root.uri, (value) => value + 1, ifAbsent: () => 1);
    _loadedRoots.remove(root.uri);
    _tracksByRoot.remove(root.uri);
    if (unavailable) _error = 'FOLDER_UNAVAILABLE';
    _publish();
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
        );
      }
    }
    throw const FormatException('Invalid local music folder');
  }

  void _applySelection(_Selection selection) {
    final previous = {for (final root in roots) root.uri: root};
    final retained = {
      for (final root in selection.roots)
        if (previous[root.uri]?.selectionId == root.selectionId &&
            !root.needsReapproval)
          root.uri,
    };
    _loadedRoots.retainAll(retained);
    _tracksByRoot.removeWhere((uri, _) => !retained.contains(uri));
    _unavailableRoots
      ..clear()
      ..addAll(selection.roots
          .where((root) => root.needsReapproval)
          .map((root) => root.uri));
    _selection = selection;
    _publish();
  }

  Future<bool> chooseFolder({LocalMusicRoot? reconnect}) =>
      _select('pickFolder', initialUri: reconnect?.uri);
  Future<bool> chooseSystem() => _select('pickSystem');

  /// Cancellation leaves the approved sources and their tracks intact.
  Future<bool> _select(String method, {Uri? initialUri}) {
    if (_disabling != null || _renaming != null || _removing != null) {
      return Future.value(false);
    }
    if (_choosing != null) return _choosing!;
    final result = _choosing = _choose(method, initialUri).whenComplete(() {
      _choosing = null;
      _notify();
    });
    _notify();
    return result;
  }

  Future<bool> _choose(String method, Uri? initialUri) async {
    final revision = _revision;
    await initialize();
    if (!_current(revision)) return false;
    try {
      final folder = roots.where((root) => !root.isSystem).firstOrNull;
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

  Future<void> refresh() async {
    await initialize();
    if (!enabled ||
        _disabling != null ||
        _renaming != null ||
        _removing != null) {
      return;
    }
    if (_choosing != null) {
      await _choosing;
      return;
    }
    if (_scanning != null) return _scanning;
    await _startScan(_revision);
  }

  Future<void> _startScan(int revision) async {
    final scan = _scanning = _scanRoots(revision);
    _notify();
    try {
      await scan;
    } finally {
      if (identical(_scanning, scan)) {
        _scanning = null;
        _notify();
      }
    }
  }

  /// Resume as soon as the selected source has delivered the needed tracks.
  Future<void> loadForPlayback(Iterable<String> trackIds) async {
    await initialize();
    final requested = trackIds.toSet();
    bool ready() => requested.every(_byId.containsKey);
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

  Future<void> _scanRoots(int revision) async {
    if (!unavailable) _error = null;
    for (final root in roots) {
      if (!_current(revision)) return;
      if (!isRootUnavailable(root)) await _scan(root, revision);
    }
    if (_current(revision)) {
      unawaited(_rememberDocumentProofs());
      unawaited(_reconcileDownloadRenames());
    }
  }

  Future<void> _scan(LocalMusicRoot root, int revision) async {
    final rootRevision = _rootRevisions[root.uri];
    bool active() =>
        _current(revision) && _rootRevisions[root.uri] == rootRevision;
    final scanId = ++_nextScanId;
    _channel.setMethodCallHandler(_handleNativeCall);
    _batchCallbacks[scanId] = (documents) {
      if (!active()) return;
      final merged =
          Map<String, LocalMusicTrack>.of(_tracksByRoot[root.uri] ?? const {});
      _collectTracks(documents, root.uri, merged);
      _tracksByRoot[root.uri] = merged;
      _publish();
      _notify();
    };
    try {
      final documents = await _channel.invokeListMethod<dynamic>(
          'listTracks', {'treeUri': root.uri.toString(), 'scanId': scanId});
      if (!active()) return;
      if (documents == null) throw const FormatException('No scan result');
      final tracks = <String, LocalMusicTrack>{};
      _collectTracks(documents, root.uri, tracks);
      _tracksByRoot[root.uri] = tracks;
      _loadedRoots.add(root.uri);
      _publish();
      _notify();
    } catch (e) {
      if (!active()) return;
      if (e is PlatformException && e.code == 'FOLDER_UNAVAILABLE') {
        _loseAccess(root);
      } else {
        _recordError(e);
      }
    } finally {
      _batchCallbacks.remove(scanId);
    }
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final data = call.arguments;
    if (call.method == 'trackBatch' && data is Map && data['tracks'] is List) {
      _batchCallbacks[data['scanId']]?.call(data['tracks'] as List);
    }
  }

  static void _collectTracks(Iterable<dynamic> documents, Uri source,
      Map<String, LocalMusicTrack> tracks) {
    for (final document in documents) {
      final track = LocalMusicTrack.fromDocument(document, source);
      if (track != null) tracks[track.playbackId] = track;
    }
  }

  void _publish() {
    final tracks = {
      for (final root in roots) ...?_tracksByRoot[root.uri],
    };
    final displayed = <LocalMusicTrack>[];
    final byUri = <String, LocalMusicTrack>{};
    final documents = <(String, String), List<LocalMusicTrack>>{};
    for (final track in tracks.values) {
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
        if (track.documentVisibilityKey case final String key) key: track,
      },
    };
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
        _disabling != null ||
        _removing != null) {
      return Future.value(false);
    }
    if (!_usesMultipleRoots) return disable().then((_) => error == null);
    final result = _removing = _remove(root).whenComplete(() {
      _removing = null;
      _notify();
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
    if (_initialization != null) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
