import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../globals.dart';
import '../../network/direct_http_client.dart';
import '../../network/network_proxy.dart';
import '../../network/reloadable_http_client.dart';
import '../../videos/models/music_metadata.dart';
import '../models/music_lyrics.dart';
import '../models/music_lyrics_match.dart';
import '../models/music_search_text.dart';
import 'lrc_lyrics.dart';
import 'music_lyrics_preferences.dart';

const _source = 'LRCLIB';
const _host = 'lrclib.net';
const _lookupPath = '/api/get';
const _searchPath = '/api/search';
const _maxResponseBytes = 512 * 1024;
const _maxSearchResponseBytes = 2 * 1024 * 1024;
const _maxSearchResults = 20;
const _maxCandidateDuration = Duration(days: 365);
const _timeout = Duration(seconds: 12);
final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
final _lrclib = LrclibMusicLyricsService();

Future<MusicLyrics> loadMusicLyrics(
    MusicMetadata track, int? durationSeconds, String videoId,
    {bool Function()? isPlaybackCurrent, Future<void>? retired}) {
  return _withLrclibConsent(
    const MusicLyrics.unavailable(),
    () => _videoId.hasMatch(videoId) && (isPlaybackCurrent?.call() ?? true),
    (isCurrent) => _lrclib.load(track, durationSeconds,
        isCurrent: isCurrent, retired: retired),
  );
}

Future<List<MusicLyricsMatch>> searchMusicLyrics({
  required String trackName,
  required String artistName,
  required String albumName,
  required int? durationSeconds,
  required bool Function() isCurrent,
}) {
  return _withLrclibConsent(
    const <MusicLyricsMatch>[],
    isCurrent,
    (isCurrent) => _lrclib.search(
      trackName: trackName,
      artistName: artistName,
      albumName: albumName,
      durationSeconds: durationSeconds,
      isCurrent: isCurrent,
    ),
  );
}

Future<T> _withLrclibConsent<T>(
  T unavailable,
  bool Function() isRequestCurrent,
  Future<T> Function(bool Function()) run,
) async {
  if (!isRequestCurrent() || !isLrclibEnabled()) return unavailable;
  final database = db;
  final profile = database.profileId;
  final consent = lrclibPreferenceRevision.value;
  final proxy = NetworkProxy.instance;
  final config = proxy.config;
  return run(() {
    return isRequestCurrent() &&
        identical(db, database) &&
        db.profileId == profile &&
        lrclibPreferenceRevision.value == consent &&
        !proxy.isChanging &&
        identical(proxy.config, config) &&
        isLrclibEnabled();
  });
}

void _validateDestination(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host != _host ||
      uri.port != 443 ||
      (uri.path != _lookupPath && uri.path != _searchPath) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const MusicLyricsRequestException();
  }
}

http.Client _client() => IOClient(ReloadableHttpClient(() {
      final client = createDirectHttpClient()..connectionTimeout = _timeout;
      NetworkProxy.instance.configureClient(client,
          validateDestination: _validateDestination,
          requireValidCertificate: true);
      return client;
    }));

/// Safe to show as a generic retry state. Provider URLs and bodies stay out of
/// diagnostics. The provider sees only the recording's public music metadata.
class MusicLyricsRequestException implements Exception {
  const MusicLyricsRequestException();
}

class LrclibMusicLyricsService {
  final http.Client Function() _createClient;
  final DateTime Function() _now;
  Completer<void>? _active;
  DateTime? _retryAfter;

  LrclibMusicLyricsService({
    http.Client Function()? createClient,
    DateTime Function()? now,
  })  : _createClient = createClient ?? _client,
        _now = now ?? DateTime.now;

