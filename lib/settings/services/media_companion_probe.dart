import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../network/gateway_http_client.dart';
import '../../network/media_companion.dart';
import '../../network/native_proxy_http_client.dart';
import '../../network/network_proxy.dart';
import '../../player/media_source.dart';
import '../../videos/models/adaptive_format.dart';
import '../../videos/models/video.dart';
import '../models/db/server.dart';

const setupSampleVideoId = 'dQw4w9WgXcQ';
const chocolateMooInstanceUrl = 'https://yt.chocolatemoo53.com';

// The operator rotates these hosts independently of the sample video.
// Only show them as candidates. The existing consent flow grants access.
// https://status.chocolatemoo53.com/
const _chocolateMooCompanions = {
  'https://yt-comp1.chocolatemoo53.com',
  'https://yt-comp2.chocolatemoo53.com',
  'https://yt-comp3.chocolatemoo53.com',
  'https://yt-comp4.chocolatemoo53.com',
  'https://yt-comp5.chocolatemoo53.com',
  'https://yt-comp6.chocolatemoo53.com',
};

bool get supportsMediaCompanionDiscovery =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Set<String> knownMediaCompanionCandidates(Server server) =>
    supportsMediaCompanionDiscovery &&
            mediaCompanionInstanceAddress(server) == chocolateMooInstanceUrl
        ? _chocolateMooCompanions
            .difference(trustedMediaCompanionOrigins(server))
        : const {};

