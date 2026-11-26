import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../globals.dart' show service;
import '../../playlists/models/playlist.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_artist.dart';
import '../models/music_artist_identity.dart';
import '../../videos/models/music_metadata.dart';
import '../../videos/models/video.dart';
import '../models/local_music_album.dart';
import '../models/local_music_artist.dart';
import '../models/local_music_genre.dart';
import '../models/local_music_track.dart';
import '../models/music_library_entry.dart';
import '../models/music_lyrics.dart';
import '../models/music_search_text.dart';
import '../models/on_device_music_entry.dart';
import 'local_music_library.dart';
import 'local_music_lyrics_authoring.dart';
import 'local_music_timed_lyrics.dart';
import 'lrc_lyrics.dart';
import 'music_library_service.dart';
import 'music_lyrics_corrections.dart';
import 'music_offline_lyrics.dart';
import 'on_device_music_downloads.dart';

enum MusicLibrarySearchType {
  songs,
  playlists,
  albums,
  artists,
  genres,
  lyrics;

  static const categories = {songs, playlists, albums, artists, genres};
}

sealed class MusicLibrarySearchHit {
  const MusicLibrarySearchHit({this.lyricLine});

  final String? lyricLine;

  String get key;
  String get title;
  String? get subtitle;
}

final class MusicLibrarySearchBookmark extends MusicLibrarySearchHit {
  const MusicLibrarySearchBookmark(this.entry,
      {String? artistByline, super.lyricLine})
      : _artistByline = artistByline;

  final MusicLibraryEntry entry;
  final String? _artistByline;

  @override
  String get key => 'bookmark:${entry.kind.name}:${entry.id}';
  @override
  String get title => entry.displayTitle;
  @override
  String? get subtitle {
    final label = _artistByline ?? entry.subtitle;
    return label.isEmpty ? null : label;
  }
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
  const MusicLibrarySearchFile(this.entry,
      {String? artistByline, super.lyricLine})
      : _artistByline = artistByline;

  final OnDeviceMusicEntry entry;
  final String? _artistByline;

  @override
  String get key => entry.id;
  @override
  String get title => entry.title;
  @override
  String? get subtitle => _artistByline ?? entry.artist;
}

/// Match aliases as additional terms while keeping the source index reusable.
bool musicSearchMatchesWithArtistAliases(
    List<String> terms, String sourceText, Iterable<String> aliases) {
  if (terms.every(sourceText.contains)) return true;
  final aliasText = normalizeMusicSearchText(aliases.join(' '));
  return terms
      .every((term) => sourceText.contains(term) || aliasText.contains(term));
}

Iterable<String> catalogArtistSearchAliases(
    MusicLibraryService library, Iterable<MusicArtistCredit> credits) sync* {
  for (final credit in credits) {
    if (credit.id case final id?) {
      if (library.artistAlias(MusicArtistIdentity.catalog(id))
          case final alias?) {
        yield alias;
      }
    }
  }
}

Iterable<String> fileArtistCreditNames(OnDeviceMusicEntry file) {
  if (file.deviceTrack case final track?) {
    return localMusicArtistCredits(track).map((credit) => credit.name);
  }
  return file.download!.musicMetadata!.artistCredits
      .map((credit) => credit.name);
}

Iterable<String> fileArtistSearchAliases(
    MusicLibraryService? library, OnDeviceMusicEntry file) sync* {
  if (library == null) return;
  if (file.deviceTrack case final track?) {
    for (final credit in localMusicArtistCredits(track)) {
      if (library.artistAlias(MusicArtistIdentity.device(credit.key))
          case final alias?) {
        yield alias;
      }
    }
  } else {
    yield* catalogArtistSearchAliases(
        library, file.download!.musicMetadata!.artistCredits);
  }
}

String? musicFileArtistByline(
    MusicLibraryService? library, OnDeviceMusicEntry file) {
  if (library == null) return file.artist;
  if (file.deviceTrack case final track?) {
    return library.deviceArtistByline(track);
  }
  final music = file.download!.musicMetadata!;
  return library.catalogArtistByline(music.artist, music.artistCredits);
}

final class MusicLibrarySearchAlbum extends MusicLibrarySearchHit {
  const MusicLibrarySearchAlbum(this.album);

  final LocalMusicAlbum album;

  @override
  String get key => 'album:${album.key}';
  @override
  String get title => album.title;
  @override
  String? get subtitle => album.albumArtist;
}

final class MusicLibrarySearchArtist extends MusicLibrarySearchHit {
  const MusicLibrarySearchArtist(this.artist);

  final LocalMusicArtist artist;

