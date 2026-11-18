import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../globals.dart';
import '../../network/direct_http_client.dart';
import '../../network/network_proxy.dart';
import '../../network/reloadable_http_client.dart';
import '../../videos/models/music_metadata.dart';
import 'music_community_cover_preferences.dart';
import 'music_cover_match.dart';

const _budget = Duration(seconds: 16);
const _imageLimit = 2 * 1024 * 1024;
const _mbid = r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}';
final _caaPath = RegExp(
    '^/(?:release|release-group)/$_mbid/(?:front-500|[0-9]+(?:-500)?(?:\\.(?:jpg|jpeg|png))?)\$');
final _archiveHost = RegExp(r'^(?:ia|dn)[0-9]+(?:\.[a-z]{2})?\.archive\.org$');
final _archivePath = RegExp('^/(?:download/|[0-9]+/items/)(mbid-$_mbid)/'
    r'\1-[0-9]+(?:(?:-|_thumb)500)?\.(?:jpg|jpeg|png)$');
final _provider = CommunityMusicCoverService();
final _clock = Stopwatch()..start();

/// Only the enabled profile can start a lookup or receive its result.
Future<Uint8List?> fetchCommunityMusicCover(
    MusicMetadata track, int? durationSeconds,
    {required bool Function() isCurrent}) {
  if (!isCurrent() || !isCommunityCoverArtEnabled()) return Future.value(null);
  final owner = db;
  final profile = owner.profileId;
  final consent = communityCoverArtPreferenceRevision.value;
  return _provider.fetch(track, durationSeconds,
      scope: (owner, profile, consent),
      isCurrent: () =>
          identical(owner, db) &&
          owner.profileId == profile &&
          communityCoverArtPreferenceRevision.value == consent &&
          isCommunityCoverArtEnabled() &&
          isCurrent());
}

/// Contains no provider URL, listening history, response body or credentials.
class MusicCommunityCoverException implements Exception {
  const MusicCommunityCoverException();
}

bool _isSearch(Uri uri) =>
    uri.host == 'musicbrainz.org' &&
    uri.path == '/ws/2/recording' &&
    uri.queryParameters.keys.every(const {'query', 'fmt', 'limit'}.contains);

bool _isImage(Uri uri) =>
    !uri.hasQuery &&
    (uri.host == 'coverartarchive.org' && _caaPath.hasMatch(uri.path) ||
        (uri.host == 'archive.org' || _archiveHost.hasMatch(uri.host)) &&
            _archivePath.hasMatch(uri.path));

void _validate(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      !(_isSearch(uri) || _isImage(uri))) {
    throw const MusicCommunityCoverException();
  }
}

http.Client _client(void Function() check) => IOClient(ReloadableHttpClient(() {
      check();
      final raw = createDirectHttpClient()..connectionTimeout = _budget;
      NetworkProxy.instance.configureClient(raw, validateDestination: (uri) {
        check();
        _validate(uri);
      }, requireValidCertificate: true);
      return raw;
    }));

class _CoverLookup {
  final listeners = <bool Function()>{};
  late final Future<Uint8List?> result;
}

enum _Provider { musicBrainz, coverArt }

class CommunityMusicCoverService {
  final http.Client Function()? _createClient;
  final Future<void> Function(Duration) _wait;
  final int Function() _milliseconds;
  final _pending = <(Object?, Object, Uri, int?), _CoverLookup>{};
  Future<void> _lastTurn = Future.value();
  int _nextSearch = 0;
  final _cooldown = <_Provider, int>{};

  CommunityMusicCoverService(
      {http.Client Function()? createClient,
      Future<void> Function(Duration)? wait,
      int Function()? milliseconds})
      : _createClient = createClient,
        _wait = wait ?? Future<void>.delayed,
        _milliseconds = milliseconds ?? (() => _clock.elapsedMilliseconds);

  Future<Uint8List?> fetch(MusicMetadata track, int? durationSeconds,
      {required bool Function() isCurrent, Object? scope}) async {
    final proxy = NetworkProxy.instance;
    final route = proxy.config;
    bool current() =>
        !proxy.isChanging && identical(route, proxy.config) && isCurrent();
    if (!current()) return null;
    final search = musicCoverSearchUri(track, durationSeconds);
    if (search == null) return null;
    final key = (scope, route, search, durationSeconds);
    var pending = _pending[key];
    if (pending == null) {
      if (_pending.length >= 6) throw const MusicCommunityCoverException();
      final lookup = _CoverLookup()..listeners.add(current);
      _pending[key] = pending = lookup;
      bool active() => lookup.listeners.any((listener) => listener());
      lookup.result =
          _load(search, track, durationSeconds, active).whenComplete(() {
        _pending.remove(key);
      });
    } else {
      pending.listeners.add(current);
    }
    try {
      final cover = await pending.result;
      return current() ? cover : null;
    } catch (_) {
      if (!current()) return null;
      throw const MusicCommunityCoverException();
    } finally {
      pending.listeners.remove(current);
    }
  }

