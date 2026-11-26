import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../playlists/models/playlist.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/video.dart';
import '../models/music_library_entry.dart';
import '../models/on_device_music_entry.dart';
import 'music_catalog_service.dart';
import 'music_library_service.dart';

typedef AndroidAutoPlayback<T> = Future<void> Function(
    List<T> entries, int index, String? title, bool Function() isCurrent);
typedef _Songs = ({List<Video> videos, List<OnDeviceMusicEntry> device});

enum AndroidAutoQueueAction {
  addToQueue,
  removeFromQueue,
  moveQueueEarlier,
  moveQueueLater,
}

class _BrowseItem {
  final MediaItem item;
  final Future<List<MediaItem>> Function()? children;
  final Future<_Songs> Function()? songs;
  final (String, int)? occurrence;
  final String? queueTitle;
  final bool? onDeviceSong;

  const _BrowseItem(
    this.item, {
    this.children,
    this.songs,
    this.occurrence,
    this.queueTitle,
    this.onDeviceSong,
  });
}

/// Adapter for the supported Android media browser and session callbacks.
/// Browser IDs name server-side objects only within the current profile session.
class AndroidAutoMusic {
  static const _pageSize = 100;
  static const _cacheSize = 2048;
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  final Object? Function() session;
  final IDbClient Function() database;
  final MusicCatalogService catalog;
  final AndroidAutoPlayback<Video> playVideos;
  final AndroidAutoPlayback<OnDeviceMusicEntry> playDevice;
  final Future<List<OnDeviceMusicEntry>> Function()? loadDevice;
  final List<Playlist> Function(IDbClient)? loadPlaylists;
  final AppLocalizations Function()? labels;
  final _items = <String, _BrowseItem>{};
  Object? _scope;
  String _namespace = '';
  int _playRequest = 0;

  AndroidAutoMusic({
    required this.session,
    required this.database,
    required this.catalog,
    required this.playVideos,
    required this.playDevice,
    this.loadDevice,
    this.loadPlaylists,
    this.labels,
  });

  Iterable<String> get loadedParents => [
        AudioService.browsableRootId,
        AudioService.recentRootId,
        for (final node in _items.values)
          if (node.children != null) node.item.id,
      ];

  void invalidate() {
    _scope = null;
    _items.clear();
    _playRequest++;
  }

  bool Function()? _request() {
    final scope = session();
    if (scope != _scope) {
      invalidate();
      _scope = scope;
      _namespace = const Uuid().v4();
    }
    if (scope == null) return null;
    final namespace = _namespace;
    return () =>
        _namespace == namespace && _scope == scope && session() == scope;
  }

  Future<List<MediaItem>> getChildren(String parentId) async {
    final current = _request();
    if (current == null) return [];
    final children = parentId == AudioService.browsableRootId
        ? _root()
        : await _items[parentId]?.children?.call();
    return current() ? children ?? [] : [];
  }

  Future<MediaItem?> getMediaItem(String id) async {
    final current = _request();
    final node = _items[id];
    if (current == null || node == null) return null;
    final load = node.songs;
    if (load == null) return node.item;
    final songs = await load();
    final index = _indexOf(songs, node.occurrence!);
    return !current() || index < 0 ? null : _item(songs, index, id);
  }

  /// Null identifies a folder, an unknown ID or a retired profile's song.
  bool? isOnDeviceSong(String id) =>
      _request() == null ? null : _items[id]?.onDeviceSong;

  Future<({Video? video, OnDeviceMusicEntry? device})?> resolveQueueSong(
    String id,
  ) async {
    final current = _request();
    final node = _items[id];
    if (current == null || node == null || node.songs == null) return null;
    final songs = await node.songs!();
    final index = _indexOf(songs, node.occurrence!);
    if (!current() || index < 0) return null;
    return songs.videos.isEmpty
        ? (video: null, device: songs.device[index])
        : (video: songs.videos[index], device: null);
  }

  List<MediaItem> _root() {
    final locale = labels?.call();
    final saved = locale?.musicSavedSongs ?? 'Saved songs';
    final playlists = locale?.playlists ?? 'Playlists';
    final device = locale?.onDeviceSubscriptions ?? 'On device';
    return [
      _folder('saved', saved, () => _savedItems(saved)),
      _folder('playlists', playlists, _playlistItems),
      if (loadDevice != null)
        _folder('device', device, () => _deviceItems(device)),
    ];
  }

  Future<List<MediaItem>> _savedItems(String title) =>
      _songItems('saved', title, () async => _savedSongs());

  Future<List<MediaItem>> _deviceItems(String title) =>
      _songItems('device', title, _deviceSongs);