  Future<MusicLyrics> load(MusicMetadata track, int? playbackSeconds,
      {required bool Function() isCurrent, Future<void>? retired}) async {
    const unavailable = MusicLyrics.unavailable();
    final signature = _signature(track);
    if (signature == null) return unavailable;
    final (title, artist, album) = signature;
    final duration =
        playbackSeconds != null && playbackSeconds > 0 ? playbackSeconds : null;
    final uri = Uri.https(_host, _lookupPath, {
      'track_name': title,
      'artist_name': artist,
      if (album.isNotEmpty) 'album_name': album,
      if (duration != null && duration <= 3600) 'duration': '$duration',
    });
    var readerRetired = false;
    retired?.then((_) => readerRetired = true);
    bool current() => !readerRetired && isCurrent();
    final lyrics =
        await _request(uri, _maxResponseBytes, unavailable, current, (json) {
      if (json is! Map<String, dynamic>) {
        throw const MusicLyricsRequestException();
      }
      final record = _recordMetadata(json);
      if (record == null) throw const MusicLyricsRequestException();
      if (_key(record.title) != _key(title) ||
          _key(record.artist) != _key(artist) ||
          (album.isNotEmpty && _key(record.album) != _key(album)) ||
          (duration != null && (record.duration - duration).abs() > 2)) {
        return unavailable;
      }
      return _parseLyrics(json, duration);
    }, retired: retired);
    if (!current()) return unavailable;
    if (lyrics.kind != MusicLyricsKind.unavailable) return lyrics;
    if (duration == null && album.isEmpty) return unavailable;
    return _request(
        _searchUri(title, artist, ''),
        _maxSearchResponseBytes,
        unavailable,
        current,
        (json) => _bestRecordingLyrics(json, title, artist, album, duration),
        retired: retired);
  }

  Future<List<MusicLyricsMatch>> search({
    required String trackName,
    required String artistName,
    required String albumName,
    required int? durationSeconds,
    required bool Function() isCurrent,
  }) async {
    const unavailable = <MusicLyricsMatch>[];
    final (title, artist) = _recordingLabels(trackName, artistName);
    final album = _label(albumName);
    if (title.isEmpty) return unavailable;
    Future<List<MusicLyricsMatch>> lookup(String release) => _request(
            _searchUri(title, artist, release),
            _maxSearchResponseBytes,
            unavailable,
            isCurrent, (json) {
          if (json is! List) throw const MusicLyricsRequestException();
          final matches = <MusicLyricsMatch>[];
          final ids = <int>{};
          for (final entry in json.take(_maxSearchResults)) {
            if (entry is! Map<String, dynamic>) continue;
            final result = _recordMetadata(entry);
            if (result == null ||
                result.duration > _maxCandidateDuration.inSeconds) {
              continue;
            }
            final canSync = durationSeconds != null &&
                (result.duration - durationSeconds).abs() <= 2;
            final lyrics =
                _parseLyrics(entry, canSync ? durationSeconds : null);
            if (lyrics.kind == MusicLyricsKind.unavailable ||
                !ids.add(result.id)) {
              continue;
            }
            matches.add(MusicLyricsMatch(
              id: result.id,
              trackName: result.title,
              artistName: result.artist,
              albumName: result.album,
              duration: Duration(
                  microseconds:
                      (result.duration * Duration.microsecondsPerSecond)
                          .round()),
              lyrics: lyrics,
            ));
          }
          return List.unmodifiable(matches);
        });
    final matches = await lookup(album);
    if (matches.isNotEmpty || album.isEmpty || artist.isEmpty || !isCurrent()) {
      return matches;
    }
    return lookup('');
  }

  Future<T> _request<T>(
    Uri uri,
    int maxResponseBytes,
    T unavailable,
    bool Function() isCurrent,
    T Function(Object) decode, {
    Future<void>? retired,
  }) async {
    if (!isCurrent()) return unavailable;
    // A replacement reader can mount before the previous one is disposed.
    while (_active != null && retired != null) {
      final canceled = await Future.any([
        _active!.future.then((_) => false),
        retired.then((_) => true),
      ]);
      if (canceled || !isCurrent()) return unavailable;
    }
    final retryAfter = _retryAfter;
    if (_active != null ||
        (retryAfter != null && _now().isBefore(retryAfter))) {
      throw const MusicLyricsRequestException();
    }
    final active = _active = Completer<void>();
    http.Client? client;
    try {
      _validateDestination(uri);
      if (!isCurrent()) return unavailable;
      client = _createClient();
      final request = _get(client, uri, maxResponseBytes, isCurrent);
      final response = retired == null
          ? request
          : Future.any([request, retired.then((_) => null)]);
      final payload = await response.timeout(_timeout);
      return !isCurrent() || payload == null ? unavailable : decode(payload);
    } catch (_) {
      if (!isCurrent()) return unavailable;
      throw const MusicLyricsRequestException();
    } finally {
      client?.close();
      _active = null;
      active.complete();
    }
  }

