import 'package:flutter/foundation.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../globals.dart' show service;
import '../../playlists/models/playlist.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_library_entry.dart';
import '../models/music_search_text.dart';
import '../models/on_device_music_entry.dart';
import 'local_music_library.dart';
import 'music_library_service.dart';
import 'on_device_music_downloads.dart';

enum MusicLibrarySearchType { all, songs, playlists }

sealed class MusicLibrarySearchHit {
  const MusicLibrarySearchHit();

  String get key;
  String get title;
  String? get subtitle;
}

final class MusicLibrarySearchBookmark extends MusicLibrarySearchHit {
  const MusicLibrarySearchBookmark(this.entry);

  final MusicLibraryEntry entry;

  @override
  String get key => 'bookmark:${entry.kind.name}:${entry.id}';
  @override
  String get title => entry.displayTitle;
  @override
  String? get subtitle => entry.subtitle.isEmpty ? null : entry.subtitle;
}

final class MusicLibrarySearchPlaylist extends MusicLibrarySearchHit {
  const MusicLibrarySearchPlaylist(this.playlist);

  final Playlist playlist;

  @override
  String get key => 'playlist:${playlist.playlistId}';
  @override
  String get title => playlist.title;
  @override
  String? get subtitle => playlist.author.isEmpty ? null : playlist.author;
}

final class MusicLibrarySearchFile extends MusicLibrarySearchHit {
  const MusicLibrarySearchFile(this.entry);

  final OnDeviceMusicEntry entry;

  @override
  String get key => entry.id;
  @override
  String get title => entry.title;
  @override
  String? get subtitle => entry.artist;
}

typedef _FileOwner = ({IDbClient database, String profileId});

/// Searches metadata from the active profile and its authorized local files.
class MusicLibrarySearch extends ChangeNotifier {
  MusicLibrarySearch(
      {LocalMusicLibrary? deviceLibrary, OnDeviceMusicDownloads? downloads})
      : _device = deviceLibrary ?? LocalMusicLibrary.instance,
        _downloads = downloads ?? OnDeviceMusicDownloads();

  final LocalMusicLibrary _device;
  final OnDeviceMusicDownloads _downloads;
  final _searchText = Expando<String>();
  late final Listenable fileChanges = Listenable.merge([_device, this]);
  _FileOwner? _requestOwner;
  _FileOwner? _readyOwner;
  List<DownloadedVideo> _requested = const [];
  Map<String, DownloadedVideo> _requestedById = const {};
  Object? _checkedSource;
  Future<void>? _pending;
  bool Function()? _requestCurrent;
  int _revision = 0;
  bool _disposed = false;

  Object get _deviceSource => (
        _device.enabled,
        _device.unavailable,
        _device.selectionId,
        _device.tracks,
        _device.scanning,
      );

  /// Checks the existing device grant and completed files without asking for
  /// new access or reading a remote catalog. The owner controls when to run it.
  Future<void> refreshFiles({
    required IDbClient database,
    required String profileId,
    required Iterable<DownloadedVideo> downloads,
    bool force = false,
    bool Function()? isCurrent,
  }) {
    if (_disposed ||
        database.profileId != profileId ||
        isCurrent?.call() == false) {
      return Future.value();
    }
    final owner = (database: database, profileId: profileId);
    final candidates = [
      for (final file in downloads)
        if (file.profileId == profileId &&
            file.audioOnly &&
            file.musicMetadata != null &&
            file.downloadComplete &&
            !file.downloadFailed &&
            !file.storageFailed &&
            !file.authenticationRequired)
          file,
    ];
    if (!force &&
        owner == _requestOwner &&
        listEquals(candidates, _requested)) {
      if (_pending case final pending? when _requestCurrent?.call() != false) {
        return pending;
      }
      if (_readyOwner == owner && _checkedSource == _deviceSource) {
        return Future.value();
      }
    }
    if (owner != _requestOwner) _readyOwner = null;
    _requestOwner = owner;
    _requested = candidates;
    _requestedById = {for (final file in candidates) file.videoId: file};
    _requestCurrent = isCurrent;
    final revision = ++_revision;
    bool current() =>
        !_disposed &&
        _revision == revision &&
        database.profileId == profileId &&
        isCurrent?.call() != false;
    return _pending =
        _refreshFiles(owner, candidates, current).whenComplete(() {
      if (!_disposed && revision == _revision) {
        _pending = null;
        _requestCurrent = null;
        if (current()) notifyListeners();
      }
    });
  }

  Future<void> _refreshFiles(_FileOwner owner, List<DownloadedVideo> candidates,
      bool Function() current) async {
    await _device.initialize();
    if (!current()) return;
    await _device.revalidate();
    if (!current()) return;
    if (_device.enabled && !_device.unavailable && !_device.loaded) {
      await _device.refresh();
    }
    if (!current()) return;
    final source = _deviceSource;
    await _downloads.refresh(_device, owner.profileId, candidates,
        isCurrent: current);
    if (!current()) return;
    _checkedSource = source;
    _readyOwner = owner;
  }

  List<MusicLibrarySearchHit> search(String query,
      {required IDbClient database,
      required String profileId,
      MusicLibrarySearchType type = MusicLibrarySearchType.all}) {
    final terms = musicSearchTerms(query);
    if (_disposed || terms.isEmpty || database.profileId != profileId) {
      return const [];
    }
    bool matches(Object row, List<String?> fields) {
      final text = _searchText[row] ??=
          normalizeMusicSearchText(fields.nonNulls.join(' '));
      return terms.every(text.contains);
    }

    final library = MusicLibraryService.forProfile(database, profileId);
    final owner = (database: database, profileId: profileId);
    final includeSongs = type != MusicLibrarySearchType.playlists;
    final includePlaylists = type != MusicLibrarySearchType.songs;
    return [
      for (final item in library.entries)
        if (((includeSongs && item.kind == MusicLibraryKind.song) ||
                (includePlaylists && item.kind == MusicLibraryKind.playlist)) &&
            matches(item, [
              item.displayTitle,
              item.subtitle,
              item.album,
              ...item.artistCredits.map((credit) => credit.name),
            ]))
          MusicLibrarySearchBookmark(item),
      if (includePlaylists)
        for (final playlist in _localPlaylists(database.forProfile(profileId)))
          if (library.isMusicPlaylist(playlist) &&
              matches(playlist, [playlist.title, playlist.author]))
            MusicLibrarySearchPlaylist(playlist),
      if (includeSongs && _readyOwner == owner)
        for (final file in _downloads.entries(_device, profileId))
          if (_fileCurrent(file) &&
              matches(file.deviceTrack ?? file.download!, [
                file.title,
                file.artist,
                file.album,
                file.deviceTrack?.albumArtist,
                file.fileName,
              ]))
            MusicLibrarySearchFile(file),
    ];
  }

  bool _fileCurrent(OnDeviceMusicEntry file) {
    final download = file.download;
    if (download == null) return _device.enabled && !_device.unavailable;
    return _requestedById[download.videoId] == download &&
        (download.storageUri == null || _checkedSource == _deviceSource);
  }

  List<Playlist> _localPlaylists(IDbClient database) {
    try {
      return service.getLocalPlaylists(database: database);
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _downloads.dispose();
    super.dispose();
  }
}
