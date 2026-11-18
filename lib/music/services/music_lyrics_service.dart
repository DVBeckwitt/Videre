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
import 'lrc_lyrics.dart';
import 'music_lyrics_preferences.dart';

const _source = 'LRCLIB';
const _host = 'lrclib.net';
const _path = '/api/get';
const _maxResponseBytes = 512 * 1024;
const _timeout = Duration(seconds: 12);
final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
final _lookup = LrclibMusicLyricsService();

Future<MusicLyrics> loadMusicLyrics(
    MusicMetadata track, int? durationSeconds, String videoId) async {
  if (!_videoId.hasMatch(videoId) || !isLrclibEnabled()) {
    return const MusicLyrics.unavailable();
  }
  final database = db;
  final profile = database.profileId;
  final consent = lrclibPreferenceRevision.value;
  final proxy = NetworkProxy.instance;
  final config = proxy.config;
  return _lookup.load(track, durationSeconds, isCurrent: () {
    return identical(db, database) &&
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
      uri.path != _path ||
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
  bool _loading = false;
  DateTime? _retryAfter;

  LrclibMusicLyricsService({
    http.Client Function()? createClient,
    DateTime Function()? now,
  })  : _createClient = createClient ?? _client,
        _now = now ?? DateTime.now;

  Future<MusicLyrics> load(MusicMetadata track, int? playbackSeconds,
      {required bool Function() isCurrent}) async {
    if (!isCurrent()) return const MusicLyrics.unavailable();
    final signature = _signature(track);
    if (signature == null) return const MusicLyrics.unavailable();
    final (title, artist, album) = signature;
    final duration =
        playbackSeconds != null && playbackSeconds > 0 ? playbackSeconds : null;
    final uri = Uri.https(_host, _path, {
      'track_name': title,
      'artist_name': artist,
      if (album.isNotEmpty) 'album_name': album,
      if (duration != null && duration <= 3600) 'duration': '$duration',
    });
    final retryAfter = _retryAfter;
    if (_loading || (retryAfter != null && _now().isBefore(retryAfter))) {
      throw const MusicLyricsRequestException();
    }
    _loading = true;
    http.Client? client;
    try {
      _validateDestination(uri);
      if (!isCurrent()) return const MusicLyrics.unavailable();
      client = _createClient();
      final record = await _get(client, uri, isCurrent).timeout(_timeout);
      if (!isCurrent() || record == null) {
        return const MusicLyrics.unavailable();
      }
      return _parseMatch(record, title, artist, album, duration);
    } catch (_) {
      if (!isCurrent()) return const MusicLyrics.unavailable();
      throw const MusicLyricsRequestException();
    } finally {
      client?.close();
      _loading = false;
    }
  }

  Future<Map<String, dynamic>?> _get(
      http.Client client, Uri uri, bool Function() isCurrent) async {
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
        (response.contentLength ?? 0) > _maxResponseBytes ||
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
      if (bytes.length + chunk.length > _maxResponseBytes) {
        throw const MusicLyricsRequestException();
      }
      bytes.add(chunk);
    }
    final json = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (json is! Map<String, dynamic>) {
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

final _uploadSuffix = RegExp(
    r'\s*\((?:official(?: music)? (?:video|audio)|lyric video|lyrics|visuali[sz]er|4k remaster|hd|4k)\)\s*$',
    caseSensitive: false);
final _artistSuffix = RegExp(r'(?:\s+-\s+Topic|VEVO)$', caseSensitive: false);
final _separator = RegExp(r'\s+[-–—]\s+');
final _spaces = RegExp(r'\s+');

String _label(Object? value) => value is String && value.length <= 320
    ? cleanLyricsText(value).replaceAll(_spaces, ' ')
    : '';

String _key(Object? value) => _label(value).toLowerCase().replaceAll('’', "'");

(String, String, String)? _signature(MusicMetadata track) {
  var title = _label(track.title);
  var artist = _label(track.artist).replaceFirst(_artistSuffix, '');
  while (_uploadSuffix.hasMatch(title)) {
    title = title.replaceFirst(_uploadSuffix, '').trim();
  }
  final separator = _separator.firstMatch(title);
  if (separator != null) {
    final prefix = title.substring(0, separator.start);
    if (_key(prefix).replaceAll(' ', '') == _key(artist).replaceAll(' ', '')) {
      title = title.substring(separator.end);
      artist = prefix;
    }
  }
  if (title.isEmpty || artist.isEmpty) return null;
  return (title, artist, _label(track.album));
}

MusicLyrics _parseMatch(Map<String, dynamic> record, String title,
    String artist, String album, int? playbackSeconds) {
  final length = record['duration'];
  final recordTitle = _key(record['trackName'] ?? record['name']);
  final recordArtist = _key(record['artistName']);
  if (record['id'] is! int ||
      (record['id'] as int) <= 0 ||
      recordTitle.isEmpty ||
      recordArtist.isEmpty ||
      length is! num ||
      !length.isFinite ||
      length <= 0 ||
      record['instrumental'] is! bool) {
    throw const MusicLyricsRequestException();
  }
  if (recordTitle != _key(title) ||
      recordArtist != _key(artist) ||
      (album.isNotEmpty && _key(record['albumName']) != _key(album)) ||
      (playbackSeconds != null && (length - playbackSeconds).abs() > 2)) {
    return const MusicLyrics.unavailable();
  }
  if (record['instrumental'] == true) {
    return const MusicLyrics.instrumental(source: _source);
  }
  final synced = record['syncedLyrics'];
  final lines = parseLrc(synced is String ? synced : null);
  if (synced is String && lrcCanSynchronize(synced, lines, playbackSeconds)) {
    return MusicLyrics.synced(lines, source: _source);
  }
  final plain = record['plainLyrics'];
  final text = cleanLyricsText(plain is String ? plain : null);
  if (text.isNotEmpty) return MusicLyrics.plain(text, source: _source);
  if (lines.isEmpty) return const MusicLyrics.unavailable();
  // Multiple timestamps on one LRC line can repeat a long string thousands
  // of times. Keep all the words while avoiding a large joined allocation.
  var size = lines.length - 1;
  for (final line in lines) {
    size += line.text.length;
    if (size > maxLyricsCharacters) {
      return MusicLyrics.plainCues(lines, source: _source);
    }
  }
  return MusicLyrics.plain(lines.map((line) => line.text).join('\n'),
      source: _source);
}