  Future<Uint8List?> _load(Uri search, MusicMetadata track, int? duration,
      bool Function() active) async {
    var finished = false;
    void check() {
      if (finished || !active()) throw const MusicCommunityCoverException();
    }

    final client = _createClient?.call() ?? _client(check);

    Future<Uint8List?> read() async {
      _checkCooldown(_Provider.coverArt);
      final json = await _read(client, search, _Provider.musicBrainz, check);
      if (json == null) return null;
      check();
      final group = musicCoverReleaseGroupId(
          track, duration, jsonDecode(utf8.decode(json)));
      if (group == null) return null;
      final initial =
          Uri.https('coverartarchive.org', '/release-group/$group/front-500');
      final bytes = await _read(client, initial, _Provider.coverArt, check);
      if (bytes == null) return null;
      check();
      return _thumbnailPng(bytes);
    }

    try {
      return await read().timeout(_budget);
    } finally {
      finished = true;
      client.close();
    }
  }

  void _checkCooldown(_Provider provider) {
    if ((_cooldown[provider] ?? 0) > _milliseconds()) {
      throw const MusicCommunityCoverException();
    }
  }

  Future<http.StreamedResponse> _sendSearch(
      http.Client client, http.Request request, void Function() check) {
    // Hold the queue through response headers. A cancelled waiter takes no
    // request slot, and a slow connection cannot put two starts back-to-back.
    final turn = _lastTurn.then((_) async {
      check();
      _checkCooldown(_Provider.musicBrainz);
      final delay = _nextSearch - _milliseconds();
      if (delay > 0) await _wait(Duration(milliseconds: delay));
      check();
      // A previous cover request may have received a cooldown while this
      // recording was queued. Its search cannot produce usable artwork yet.
      _checkCooldown(_Provider.coverArt);
      _checkCooldown(_Provider.musicBrainz);
      _nextSearch = _milliseconds() + 1000;
      final response = await client.send(request).timeout(_budget);
      _recordCooldown(_Provider.musicBrainz, response);
      return response;
    });
    _lastTurn = turn.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return turn;
  }

  Future<Uint8List?> _read(http.Client client, Uri initial, _Provider provider,
      void Function() check) async {
    var uri = initial;
    final image = provider == _Provider.coverArt;
    final limit = image ? _imageLimit : 512 * 1024;
    for (var hop = 0; hop <= 4; hop++) {
      check();
      _checkCooldown(provider);
      _validate(uri);
      if (image && !_isImage(uri) || !image && !_isSearch(uri)) {
        throw const MusicCommunityCoverException();
      }
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['accept'] =
            image ? 'image/jpeg,image/png' : 'application/json'
        ..headers['user-agent'] =
            'Videre/${packageInfo?.version ?? 'development'} (https://github.com/DVBeckwitt/Videre)';
      final response = await (image
          ? client.send(request)
          : _sendSearch(client, request, check));
      if (image) _recordCooldown(provider, response);
      check();
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        if (response.statusCode == 404) return null;
        final location = response.headers['location'];
        if (image &&
            location != null &&
            location.length <= 2048 &&
            const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final next = uri.resolve(location);
          // The first CAA hop can resolve a group to a representative release.
          // Archive storage mirrors should preserve that item and image.
          if (uri.host != 'coverartarchive.org' &&
              (!next.path.endsWith(
                      '/${uri.pathSegments.sublist(uri.pathSegments.length - 2).join('/')}') ||
                  next.host == 'coverartarchive.org')) {
            throw const MusicCommunityCoverException();
          }
          uri = next;
          continue;
        }
        throw const MusicCommunityCoverException();
      }
      final type = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if ((response.contentLength ?? 0) > limit ||
          (image
              ? !const {'image/png', 'image/jpeg'}.contains(type)
              : type != 'application/json')) {
        await response.stream.listen(null).cancel();
        throw const MusicCommunityCoverException();
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        check();
        if (bytes.length + chunk.length > limit) {
          throw const MusicCommunityCoverException();
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }
    throw const MusicCommunityCoverException();
  }

  void _recordCooldown(_Provider provider, http.BaseResponse response) {
    if (response.statusCode != 429 && response.statusCode != 503) return;
    final raw = response.headers['retry-after']?.trim() ?? '';
    int? seconds = int.tryParse(raw);
    if (seconds == null && raw.isNotEmpty) {
      try {
        seconds = HttpDate.parse(raw).difference(DateTime.now()).inSeconds + 1;
      } catch (_) {
        // Unusable Retry-After still backs off this provider.
      }
    }
    final until = _milliseconds() + (seconds ?? 10).clamp(1, 31536000) * 1000;
    // In-flight image requests can complete out of order. Honor every
    // outstanding Retry-After even if its caller has left Now Playing.
    if (until > (_cooldown[provider] ?? 0)) _cooldown[provider] = until;
  }
}

Future<Uint8List> _thumbnailPng(Uint8List bytes) async {
  final jpeg = bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff;
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  final png = bytes.length >= signature.length &&
      signature.indexed.every((entry) => bytes[entry.$1] == entry.$2);
  if (!jpeg && !png) throw const MusicCommunityCoverException();
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width < 1 ||
        descriptor.width > 1024 ||
        descriptor.height < 1 ||
        descriptor.height > 1024) {
      throw const MusicCommunityCoverException();
    }
    codec = await descriptor.instantiateCodec();
    if (codec.frameCount != 1) throw const MusicCommunityCoverException();
    frame = (await codec.getNextFrame()).image;
    final data = await frame.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes > _imageLimit) {
      throw const MusicCommunityCoverException();
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    frame?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