  MusicLibraryService _library(IDbClient owner) =>
      MusicLibraryService.forProfile(owner, owner.profileId);

  _Songs _savedSongs() => (
        videos: [
          for (final entry in _library(database()).entries)
            if (entry.kind == MusicLibraryKind.song && _validId(entry.id))
              entry.toVideo(),
        ],
        device: const [],
      );

  Future<_Songs> _deviceSongs() async {
    final current = _request();
    if (current == null) {
      return (videos: const <Video>[], device: const <OnDeviceMusicEntry>[]);
    }
    final profile = database().profileId;
    final entries = await loadDevice?.call() ?? const <OnDeviceMusicEntry>[];
    return (
      videos: const <Video>[],
      device: current()
          ? [
              for (final entry in entries)
                if (entry.deviceTrack != null ||
                    entry.download?.profileId == profile)
                  entry,
            ]
          : const <OnDeviceMusicEntry>[],
    );
  }

  List<Playlist> _playlists() {
    final owner = database();
    final library = _library(owner);
    return (loadPlaylists?.call(owner.forProfile(owner.profileId)) ?? const [])
        .where(library.isMusicPlaylist)
        .toList();
  }

  _Songs _playlistSongs(String id) {
    final playlist =
        _playlists().where((row) => row.playlistId == id).firstOrNull;
    return (
      videos: [
        for (final video in playlist?.videos ?? const <Video>[])
          if (!video.filtered &&
              !video.filterHide &&
              video.isUpcoming != true &&
              video.musicMetadata != null &&
              _validId(video.videoId))
            video,
      ],
      device: const [],
    );
  }

  Future<List<MediaItem>> _playlistItems([int offset = 0]) async => _page(
        'playlists',
        [
          for (final playlist in _playlists())
            () => _folder(
                'playlist:${playlist.playlistId}',
                playlist.title,
                () => _songItems(
                    'playlist:${playlist.playlistId}',
                    playlist.title,
                    () async => _playlistSongs(playlist.playlistId))),
        ],
        offset,
        _playlistItems,
      );

  Future<List<MediaItem>> _songItems(
      String key, String? title, Future<_Songs> Function() load,
      [int offset = 0]) async {
    final current = _request();
    if (current == null) return [];
    final songs = await load();
    return current() ? _rows(key, title, songs, load, offset) : [];
  }

  List<MediaItem> _rows(
      String key, String? title, _Songs songs, Future<_Songs> Function() load,
      [int offset = 0]) {
    final seen = <String, int>{};
    final rows = <MediaItem Function()>[];
    for (var index = 0; index < _length(songs); index++) {
      final slot = index;
      final source = _sourceId(songs, slot);
      final occurrence = (
        source,
        seen.update(source, (count) => count + 1, ifAbsent: () => 0)
      );
      rows.add(() {
        final item =
            _item(songs, slot, _id([key, occurrence.$1, occurrence.$2]));
        return _register(_BrowseItem(item,
            songs: load,
            occurrence: occurrence,
            queueTitle: title,
            onDeviceSong: songs.videos.isEmpty));
      });
    }
    return _page(
        key, rows, offset, (offset) => _songItems(key, title, load, offset));
  }

  List<MediaItem> _page(String key, List<MediaItem Function()> rows, int offset,
      Future<List<MediaItem>> Function(int) loadPage) {
    final end = offset + _pageSize;
    return [
      for (final row in rows.skip(offset).take(_pageSize)) row(),
      if (end < rows.length)
        _folder(
            'page:$key:$end',
            '${end + 1}–${(end + _pageSize).clamp(0, rows.length)}',
            () => loadPage(end)),
    ];
  }

  MediaItem _folder(String key, String title,
          Future<List<MediaItem>> Function() children) =>
      _register(_BrowseItem(
        MediaItem(id: _id([key]), title: _text(title), playable: false),
        children: children,
      ));

  String _id(List<Object> key) =>
      'car:${sha256.convert(utf8.encode(jsonEncode([_namespace, ...key])))}';

  MediaItem _register(_BrowseItem entry) {
    final id = entry.item.id;
    _items.remove(id);
    _items[id] = entry;
    if (_items.length > _cacheSize) _items.remove(_items.keys.first);
    return entry.item;
  }

  static String _text(String value) => String.fromCharCodes(
      value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim().runes.take(256));

  static bool _validId(String id) => _videoId.stringMatch(id) == id;

  static int _length(_Songs songs) =>
      songs.videos.isEmpty ? songs.device.length : songs.videos.length;

  static String _sourceId(_Songs songs, int index) => songs.videos.isEmpty
      ? songs.device[index].id
      : songs.videos[index].videoId;

