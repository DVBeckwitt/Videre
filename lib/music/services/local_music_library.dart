import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../downloads/services/download_rename.dart';
import '../models/local_music_track.dart';

typedef _SelectedFolder = ({Uri uri, String name, String? selectionId});

/// Library for the Android music source the listener has approved.
class LocalMusicLibrary extends ChangeNotifier with WidgetsBindingObserver {
  static final instance = LocalMusicLibrary();
  static const _channel =
      MethodChannel('com.github.dvbeckwitt.videre/local_music');
  static final _batchCallbacks = <int, void Function(List<dynamic>)>{};
  static int _nextScanId = 0;

  _SelectedFolder? _folder;
  List<LocalMusicTrack> _tracks = const [];
  Map<String, LocalMusicTrack> _byId = const {};
  Set<String> _uris = const {};
  Future<void>? _initialization;
  Future<bool>? _choosing;
  Future<dynamic>? _picker;
  Future<void>? _scanning;
  Future<bool>? _renaming;
  Future<void> _downloadRenameSync = Future.value();
  Future<void>? _disabling;
  int _revision = 0;
  bool _loaded = false;
  bool _unavailable = false;
  bool _disposed = false;
  String? _error;

  bool get enabled => _folder != null;
  bool get busy =>
      _choosing != null || scanning || _renaming != null || _disabling != null;
  bool get scanning => _scanning != null;
  bool get loaded => _loaded;
  bool get unavailable => _unavailable;
  bool get isSystem => _folder?.uri == LocalMusicTrack.systemSource;
  String? get folderName => _folder?.name;
  String? get selectionId => _folder?.selectionId;
  bool acceptsSessionSelection(String? id) =>
      enabled && !unavailable && id == selectionId;
  String? get error => _error;
  List<LocalMusicTrack> get tracks => _tracks;
  bool containsUri(String uri) => _uris.contains(uri);
  LocalMusicTrack? trackById(String id) => _byId[id];