  @override
  String get key => 'artist:${artist.key}';
  @override
  String get title => artist.name;
  @override
  String? get subtitle => null;
}

final class MusicLibrarySearchGenre extends MusicLibrarySearchHit {
  const MusicLibrarySearchGenre(this.genreKey, this.title);

  final String genreKey;
  @override
  final String title;

  @override
  String get key => 'genre:$genreKey';
  @override
  String? get subtitle => null;
}

/// A catalog recording saved through the lyrics reader.
final class MusicLibrarySearchRecording extends MusicLibrarySearchHit {
  const MusicLibrarySearchRecording(this.video, {required super.lyricLine});

  final Video video;

  @override
  String get key => 'recording:${video.videoId}';
  @override
  String get title => video.title ?? video.videoId;
  @override
  String? get subtitle => video.author;
}

final _lyricSeparators = RegExp(r'[\p{P}\s]+', unicode: true);

String _lyricText(String text) =>
    normalizeMusicSearchText(text).replaceAll(_lyricSeparators, ' ').trim();

List<String> _lyricTerms(String query) {
  final normalized = _lyricText(query);
  return normalized.isEmpty ? const [] : normalized.split(' ');
}

String _lyricExcerpt(String line, List<String> terms) {
  const length = 144;
  final trimmed = line.trim();
  if (trimmed.length <= length) return trimmed;
  final normalized = normalizeMusicSearchText(trimmed);
  final first = terms
      .map(normalized.indexOf)
      .where((offset) => offset >= 0)
      .fold(trimmed.length, (first, offset) => offset < first ? offset : first);
  final start = (first - 28).clamp(0, trimmed.length - length);
  final end = start + length;
  // Do not slice through a Unicode surrogate pair.
  bool splitPair(int offset) =>
      offset > 0 &&
      offset < trimmed.length &&
      (trimmed.codeUnitAt(offset) & 0xfc00) == 0xdc00;
  final excerpt = trimmed.substring(
      splitPair(start) ? start - 1 : start, splitPair(end) ? end + 1 : end);
  return '${start == 0 ? '' : '…'}${excerpt.trim()}${end == trimmed.length ? '' : '…'}';
}

String? _matchingLyricLine(MusicLyrics? lyrics, List<String> terms) {
  if (lyrics == null || terms.isEmpty) return null;
  final rawLines = lyrics.text == null
      ? lyrics.cues.indexed
          .map((item) => lyrics.displayTextByCue[item.$1] ?? item.$2.text)
      : [lyrics.text!];
  final seen = <String>{};
  for (final raw in rawLines) {
    if (!seen.add(raw)) continue;
    for (final line in LineSplitter.split(raw)) {
      final normalized = _lyricText(line);
      if (terms.every(normalized.contains)) return _lyricExcerpt(line, terms);
    }
  }
  return null;
}

typedef _FileOwner = ({IDbClient database, String profileId});

/// Searches the active profile's library, authorized files, and local lyrics.
class MusicLibrarySearch extends ChangeNotifier {
  MusicLibrarySearch(
      {LocalMusicLibrary? deviceLibrary, OnDeviceMusicDownloads? downloads})
      : _device = deviceLibrary ?? LocalMusicLibrary.instance,
        _downloads = downloads ?? OnDeviceMusicDownloads();