  static int _indexOf(_Songs songs, (String, int) occurrence) {
    var ordinal = 0;
    for (var index = 0; index < _length(songs); index++) {
      if (_sourceId(songs, index) == occurrence.$1 &&
          ordinal++ == occurrence.$2) {
        return index;
      }
    }
    return -1;
  }

  static MediaItem _item(_Songs songs, int index, String id) {
    final video = songs.videos.isEmpty ? null : songs.videos[index];
    final device = video == null ? songs.device[index] : null;
    final music = video?.musicMetadata;
    final milliseconds = device?.deviceTrack?.durationMs;
    final seconds = video?.lengthSeconds ?? device?.download?.lengthSeconds;
    return MediaItem(
      id: id,
      title: _text(music?.title ?? device?.title ?? video?.title ?? ''),
      artist: _text(music?.artist ?? device?.artist ?? ''),
      album: _text(music?.album ?? device?.album ?? ''),
      duration: milliseconds != null
          ? Duration(milliseconds: milliseconds)
          : seconds == null
              ? null
              : Duration(seconds: seconds),
    );
  }

  static String _query(String query, Map<String, dynamic>? extras) {
    final spoken = _text(query);
    if (spoken.isNotEmpty) return spoken;
    return [
      for (final name in ['title', 'artist', 'album', 'playlist', 'genre'])
        if (extras?['android.intent.extra.$name'] case final String value)
          _text(value),
    ].where((value) => value.isNotEmpty).join(' ');
  }

  static bool _match(String query, Iterable<String?> fields) {
    final text = fields.nonNulls.join(' ').toLowerCase();
    return query.toLowerCase().split(RegExp(r'\s+')).every(text.contains);
  }

  _Songs _searchSaved(String query) => (
        videos: _savedSongs().videos.where((video) {
          final music = video.musicMetadata!;
          return _match(query, [music.title, music.artist, music.album]);
        }).toList(),
        device: const [],
      );

  Future<_Songs> _searchDevice(String query) async => (
        videos: const <Video>[],
        device: (await _deviceSongs())
            .device
            .where((entry) =>
                _match(query, [entry.title, entry.artist, entry.album]))
            .toList(),
      );

  Future<(_Songs, Future<_Songs> Function())> _searchSongs(
      String query, bool Function() current) async {
    final saved = _searchSaved(query);
    if (saved.videos.isNotEmpty || !current()) {
      return (saved, () async => _searchSaved(query));
    }
    final device = await _searchDevice(query);
    if (device.device.isNotEmpty || !current() || query.isEmpty) {
      return (device, () => _searchDevice(query));
    }
    _Songs result;
    try {
      final tracks = await catalog.searchSongs(query);
      result = (
        videos: [
          for (final track in tracks.take(_pageSize))
            if (_validId(track.videoId)) track.toVideo()
        ],
        device: const [],
      );
    } on Exception {
      result = (videos: const <Video>[], device: const <OnDeviceMusicEntry>[]);
    }
    return (result, () async => result);
  }

  Future<List<MediaItem>> search(String query,
      [Map<String, dynamic>? extras]) async {
    final current = _request();
    if (current == null) return [];
    final text = _query(query, extras);
    if (text.isEmpty) return [];
    final (songs, reload) = await _searchSongs(text, current);
    if (!current()) return [];
    return _rows('search:$text', null, songs, reload);
  }

  Future<void> playFromMediaId(String id) async {
    final current = _request();
    final node = _items[id];
    final load = node?.songs;
    if (current == null || node == null || load == null) return;
    final request = ++_playRequest;
    bool canCommit() => current() && request == _playRequest;
    final songs = await load();
    final index = _indexOf(songs, node.occurrence!);
    if (canCommit() && index >= 0) {
      await _play(songs, index, node.queueTitle, canCommit);
    }
  }

  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    final current = _request();
    if (current == null) return;
    final request = ++_playRequest;
    bool canCommit() => current() && request == _playRequest;
    final text = _query(query, extras);
    final playlist = text.isEmpty
        ? null
        : _playlists()
            .where((playlist) =>
                playlist.title.toLowerCase() == text.toLowerCase())
            .firstOrNull;
    final songs = playlist == null
        ? (await _searchSongs(text, canCommit)).$1
        : _playlistSongs(playlist.playlistId);
    if (canCommit() && _length(songs) != 0) {
      await _play(songs, 0, playlist?.title, canCommit);
    }
  }

  Future<void> _play(
          _Songs songs, int index, String? title, bool Function() current) =>
      songs.videos.isEmpty
          ? playDevice(songs.device, index, title, current)
          : playVideos(songs.videos, index, title, current);
}
