import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../settings/models/db/server.dart';

/// Checks instance DASH manifests before the native player can retry a known
/// failure. Signed URLs are kept only for this playback attempt.
class DashManifestResolver {
  final http.Client client;
  final Duration timeout;
  final DateTime Function() _now;
  final _routes =
      <(Server, String, String?), ({DateTime expires, bool needsCheck})>{};

  DashManifestResolver(this.client,
      {this.timeout = const Duration(seconds: 5), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  (Server, String, String?) _route(Uri manifest, Server server) => (
        server,
        manifest.path.replaceFirst(RegExp(r'/id/[^/]+$'), '/id/'),
        manifest.queryParameters['local'],
      );

  void invalidate(String url, Server server) =>
      _routes.remove(_route(Uri.parse(url), server));

  bool _sameOrigin(Uri uri, Uri server) =>
      uri.userInfo.isEmpty &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.scheme == server.scheme &&
      uri.host == server.host &&
      uri.port == server.port;

  Future<http.Response> _get(Uri uri, Server server) async {
    // Do not forward custom instance credentials through an untrusted redirect.
    return (() async {
      var target = uri;
      for (var redirects = 0;; redirects++) {
        final request = http.Request('GET', target)..followRedirects = false;
        request.headers.addAll(server.headersForUrl(target.toString()) ?? {});
        final response =
            await http.Response.fromStream(await client.send(request));
        final location = response.headers['location'];
        if (response.statusCode < 300 ||
            response.statusCode >= 400 ||
            location == null ||
            redirects >= 3) {
          return response;
        }
        final next = target.resolve(location);
        if (!_sameOrigin(next, Uri.parse(server.url))) return response;
        target = next;
      }
    })()
        .timeout(timeout);
  }

  /// Null means this source failed; the caller should use its normal fallback.
  Future<String?> resolve(String url, String videoId, Server server) async {
    final instance = Uri.parse(server.url);
    final manifest = Uri.parse(url);
    // Direct YouTube manifests are outside this Invidious-specific workaround.
    if (!_sameOrigin(manifest, instance) ||
        (manifest.queryParameters['check']?.isNotEmpty ?? false)) {
      return url;
    }

    // Remember route behavior, never signed URLs or video-specific failures.
    // Healthy playbacks avoid another probe; affected routes skip the known 400.
    _routes.removeWhere((_, entry) => !entry.expires.isAfter(_now()));
    final route = _route(manifest, server);
    final cached = _routes[route];
    if (cached != null && !cached.needsCheck) return url;
    void remember(bool needsCheck) {
      if (_routes.length >= 20) _routes.remove(_routes.keys.first);
      _routes[route] = (
        expires: _now().add(const Duration(minutes: 2)),
        needsCheck: needsCheck
      );
    }

    try {
      if (cached == null) {
        final response = await _get(manifest, server);
        if (response.statusCode == 200) {
          remember(false);
          return url;
        }
        // Leave cross-origin redirect handling to the native player.
        if (response.statusCode >= 300 && response.statusCode < 400) return url;
        if (response.statusCode != 400 ||
            response.body.trim() != 'No check ID.') {
          return null;
        }
        remember(true);
      }

      final base = server.url.endsWith('/') ? server.url : '${server.url}/';
      final watch = Uri.parse(base).resolve('watch').replace(queryParameters: {
        'v': videoId,
        'quality': 'dash',
        'local': manifest.queryParameters['local'] ?? 'false',
      });
      final page = await _get(watch, server);
      if (page.statusCode != 200) return null;
      final document = html.parse(page.body);
      for (final source in document.querySelectorAll('video#player source')) {
        if (source.attributes['type']?.toLowerCase() !=
            'application/dash+xml') {
          continue;
        }
        final src = source.attributes['src'];
        if (src == null || src.trim().isEmpty) continue;
        final recovered = watch.resolve(src);
        if (!_sameOrigin(recovered, instance) ||
            !recovered.path.endsWith('/api/manifest/dash/id/$videoId') ||
            (recovered.queryParameters['check']?.isEmpty ?? true) ||
            (manifest.queryParameters['local'] == 'true' &&
                recovered.queryParameters['local'] != 'true')) {
          continue;
        }
        // Use the URL exactly as supplied by the player, including its signature
        // and proxy parameters. Retry once; never loop on a rejected signature.
        final retry = await _get(recovered, server);
        return retry.statusCode == 200 ? recovered.toString() : null;
      }
    } catch (_) {
      // Timeouts, malformed pages, and network errors use progressive fallback.
      // Do not log signed URLs, page contents, or custom authentication headers.
    }
    return null;
  }
}
