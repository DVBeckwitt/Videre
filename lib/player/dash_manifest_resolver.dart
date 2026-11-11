import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../network/nerdvpn_access.dart';
import '../settings/models/db/server.dart';
import '../settings/models/errors/invidious_service_error.dart';
import 'models/backend_playback.dart';

/// Checks instance DASH manifests before the native player can retry a known
/// failure. Signed URLs are kept only for this playback attempt.
class DashManifestResolver {
  static const maxInlineManifestBytes = 1024 * 1024;
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

  Duration? _retryAfter(http.Response response) {
    final value = response.headers['retry-after']?.trim();
    if (value == null) return null;
    final seconds =
        RegExp(r'^\d+$').hasMatch(value) ? int.tryParse(value) : null;
    if (seconds != null) {
      final delay = Duration(seconds: seconds);
      return delay.inSeconds == seconds ? delay : null;
    }
    try {
      final delay = HttpDate.parse(value).difference(_now());
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }

  String? _inlineManifest(http.Response response, Uri requested) {
    if (response.request?.url != requested ||
        response.bodyBytes.length > maxInlineManifestBytes) {
      return null;
    }
    final String content;
    try {
      // HTTP's default text encoding may be Latin-1. The native inline source
      // uses UTF-8, so preserve XML text without changing its declared encoding.
      content = utf8.decode(response.bodyBytes);
    } on FormatException {
      return null;
    }
    final encoding = RegExp(
      r'''^\s*<\?xml\b[^>]*\bencoding\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(content)?.group(1)?.toLowerCase();
    if (encoding != null && encoding != 'utf-8' && encoding != 'utf8') {
      return null;
    }
    // HTML parsing supplies its own html/body wrappers. Check the original
    // document's first element before using it to classify the MPD attributes.
    if (!RegExp(
            r'^\s*(?:<\?xml\b[^>]*\?>\s*)?(?:<!--[^>]*-->\s*)*<MPD(?=[\s/>])')
        .hasMatch(content)) {
      return null;
    }
    final document = html.parse(content);
    final body = document.body;
    if (body == null ||
        body.children.length != 1 ||
        document.head?.children.isNotEmpty == true) {
      return null;
    }
    final root = body.children.single;
    if (root.localName != 'mpd' || root.attributes['type'] != 'static') {
      return null;
    }
    // Do not freeze a live manifest into Media3's static sideloaded source.
    // Unrecognized documents retain the ordinary network/parser path.
    if (body.nodes.any(
        (node) => node.nodeType == 3 && node.text?.trim().isNotEmpty == true)) {
      return null;
    }
    return content;
  }

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
  /// [onMissingCheck] signals that this route requires a signed manifest.
  /// [onManifest] receives a bounded static UTF-8 response for this attempt.
  /// Its base URL is unchanged and neither the body nor its signature is cached.
  Future<String?> resolve(String url, String videoId, Server server,
      {bool throwRetryable = false,
      void Function()? onMissingCheck,
      void Function(String content)? onManifest}) async {
    void provideManifest(http.Response response, Uri requested) {
      if (onManifest == null) return;
      final content = _inlineManifest(response, requested);
      if (content != null) onManifest(content);
    }

    void checkRetryable(http.Response response) {
      if (NerdVpnAccess.supports(server) && response.statusCode >= 400) {
        dynamic body;
        try {
          body = jsonDecode(response.body);
        } on FormatException {
          // An upstream error page still follows the existing fallback policy.
        }
        final code = body is Map ? body['error'] : null;
        if (code is String) {
          final failure = InvidiousServiceError(code,
              statusCode: response.statusCode,
              errorCode: code,
              isGatewayResponse: true);
          if (failure.isGatewayAccessFailure) throw failure;
        }
      }
      if (response.statusCode < 400) return;
      final retryAfter = _retryAfter(response);
      final invalidRetryAfter =
          response.headers.containsKey('retry-after') && retryAfter == null;
      final failure = InvidiousServiceError('DASH request failed',
          statusCode: response.statusCode,
          retryAfter: retryAfter,
          retryAfterIsInvalid: invalidRetryAfter);
      // Access and cooldown refusals apply to the playback attempt, including
      // progressive sources and other backends. Never discard them as a
      // missing manifest or bypass them with an inline manifest.
      if (const [401, 403, 429].contains(response.statusCode) ||
          invalidRetryAfter ||
          (retryAfter ?? Duration.zero) > Duration.zero) {
        throw failure;
      }
      if (throwRetryable && isBackendRetryable(failure)) {
        throw const BackendPlaybackFailure();
      }
    }

    final instance = Uri.parse(server.url);
    final manifest = Uri.parse(url);
    if (!_sameOrigin(manifest, instance)) return null;
    if (manifest.queryParameters['check']?.isNotEmpty ?? false) {
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
        checkRetryable(response);
        if (response.statusCode == 200) {
          remember(false);
          provideManifest(response, manifest);
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
      onMissingCheck?.call();

      final base = server.url.endsWith('/') ? server.url : '${server.url}/';
      final watch = Uri.parse(base).resolve('watch').replace(queryParameters: {
        'v': videoId,
        'quality': 'dash',
        'local': manifest.queryParameters['local'] ?? 'false',
      });
      final page = await _get(watch, server);
      checkRetryable(page);
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
        checkRetryable(retry);
        if (retry.statusCode == 200) {
          provideManifest(retry, recovered);
          return recovered.toString();
        }
        return null;
      }
    } catch (error) {
      if (error is NerdVpnAccessRequired ||
          error is InvidiousServiceError ||
          error is HandshakeException ||
          (error is SocketException && error.osError == null)) {
        rethrow;
      }
      if (throwRetryable && isBackendRetryable(error)) {
        throw const BackendPlaybackFailure();
      }
      // Timeouts, malformed pages, and network errors use progressive fallback.
      // Do not log signed URLs, page contents, or custom authentication headers.
    }
    return null;
  }
}
