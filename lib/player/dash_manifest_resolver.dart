import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../network/gateway_http_client.dart';
import '../network/media_companion.dart';
import '../network/nerdvpn_access.dart';
import '../network/tor_browser.dart';
import '../network/youtube_privacy.dart';
import '../settings/models/db/server.dart';
import '../settings/models/errors/invidious_service_error.dart';
import 'models/backend_playback.dart';

enum _MediaRedirect { trustedCompanion, blockedOrigin }

class _ManifestConsentWithdrawn implements Exception {
  const _ManifestConsentWithdrawn();
}

/// Checks instance DASH manifests before the native player can retry a known
/// failure. Signed URLs are kept only for this playback attempt.
class DashManifestResolver {
  static const maxInlineManifestBytes = 1024 * 1024;
  // Recovery pages can exceed the inline-manifest limit. Bound all response
  // bodies while reading, including errors and signed download discovery.
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _warmFetchBudget = Duration(milliseconds: 1250);
  static const _onionFetchBudget = Duration(seconds: 45);
  final http.Client client;
  final Duration? _timeout;
  final void Function()? beforeRequest;
  final DateTime Function() _now;
  final _routes = <(Server, String, String?),
      ({DateTime expires, bool needsCheck, String? nativeManifestPath})>{};

  DashManifestResolver(this.client,
      {Duration? timeout, DateTime Function()? now, this.beforeRequest})
      : _timeout = timeout,
        _now = now ?? DateTime.now;

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