  Future<Object?> _get(http.Client client, Uri uri, int maxResponseBytes,
      bool Function() isCurrent) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['accept'] = 'application/json'
      ..headers['user-agent'] =
          'Videre/${packageInfo?.version ?? 'development'} (https://github.com/DVBeckwitt/Videre)';
    final response = await client.send(request);
    if (response.statusCode == 429 || response.statusCode == 503) {
      _recordCooldown(response.headers['retry-after']);
    }
    if (!isCurrent() ||
        response.statusCode != 200 ||
        (response.contentLength ?? 0) > maxResponseBytes ||
        response.headers['content-type']
                ?.split(';')
                .first
                .trim()
                .toLowerCase() !=
            'application/json') {
      await response.stream.listen(null).cancel();
      if (!isCurrent() || response.statusCode == 404) return null;
      throw const MusicLyricsRequestException();
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (!isCurrent()) return null;
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const MusicLyricsRequestException();
      }
      bytes.add(chunk);
    }
    final json = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (json == null) {
      throw const MusicLyricsRequestException();
    }
    return json;
  }

  void _recordCooldown(String? header) {
    final now = _now();
    int? seconds;
    if (header != null) {
      seconds = int.tryParse(header.trim());
      if (seconds == null) {
        try {
          seconds = HttpDate.parse(header).difference(now).inSeconds + 1;
        } catch (_) {
          // Use a short delay even if the provider omits a usable value.
        }
      }
    }
    _retryAfter = now.add(Duration(seconds: (seconds ?? 5).clamp(1, 31536000)));
  }
}

const _uploadLabel =
    r'(?:official(?: music)? (?:video|audio)|music video|official lyrics?(?: video)?|lyrics?(?: video)?|visuali[sz]er|(?:hd|4k)(?: remaster(?:ed)?)?)';
final _uploadSuffix = RegExp(
    r'(?:\s*\(\s*' +
        _uploadLabel +
        r'\s*\)|\s*\[\s*' +
        _uploadLabel +
        r'\s*\]|\s+[-–—|]\s*' +
        _uploadLabel +
        r')\s*$',
    caseSensitive: false);
final _artistSuffix =
    RegExp(r'(?:\s+[-–—]\s+Topic|VEVO)$', caseSensitive: false);
final _separator = RegExp(r'\s+[-–—]\s+');
final _spaces = RegExp(r'\s+');
final _dashes = RegExp(r'[‐‑–—−]');
final _lyricsWord = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);

String _label(Object? value) => value is String && value.length <= 320
    ? cleanLyricsText(value).replaceAll(_spaces, ' ')
    : '';

String _key(String value) => normalizeMusicSearchText(value)
    .replaceAll('’', "'")
    .replaceAll(_dashes, '-');

Uri _searchUri(String title, String artist, String album) =>
    Uri.https(_host, _searchPath, {
      'track_name': title,
      if (artist.isNotEmpty) 'artist_name': artist,
      if (album.isNotEmpty) 'album_name': album,
    });

(String, String) _recordingLabels(String rawTitle, String rawArtist) {
  var title = _label(rawTitle);
  var artist = _label(rawArtist).replaceFirst(_artistSuffix, '').trim();
  while (_uploadSuffix.hasMatch(title)) {
    title = title.replaceFirst(_uploadSuffix, '').trim();
  }
  final separator = _separator.firstMatch(title);
  if (separator != null) {
    final prefix = title.substring(0, separator.start);
    if (_key(prefix).replaceAll(' ', '') == _key(artist).replaceAll(' ', '')) {
      title = title.substring(separator.end).trim();
      artist = prefix.trim();
    }
  }
  return (title, artist);
}

(String, String, String)? _signature(MusicMetadata track) {
  final (title, artist) = _recordingLabels(track.title, track.artist);
  if (title.isEmpty || artist.isEmpty) return null;
  return (title, artist, _label(track.album));
}

