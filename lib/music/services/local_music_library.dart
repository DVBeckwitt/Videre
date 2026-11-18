import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/local_music_track.dart';

typedef _SelectedFolder = ({Uri uri, String name});

/// Device-local library. Only the native picker can establish a folder grant.
class LocalMusicLibrary extends ChangeNotifier {
  static final instance = LocalMusicLibrary();
  static const _channel =
      MethodChannel('com.github.dvbeckwitt.videre/local_music');

  _SelectedFolder? _folder;
  List<LocalMusicTrack> _tracks = const [];
  Map<String, LocalMusicTrack> _byId = const {};
  Set<String> _uris = const {};
  Future<void>? _initialization;
  Future<bool>? _choosing;
  Future<dynamic>? _picker;
  Future<void>? _scanning;
  Future<void>? _disabling;
  int _revision = 0;
  bool _loaded = false;
  bool _unavailable = false;
  bool _disposed = false;
  String? _error;

  bool get enabled => _folder != null;
  bool get busy => _choosing != null || _scanning != null || _disabling != null;
  bool get loaded => _loaded;
  bool get unavailable => _unavailable;
  String? get folderName => _folder?.name;
  String? get error => _error;
  List<LocalMusicTrack> get tracks => _tracks;
  bool containsUri(String uri) => _uris.contains(uri);
  LocalMusicTrack? trackById(String id) => _byId[id];

  // The Android side reads only its stored selection here. It never queries
  // documents, opens audio or invokes the picker when initializing settings.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final revision = _revision;
    try {
      final folder = await _readFolder();
      if (_revision == revision && _disabling == null) _folder = folder;
    } catch (e) {
      if (_revision == revision) _recordError(e);
    } finally {
      _notify();
    }
  }

  Future<_SelectedFolder?> _readFolder() async =>
      _parseFolder(await _channel.invokeMethod<dynamic>('getFolder'));

  static _SelectedFolder? _parseFolder(dynamic result) {
    if (result == null) return null;
    if (result is Map && result['uri'] is String && result['name'] is String) {
      final uri = Uri.tryParse(result['uri'] as String);
      if (uri != null &&
          uri.scheme == 'content' &&
          uri.authority.isNotEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          uri.pathSegments.length == 2 &&
          uri.pathSegments.first == 'tree' &&
          uri.pathSegments.last.isNotEmpty) {
        return (uri: uri, name: result['name'] as String);
      }
    }
    throw const FormatException('Invalid local music folder');
  }

  /// Cancellation leaves the previous folder and its tracks intact.
  Future<bool> chooseFolder() {
    if (_disabling != null) return Future.value(false);
    if (_choosing != null) return _choosing!;
    final result = _choosing = _choose().whenComplete(() {
      _choosing = null;
      _notify();
    });
    _notify();
    return result;
  }

  Future<bool> _choose() async {
    final revision = _revision;
    await initialize();
    if (_revision != revision) return false;
    try {
      _picker = _channel.invokeMethod<dynamic>(
          'pickFolder', {'initialUri': _folder?.uri.toString()});
      final selection = _parseFolder(await _picker);
      _picker = null;
      if (_revision != revision || selection == null) return false;
      if (selection.uri != _folder?.uri) _clearTracks();
      _folder = selection;
      _error = null;
      _unavailable = false;
      final newRevision = ++_revision;
      _notify();
      await _scan(selection, newRevision);
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
    if (folder == null || _disabling != null) return;
    if (_choosing != null) {
      await _choosing;
      return;
    }
    if (_scanning != null) return _scanning;
    final scan = _scanning = _scan(folder, _revision).whenComplete(() {
      _scanning = null;
      _notify();
    });
    _notify();
    await scan;
  }

  Future<void> _scan(_SelectedFolder folder, int revision) async {
    try {
      final documents = await _channel.invokeListMethod<dynamic>(
          'listTracks', {'treeUri': folder.uri.toString()});
      if (_revision != revision) return;
      if (documents == null) throw const FormatException('No scan result');
      final tracks = <String, LocalMusicTrack>{};
      for (final document in documents) {
        final track = LocalMusicTrack.fromDocument(document, folder.uri);
        if (track != null) tracks[track.uri] = track;
      }
      _tracks = List.unmodifiable(tracks.values);
      _uris = tracks.keys.toSet();
      _byId = {for (final track in _tracks) track.playbackId: track};
      _loaded = true;
      _error = null;
      _unavailable = false;
    } catch (e) {
      if (_revision != revision) return;
      _recordError(e);
      if (_error == 'FOLDER_UNAVAILABLE') {
        _clearTracks();
        _unavailable = true;
      }
    }
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
    super.dispose();
  }
}