  Duration? _retryAfter(http.BaseResponse response) {
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

  InvidiousServiceError? _httpFailure(http.BaseResponse response) {
    if (response.statusCode < 400) return null;
    final retryAfter = _retryAfter(response);
    return InvidiousServiceError('DASH request failed',
        statusCode: response.statusCode,
        retryAfter: retryAfter,
        retryAfterIsInvalid:
            response.headers.containsKey('retry-after') && retryAfter == null);
  }

  bool _isRefusal(InvidiousServiceError failure) =>
      const [401, 403, 429].contains(failure.statusCode) ||
      failure.retryAfterIsInvalid ||
      (failure.retryAfter ?? Duration.zero) > Duration.zero;

  Future<void> _cancelRead(Future<void> Function() cancel) async {
    try {
      await cancel();
    } catch (_) {
      // Cleanup must not replace a refusal or timeout.
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

  Future<({http.Response response, Uri target})> _get(Uri uri, Server server,
      {Duration? budget,
      bool playbackManifest = false,
      bool Function()? isCurrent}) async {
    // Do not forward custom instance credentials through an untrusted redirect.
    var expired = false;
    // A cold Tor circuit can outlast the ordinary five-second probe. Allow the
    // native transport's 15-second connection and 30-second read budgets before
    // abandoning adaptive playback. Explicit and optional warm limits win.
    final timeout = _timeout ??
        (uri.host.toLowerCase().endsWith('.onion')
            ? _onionFetchBudget
            : const Duration(seconds: 5));
    final limit = budget != null && budget < timeout ? budget : timeout;
    InvidiousServiceError? refusal;
    StreamIterator<List<int>>? activeBody;

    Future<http.Response> read(http.StreamedResponse response) async {
      if (expired) {
        unawaited(_cancelRead(() => response.stream
            .listen(null, onError: (Object _, StackTrace __) {})
            .cancel()));
        throw TimeoutException('DASH request timed out.', limit);
      }
      final failure = _httpFailure(response);
      // Keep the refusal if only its headers arrive before the deadline.
      // A complete body can still carry a more specific gateway error code.
      final headerRefusal =
          failure != null && _isRefusal(failure) ? failure : null;
      refusal = headerRefusal;
      final body = StreamIterator(response.stream);
      activeBody = body;
      final bytes = BytesBuilder(copy: false);
      try {
        while (await body.moveNext()) {
          if (body.current.length > _maxResponseBytes - bytes.length) {
            throw const FormatException('DASH response exceeds 4 MiB.');
          }
          bytes.add(body.current);
        }
        return http.Response.bytes(bytes.takeBytes(), response.statusCode,
            request: response.request,
            headers: response.headers,
            isRedirect: response.isRedirect,
            persistentConnection: response.persistentConnection,
            reasonPhrase: response.reasonPhrase);
      } catch (_) {
        if (headerRefusal != null) throw headerRefusal;
        rethrow;
      } finally {
        activeBody = null;
        unawaited(_cancelRead(body.cancel));
      }
    }

    return (() async {
      var target = uri;
      for (var redirects = 0;; redirects++) {
        beforeRequest?.call();
        if (isCurrent?.call() == false) throw const _ManifestConsentWithdrawn();
        final request = http.Request('GET', target)..followRedirects = false;
        request.headers.addAll(server.headersForUrl(target.toString()) ?? {});
        final stream = playbackManifest
            ? await GatewayHttpClient.withManifestProbe(
                server, target, () => client.send(request))
            : await client.send(request);
        final response = await read(stream);
        if (isCurrent?.call() == false) throw const _ManifestConsentWithdrawn();
        final location = response.headers['location'];
        if (expired ||
            response.statusCode < 300 ||
            response.statusCode >= 400 ||
            location == null ||
            redirects >= 3) {
          return (response: response, target: target);
        }
        final next = target.resolve(location);
        if (!_sameOrigin(next, Uri.parse(server.url))) {
          return (response: response, target: target);
        }
        target = next;
      }
    })()
        .timeout(limit, onTimeout: () {
      expired = true;
      final body = activeBody;
      if (body != null) unawaited(_cancelRead(body.cancel));
      throw refusal ?? TimeoutException('DASH request timed out.', limit);
    });
  }

  /// Track discovery reads only the selected frontend. A companion handoff is
  /// left to Android; failure to list tracks does not interrupt the decoder.
  Future<String?> loadTrackManifest(String url, Server server,
      {bool Function()? isCurrent}) async {
    final target = Uri.tryParse(url);
    if (target == null || !_sameOrigin(target, Uri.parse(server.url))) {
      return null;
    }
    try {
      final result = await _get(target, server,
          playbackManifest: true, isCurrent: isCurrent);
      if (result.response.statusCode != 200) return null;
      return utf8.decode(result.response.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  /// Null means this source failed; the caller should use its normal fallback.
  /// [onMissingCheck] signals that this route requires a signed manifest.
  /// [onMediaOriginBlocked] lets native playback handle approved media
  /// redirects and signed watch-page sources. The signal carries no address.
  /// [onManifest] receives a bounded static UTF-8 response for this attempt.
  /// The returned URL is the body’s base, including any validated same-origin
  /// redirect. Neither the body nor its signature is cached.
  /// [requireManifest] fetches even already-signed URLs for download discovery.
  /// [isCurrent] guards every request for a shared profile route.
  Future<String?> resolve(String url, String videoId, Server server,
      {bool throwRetryable = false,
      bool requireManifest = false,
      void Function()? onMissingCheck,
      void Function()? onMediaOriginBlocked,
      void Function(String content)? onManifest,
      bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return null;
    bool? provideManifest(http.Response response, Uri requested) {
      if (onManifest == null) return null;
      final content = _inlineManifest(response, requested);
      if (content != null) onManifest(content);
      return content != null;
    }

    void checkRetryable(http.Response response) {
      final failure = _httpFailure(response);
      if (failure == null) return;
      if (NerdVpnAccess.supports(server)) {
        dynamic body;
        try {
          body = jsonDecode(response.body);
        } on FormatException {
          // An upstream error page still follows the existing fallback policy.
        }
        final code = body is Map ? body['error'] : null;
        if (code is String) {
          final gatewayFailure = InvidiousServiceError(code,
              statusCode: failure.statusCode,
              retryAfter: failure.retryAfter,
              retryAfterIsInvalid: failure.retryAfterIsInvalid,
              errorCode: code,
              isGatewayResponse: true);
          if (gatewayFailure.isGatewayAccessFailure) throw gatewayFailure;
        }
      }
      // Access and cooldown refusals apply to the playback attempt, including
      // progressive sources and other backends. Never discard them as a
      // missing manifest or bypass them with an inline manifest.
      if (_isRefusal(failure)) throw failure;
      if (throwRetryable && isBackendRetryable(failure)) {
        throw const BackendPlaybackFailure();
      }
    }

    final instance = Uri.parse(server.url);
    _MediaRedirect? classifyMediaRedirect(http.Response response, Uri target) {
      if (onMediaOriginBlocked == null ||
          !const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return null;
      }
      final location = response.headers['location'];
      if (location == null) return null;
      final destination = target.resolve(location);
      if (!const {'http', 'https'}.contains(destination.scheme) ||
          destination.host.isEmpty ||
          destination.userInfo.isNotEmpty ||
          isOfficialYoutubeUrl(destination) ||
          destination.origin == instance.origin) {
        return null;
      }
      // A redirect may ask the client to wait before making another request.
      if (response.headers.containsKey('retry-after')) {
        final delay = _retryAfter(response);
        if (delay == null || delay > Duration.zero) {
          throw InvidiousServiceError('DASH redirect requested a cooldown',
              statusCode: response.statusCode,
              retryAfter: delay,
              retryAfterIsInvalid: delay == null);
        }
      }
      if (allowsMediaCompanion(server, destination)) {
        return _MediaRedirect.trustedCompanion;
      }
      return _MediaRedirect.blockedOrigin;
    }

    final manifest = Uri.parse(url);
    if (!_sameOrigin(manifest, instance)) return null;
    if (!requireManifest &&
        (manifest.queryParameters['check']?.isNotEmpty ?? false)) {
      return url;
    }

    // Remember route behavior, never signed URLs or manifest bodies. Android
    // VOD can share one fresh body between native playback and track discovery.
    if (isCurrent == null) {
      _routes.removeWhere((_, entry) => !entry.expires.isAfter(_now()));
    }
    final route = _route(manifest, server);
    final cached = isCurrent == null ? _routes[route] : null;
    final warmUnsigned = cached?.needsCheck == false;
    var probingWarmUnsigned = warmUnsigned;
    if (!requireManifest &&
        probingWarmUnsigned &&
        (onManifest == null || cached?.nativeManifestPath == manifest.path)) {
      return url;
    }
    void remember(bool needsCheck, {String? nativeManifestPath}) {
      if (isCurrent != null) return;
      // A confirmed signature can replace an unsigned hint. A warm probe
      // cannot replace newer signed evidence or recreate an invalidated route.
      final current = _routes[route];
      if (warmUnsigned &&
          current != cached &&
          !(needsCheck && current?.needsCheck == false)) {
        return;
      }
      if (_routes.length >= 20) _routes.remove(_routes.keys.first);
      _routes[route] = (
        expires: _now().add(const Duration(minutes: 2)),
        needsCheck: needsCheck,
        nativeManifestPath: nativeManifestPath,
      );
    }

    try {
      if (cached?.needsCheck != true) {
        final (:response, :target) = await _get(manifest, server,
            budget: probingWarmUnsigned ? _warmFetchBudget : null,
            playbackManifest: onMediaOriginBlocked != null,
            isCurrent: isCurrent);
        checkRetryable(response);
        if (response.statusCode == 200) {
          final reused = provideManifest(response, target);
          remember(false,
              nativeManifestPath: reused == false ? manifest.path : null);
          return reused == true && target != manifest ? target.toString() : url;
        }
        // Keep onion playback on its selected origin even when the browser
        // manifest advertises a public companion. Try a same-origin source.
        if (response.statusCode >= 300 && response.statusCode < 400) {
          // The native media client owns companion access. Always give it the
          // original source URL and never fetch the companion in this client.
          final redirect = classifyMediaRedirect(response, target);
          if (redirect == _MediaRedirect.trustedCompanion) return url;
          if (redirect == _MediaRedirect.blockedOrigin) {
            onMediaOriginBlocked!();
            return null;
          }
          final location = response.headers['location'];
          if (TorBrowser.isOnionAddress(instance) &&
              (location == null ||
                  !_sameOrigin(target.resolve(location), instance))) {
            return null;
          }
          // Other instances retain their native redirect handling.
          if (probingWarmUnsigned) {
            remember(false, nativeManifestPath: manifest.path);
          }
          return url;
        }
        if (response.statusCode != 400 ||
            response.body.trim() != 'No check ID.') {
          return probingWarmUnsigned ? url : null;
        }
        probingWarmUnsigned = false;
        remember(true);
      }
      onMissingCheck?.call();

      final base = server.url.endsWith('/') ? server.url : '${server.url}/';
      final watch = Uri.parse(base).resolve('watch').replace(queryParameters: {
        'v': videoId,
        'quality': 'dash',
        'local': manifest.queryParameters['local'] ?? 'false',
      });
      final page = (await _get(watch, server, isCurrent: isCurrent)).response;
      checkRetryable(page);
      if (page.statusCode != 200) return null;
      final document = html.parse(page.body);
      var blockedWatchSource = false;
      Uri? frontend;
      String? companion;
      for (final source in document.querySelectorAll('video#player source')) {
        if (source.attributes['type']?.toLowerCase() !=
            'application/dash+xml') {
          continue;
        }
        final src = source.attributes['src']?.trim();
        if (src == null || src.isEmpty) continue;
        final candidate = Uri.tryParse(src);
        if (candidate == null) continue;
        final recovered = watch.resolveUri(candidate);
        if (!recovered.path.endsWith('/api/manifest/dash/id/$videoId') ||
            (recovered.queryParameters['check']?.isEmpty ?? true) ||
            (manifest.queryParameters['local'] == 'true' &&
                recovered.queryParameters['local'] != 'true')) {
          continue;
        }
        if (!_sameOrigin(recovered, instance)) {
          if (requireManifest ||
              onMediaOriginBlocked == null ||
              recovered.scheme != 'https' ||
              recovered.host.isEmpty ||
              recovered.userInfo.isNotEmpty ||
              parseMediaCompanionOrigin(recovered.origin) == null ||
              recovered.queryParametersAll['check']!.length != 1 ||
              (recovered.queryParametersAll['local']?.length ?? 0) > 1) {
            continue;
          }
          if (allowsMediaCompanion(server, recovered)) {
            // Only the native media transport may request the companion. Keep
            // the signed query's exact spelling, order and repeated fields.
            companion ??= src.startsWith('//') ? '${watch.scheme}:$src' : src;
          } else {
            blockedWatchSource = true;
          }
          continue;
        }
        frontend ??= recovered;
      }
      if (frontend != null) {
        // Keep the frontend route that already works on instances advertising
        // multiple sources. Probe only one signed address.
        final (response: retry, :target) = await _get(frontend, server,
            playbackManifest: onMediaOriginBlocked != null,
            isCurrent: isCurrent);
        checkRetryable(retry);
        if (retry.statusCode == 200) {
          final reused = provideManifest(retry, target);
          return (reused == true ? target : frontend).toString();
        }
        final redirect = classifyMediaRedirect(retry, target);
        if (redirect == _MediaRedirect.trustedCompanion) {
          return frontend.toString();
        }
        if (redirect == _MediaRedirect.blockedOrigin) {
          if (companion == null) onMediaOriginBlocked!();
          return companion;
        }
        if (retry.statusCode == 404 || retry.statusCode == 410) {
          return companion;
        }
        return null;
      }
      if (companion != null) return companion;
      if (blockedWatchSource) onMediaOriginBlocked!();
    } catch (error) {
      if (error is _ManifestConsentWithdrawn || isCurrent?.call() == false) {
        return null;
      }
      if (error is NerdVpnAccessRequired ||
          error is InvidiousServiceError ||
          error is HandshakeException ||
          (error is SocketException && error.osError == null)) {
        rethrow;
      }
      // A failed optional warm fetch still leaves the native request available
      // on the same route. Access and cooldown refusals above stay terminal.
      if (probingWarmUnsigned) {
        if (error is TimeoutException) {
          remember(false, nativeManifestPath: manifest.path);
        }
        return url;
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