MusicLyrics _bestRecordingLyrics(
    Object json, String title, String artist, String album, int? duration) {
  if (json is! List) throw const MusicLyricsRequestException();
  const unavailable = MusicLyrics.unavailable();
  var best = unavailable;
  (int, num)? bestRank;
  var conflicting = false;
  final titleKey = _key(title);
  final artistKey = _key(artist);
  final albumKey = _key(album);
  for (final entry in json.take(_maxSearchResults)) {
    if (entry is! Map<String, dynamic>) continue;
    final record = _recordMetadata(entry);
    if (record == null) continue;
    final (candidateTitle, candidateArtist) =
        _recordingLabels(record.title, record.artist);
    if (_key(candidateTitle) != titleKey ||
        _key(candidateArtist) != artistKey) {
      continue;
    }
    final sameAlbum = albumKey.isNotEmpty && _key(record.album) == albumKey;
    final difference =
        duration == null ? null : (record.duration - duration).abs();
    final canSync = difference != null && difference <= 2;
    // A close duration can corroborate an alternate release. A slightly
    // different cut of the same release is suitable for reading only.
    if (!canSync &&
        (!sameAlbum ||
            (difference != null && difference > 5) ||
            entry['instrumental'] == true)) {
      continue;
    }
    final rank = (sameAlbum ? 0 : 1, difference ?? 0);
    final previous = bestRank;
    if (previous != null &&
        (rank.$1 > previous.$1 ||
            (rank.$1 == previous.$1 && rank.$2 > previous.$2))) {
      continue;
    }
    final lyrics = _parseLyrics(entry, canSync ? duration : null);
    if (lyrics.kind == MusicLyricsKind.unavailable) continue;
    if (rank == previous) {
      if ((best.kind == MusicLyricsKind.instrumental) !=
              (lyrics.kind == MusicLyricsKind.instrumental) ||
          (!sameAlbum && !_sameLyricWords(best, lyrics))) {
        conflicting = true;
      }
      if (lyrics.kind == MusicLyricsKind.synced) best = lyrics;
    } else {
      bestRank = rank;
      best = lyrics;
      conflicting = false;
    }
  }
  return conflicting ? unavailable : best;
}

Iterable<String> _lyricWords(MusicLyrics lyrics) sync* {
  final text = lyrics.text;
  final lines =
      text == null ? lyrics.cues.map((cue) => cue.text) : text.split('\n');
  for (final line in lines) {
    for (final word in _lyricsWord.allMatches(normalizeMusicSearchText(line))) {
      yield word.group(0)!;
    }
  }
}

bool _sameLyricWords(MusicLyrics first, MusicLyrics second) {
  // Repeated timestamps can share a single cue string. Bound the expanded
  // text before normalizing or walking the words on the UI isolate.
  var remaining = 2 * maxLyricsCharacters;
  for (final lyrics in [first, second]) {
    remaining -= lyrics.text?.length ?? 0;
    for (final cue in lyrics.cues) {
      remaining -= cue.text.length;
    }
    if (remaining < 0) return false;
  }
  final left = _lyricWords(first).iterator;
  final right = _lyricWords(second).iterator;
  while (left.moveNext()) {
    if (!right.moveNext() || left.current != right.current) return false;
  }
  return !right.moveNext();
}

typedef _RecordMetadata = ({
  int id,
  String title,
  String artist,
  String album,
  num duration,
});

_RecordMetadata? _recordMetadata(Map<String, dynamic> record) {
  final id = record['id'];
  final length = record['duration'];
  final title = _label(record['trackName'] ?? record['name']);
  final artist = _label(record['artistName']);
  if (id is! int ||
      id <= 0 ||
      title.isEmpty ||
      artist.isEmpty ||
      length is! num ||
      !length.isFinite ||
      length <= 0 ||
      record['instrumental'] is! bool) {
    return null;
  }
  return (
    id: id,
    title: title,
    artist: artist,
    album: _label(record['albumName']),
    duration: length,
  );
}

MusicLyrics _parseLyrics(Map<String, dynamic> record, int? playbackSeconds) {
  if (record['instrumental'] == true) {
    return const MusicLyrics.instrumental(source: _source);
  }
  final synced = record['syncedLyrics'];
  final (:lines, :wordsByCue, :displayTextByCue, :breakStarts) =
      parseEnhancedLrc(
    synced is String ? synced : null,
    playbackDuration:
        playbackSeconds == null ? null : Duration(seconds: playbackSeconds),
  );
  if (lrcFitsDuration(lines, playbackSeconds)) {
    return MusicLyrics.synced(lines,
        source: _source,
        wordsByCue: wordsByCue,
        displayTextByCue: displayTextByCue,
        breakStarts: breakStarts);
  }
  final plain = record['plainLyrics'];
  final text = cleanLyricsText(plain is String ? plain : null);
  if (text.isNotEmpty) return MusicLyrics.plain(text, source: _source);
  final fallback = lines.isEmpty && synced is String ? parseLrc(synced) : lines;
  if (fallback.isEmpty) return const MusicLyrics.unavailable();
  // Multiple timestamps on one LRC line can repeat a long string thousands
  // of times. Keep all the words while avoiding a large joined allocation.
  var size = fallback.length - 1;
  for (final line in fallback) {
    size += line.text.length;
    if (size > maxLyricsCharacters) {
      return MusicLyrics.plainCues(fallback, source: _source);
    }
  }
  return MusicLyrics.plain(fallback.map((line) => line.text).join('\n'),
      source: _source);
}