// Check one primary video route and one primary audio route from the sample.
// Uncertain results leave setup usable. Only an origin is presented for consent.
Future<Set<String>> discoverSetupMediaCompanions(
    Server server, Video video, http.Client client,
    {required bool Function() isCurrent,
    bool reportUnavailable = false}) async {
  Set<String> unavailable() {
    if (reportUnavailable) throw StateError('Sample media check unavailable');
    return {};
  }

  if (!supportsMediaCompanionDiscovery ||
      !isMediaCompanionEligibleServer(server) ||
      !isCurrent()) {
    return unavailable();
  }
  final proxy = NetworkProxy.instance.config;
  const budget = Duration(seconds: 4);
  final clock = Stopwatch()..start();
  var expired = false;
  bool sameContext() =>
      isCurrent() &&
      !NetworkProxy.instance.isChanging &&
      identical(NetworkProxy.instance.config, proxy);
  bool current() => !expired && clock.elapsed < budget && sameContext();
  final trusted = trustedMediaCompanionOrigins(server);

  Future<Set<String>?> inspect() async {
    final combined = (video.formatStreams ?? [])
        .reversed
        .where((stream) =>
            !stream.isLegacyHd720 && stream.type.startsWith('video/'))
        .map((stream) => parseMediaUrl(stream.url))
        .whereType<String>()
        .firstOrNull;
    final hls = parseMediaUrl(video.hlsUrl);
    final dash = parseMediaUrl(video.dashUrl);
    final manifest = video.liveNow == true ? hls ?? dash : dash ?? hls;
    final audio = (video.adaptiveFormats ?? <AdaptiveFormat>[])
        .where((track) =>
            track.type.startsWith('audio/') &&
            (track.audioTrack == null ||
                track.audioTrack?.audioIsDefault == true) &&
            parseMediaUrl(track.url) != null)
        .toList()
      ..sort((a, b) => (int.tryParse(b.bitrate ?? '') ?? 0)
          .compareTo(int.tryParse(a.bitrate ?? '') ?? 0));
    final routes = <(String, bool)>{
      if (manifest != null)
        (manifest, true)
      else if (combined != null)
        (combined, false),
      if (audio.isNotEmpty)
        (audio.first.url, false)
      else if (combined != null)
        (combined, false),
    };

    final found = <String>{};
    final seen = <Uri>{};
    final resolved = <Uri>{};
    var incomplete = routes.isEmpty;
    final frontend = Uri.parse(server.url);
    var requests = 0;
    for (final (raw, manifest) in routes) {
      if (!current()) return null;
      var uri = Uri.parse(proxyMediaUrl(raw, server, adaptive: manifest));
      if (isMediaCompanionAccountRoute(uri)) return null;
      if (!sameMediaOrigin(uri, frontend)) {
        final origin = _companionOrigin(uri, requireMediaPath: false);
        if (origin == null) {
          incomplete = true;
        } else {
          found.add(origin);
        }
        continue;
      }
      // The worker client buffers API response bodies and cannot perform a
      // read-only gateway probe. Foreground setup uses the streaming client.
      if (client is NativeProxyHttpClient) {
        incomplete = true;
        continue;
      }
      final hops = <Uri>[];
      for (var hop = 0; hop < 2 && requests < 4; hop++) {
        if (!current()) return null;
        if (!seen.add(uri)) break;
        hops.add(uri);
        requests++;
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..persistentConnection = false
          ..headers.addAll(server.headersForUrl(uri.toString()) ?? {})
          ..headers['Range'] = 'bytes=0-0';
        final response = await GatewayHttpClient.withCompanionDiscovery(
            server, uri, () => client.send(request));
        // Never buffer even one response chunk. A frontend may ignore Range.
        unawaited(response.stream
            .listen(null, onError: (Object _, StackTrace __) {})
            .cancel()
            .catchError((Object _) {}));
        if (!current()) return null;
        if (const {401, 403, 407, 429}.contains(response.statusCode) ||
            response.headers.containsKey('retry-after')) {
          return null;
        }
        if (response.statusCode == 200 &&
            response.headers['content-type']
                    ?.toLowerCase()
                    .startsWith('text/html') ==
                true) {
          return null;
        }
        if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          if (response.statusCode == 200 || response.statusCode == 206) {
            resolved.add(uri);
          }
          break;
        }
        final location = response.headers['location'];
        if (location == null || location.length > 8192) break;
        final relative = Uri.tryParse(location);
        if (relative == null) break;
        final target = uri.resolveUri(relative);
        if (isMediaCompanionAccountRoute(target)) return null;
        if (target.userInfo.isNotEmpty) break;
        if (!sameMediaOrigin(target, frontend)) {
          final origin = _companionOrigin(target, requireMediaPath: true);
          if (origin != null) {
            resolved.add(uri);
            found.add(origin);
          }
          break;
        }
        uri = target;
      }
      if (resolved.contains(uri)) {
        resolved.addAll(hops);
      } else {
        incomplete = true;
      }
    }
    if (!current()) return null;
    final candidates = found.difference(trusted);
    return incomplete && candidates.isEmpty ? null : candidates;
  }

  Set<String>? result;
  try {
    result = await inspect().timeout(budget, onTimeout: () {
      expired = true;
      return null;
    });
  } catch (_) {
    // Network exceptions can contain signed stream URLs.
  }
  if (!sameContext()) return unavailable();
  final known = knownMediaCompanionCandidates(server);
  if (known.isNotEmpty) {
    return {
      ...known,
      ...?result
          ?.difference(known)
          .take(maxMediaCompanionOrigins - known.length),
    };
  }
  return result ?? unavailable();
}

String? _companionOrigin(Uri uri, {required bool requireMediaPath}) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.path.isEmpty ||
      uri.path == '/' ||
      isMediaCompanionAccountRoute(uri)) {
    return null;
  }
  // Identity providers also redirect to separate HTTPS origins. For a
  // redirect, require a recognizable actual media route before prompting.
  final path = uri.path.toLowerCase();
  if (requireMediaPath &&
      !isMediaCompanionPlaybackRoute(uri) &&
      !const ['.mp4', '.m4a', '.webm', '.aac', '.opus'].any(path.endsWith)) {
    return null;
  }
  return parseMediaCompanionOrigin(uri.origin);
}