  // The Android side reads only its stored selection here. It never queries
  // documents, opens audio or invokes the picker when initializing settings.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    WidgetsBinding.instance.addObserver(this);
    final revision = _revision;
    try {
      final folder = await _readFolder();
      if (_revision == revision && _disabling == null) _folder = folder;
    } catch (e) {
      if (_revision == revision) _recordError(e);
    } finally {
      _notify();
    }
    unawaited(_reconcileDownloadRenames());
  }

  Future<_SelectedFolder?> _readFolder() async =>
      _parseFolder(await _channel.invokeMethod<dynamic>('getFolder'));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(revalidate());
  }

  /// Android can revoke a grant while the Activity is in the background.
  /// A negative result invalidates scans and notifies the active audio player.
  Future<void> revalidate() async {
    final picker = _picker;
    if (picker != null) {
      try {
        await picker;
      } on Exception {
        // If the chooser failed, the previous source still needs checking.
      }
    }
    final folder = _folder;
    if (_disposed || folder == null || _disabling != null) {
      return;
    }
    final revision = _revision;
    bool? available;
    try {
      available = await _channel.invokeMethod<bool>(
          'checkFolderAccess', {'treeUri': folder.uri.toString()});
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (available == null || _revision != revision || _disposed) return;
    if (available) {
      if (_unavailable) {
        _unavailable = false;
        _error = null;
        _notify();
      }
      return;
    }
    if (_unavailable) return;
    if (_picker != null) {
      // The pending picker may replace this tree or leave its grant unchanged.
      await revalidate();
      return;
    }
    ++_revision;
    _clearTracks();
    _unavailable = true;
    _error = 'FOLDER_UNAVAILABLE';
    _notify();
  }

  static _SelectedFolder? _parseFolder(dynamic result) {
    if (result == null) return null;
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
        return (
          uri: uri,
          name: result['name'] as String,
          selectionId: result['selectionId'] as String?
        );
      }
    }
    throw const FormatException('Invalid local music folder');
  }

  Future<bool> chooseFolder() => _select('pickFolder');
  Future<bool> chooseSystem() => _select('pickSystem');

  /// Cancellation leaves the previous source and its tracks intact.
  Future<bool> _select(String method) {
    if (_disabling != null || _renaming != null) return Future.value(false);
    if (_choosing != null) return _choosing!;
    final result = _choosing = _choose(method).whenComplete(() {
      _choosing = null;
      _notify();
    });
    _notify();
    return result;
  }

  Future<bool> _choose(String method) async {
    final revision = _revision;
    await initialize();
    if (_revision != revision) return false;
    try {
      _picker = _channel.invokeMethod<dynamic>(
          method, {'initialUri': isSystem ? null : _folder?.uri.toString()});
      final selection = _parseFolder(await _picker);
      _picker = null;
      if (_revision != revision || selection == null) return false;
      if (selection.uri != _folder?.uri ||
          selection.selectionId != selectionId) {
        _clearTracks();
      }
      _folder = selection;
      _error = null;
      _unavailable = false;
      final newRevision = ++_revision;
      await _startScan(selection, newRevision);
      return _revision == newRevision;
    } catch (e) {
      _picker = null;
      if (_revision == revision) _recordError(e);
      return false;
    }
  }

  Future<void> refresh() async {
    await initialize();
    final folder = _folder;
    if (folder == null || _disabling != null || _renaming != null) return;
    if (_choosing != null) {
      await _choosing;
      return;
    }
    if (_scanning != null) return _scanning;
    await _startScan(folder, _revision);
  }

  Future<void> _startScan(_SelectedFolder folder, int revision) async {
    final scan = _scanning = _scan(folder, revision);
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

  Future<void> _scan(_SelectedFolder folder, int revision) async {
    final scanId = ++_nextScanId;
    _channel.setMethodCallHandler(_handleNativeCall);
    _batchCallbacks[scanId] = (documents) {
      if (_revision != revision || _disposed) return;
      final merged = Map.of(_byId);
      _collectTracks(documents, folder.uri, merged);
      _publish(merged);
      _notify();
    };
    try {
      final documents = await _channel.invokeListMethod<dynamic>(
          'listTracks', {'treeUri': folder.uri.toString(), 'scanId': scanId});
      if (_revision != revision || _disposed) return;
      if (documents == null) throw const FormatException('No scan result');
      final tracks = <String, LocalMusicTrack>{};
      _collectTracks(documents, folder.uri, tracks);
      _publish(tracks);
      _loaded = true;
      _error = null;
      _unavailable = false;
      unawaited(_reconcileDownloadRenames());
    } catch (e) {
      if (_revision != revision) return;
      _recordError(e);
      if (_error == 'FOLDER_UNAVAILABLE') {
        _clearTracks();
        _unavailable = true;
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

  void _publish(Map<String, LocalMusicTrack> tracks) {
    _byId = tracks;
    _tracks = List.unmodifiable(tracks.values);
    _uris = _tracks.map((track) => track.uri).toSet();
  }

  Future<bool> renameTrack(LocalMusicTrack track, String fullName) async {
    final folder = _folder;
    final current = _byId[track.playbackId];
    if (folder == null || current == null || !current.canRename || busy) {
      return false;
    }
    final revision = _revision;
    final rename = _renaming = _rename(folder, current, fullName, revision);
    _notify();
    try {
      return await rename;
    } finally {
      _renaming = null;
      _notify();
    }
  }

  Future<bool> _rename(_SelectedFolder folder, LocalMusicTrack current,
      String name, int revision) async {
    _error = null;
    try {
      final result = await _channel.invokeMethod<dynamic>('renameTrack', {
        'treeUri': folder.uri.toString(),
        'uri': current.uri,
        'name': name,
      });
      if (result == null) return false;
      final reconcile = _reconcileDownloadRenames();
      if (_disposed || _revision != revision) {
        await reconcile;
        return false;
      }
      final track = LocalMusicTrack.fromDocument(result, folder.uri);
      if (track == null || track.playbackId != current.playbackId) {
        throw const FormatException('Invalid rename result');
      }
      _publish({..._byId, track.playbackId: track});
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

  /// Drop membership before waiting on a picker, scan or Android grant release.
  Future<void> disable() {
    if (_disabling != null) return _disabling!;
    ++_revision;
    _folder = null;
    _clearTracks();
    _error = null;
    _unavailable = false;
    final result = _disabling = _forget().whenComplete(() {
      _disabling = null;
      _notify();
    });
    _notify();
    return result;
  }

  Future<void> _forget() async {
    try {
      // A picker can finish after opt-out and already hold a new native grant.
      try {
        await _picker;
      } on PlatformException {
        // The old grant may still exist when the pending picker failed.
      }
      final saved = await _readFolder();
      if (saved != null) {
        await _channel.invokeMethod<void>(
            'forgetFolder', {'treeUri': saved.uri.toString()});
      }
    } catch (e) {
      _recordError(e);
    }
  }

  void _clearTracks() {
    _tracks = const [];
    _byId = const {};
    _uris = const {};
    _loaded = false;
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