  final LocalMusicLibrary _device;
  final OnDeviceMusicDownloads _downloads;
  final _searchText = Expando<String>();
  final _deviceGroups = <MusicLibrarySearchType, List<MusicLibrarySearchHit>>{};
  List<LocalMusicTrack>? _groupTracks;
  late final Listenable fileChanges = Listenable.merge([_device, this]);
  _FileOwner? _requestOwner;
  _FileOwner? _readyOwner;
  List<DownloadedVideo> _requested = const [];
  Map<String, DownloadedVideo> _requestedById = const {};
  Object? _checkedSource;
  Future<void>? _pending;
  bool Function()? _requestCurrent;
  int _revision = 0;
  int? _checkedRevision;
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
    _checkedRevision = _revision;
    _readyOwner = owner;
  }

  List<MusicLibrarySearchHit> search(String query,
      {required IDbClient database,
      required String profileId,
      Set<MusicLibrarySearchType> types = MusicLibrarySearchType.categories,
      Map<LocalMusicTrack, String> deviceLyricMatches = const {}}) {
    if (_disposed || database.profileId != profileId) return const [];
    if (types.contains(MusicLibrarySearchType.lyrics)) {
      return _searchLyrics(query, database, profileId, deviceLyricMatches);
    }
    final terms = musicSearchTerms(query);
    if (terms.isEmpty) return const [];
    bool matches(Object row, List<String?> Function() fields,
        [Iterable<String> aliases = const []]) {
      final text = _searchText[row] ??=
          normalizeMusicSearchText(fields().nonNulls.join(' '));
      return musicSearchMatchesWithArtistAliases(terms, text, aliases);
    }

    final library = MusicLibraryService.forProfile(database, profileId);
    final owner = (database: database, profileId: profileId);
    final includeSongs = types.contains(MusicLibrarySearchType.songs);
    final includePlaylists = types.contains(MusicLibrarySearchType.playlists);
    return [
      if (includeSongs || includePlaylists)
        for (final item in library.entries)
          if (((includeSongs && item.kind == MusicLibraryKind.song) ||
                  (includePlaylists &&
                      item.kind == MusicLibraryKind.playlist)) &&
              matches(
                  item,
                  () => [
                        item.displayTitle,
                        item.subtitle,
                        item.album,
                        ...item.artistCredits.map((credit) => credit.name),
                      ],
                  catalogArtistSearchAliases(library, item.artistCredits)))
            MusicLibrarySearchBookmark(item,
                artistByline: library.catalogArtistByline(
                    item.subtitle, item.artistCredits)),
      if (includePlaylists)
        for (final playlist in _localPlaylists(database.forProfile(profileId)))
          if (library.isMusicPlaylist(playlist) &&
              matches(playlist, () => [playlist.title, playlist.author]))
            MusicLibrarySearchPlaylist(playlist),
      if (includeSongs && _readyOwner == owner)
        for (final file in _downloads.entries(_device, profileId))
          if (_fileCurrent(file) &&
              matches(
                  file.deviceTrack ?? file.download!,
                  () => [
                        file.title,
                        file.artist,
                        file.album,
                        file.deviceTrack?.albumArtist,
                        file.fileName,
                        file.deviceTrack?.titleSort,
                        file.deviceTrack?.artistSort,
                        file.deviceTrack?.albumSort,
                        file.deviceTrack?.albumArtistSort,
                        ...fileArtistCreditNames(file),
                      ],
                  fileArtistSearchAliases(library, file)))
            MusicLibrarySearchFile(file,
                artistByline: musicFileArtistByline(library, file)),
      if (_readyOwner == owner &&
          _checkedSource == _deviceSource &&
          _device.enabled &&
          !_device.unavailable)
        for (final group in _groups(types))
          if (matches(group, () => [group.title, group.subtitle])) group,
    ];
  }

  Iterable<MusicLibrarySearchHit> _groups(
      Set<MusicLibrarySearchType> types) sync* {
    const groupTypes = {
      MusicLibrarySearchType.albums,
      MusicLibrarySearchType.artists,
      MusicLibrarySearchType.genres,
    };
    if (!groupTypes.any(types.contains)) return;
    final tracks = _device.visibleTracks;
    // Hiding a track can change the visible snapshot without a catalog rescan.
    if (!listEquals(_groupTracks, tracks)) {
      _groupTracks = tracks;
      _deviceGroups.clear();
    }
    if (types.contains(MusicLibrarySearchType.albums)) {
      yield* _deviceGroups.putIfAbsent(
          MusicLibrarySearchType.albums,
          () => [
                for (final album in groupLocalMusicAlbums(tracks))
                  MusicLibrarySearchAlbum(album),
              ]);
    }
    if (types.contains(MusicLibrarySearchType.artists)) {
      yield* _deviceGroups.putIfAbsent(
          MusicLibrarySearchType.artists,
          () => [
                for (final artist in groupLocalMusicArtists(tracks))
                  MusicLibrarySearchArtist(artist),
              ]);
    }
    if (types.contains(MusicLibrarySearchType.genres)) {
      yield* _deviceGroups.putIfAbsent(
          MusicLibrarySearchType.genres,
          () => [
                for (final genre in groupLocalMusicGenres(tracks).entries)
                  MusicLibrarySearchGenre(genre.key, genre.value),
              ]);
    }
  }

  Stream<void> watchSavedLyrics(IDbClient database, String profileId) =>
      MusicOfflineLyrics(database.forProfile(profileId)).changes;

  List<MusicLibrarySearchHit> _searchLyrics(
    String query,
    IDbClient database,
    String profileId,
    Map<LocalMusicTrack, String> deviceMatches,
  ) {
    final terms = _lyricTerms(query);
    if (terms.isEmpty) return const [];

    final owner = database.forProfile(profileId);
    final offline = MusicOfflineLyrics(owner);
    final corrections = MusicLyricsCorrections(owner);
    String? catalogLine(String id, MusicMetadata track, int? duration) =>
        _matchingLyricLine(
          corrections.read(id)?.lyrics ??
              offline.read(id, track: track, durationSeconds: duration),
          terms,
        );

    final hits = <MusicLibrarySearchHit>[];
    final candidates = <String>{};
    final matched = <String>{};
    if (_checkedRevision == _revision &&
        _readyOwner == (database: database, profileId: profileId)) {
      for (final file in _downloads.entries(_device, profileId)) {
        if (!_fileCurrent(file)) continue;
        if (file.deviceTrack case final track?) {
          if (deviceMatches[track] case final line?) {
            hits.add(MusicLibrarySearchFile(file, lyricLine: line));
          }
        } else if (file.download case final download?) {
          final id = download.videoId;
          candidates.add(id);
          final line =
              catalogLine(id, download.musicMetadata!, download.lengthSeconds);
          if (line != null && matched.add(id)) {
            hits.add(MusicLibrarySearchFile(file, lyricLine: line));
          }
        }
      }
    }

    final library = MusicLibraryService.forProfile(database, profileId);
    for (final entry in library.entries) {
      if (entry.kind != MusicLibraryKind.song) continue;
      candidates.add(entry.id);
      if (matched.contains(entry.id)) continue;
      final line = catalogLine(
          entry.id,
          MusicMetadata(
              title: entry.title, artist: entry.subtitle, album: entry.album),
          entry.durationSeconds);
      if (line != null && matched.add(entry.id)) {
        hits.add(MusicLibrarySearchBookmark(entry, lyricLine: line));
      }
    }
    for (final recording in offline.catalogRecordings()) {
      if (candidates.contains(recording.videoId)) continue;
      final line = catalogLine(
          recording.videoId, recording.track, recording.durationSeconds);
      if (line == null) continue;
      hits.add(MusicLibrarySearchRecording(
        Video(
          videoId: recording.videoId,
          title: recording.track.title,
          author: recording.track.artist,
          musicMetadata: recording.track,
          lengthSeconds: recording.durationSeconds,
        ),
        lyricLine: line,
      ));
    }
    return hits;
  }

  /// Reads one authorized local recording at a time and keeps matching lines.
  /// Provider-backed rows can contribute drafts already stored on this device.
  Stream<({LocalMusicTrack track, String line})> findDeviceLyricMatches(
    String query, {
    required IDbClient database,
    required String profileId,
    required bool Function() isCurrent,
  }) async* {
    final terms = _lyricTerms(query);
    bool current() =>
        !_disposed && database.profileId == profileId && isCurrent();
    if (terms.isEmpty ||
        !current() ||
        _checkedRevision != _revision ||
        _readyOwner != (database: database, profileId: profileId)) {
      return;
    }
    final owner = database.forProfile(profileId);
    for (final track in _device.visibleTracks) {
      if (!current()) return;
      final line = await _readDeviceLyric(track, terms, owner, current);
      if (!current()) return;
      if (line != null) yield (track: track, line: line);
    }
  }

  /// Verify that a visible device hit still has the line before playing it.
  Future<String?> recheckDeviceLyric(
    String query,
    LocalMusicTrack track, {
    required IDbClient database,
    required String profileId,
    required bool Function() isCurrent,
  }) {
    bool current() =>
        !_disposed && database.profileId == profileId && isCurrent();
    return _readDeviceLyric(
        track, _lyricTerms(query), database.forProfile(profileId), current);
  }

  Future<String?> _readDeviceLyric(
    LocalMusicTrack track,
    List<String> terms,
    IDbClient owner,
    bool Function() current,
  ) async {
    bool trackCurrent() =>
        current() &&
        identical(_device.visibleTrackById(track.playbackId), track);
    if (terms.isEmpty || !trackCurrent()) return null;
    final raw =
        track.isDocumentProvider ? null : await _device.readTrackLyrics(track);
    if (!trackCurrent() || (raw == null && !track.isDocumentProvider)) {
      return null;
    }

    final editor = LocalMusicLyricsAuthoring.forTrack(
        database: owner, track: track, isCurrent: trackCurrent);
    final authored = editor?.load(source: '');
    if (authored != null) return _matchingLyricLine(authored, terms);
    if (editor?.readPlainDraft() case final plain?) {
      return _matchingLyricLine(MusicLyrics.plain(plain), terms);
    }
    if (raw == null) return null;
    final sidecar = decodeLocalTimedLyrics(raw.timedSidecar, source: '');
    if (sidecar != null) return _matchingLyricLine(sidecar, terms);

    for (final source in [raw.sidecar, raw.embedded]) {
      final text = parseLocalLrc(source).plain;
      if (text.isNotEmpty) {
        return _matchingLyricLine(MusicLyrics.plain(text), terms);
      }
    }
    return null;
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
