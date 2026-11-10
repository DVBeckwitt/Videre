import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/http.dart';
import 'package:clipious/player/dash_manifest_resolver.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/extensions.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/search/models/search_date.dart';
import 'package:clipious/search/models/search_duration.dart';
import 'package:clipious/search/models/search_results.dart';
import 'package:clipious/search/models/search_sort_by.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/settings/models/errors/cannot_add_server_error.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/models/errors/missing_software_key.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/utils/video_post_processing.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/dearrow.dart';
import 'package:clipious/videos/models/dislike.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:sembast/sembast.dart';

import 'channels/models/channel.dart';
import 'channels/models/channel_playlists.dart';
import 'channels/models/channel_videos.dart';
import 'comments/models/video_comments.dart';
import 'notifications/models/db/subscription_notifications.dart';
import 'network/native_proxy_http_client.dart';
import 'network/network_proxy.dart';
import 'network/origin_scoped_http_client.dart';
import 'network/gateway_context.dart';
import 'network/gateway_session_bridge.dart';
import 'network/nerdvpn_access.dart';
import 'settings/services/gateway_auth.dart';
import 'search/models/search_suggestion.dart';
import 'settings/models/db/server.dart';
import 'subscription_management/models/subscription.dart';
import 'videos/models/sponsor_segment_types.dart';
import 'videos/services/watch_history.dart';
import 'utils/interfaces/db.dart';
import 'utils/sembast_sqflite_database.dart';

const urlGetVideo = '/api/v1/videos/:id';
const urlGetTranscript = '/api/v1/transcripts/:id';
const urlGetCaptions = '/api/v1/captions/:id';
const urlGetTrending = '/api/v1/trending';
const urlGetPopular = '/api/v1/popular';
const urlGetUserFeed = '/api/v1/auth/feed';
const urlSearchSuggestions = '/api/v1/search/suggestions';
const urlSearch = '/api/v1/search';
const urlStats = '/api/v1/stats';
const urlGetSubscriptions = '/api/v1/auth/subscriptions';
const urlAddDeleteSubscriptions = '/api/v1/auth/subscriptions/:ucid';
const urlGetComments = '/api/v1/comments/:id';
const urlGetChannel = '/api/v1/channels/:id';
const urlGetChannelVideos = '/api/v1/channels/:id/videos';
const urlGetChannelStreams = '/api/v1/channels/:id/streams';
const urlGetChannelShorts = '/api/v1/channels/:id/shorts';
const urlGetSponsorSegments =
    'https://sponsor.ajay.app/api/skipSegments?videoID=:id';
const urlGetDeArrow = 'https://sponsor.ajay.app/api/branding?videoID=:id';
const urlGetUserPlaylists = '/api/v1/auth/playlists';
const urlGetUserPlaylist = '/api/v1/auth/playlists/:id';
const urlPostUserPlaylists = '/api/v1/auth/playlists';
const urlGetChannelPlaylists = '/api/v1/channels/:id/playlists';
const urlPostUserPlaylistVideo = '/api/v1/auth/playlists/:id/videos';
const urlDeleteUserPlaylist = '/api/v1/auth/playlists/:id';
const urlDeleteUserPlaylistVideo = '/api/v1/auth/playlists/:id/videos/:index';
const urlGetPublicPlaylist = '/api/v1/playlists/:id';
const urlGetMix = '/api/v1/mixes/:id';
const urlGetDislikes = 'https://returnyoutubedislikeapi.com/votes?videoId=';
const urlGetClearHistory = '/api/v1/auth/history';
const urlAddDeleteHistory = '/api/v1/auth/history/:id';

/// The caller owns the visible lifetime of an interactive video load.
class VideoLoadObserver {
  final bool Function() isCurrent;
  final void Function() onRetry;

  const VideoLoadObserver({required this.isCurrent, required this.onRetry});
}

class _InteractiveVideoRequest {
  final observers = <VideoLoadObserver>{};
  late final Future<Video> result;
  bool retrying = false;

  bool get hasActiveObserver =>
      observers.any((observer) => observer.isCurrent());

  void announceRetry() {
    retrying = true;
    for (final observer in List.of(observers)) {
      if (observer.isCurrent()) observer.onRetry();
    }
  }
}

class Service {
  final log = Logger('Service');
  final Client httpClient;
  late final dashManifestResolver = DashManifestResolver(httpClient);
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  final _videoRequests = <String, Future<Response>>{};
  final _interactiveVideoRequests =
      <(String, Server, Object, int, bool), _InteractiveVideoRequest>{};
  final _browseCache = <String, ({DateTime expires, Response response})>{};
  int _sessionRevision = 0;
  Future<void> _localPlaylistWrite = Future.value();
  final Map<String, int> _authenticationAttempts = {};
  final Map<String, Future<Server>> _keyMigrations = {};
  String _accountKey(Server server) =>
      jsonEncode([server.profileId, server.accountId]);
  int _beginAuthentication(Server server) => _authenticationAttempts
      .update(_accountKey(server), (value) => value + 1, ifAbsent: () => 1);

  Future<Server?> _storeCredentials(Server original, int generation,
      {String? authToken,
      String? sidCookie,
      bool? gatewayEnabled,
      bool clearApiKeyHeader = false}) async {
    final owner = db.forProfile(original.profileId);
    bool unchanged(Server? saved) =>
        saved != null &&
        saved.url == original.url &&
        saved.authToken == original.authToken &&
        saved.sidCookie == original.sidCookie &&
        (_authenticationAttempts[_accountKey(original)] ?? 0) == generation;
    Server updated(Server saved) => saved.copyWith(
        authToken: authToken,
        sidCookie: sidCookie,
        gatewayEnabled: gatewayEnabled ?? saved.gatewayEnabled,
        customHeaders: clearApiKeyHeader
            ? (Map<String, String>.from(saved.customHeaders)
              ..removeWhere((name, _) => NerdVpnAccess.isKeyHeader(name)))
            : saved.customHeaders);
    if (owner is SembastSqfDb) {
      return owner.db.transaction((txn) async {
        final record = owner.serversStore.record(original.accountId);
        final data = await record.get(txn);
        final saved = data == null ? null : Server.fromJson(data);
        if (!unchanged(saved)) return null;
        final result = updated(saved!);
        await record.put(txn, result.toJson());
        return result;
      });
    }
    final saved = owner.getAccount(original.accountId);
    if (!unchanged(saved)) return null;
    final result = updated(saved!);
    await owner.upsertServer(result);
    return result;
  }

  void clearSessionCaches() {
    _sessionRevision++;
    _videoRequests.clear();
    _interactiveVideoRequests.clear();
    _browseCache.clear();
  }

  Service(
      {Client? httpClient,
      DateTime Function()? now,
      Future<void> Function(Duration)? wait})
      // Android's worker transport already scopes redirects natively, with a
      // single timeout for the entire chain rather than one timeout per hop.
      : httpClient = httpClient is NativeProxyHttpClient
            ? httpClient
            : OriginScopedHttpClient(httpClient ?? http.Client()),
        _now = now ?? DateTime.now,
        _wait = wait ?? Future<void>.delayed;

  Duration? _retryAfter(http.BaseResponse response) {
    final value = response.headers['retry-after']?.trim();
    if (value == null) return null;
    final seconds =
        RegExp(r'^\d+$').hasMatch(value) ? int.tryParse(value) : null;
    if (seconds != null) {
      final delay = Duration(seconds: seconds);
      return seconds >= 0 && delay.inSeconds == seconds ? delay : null;
    }
    try {
      final delay = HttpDate.parse(value).difference(_now());
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      // HttpDate also throws HttpException/RangeError for malformed input.
      return null;
    }
  }

  Future<Response> _sendGet(ServerRequest request) async {
    var response = await httpClient.get(request.uri, headers: request.headers);
    if (response.statusCode == 429) {
      final delay = _retryAfter(response);
      // A long server cooldown belongs in the UI, not a hidden retry loop.
      if (delay != null && delay <= const Duration(seconds: 2)) {
        if (delay > Duration.zero) await _wait(delay);
        response = await httpClient.get(request.uri, headers: request.headers);
      }
    }
    return response;
  }

  Future<Response> _get(ServerRequest request,
      {bool cache = false, bool coalesce = false}) async {
    final key = request._cacheKey;
    if (coalesce) {
      // Share only the HTTP work. Each caller decodes and applies its settings.
      return _videoRequests.putIfAbsent(
          key,
          () => _sendGet(request)
                  .timeout(const Duration(seconds: 15))
                  .whenComplete(() {
                _videoRequests.remove(key);
              }));
    }
    if (cache) {
      _browseCache.removeWhere((_, entry) => !entry.expires.isAfter(_now()));
      final cached = _browseCache[key];
      if (cached != null) return cached.response;
    }
    return _sendGet(request);
  }

  void _cacheBrowse(
      ServerRequest request, Response response, Iterable results) {
    if (results.isEmpty ||
        response.statusCode != 200 ||
        (response.headers['content-type'] ?? '')
            .toLowerCase()
            .contains('html') ||
        (response.headers['cache-control'] ?? '')
            .toLowerCase()
            .contains('no-store')) {
      return;
    }
    // Store only successfully decoded browsing data, never playback URLs.
    _browseCache.putIfAbsent(
        request._cacheKey,
        () => (
              expires: _now().add(const Duration(seconds: 15)),
              response: response
            ));
    if (_browseCache.length > 20) _browseCache.remove(_browseCache.keys.first);
  }

  String urlFormatForLog(Uri? uri) {
    return kDebugMode ? uri.toString() : '${uri?.replace(host: 'xxxxxxxxxx')}';
  }

  bool _looksLikeJson(String body, String contentType) {
    return contentType.contains('json') ||
        body.startsWith('{') ||
        body.startsWith('[');
  }

  dynamic _decodeJsonResponse(
    String body,
    String contentType,
    int statusCode,
  ) {
    if (body.isEmpty || !_looksLikeJson(body, contentType)) return null;

    try {
      return jsonDecode(body);
    } on FormatException {
      if (statusCode >= 200 && statusCode < 300) {
        throw InvidiousServiceError(
          'The server returned malformed JSON',
          statusCode: statusCode,
        );
      }
      return null;
    }
  }

  String _errorMessage(dynamic json, bool isHtml, int statusCode) {
    if (json is Map && json['error'] != null) {
      return json['error'].toString();
    }
    if (isHtml) {
      return 'The reverse proxy returned HTML instead of Invidious JSON';
    }
    return 'Request failed with HTTP $statusCode';
  }

  dynamic handleResponse(Response response) {
    final body = utf8
        .decode(response.bodyBytes, allowMalformed: response.statusCode == 429)
        .trim();
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final isSuccessful =
        response.statusCode >= 200 && response.statusCode < 300;
    final isHtml = contentType.contains('html') || body.startsWith('<');

    log.info(
        "Response from ${response.request?.method} ${urlFormatForLog(response.request?.url)}, status: ${response.statusCode}");

    final json = _decodeJsonResponse(
      body,
      contentType,
      response.statusCode,
    );
    final errorCode =
        json is Map && json['error'] is String ? json['error'] as String : null;
    final isGatewayResponse = response.request != null &&
        isNerdVpnUrl(response.request!.url.toString());
    final retryAfter = _retryAfter(response);
    final retryAfterIsInvalid =
        response.headers.containsKey('retry-after') && retryAfter == null;

    if (response.statusCode == 429) {
      final seconds =
          retryAfter == null ? null : (retryAfter.inMilliseconds / 1000).ceil();
      throw InvidiousServiceError(
        seconds != null && seconds > 0
            ? 'Too many requests. Try again in $seconds seconds.'
            : 'Too many requests. Try again later.',
        statusCode: 429,
        responseWasHtml: isHtml,
        retryAfter: retryAfter,
        retryAfterIsInvalid: retryAfterIsInvalid,
        errorCode: errorCode,
        isGatewayResponse: isGatewayResponse,
      );
    }

    if (!isSuccessful) {
      final message = _errorMessage(json, isHtml, response.statusCode);

      log.severe(message);
      throw InvidiousServiceError(
        message,
        statusCode: response.statusCode,
        responseWasHtml: isHtml,
        retryAfter: retryAfter,
        retryAfterIsInvalid: retryAfterIsInvalid,
        errorCode: errorCode,
        isGatewayResponse: isGatewayResponse,
      );
    }

    if (body.isEmpty) return null;
    if (json != null) return json;

    if (isHtml) {
      throw InvidiousServiceError(
        'The reverse proxy returned HTML instead of Invidious JSON',
        statusCode: response.statusCode,
        responseWasHtml: true,
      );
    }

    throw InvidiousServiceError(
      'Expected JSON but received '
      '${contentType.isEmpty ? 'an unknown content type' : contentType}',
      statusCode: response.statusCode,
    );
  }

  Future<ServerRequest> buildRequest(String baseUrl,
      {Map<String, String>? pathParams,
      Map<String, String?>? query,
      bool authenticated = false,
      String accept = 'application/json',
      bool forceJson = false,
      Server? serverOverride}) async {
    try {
      final server = await _migrateNerdVpnKey(
          serverOverride ?? (await db.getCurrentlySelectedServer()));
      String url = '${(server).url}$baseUrl';

      pathParams?.forEach((key, value) {
        url = url.replaceAll(key, value);
      });

      var uri = Uri.parse(url);
      final queryParameters = <String, dynamic>{
        ...uri.queryParametersAll,
        for (final entry in query?.entries ?? <MapEntry<String, String?>>[])
          if (entry.value != null) entry.key: entry.value,
        // Playback stays on Invidious even for profiles/backups that used to
        // disable media proxying. There is no direct YouTube transport mode.
        'local': 'true',
      };
      if (queryParameters.isNotEmpty) {
        uri = uri.replace(queryParameters: queryParameters);
      }
      log.info('calling ${urlFormatForLog(uri)}');

      var headers = Map<String, String>.from(server.customHeaders);
      if (!headers.keys.any((name) => name.toLowerCase() == 'accept')) {
        headers['Accept'] = accept;
      }

      if (authenticated) {
        for (final header in getAuthenticationHeaders(server).entries) {
          if (header.key.toLowerCase() == 'cookie') {
            headers = mergeRequestCookies(headers, header.value);
          } else {
            headers[header.key] = header.value;
          }
        }
      }

      if (forceJson) {
        headers['Content-Type'] = 'application/json';
      }

      return ServerRequest(
          uri: uri,
          headers: gatewayContextHeaders(
              profileId: server.profileId,
              accountId: server.accountId,
              serverUrl: server.url,
              targetUrl: uri.toString(),
              headers: headers),
          server: server);
    } catch (err) {
      log.severe('Couldn\'t build url', err);
      rethrow;
    }
  }

  /// Normalize stored credentials before a caller freezes its playback route.
  /// Migration keeps the original server snapshot and may not admit a newer
  /// account, profile, session, or proxy configuration while it is pending.
  Future<Server> preparePlaybackServer({Server? serverOverride}) async {
    final owner = db;
    final profileId = owner.profileId;
    final sessionRevision = _sessionRevision;
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        identical(db, owner) &&
        owner.profileId == profileId &&
        _sessionRevision == sessionRevision &&
        !NetworkProxy.instance.isChanging &&
        identical(NetworkProxy.instance.config, proxy);
    final selected = serverOverride ?? await owner.getCurrentlySelectedServer();
    if (!current()) throw StateError('The playback connection changed.');
    final server = await _migrateNerdVpnKey(selected);
    if (!current()) throw StateError('The playback connection changed.');
    if (serverOverride == null) {
      final selectedNow = await owner.getCurrentlySelectedServer();
      if (!current() || !BackendPlayback(server).matches(selectedNow)) {
        throw StateError('The playback connection changed.');
      }
    }
    return server;
  }

  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    final observer = serverOverride == null ? loadObserver : null;
    final originalDb = db;
    final profileId = originalDb.profileId;
    final sessionRevision = _sessionRevision;
    final proxy = NetworkProxy.instance.config;
    bool connectionCurrent() =>
        identical(db, originalDb) &&
        originalDb.profileId == profileId &&
        _sessionRevision == sessionRevision &&
        !NetworkProxy.instance.isChanging &&
        identical(NetworkProxy.instance.config, proxy);
    bool active() =>
        observer == null || (observer.isCurrent() && connectionCurrent());
    // Import legacy credentials before freezing the admitted header snapshot.
    // Keep the original context across that await; migration must not bless a
    // concurrent profile, session, or proxy change as a new playback request.
    final server = await preparePlaybackServer(serverOverride: serverOverride);
    if (!connectionCurrent()) {
      throw StateError('The playback connection changed.');
    }
    // Explicit callers (downloads and connection tests) own their server snapshot
    // and subsequent request headers. Only normal playback may change routes.
    final initialRequest =
        serverOverride == null ? BackendPlayback(server) : null;
    final connection = initialRequest ?? BackendPlayback(server);
    var playback = server.backendSelector == null ? null : initialRequest;
    Video video;
    while (true) {
      if (!active()) throw StateError('The video load was cancelled.');
      try {
        video = await _getVideoMetadata(videoId, playback?.server ?? server,
            backendRequest: playback ?? initialRequest,
            onBackendRequest: onBackendRequest,
            loadObserver: observer,
            allowSameRouteRetry: (playback?.retryIndex ?? 0) == 0);
        break;
      } catch (error) {
        if (!active() ||
            !isBackendRetryable(error) ||
            playback?.canRetry != true) {
          rethrow;
        }
        if (!playback!.matches(await db.getCurrentlySelectedServer())) rethrow;
        final next = playback.next();
        if (next == null) rethrow;
        playback = next;
      }
    }
    if (!active()) throw StateError('The video load was cancelled.');
    final processed = await _processVideo(video.copyWith(
        backendPlayback: playback,
        playbackConnection: playback ?? connection,
        playbackSourceId: Object()));
    if (initialRequest != null &&
        !initialRequest.matches(await db.getCurrentlySelectedServer())) {
      throw StateError(
          'The playback connection changed while loading this video.');
    }
    if (!active()) throw StateError('The video load was cancelled.');
    return processed;
  }

  /// A player-side choice uses a transient routing snapshot while retaining the
  /// saved server as its admission baseline. It never bypasses proxy/auth checks.
  Future<Video> getVideoForBackend(String videoId, BackendPlayback request,
      {void Function(BackendPlayback request)? onBackendRequest,
      bool Function()? isCurrent}) async {
    var playback = request;
    bool active() => isCurrent?.call() ?? true;
    while (true) {
      if (!active() ||
          !playback.matches(await db.getCurrentlySelectedServer())) {
        throw StateError('The playback connection changed.');
      }
      if (!active()) throw StateError('The video changed.');
      Video loaded;
      try {
        loaded = await _getVideoMetadata(videoId, playback.server,
            backendRequest: playback, onBackendRequest: onBackendRequest);
      } catch (error) {
        if (!active() || !isBackendRetryable(error) || !playback.canRetry) {
          rethrow;
        }
        if (!playback.matches(await db.getCurrentlySelectedServer())) rethrow;
        final next = playback.next();
        if (next == null) rethrow;
        playback = next;
        continue;
      }
      final processed = await _processVideo(loaded.copyWith(
          backendPlayback: playback,
          playbackConnection: playback,
          playbackSourceId: Object()));
      if (!active() ||
          !playback.matches(await db.getCurrentlySelectedServer())) {
        throw StateError('The playback connection changed.');
      }
      return processed;
    }
  }

  Future<Video> _getVideoMetadata(String videoId, Server server,
      {BackendPlayback? backendRequest,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver,
      bool allowSameRouteRetry = true}) async {
    final video = await _loadVideoMetadata(videoId, server,
        backendRequest: backendRequest,
        onBackendRequest: onBackendRequest,
        loadObserver: loadObserver,
        allowSameRouteRetry: allowSameRouteRetry);
    // A successful HTTP response can still belong to another cache key. Reject
    // it before source admission, post-processing, or any backend retry.
    if (video.videoId != videoId) {
      throw const FormatException('The server returned another video.');
    }
    return video;
  }

  Future<Video> _loadVideoMetadata(String videoId, Server server,
      {BackendPlayback? backendRequest,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver,
      bool allowSameRouteRetry = true}) async {
    final originalDb = db;
    final profileId = originalDb.profileId;
    final sessionRevision = _sessionRevision;
    final proxy = NetworkProxy.instance.config;
    final request = await buildRequest(urlGetVideo,
        pathParams: {':id': videoId}, serverOverride: server);
    if (backendRequest != null) {
      if (!backendRequest.matches(await db.getCurrentlySelectedServer())) {
        throw StateError(
            'The playback connection changed while loading this video.');
      }
      if (loadObserver?.isCurrent() == false) {
        throw StateError('The video load was cancelled.');
      }
      onBackendRequest?.call(backendRequest);
    }
    if (loadObserver != null && backendRequest != null) {
      bool connectionCurrent() =>
          identical(db, originalDb) &&
          originalDb.profileId == profileId &&
          _sessionRevision == sessionRevision &&
          !NetworkProxy.instance.isChanging &&
          identical(NetworkProxy.instance.config, proxy);
      Future<bool> unchanged() async =>
          connectionCurrent() &&
          backendRequest
              .matches(await originalDb.getCurrentlySelectedServer()) &&
          connectionCurrent();
      if (!connectionCurrent()) {
        throw StateError('The playback connection changed.');
      }
      return _getInteractiveVideoMetadata(request, backendRequest, loadObserver,
          unchanged: unchanged, allowRetry: allowSameRouteRetry);
    }
    if (!isNerdVpnUrl(request.uri.toString())) {
      final response = await _get(request, coalesce: true);
      return Video.fromJson(handleResponse(response));
    }
    final owner = originalDb.forProfile(server.profileId);
    // Unsaved connection tests are allowed, but deleting or changing a saved
    // account must not dispatch another request with its old credentials.
    final account = owner.getAccount(server.accountId);
    final selected = (await originalDb.getServers())
        .where((account) => account.inUse)
        .firstOrNull;
    Future<bool> unchanged() async {
      final currentSelected = (await originalDb.getServers())
          .where((account) => account.inUse)
          .firstOrNull;
      return identical(db, originalDb) &&
          originalDb.profileId == profileId &&
          _sessionRevision == sessionRevision &&
          !NetworkProxy.instance.isChanging &&
          identical(NetworkProxy.instance.config, proxy) &&
          currentSelected == selected &&
          owner.getAccount(server.accountId) == account;
    }

    const budget = Duration(seconds: 15);
    final started = _now();
    var expired = false;
    Duration remaining() => budget - _now().difference(started);

    Future<Video> load() async {
      final response = await _get(request, coalesce: true);
      try {
        return Video.fromJson(handleResponse(response));
      } on InvidiousServiceError catch (error) {
        // NerdVPN uses 500 for this transient companion startup response.
        // Do not turn arbitrary 500s, gateway failures or other instances into
        // retries. Keep the same account, backend cookie and metadata URL.
        if (response.request?.url.origin != request.uri.origin ||
            error.statusCode != 500 ||
            error.responseWasHtml ||
            error.retryAfterIsInvalid ||
            error.errorCode !=
                'This backend is still starting and not yet available. '
                    'Please wait for a short time or use another backend.') {
          rethrow;
        }
        final delay = error.retryAfter ?? const Duration(seconds: 1);
        if (expired ||
            delay > const Duration(seconds: 2) ||
            remaining() <= delay) {
          rethrow;
        }
        if (!await unchanged()) {
          throw StateError('The playback connection changed.');
        }
        if (delay > Duration.zero) await _wait(delay);
        if (!await unchanged()) {
          throw StateError('The playback connection changed.');
        }
        if (expired || remaining() <= Duration.zero) {
          throw TimeoutException('Video metadata request expired.');
        }
        // One additional request only, even if it returns another retryable
        // status. Do not restart the usual GET retry or its timeout budget.
        final retried = await httpClient
            .get(request.uri, headers: request.headers)
            .timeout(remaining());
        if (!await unchanged()) {
          throw StateError('The playback connection changed.');
        }
        return Video.fromJson(handleResponse(retried));
      }
    }

    return load().timeout(budget, onTimeout: () {
      expired = true;
      throw TimeoutException('Video metadata request expired.');
    });
  }

  Future<Video> _getInteractiveVideoMetadata(
      ServerRequest request, BackendPlayback route, VideoLoadObserver observer,
      {required Future<bool> Function() unchanged,
      required bool allowRetry}) async {
    final key = (
      request._cacheKey,
      route.preferredServer,
      NetworkProxy.instance.config,
      _sessionRevision,
      allowRetry
    );
    final existing = _interactiveVideoRequests[key];
    final pending = existing ?? _InteractiveVideoRequest();
    pending.observers.add(observer);
    if (existing == null) {
      _interactiveVideoRequests[key] = pending;
      pending.result = _loadInteractiveVideoMetadata(request, pending,
              unchanged: unchanged, allowRetry: allowRetry)
          .whenComplete(() {
        if (identical(_interactiveVideoRequests[key], pending)) {
          _interactiveVideoRequests.remove(key);
        }
      });
    }
    try {
      if (pending.retrying && observer.isCurrent()) observer.onRetry();
      final video = await pending.result;
      if (!observer.isCurrent()) {
        throw StateError('The video load was cancelled.');
      }
      return video;
    } finally {
      pending.observers.remove(observer);
    }
  }

  Future<Video> _loadInteractiveVideoMetadata(
      ServerRequest request, _InteractiveVideoRequest pending,
      {required Future<bool> Function() unchanged, required bool allowRetry}) {
    const budget = Duration(seconds: 15);
    final started = _now();
    var expired = false;
    Duration remaining() => budget - _now().difference(started);

    Future<void> checkCurrent() async {
      if (!pending.hasActiveObserver ||
          !await unchanged() ||
          !pending.hasActiveObserver) {
        throw StateError('The video or playback connection changed.');
      }
      if (expired || remaining() <= Duration.zero) {
        throw TimeoutException('Video metadata request expired.');
      }
    }

    Future<Video> load() async {
      await checkCurrent();
      Response? response;
      try {
        response = await httpClient.get(request.uri, headers: request.headers);
        await checkCurrent();
        return Video.fromJson(handleResponse(response));
      } catch (error) {
        final delay =
            allowRetry ? _videoRetryDelay(error, response, request) : null;
        if (expired || delay == null || remaining() <= delay) rethrow;
        await checkCurrent();
        pending.announceRetry();
        if (delay > Duration.zero) await _wait(delay);
        await checkCurrent();
        // Keep one budget for transient failures and rate limits. The follow-up
        // uses the exact original request, with no second retry wrapper.
        final retried =
            await httpClient.get(request.uri, headers: request.headers);
        await checkCurrent();
        return Video.fromJson(handleResponse(retried));
      }
    }

    return load().timeout(budget, onTimeout: () {
      expired = true;
      throw TimeoutException('Video metadata request expired.');
    });
  }

  Duration? _videoRetryDelay(
      Object error, Response? response, ServerRequest request) {
    const defaultDelay = Duration(seconds: 1);
    if (error is TimeoutException ||
        (error is SocketException && error.osError != null)) {
      return defaultDelay;
    }
    if (error is! InvidiousServiceError ||
        error.isGatewayAccessFailure ||
        response == null ||
        (response.request?.url.origin ?? request.uri.origin) !=
            request.uri.origin ||
        !const {408, 429, 500, 502, 503, 504}.contains(error.statusCode) ||
        (error.statusCode == 500 && error.responseWasHtml)) {
      return null;
    }
    final delay = error.retryAfter;
    if (delay != null) {
      return delay <= const Duration(seconds: 2) ? delay : null;
    }
    return error.statusCode == 429 ||
            response.headers.containsKey('retry-after')
        ? null
        : defaultDelay;
  }

  /// Recovery changes only the server snapshot on this video, never the saved
  /// preference. Instances may still choose a different extraction backend.
  Future<Video?> retryVideoBackend(Video video,
      {required bool Function() isCurrent,
      void Function(BackendPlayback request)? onRetry}) async {
    var playback = video.backendPlayback;
    if (playback == null || !isCurrent() || !playback.acquireRecovery()) {
      return null;
    }
    final original = playback;
    try {
      while (isCurrent() &&
          playback!.matches(await db.getCurrentlySelectedServer())) {
        if (!isCurrent()) return null;
        final next = playback.next();
        if (next == null) return null;
        playback = next;
        Video loaded;
        try {
          loaded = await _getVideoMetadata(video.videoId, next.server,
              backendRequest: next, onBackendRequest: onRetry);
        } catch (error) {
          if (!isBackendRetryable(error)) rethrow;
          continue;
        }
        if (!isCurrent() ||
            !next.matches(await db.getCurrentlySelectedServer())) {
          return null;
        }
        final processed = await _processVideo(loaded.copyWith(
            backendPlayback: next,
            playbackConnection: next,
            playbackSourceId: Object()));
        if (!isCurrent() ||
            !next.matches(await db.getCurrentlySelectedServer())) {
          return null;
        }
        return processed.preservingMusicMetadataFrom(video);
      }
      return null;
    } finally {
      original.releaseRecovery();
    }
  }

  /// Refresh one admitted source without stacking metadata or backend retries.
  Future<Video> refreshPlaybackVideo(Video video,
      {required bool Function() isCurrent}) async {
    final connection = video.playbackConnection ?? video.backendPlayback;
    if (connection == null) {
      throw StateError('The original playback connection is unavailable.');
    }
    final originalDb = db;
    final sessionRevision = _sessionRevision;
    bool active() =>
        isCurrent() &&
        identical(db, originalDb) &&
        _sessionRevision == sessionRevision &&
        !NetworkProxy.instance.isChanging;
    Future<void> check() async {
      if (!active() ||
          !connection.matches(await originalDb.getCurrentlySelectedServer()) ||
          !active()) {
        throw StateError('The video or playback connection changed.');
      }
    }

    await check();
    final loaded = await _getVideoMetadata(video.videoId, connection.server,
        backendRequest: connection,
        loadObserver: VideoLoadObserver(isCurrent: active, onRetry: () {}),
        allowSameRouteRetry: false);
    await check();
    if (loaded.videoId != video.videoId) {
      throw const FormatException('The server returned another video.');
    }
    return video.copyWith(
        formatStreams: loaded.formatStreams,
        adaptiveFormats: loaded.adaptiveFormats,
        dashUrl: loaded.dashUrl,
        hlsUrl: loaded.hlsUrl,
        captions: loaded.captions,
        storyboards: loaded.storyboards,
        lengthSeconds: loaded.lengthSeconds ?? video.lengthSeconds,
        playbackConnection: connection,
        playbackSourceId: Object());
  }

  Future<Video> _processVideo(Video video) async {
    video = (await DeArrow.processVideos([video]))[0];
    video = video.copyWith(
        recommendedVideos:
            (await postProcessVideos(video.recommendedVideos)).cast());
    return video;
  }

  Future<VideoTranscript> getTranscript(
    String videoId,
    Caption caption, {
    Server? serverOverride,
  }) =>
      _getTranscript(videoId, caption, serverOverride: serverOverride);

  ///Loads the selected track through the same account and extraction backend
  ///as the playing video. The structured endpoint avoids instances whose
  ///timedtext-backed captions endpoint returns an empty successful response.
  Future<String> getPlaybackCaptions(
    String videoId,
    Caption caption, {
    required Server server,
  }) async {
    try {
      return (await _getTranscript(videoId, caption,
              serverOverride: server, forPlayback: true))
          .toWebVtt();
    } catch (error) {
      if (_captionAccessFailure(error)) rethrow;
      return _getWatchPlaybackCaptions(videoId, caption, server);
    }
  }

  bool _captionAccessFailure(Object error) =>
      error is NerdVpnAccessRequired ||
      error is GatewayAuthenticationRequired ||
      error is HandshakeException ||
      (error is SocketException && error.osError == null) ||
      (error is InvidiousServiceError &&
          (error.isGatewayAccessFailure ||
              error.retryAfterIsInvalid ||
              (error.retryAfter ?? Duration.zero) > Duration.zero ||
              const {401, 403, 429}.contains(error.statusCode)));

  Future<void> _cancelCaptionRead(Future<void> Function() cancel) async {
    try {
      await cancel();
    } catch (_) {
      // Cleanup cannot replace an HTTP refusal or timeout.
    }
  }

  Future<Response> _captionResponse(ServerRequest request) {
    const timeout = Duration(seconds: 15);
    const maxBodyBytes = 4 * 1024 * 1024;
    var expired = false;
    StreamIterator<List<int>>? activeBody;

    Future<Response> read() async {
      final get = http.Request('GET', request.uri)..followRedirects = false;
      get.headers.addAll(request.headers);
      final response = await httpClient.send(get);
      final retryAfter = _retryAfter(response);
      final retryAfterIsInvalid =
          response.headers.containsKey('retry-after') && retryAfter == null;
      final refused = const {401, 403, 429}.contains(response.statusCode) ||
          (response.statusCode >= 400 &&
              (retryAfterIsInvalid ||
                  (retryAfter ?? Duration.zero) > Duration.zero));
      if (expired || refused) {
        // A refusal or a response whose headers arrived after the deadline
        // never needs its body. Do not wait for stream cleanup to finish.
        unawaited(_cancelCaptionRead(() => response.stream
            .listen(null, onError: (Object _, StackTrace __) {})
            .cancel()));
        if (expired) throw TimeoutException('Caption request expired', timeout);
        throw InvidiousServiceError('Caption request refused',
            statusCode: response.statusCode,
            retryAfter: retryAfter,
            retryAfterIsInvalid: retryAfterIsInvalid);
      }
      final body = StreamIterator(response.stream);
      activeBody = body;
      final bytes = BytesBuilder(copy: false);
      try {
        while (await body.moveNext()) {
          final chunk = body.current;
          if (chunk.length > maxBodyBytes - bytes.length) {
            throw InvidiousServiceError('Caption response is too large');
          }
          bytes.add(chunk);
        }
        return Response.bytes(bytes.takeBytes(), response.statusCode,
            request: response.request, headers: response.headers);
      } finally {
        activeBody = null;
        unawaited(_cancelCaptionRead(body.cancel));
      }
    }

    return read().timeout(timeout, onTimeout: () {
      expired = true;
      final body = activeBody;
      if (body != null) unawaited(_cancelCaptionRead(body.cancel));
      throw TimeoutException('Caption request expired', timeout);
    });
  }

  Future<String> _getWatchPlaybackCaptions(
      String videoId, Caption caption, Server server) async {
    try {
      final watch = await buildRequest('/watch',
          query: {'v': videoId}, accept: 'text/html', serverOverride: server);
      final page = await _captionResponse(watch);
      if (page.statusCode != 200) {
        throw InvidiousServiceError('The instance caption page is unavailable',
            statusCode: page.statusCode, retryAfter: _retryAfter(page));
      }
      final origin = Uri.parse(server.url);
      final prefix = origin.path.replaceFirst(RegExp(r'/$'), '');
      final paths = {
        '$prefix/api/v1/captions/$videoId',
        '$prefix/companion/api/v1/captions/$videoId',
      };
      final candidates = <Uri>{};
      final document = html.parse(utf8.decode(page.bodyBytes));
      for (final track in document.querySelectorAll('video#player track')) {
        if (!const {'captions', 'subtitles'}
                .contains(track.attributes['kind']) ||
            track.attributes['label'] != caption.label ||
            track.attributes['srclang'] != caption.languageCode) {
          continue;
        }
        final src = track.attributes['src'];
        if (src == null || src.trim().isEmpty) continue;
        final target = Uri.tryParse(src);
        if (target == null) continue;
        final resolved = watch.uri.resolveUri(target);
        if (!const {'http', 'https'}.contains(resolved.scheme) ||
            resolved.userInfo.isNotEmpty ||
            resolved.origin != origin.origin ||
            !paths.contains(resolved.path)) {
          continue;
        }
        candidates.add(resolved.removeFragment());
      }
      if (candidates.length != 1) {
        throw const FormatException('No unambiguous instance caption track');
      }
      final headers = Map<String, String>.from(watch.headers)
        ..removeWhere((name, _) => name.toLowerCase() == 'accept')
        ..['Accept'] = 'text/vtt';
      // This is the one track advertised by this video's player page. Keep its
      // signed query intact, never log/cache it, and never follow redirects.
      final response = await _captionResponse(ServerRequest(
          uri: candidates.single, headers: headers, server: watch.server));
      return _webVttTranscript(response, caption, preserveRepeatedLines: true)
          .toWebVtt();
    } catch (error) {
      if (_captionAccessFailure(error) || error is InvidiousServiceError) {
        rethrow;
      }
      throw InvidiousServiceError(
          'Could not load instance captions (${error.runtimeType})');
    }
  }

  Future<VideoTranscript> _getTranscript(
    String videoId,
    Caption caption, {
    Server? serverOverride,
    bool forPlayback = false,
  }) async {
    // Keep the fallback on the original account if the selection changes while
    // a request is pending.
    final server = serverOverride ?? await db.getCurrentlySelectedServer();
    final query = {'label': caption.label};

    VideoTranscript validate(VideoTranscript transcript) {
      if (transcript.lines.isEmpty) {
        throw const FormatException('Transcript has no usable lines');
      }
      if (forPlayback) transcript.toWebVtt();
      return transcript;
    }

    try {
      final request = await buildRequest(
        urlGetTranscript,
        pathParams: {':id': videoId},
        query: query,
        serverOverride: server,
      );
      final response = forPlayback
          ? await _captionResponse(request)
          : await _get(request).timeout(const Duration(seconds: 15));
      return validate(VideoTranscript.fromJson(handleResponse(response),
          preserveRepeatedLines: forPlayback));
    } catch (error) {
      if (forPlayback && _captionAccessFailure(error)) rethrow;
      log.warning(
        'Structured transcript unavailable; trying caption fallback '
        '(${error.runtimeType})',
      );
    }

    try {
      final canonicalRequest = await buildRequest(
        urlGetCaptions,
        pathParams: {':id': videoId},
        query: query,
        accept: 'text/vtt',
        serverOverride: server,
      );
      final request = forPlayback
          ? _playbackCaptionRequest(canonicalRequest, caption)
          : canonicalRequest;
      final response = forPlayback
          ? await _captionResponse(request)
          : await _get(request).timeout(const Duration(seconds: 15));
      return validate(_webVttTranscript(response, caption,
          preserveRepeatedLines: forPlayback));
    } on InvidiousServiceError {
      rethrow;
    } catch (error) {
      if (forPlayback && _captionAccessFailure(error)) rethrow;
      throw InvidiousServiceError(
        'Could not load transcript (${error.runtimeType})',
      );
    }
  }

  VideoTranscript _webVttTranscript(Response response, Caption caption,
      {required bool preserveRepeatedLines}) {
    final body = utf8.decode(response.bodyBytes);
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final isHtml =
        contentType.contains('html') || body.trimLeft().startsWith('<');
    if (response.statusCode < 200 || response.statusCode >= 300 || isHtml) {
      throw InvidiousServiceError(
        isHtml
            ? 'The reverse proxy returned HTML instead of WebVTT'
            : 'Request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        responseWasHtml: isHtml,
        retryAfter: _retryAfter(response),
      );
    }
    return VideoTranscript.fromWebVtt(body,
        label: caption.label,
        languageCode: caption.languageCode,
        preserveRepeatedLines: preserveRepeatedLines);
  }

  ServerRequest _playbackCaptionRequest(
      ServerRequest canonical, Caption caption) {
    try {
      final origin = Uri.parse(canonical.server!.url);
      final base =
          Uri.parse(origin.toString().endsWith('/') ? '$origin' : '$origin/');
      final advertised = base.resolve(caption.url);
      if (caption.url.trim().isEmpty ||
          advertised.userInfo.isNotEmpty ||
          !const {'http', 'https'}.contains(advertised.scheme) ||
          advertised.origin != origin.origin) {
        return canonical;
      }
      // Some instances supply a companion path or signed query. Preserve it
      // only on this video's instance; captions never fall back to Google or
      // another origin with account credentials.
      return ServerRequest(
        uri: advertised.removeFragment(),
        headers: canonical.headers,
        server: canonical.server,
      );
    } on FormatException {
      return canonical;
    }
  }

  Future<String> loginWithCookies(
      String serverUrl, String username, String password,
      {Map<String, String>? headers}) async {
    try {
      String url = '$serverUrl/login?type=invidious';
      var map = {'email': username, 'password': password};

      final response =
          await httpClient.post(Uri.parse(url), body: map, headers: headers);
      if (response.statusCode == 302 &&
          response.headers.containsKey('set-cookie')) {
        // we have a cookie to parse
        return response.headers['set-cookie']!
            .split(';')
            .firstWhere((element) => element.startsWith('SID='));
      } else {
        throw InvidiousServiceError(
            'Unexpected login response (HTTP ${response.statusCode}) or missing session cookie');
      }
    } catch (err, stacktrace) {
      if (err is InvidiousServiceError) {
        log.severe('Failed to log in with cookies: \n ${err.message}', err,
            stacktrace);
      }
      throw InvidiousServiceError('Wrong username or password');
    }
  }

  Future<String?> _browserToken(Server original) async {
    final access = NerdVpnAccess.supports(original)
        ? await NerdVpnAccess.instance.status(original)
        : null;
    if (access?.retryAt?.isAfter(_now().toUtc()) == true) {
      throw const NerdVpnAccessRequired('unavailable');
    }
    final nonce = const Uuid().v4();
    final serverUrl = NerdVpnAccess.supports(original)
        ? Uri.parse(original.url).origin
        : original.url;
    final pkce = NerdVpnAccess.supports(original) ? NerdVpnPkce.create() : null;
    final callback = Uri(
        scheme: 'videre-auth',
        host: 'callback',
        queryParameters: {'state': nonce});
    final url =
        Uri.parse('$serverUrl/authorize_token').replace(queryParameters: {
      'scopes': ':feed,:subscriptions*,:playlists*,:history*'
          '${pkce == null ? '' : ',:api_key'}',
      'callback_url': callback.toString(),
      if (pkce != null) ...{
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
      },
    }).toString();
    String result;
    try {
      result = await FlutterWebAuth2.authenticate(
          url: url, callbackUrlScheme: 'videre-auth');
    } on PlatformException catch (error) {
      if (error.code == 'CANCELED') return null;
      rethrow;
    }

    final returned = Uri.parse(result);
    if (returned.scheme != callback.scheme ||
        returned.host != callback.host ||
        returned.path != callback.path ||
        returned.userInfo.isNotEmpty ||
        returned.hasPort ||
        returned.hasFragment ||
        returned.queryParametersAll['state']?.length != 1 ||
        returned.queryParameters['state'] != nonce) {
      throw InvidiousServiceError('Sign-in returned an unexpected callback');
    }
    if (pkce == null) return returned.queryParameters['token'];
    final code = returned.queryParameters['code'];
    if (code == null ||
        code.isEmpty ||
        code.length > 65536 ||
        returned.queryParametersAll['code']?.length != 1) {
      throw InvidiousServiceError(
          'Sign-in did not return an authorization code');
    }
    final request = http.Request('POST', Uri.parse('$serverUrl/api/v1/token'))
      ..followRedirects = false
      ..headers.addAll({
        ...?original.headersForUrl('$serverUrl/api/v1/token'),
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({
        'code': code,
        'code_verifier': pkce.verifier,
        'callback_url': callback.toString(),
      });
    final http.Response exchange;
    try {
      exchange = await httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 30));
    } catch (error) {
      if (error is http.ClientException ||
          error is TimeoutException ||
          error is IOException) {
        // The server may have consumed the one-use code before the connection
        // failed. A fresh browser sign-in is required; never replay this POST.
        throw const GatewaySignInFailed(
            'NerdVPN could not complete sign-in because the connection failed or timed out. Check your connection, then sign in again.');
      }
      rethrow;
    }
    // Never log the authorization code, verifier, callback or token body.
    if (exchange.statusCode != 200) {
      if (const {429, 503}.contains(exchange.statusCode)) {
        final context = GatewayRequestContext.forAccount(
            original.profileId, original.accountId, original.url)!;
        await NerdVpnAccess.instance.recover(context.encoded,
            error: exchange.statusCode == 429 ? 'rate_limited' : 'unavailable',
            statusCode: exchange.statusCode,
            retryAfter: exchange.headers['retry-after'],
            failedIntent: access?.apiKeyIntent,
            revision: access?.revision,
            retry: false);
      }
      throw InvidiousServiceError(
          'NerdVPN sign-in could not be completed. Please sign in again.',
          statusCode: exchange.statusCode,
          retryAfter: _retryAfter(exchange));
    }
    dynamic value;
    try {
      value = jsonDecode(utf8.decode(exchange.bodyBytes));
    } on FormatException {
      throw InvidiousServiceError(
          'NerdVPN returned an invalid sign-in response');
    }
    final token = value is Map ? value['token'] : null;
    if (token is! String || token.isEmpty || token.length > 65536) {
      throw InvidiousServiceError('NerdVPN did not return an account token');
    }
    return token;
  }

  /// Used before a newly added account has a database record. Pending access is
  /// saved in the native account store, and the caller saves the returned token.
  Future<Server?> authenticateNerdVpn(Server original) async {
    if (!NerdVpnAccess.supports(original)) {
      throw ArgumentError('This server does not support NerdVPN sign-in');
    }
    if (isNerdVpnOnionUrl(original.url)) {
      // An external browser does not inherit Videre's SOCKS routing policy.
      return authenticateProtected(original);
    }
    final intent = await NerdVpnAccess.instance.beginAuth(original);
    final token = await _browserToken(original);
    if (token == null) return null;
    final authenticated = original.copyWith(authToken: token, sidCookie: null);
    await NerdVpnAccess.instance
        .authorize(authenticated, token, intent: intent);
    return authenticated;
  }

  Future<String?> logIn(String accountId, {String? profileId}) async {
    final owner = db.forProfile(profileId ?? db.profileId);
    final original = owner.getAccount(accountId);
    if (original == null) {
      throw InvidiousServiceError('Account no longer exists');
    }
    if (NerdVpnAccess.supports(original) && isNerdVpnOnionUrl(original.url)) {
      return (await logInProtected(original))?.authToken;
    }
    final generation = _beginAuthentication(original);
    final intent = NerdVpnAccess.supports(original)
        ? await NerdVpnAccess.instance.beginAuth(original)
        : null;
    final token = await _browserToken(original);

    if (token == null) return null;

    Server? server = owner.getAccount(original.accountId);

    if (server != null) {
      if (_authenticationAttempts[_accountKey(original)] != generation ||
          server.authToken != original.authToken ||
          server.sidCookie != original.sidCookie) {
        throw InvidiousServiceError('This sign-in was superseded');
      }
      if (token.isEmpty) {
        throw InvidiousServiceError('Sign-in did not return an account token');
      }
      if (intent != null) {
        await NerdVpnAccess.instance.authorize(server, token, intent: intent);
      }
      // queryParameters has already decoded the callback value.
      server = await _storeCredentials(original, generation, authToken: token);
      if (server == null) {
        throw InvidiousServiceError('This sign-in was superseded');
      }
      if (server.inUse) {
        await fileDb.refreshAccount(server);
      }
      await syncAccountHistory(server, database: owner, force: true);

      return server.authToken;
    } else {
      throw InvidiousServiceError('logging in to deleted server');
    }
  }

  Future<Server?> authenticateProtected(Server server) async {
    final intent = NerdVpnAccess.supports(server)
        ? await NerdVpnAccess.instance.beginAuth(server)
        : null;
    final token = await GatewayAuth.signIn(server);
    if (token == null) return null;
    if (token.isEmpty) {
      throw InvidiousServiceError(
          'Protected sign-in did not return an account token');
    }
    final authenticated = server.copyWith(
        authToken: token, sidCookie: null, gatewayEnabled: true);
    if (intent != null) {
      await NerdVpnAccess.instance
          .authorize(authenticated, token, intent: intent);
    }
    return authenticated;
  }

  Future<Server?> logOutProtected(Server server) async {
    final generation = _beginAuthentication(server);
    await NerdVpnAccess.instance.clear(server);
    await GatewayAuth.signOut(server);
    final saved = await _storeCredentials(server, generation,
        gatewayEnabled: false,
        clearApiKeyHeader: NerdVpnAccess.supports(server));
    if (saved != null && saved.inUse) {
      await fileDb.refreshAccount(saved);
    }
    return saved;
  }

  Future<Server?> logInAccountWithCookie(
      Server original, String username, String password) async {
    if (NerdVpnAccess.supports(original)) {
      throw InvidiousServiceError(
          'Use browser sign-in for this NerdVPN account');
    }
    final generation = _beginAuthentication(original);
    final cookie = await loginWithCookies(original.url, username, password,
        headers: original.headersForUrl(original.url));
    final saved =
        await _storeCredentials(original, generation, sidCookie: cookie);
    if (saved == null) {
      throw InvidiousServiceError('This sign-in was superseded');
    }
    if (saved.inUse) await fileDb.refreshAccount(saved);
    await syncAccountHistory(saved, force: true);
    return saved;
  }

  Future<Server?> logInProtected(Server original) async {
    final owner = db.forProfile(original.profileId);
    final generation = _beginAuthentication(original);
    final authenticated = await authenticateProtected(original);
    if (authenticated == null) return null;
    final latest = owner.getAccount(original.accountId);
    if (latest == null) {
      await GatewayAuth.signOut(original);
      throw InvidiousServiceError('Account was removed during sign-in');
    }
    if (_authenticationAttempts[_accountKey(original)] != generation ||
        latest.authToken != original.authToken ||
        latest.sidCookie != original.sidCookie) {
      throw InvidiousServiceError('This sign-in was superseded');
    }
    final saved = await _storeCredentials(original, generation,
        authToken: authenticated.authToken, gatewayEnabled: true);
    if (saved == null) {
      throw InvidiousServiceError('This sign-in was superseded');
    }
    if (saved.inUse) await fileDb.refreshAccount(saved);
    await syncAccountHistory(saved, database: owner, force: true);
    return saved;
  }

  Map<String, String> getAuthenticationHeaders(Server s) {
    if (s.authToken != null && s.authToken!.isNotEmpty) {
      log.fine('logged in with token');
      return {'Authorization': 'Bearer ${s.authToken}'};
    } else if (s.sidCookie != null && s.sidCookie!.isNotEmpty) {
      log.fine('logged in with cookie');
      return {'Cookie': s.sidCookie!};
    } else {
      throw InvidiousServiceError(
          'No authentication method provided to access authenticated endpoint');
    }
  }

  Future<List<Video>> getTrending({String? type}) async {
    String countryCode = db.getSettings(browsingCountry)?.value ?? 'US';
    // parse.queryParameters['region'] = countryCode;
    Map<String, String>? query = {'region': countryCode};

    if (type != null) {
      query.putIfAbsent('type', () => type);
    }

    var req = await buildRequest(urlGetTrending, query: query);
    final response = await _get(req, cache: true);

    Iterable i = handleResponse(response);
    var list = List<Video>.from(i.map((e) => Video.fromJson(e)));
    _cacheBrowse(req, response, list);
    list = (await postProcessVideos(list));
    return list;
  }

  Future<List<Video>> getPopular() async {
    var req = await buildRequest(urlGetPopular);
    final response = await _get(req, cache: true);
    Iterable i = handleResponse(response);
    var list = List<Video>.from(i.map((e) => Video.fromJson(e)));
    _cacheBrowse(req, response, list);
    list = (await postProcessVideos(list)).cast();
    return list;
  }

  Future<SearchResults> search(String query,
      {SearchType? type,
      int? page,
      SearchSortBy? sortBy,
      SearchDate date = SearchDate.any,
      SearchDuration duration = SearchDuration.any}) async {
    String countryCode = db.getSettings(browsingCountry)?.value ?? 'US';
    final req = await buildRequest(urlSearch, query: {
      'q': query,
      'type': type?.name,
      'page': page?.toString() ?? '1',
      'sort': sortBy?.name,
      'region': countryCode,
      'date': date != SearchDate.any ? date.name : null,
      'duration': duration != SearchDuration.any ? duration.name : null,
    });
    final response = await _get(req, cache: true);
    Iterable i = handleResponse(response);
    // only getting videos for now
    SearchResults results = SearchResults();
    try {
      for (var e in i) {
        switch (e['type']) {
          case 'video':
            results.videos.add(Video.fromJson(e));
            break;
          case 'playlist':
            results.playlists.add(Playlist.fromJson(e));
            break;
          case 'channel':
            results.channels.add(Channel.fromJson(e));
        }
      }
    } catch (err) {
      log.info((err as Error).stackTrace?.toString());
      rethrow;
    }
    log.info(results);
    _cacheBrowse(req, response,
        [...results.videos, ...results.playlists, ...results.channels]);

    results.videos = (await postProcessVideos(results.videos)).cast();
    return results;
  }

  Future<UserFeed> getUserFeed(
      {int? maxResults,
      int? page,
      bool saveLastSeen = true,
      Server? serverOverride}) async {
    // for background service to be able to use
    final req = await buildRequest(urlGetUserFeed,
        query: {
          'max_results': maxResults?.toString(),
          'page': page?.toString()
        },
        authenticated: true,
        serverOverride: serverOverride);

    final response = await _get(req);
    var feed = UserFeed.fromJson(handleResponse(response));
    feed.videos = (await postProcessVideos(feed.videos ?? [])).cast();
    feed.notifications =
        (await postProcessVideos(feed.notifications ?? [])).cast();

    // we only save the last video seen if we're on the first page otherwise it does not make sense
    if (saveLastSeen && (page ?? 1) == 1) {
      var videos = List.from(feed.notifications ?? [], growable: true);
      videos.addAll(feed.videos ?? []);
      if (videos.isNotEmpty) {
        var toSave = SubscriptionNotification(
            videos.first.videoId, DateTime.now().millisecondsSinceEpoch);
        if (req.server != null) {
          await fileDb
              .forAccount(req.server!)
              .setLastSubscriptionNotification(toSave);
        }
      }
    }

    return feed;
  }

  Future<List<SponsorSegment>> getSponsorSegments(
      String videoId, List<SponsorSegmentType> categories) async {
    try {
      String url = urlGetSponsorSegments.replaceAll(":id", videoId);

      if (categories.isNotEmpty) {
        url +=
            '&categories=[${categories.map((e) => '"${e.segmentName}"').join(",")}]';
      }

      log.info('Calling $url');
      final response = await httpClient.get(Uri.parse(url));
      final Iterable entries = handleResponse(response);
      final segments = <SponsorSegment>[];
      for (final entry in entries) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          segments.add(SponsorSegment.fromJson(entry));
        } catch (_) {
          // Keep usable segments if one entry is malformed or unsupported.
        }
      }
      return segments;
    } catch (err) {
      return [];
    }
  }

  Future<DeArrow?> getDeArrow(String videoId) async {
    try {
      String url = urlGetDeArrow.replaceAll(":id", videoId);

      log.fine("calling $url");
      final response = await httpClient.get((Uri.parse(url)));
      var body = utf8.decode(response.bodyBytes);
      var deArrow = DeArrow.fromJson(jsonDecode(body));
      deArrow.videoId = videoId;
      return deArrow;
    } catch (err) {
      return null;
    }
  }

  Future<bool> testDeArrowThumbnail(String? url) async {
    if (url != null) {
      final response = await httpClient.head(Uri.parse(url));
      log.fine("calling $url => ${response.statusCode}");
      return response.statusCode == 200;
    } else {
      return false;
    }
  }

  Future<SearchSuggestion> getSearchSuggestion(String query) async {
    if (query.isEmpty) return SearchSuggestion(query, []);
    var request = await buildRequest(urlSearchSuggestions, query: {"q": query});
    final response = await _get(request);
    SearchSuggestion search =
        SearchSuggestion.fromJson(handleResponse(response));
    // Suggestions are text. Escape literal markup before decoding entities.
    search.suggestions = search.suggestions
        .map((suggestion) => suggestion.contains('&')
            ? html.parseFragment(suggestion.replaceAll('<', '&lt;')).text ??
                suggestion
            : suggestion)
        .toList();

    return search;
  }

  Future<void> validateServer(
      String serverUrl, Map<String, String>? headers) async {
    try {
      String url = serverUrl + urlStats;
      log.info('Calling $url');
      final requestHeaders = Map<String, String>.from(headers ?? {});
      if (!requestHeaders.keys.any((name) => name.toLowerCase() == 'accept')) {
        requestHeaders['Accept'] = 'application/json';
      }
      final response = await _get(
          ServerRequest(uri: Uri.parse(url), headers: requestHeaders));
      final json = handleResponse(response);
      if (json is! Map<String, dynamic>) {
        throw InvidiousServiceError('The instance returned invalid statistics.',
            statusCode: response.statusCode);
      }

      if (json['software'] is Map && json['software']['name'] == 'invidious') {
        return;
      } else {
        throw MissingSoftwareKeyError(jsonEncode(json));
      }
    } catch (err) {
      if (err is InvidiousServiceError ||
          err is CannotAddServerError ||
          err is NerdVpnAccessRequired) {
        rethrow;
      } else {
        throw CannotAddServerError(error: err.toString());
      }
    }
  }

  Future<bool> isLoggedIn() async {
    final owner = db.forProfile(db.profileId);
    return await _authenticatedAccount(owner) != null;
  }

  Future<Server?> _authenticatedAccount(IDbClient owner) async {
    final account = await owner.getCurrentlySelectedServer();
    return hasHistoryAccount(account) ? account : null;
  }

  Future<bool> validateCurrentSession() async {
    final owner = db.forProfile(db.profileId);
    final server = await _authenticatedAccount(owner);
    if (server == null) return false;
    final generation = _authenticationAttempts[_accountKey(server)] ?? 0;
    try {
      final req = await buildRequest(urlGetSubscriptions,
          authenticated: true, serverOverride: server);
      final response = await _get(req);
      final subscriptions = handleResponse(response);
      if (subscriptions is! Iterable) {
        throw InvidiousServiceError(
          'The subscriptions endpoint returned an unexpected response',
          statusCode: response.statusCode,
        );
      }
      return true;
    } on InvidiousServiceError catch (error, stackTrace) {
      // Legacy scope failures and unknown gateway responses do not establish
      // that NerdVPN rejected the stored account token.
      if (NerdVpnAccess.supports(server)) rethrow;
      if (!error.isAuthenticationFailure) rethrow;

      await _clearAuthentication(server, generation);
      log.warning(
        'Cleared credentials rejected by the Invidious subscriptions endpoint',
        error,
        stackTrace,
      );
      return false;
    }
  }

  Future<void> validateCurrentSessionSafely() async {
    try {
      await validateCurrentSession();
    } catch (error, stackTrace) {
      log.warning(
        'Unable to validate the stored Invidious session',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _clearAuthentication(Server server, int generation) async {
    // A gateway challenge cannot establish that Invidious rejected its token.
    final gateway = await GatewayAuth.status(server);
    if (gateway.enabled) return;
    final loggedOutServer = await _storeCredentials(server, generation);
    if (loggedOutServer == null) return;
    if (!loggedOutServer.inUse) return;

    try {
      await fileDb.refreshAccount(loggedOutServer);
    } catch (error, stackTrace) {
      log.warning(
        'Failed to mirror invalidated credentials to the file database',
        error,
        stackTrace,
      );
    }
  }

  Future<NerdVpnAccessStatus> checkNerdVpnAccess(Server server) async {
    server = await _migrateNerdVpnKey(server);
    final status = await NerdVpnAccess.instance.check(server);
    if (status.ready) await syncAccountHistory(server, force: true);
    return status;
  }

  Future<Server> _migrateNerdVpnKey(Server original) async {
    if (!NerdVpnAccess.supports(original)) return original;
    final legacyKeys = original.customHeaders.entries
        .where((entry) => NerdVpnAccess.isKeyHeader(entry.key))
        .toList();
    if (legacyKeys.isEmpty) return original;
    final key = jsonEncode([
      original.profileId,
      original.accountId,
      Uri.parse(original.url).origin
    ]);
    final active = _keyMigrations[key];
    if (active != null) {
      final migrated = await active;
      if (migrated.customHeaders.keys.any(NerdVpnAccess.isKeyHeader)) {
        return original;
      }
      return original.copyWith(
          customHeaders: Map<String, String>.from(original.customHeaders)
            ..removeWhere((name, _) => NerdVpnAccess.isKeyHeader(name)));
    }
    final pending = () async {
      final status = await NerdVpnAccess.instance.status(original);
      if (status.state == 'missing' && (status.revision ?? 0) == 0) {
        final imported = await NerdVpnAccess.instance
            .setKey(original, legacyKeys.last.value, expectedRevision: 0);
        if (!imported.ready) return original;
      } else if (!status.ready) {
        // Preserve an existing manual credential until secure storage has
        // accepted it or already holds a working replacement.
        return original;
      }
      final owner = db.forProfile(original.profileId);
      Server strip(Server saved) => saved.copyWith(
          customHeaders: Map<String, String>.from(saved.customHeaders)
            ..removeWhere((name, value) => legacyKeys
                .any((entry) => entry.key == name && entry.value == value)));
      if (owner is SembastSqfDb) {
        await owner.db.transaction((txn) async {
          final record = owner.serversStore.record(original.accountId);
          final data = await record.get(txn);
          if (data == null) return;
          final saved = Server.fromJson(data);
          if (saved.url == original.url) {
            await record.put(txn, strip(saved).toJson());
          }
        });
      } else {
        final saved = owner.getAccount(original.accountId);
        if (saved != null && saved.url == original.url) {
          await owner.upsertServer(strip(saved));
        }
      }
      final saved = owner.getAccount(original.accountId);
      if (saved != null && saved.inUse && saved.url == original.url) {
        await fileDb.refreshAccount(saved);
      }
      return strip(original);
    }();
    _keyMigrations[key] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_keyMigrations[key], pending)) _keyMigrations.remove(key);
    }
  }

  Future<bool> subscribe(String channelId) async {
    final owner = db.forProfile(db.profileId);
    final account = await _authenticatedAccount(owner);
    if (account == null) return false;
    final req = await buildRequest(urlAddDeleteSubscriptions,
        pathParams: {":ucid": channelId},
        authenticated: true,
        serverOverride: account);

    final response = await httpClient.post(req.uri, headers: req.headers);
    handleResponse(response);
    return true;
  }

  Future<bool> unSubscribe(String channelId) async {
    final owner = db.forProfile(db.profileId);
    final account = await _authenticatedAccount(owner);
    if (account == null) return false;

    final req = await buildRequest(urlAddDeleteSubscriptions,
        pathParams: {":ucid": channelId},
        authenticated: true,
        serverOverride: account);

    final response = await httpClient.delete(req.uri, headers: req.headers);
    handleResponse(response);
    return true;
  }

  Future<bool> isSubscribedToChannel(String channelId) async {
    return (await getSubscriptions())
            .indexWhere((element) => element.authorId == channelId) >
        -1;
  }

  Future<List<Subscription>> getSubscriptions() async {
    final owner = db.forProfile(db.profileId);
    final account = await _authenticatedAccount(owner);
    if (account == null) return [];

    var req = await buildRequest(urlGetSubscriptions,
        authenticated: true, serverOverride: account);

    final response = await _get(req);
    Iterable i = handleResponse(response);

    return List<Subscription>.from(i.map((e) => Subscription.fromJson(e)));
  }

  Future<VideoComments> getComments(String videoId,
      {String? continuation, String? sortBy, String? source}) async {
    Map<String, String> queryStr = {};
    if (continuation != null) {
      queryStr.putIfAbsent('continuation', () => continuation);
    }
    if (sortBy != null) queryStr.putIfAbsent('sort_by', () => sortBy);
    if (source != null) queryStr.putIfAbsent('source', () => source);

    var req = await buildRequest(urlGetComments,
        pathParams: {':id': videoId}, query: queryStr);
    final response = await _get(req);
    return VideoComments.fromJson(handleResponse(response));
  }

  Future<Channel> getChannel(String channelId) async {
    // sometimes the api gives the channel with /channel/<channelid> format
    channelId = channelId.replaceAll("/channel/", '');
    var req = await buildRequest(urlGetChannel, pathParams: {':id': channelId});

    final response = await _get(req);

    var channel = Channel.fromJson(handleResponse(response));
    channel.latestVideos =
        (await postProcessVideos(channel.latestVideos ?? [])).cast();

    if (channel.latestVideos != null && channel.latestVideos!.isNotEmpty) {
      await fileDb
          .forAccount(req.server!)
          .setChannelNotificationLastViewedVideo(
              channel.authorUrl, channel.latestVideos![0].videoId);
    }
    return channel;
  }

  Future<VideosWithContinuation> getChannelVideos(
      String channelId, String? continuation,
      {bool saveLastSeen = true,
      Server? serverOverride,
      ChannelSortBy sortBy = ChannelSortBy.newest}) async {
    final req = await buildRequest(urlGetChannelVideos,
        pathParams: {':id': channelId},
        query: {
          'continuation': continuation,
          'sort_by': sortBy.name,
        },
        serverOverride: serverOverride);
    final response = await _get(req);

    var videosWithContinuation =
        VideosWithContinuation.fromJson(handleResponse(response));
    videosWithContinuation.videos =
        (await postProcessVideos(videosWithContinuation.videos)).cast();

    if (saveLastSeen && videosWithContinuation.videos.isNotEmpty) {
      await fileDb
          .forAccount(req.server!)
          .setChannelNotificationLastViewedVideo(
              channelId, videosWithContinuation.videos.first.videoId);
    }
    return videosWithContinuation;
  }

  Future<VideosWithContinuation> getChannelStreams(
      String channelId, String? continuation) async {
    final req = await buildRequest(urlGetChannelStreams,
        pathParams: {':id': channelId}, query: {'continuation': continuation});
    final response = await _get(req);

    var videosWithContinuation =
        VideosWithContinuation.fromJson(handleResponse(response));
    videosWithContinuation.videos =
        (await postProcessVideos(videosWithContinuation.videos)).cast();
    return videosWithContinuation;
  }

  Future<VideosWithContinuation> getChannelShorts(
      String channelId, String? continuation) async {
    final req = await buildRequest(urlGetChannelShorts,
        pathParams: {':id': channelId}, query: {'continuation': continuation});
    final response = await _get(req);

    var videosWithContinuation =
        VideosWithContinuation.fromJson(handleResponse(response));
    videosWithContinuation.videos =
        (await postProcessVideos(videosWithContinuation.videos)).cast();
    return videosWithContinuation;
  }

  Future<List<Playlist>> getUserPlaylists({bool postProcessing = true}) async {
    final owner = db.forProfile(db.profileId);
    // Start the account read before filtering yields so both halves belong to
    // the same person/account even if the active session changes meanwhile.
    final pendingAccount = _historyAccount(owner);
    var local = getLocalPlaylists(database: owner);
    if (postProcessing) {
      local = await Future.wait(local.map((p) async =>
          p.copyWith(videos: await VideoFilter.filterVideos(p.videos))));
    }
    try {
      final account = await pendingAccount;
      if (account == null) return local;
      var req = await buildRequest(urlGetUserPlaylists,
          authenticated: true, serverOverride: account);

      final response = await _get(req);
      Iterable i = handleResponse(response);
      var list = List<Playlist>.from(
          i.map((e) => Playlist.fromJson(e).copyWith(type: invidiousPlaylist)));
      if (postProcessing) {
        for (int i = 0; i < list.length; i++) {
          var pl = list[i];
          pl = pl.copyWith(videos: await postProcessVideos(pl.videos));
          list[i] = pl;
        }
      }
      return [...local, ...list.sortByReversed((e) => e.updated ?? 0)];
    } catch (e) {
      return local;
    }
  }

  List<Playlist> getLocalPlaylists({IDbClient? database}) {
    final stored = (database ?? db).getSettings(localPlaylistsSetting)?.value;
    final playlists = stored == null
        ? <Playlist>[]
        : (jsonDecode(stored) as List)
            .map((item) => Playlist.fromJson(Map<String, dynamic>.from(item)))
            .toList();
    if (!playlists.any((p) => p.playlistId == localWatchLaterId)) {
      playlists.insert(
          0,
          const Playlist(
              title: 'Watch Later',
              playlistId: localWatchLaterId,
              author: '',
              videoCount: 0));
    }
    return playlists;
  }

  Future<void> _updateLocalPlaylists(void Function(List<Playlist>) update,
      {IDbClient? database}) {
    final owner = database ?? db.forProfile(db.profileId);
    // Serialize saves so two quick additions cannot overwrite each other.
    return _localPlaylistWrite =
        _localPlaylistWrite.catchError((_) {}).then((_) async {
      final playlists = getLocalPlaylists(database: owner);
      update(playlists);
      await owner.saveSetting(SettingsValue(localPlaylistsSetting,
          jsonEncode(playlists.map((p) => p.toJson()).toList())));
    });
  }

  Future<ChannelPlaylists> getChannelPlaylists(String channelId,
      {String? continuation}) async {
    final req = await buildRequest(urlGetChannelPlaylists,
        pathParams: {':id': channelId}, query: {'continuation': continuation});

    final response = await _get(req);
    var channelPlaylists = ChannelPlaylists.fromJson(handleResponse(response));
    for (int i = 0; i < channelPlaylists.playlists.length; i++) {
      var pl = channelPlaylists.playlists[i];
      pl = pl.copyWith(videos: await postProcessVideos(pl.videos));
      channelPlaylists.playlists[i] = pl;
    }
    return channelPlaylists;
  }

  Future<String?> createPlayList(String name, String type) async {
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('Enter a playlist name');
    if (type == 'local') {
      final id = 'local:${const Uuid().v4()}';
      await _updateLocalPlaylists((playlists) => playlists.add(
          Playlist(title: name, playlistId: id, author: '', videoCount: 0)));
      return id;
    }
    var req = await buildRequest(urlPostUserPlaylists,
        authenticated: true, forceJson: true);

    Map<String, String> body = {
      'title': name,
      'privacy': type,
    };

    log.info(jsonEncode(body));

    final response = await httpClient.post(req.uri,
        headers: req.headers, body: jsonEncode(body));
    Map<String, dynamic> playlist = handleResponse(response);
    return playlist['playlistId'] as String;
  }

  Future<void> addVideoToPlaylist(String playListId, String videoId,
      {Video? video}) async {
    final owner = db.forProfile(db.profileId);
    if (playListId.startsWith('local:')) {
      final cached = video ??
          owner.getHistoryVideoByVideoId(videoId)?.toVideo() ??
          getLocalPlaylists(database: owner)
              .expand((p) => p.videos)
              .where((v) => v.videoId == videoId)
              .firstOrNull;
      final savedVideo = cached ??
          await getVideo(videoId,
              serverOverride: await owner.getCurrentlySelectedServer());
      await _updateLocalPlaylists((playlists) {
        final index = playlists.indexWhere((p) => p.playlistId == playListId);
        if (index < 0) throw StateError('Playlist no longer exists');
        final playlist = playlists[index];
        if (playlist.videos.any((v) => v.videoId == videoId)) return;
        // Keep display metadata; playback URLs expire and are fetched when needed.
        final videos = [
          ...playlist.videos,
          Video(
            videoId: videoId,
            indexId: videoId,
            title: savedVideo.title,
            author: savedVideo.author,
            authorId: savedVideo.authorId,
            authorUrl: savedVideo.authorUrl,
            lengthSeconds: savedVideo.lengthSeconds,
            videoThumbnails: savedVideo.videoThumbnails,
            musicMetadata: savedVideo.musicMetadata,
          )
        ];
        playlists[index] =
            playlist.copyWith(videos: videos, videoCount: videos.length);
      }, database: owner);
      return;
    }
    var req = await buildRequest(urlPostUserPlaylistVideo,
        pathParams: {":id": playListId}, authenticated: true, forceJson: true);

    Map<String, String> body = {
      'videoId': videoId,
    };

    final response = await httpClient.post(req.uri,
        headers: req.headers, body: jsonEncode(body));
    handleResponse(response);
  }

  Future<void> deleteUserPlaylist(String playListId,
      {IDbClient? database, Server? serverOverride}) async {
    final owner = database ?? db.forProfile(db.profileId);
    if (playListId.startsWith('local:')) {
      if (playListId == localWatchLaterId) return;
      await _updateLocalPlaylists(
          (playlists) =>
              playlists.removeWhere((p) => p.playlistId == playListId),
          database: owner);
      return;
    }
    var req = await buildRequest(urlDeleteUserPlaylist,
        pathParams: {":id": playListId},
        authenticated: true,
        forceJson: true,
        serverOverride:
            serverOverride ?? await owner.getCurrentlySelectedServer());

    final response = await httpClient.delete(req.uri, headers: req.headers);
    handleResponse(response);
  }

  Future<void> deleteUserPlaylistVideo(String playListId, String indexId,
      {IDbClient? database, Server? serverOverride}) async {
    final owner = database ?? db.forProfile(db.profileId);
    if (playListId.startsWith('local:')) {
      await _updateLocalPlaylists((playlists) {
        final index = playlists.indexWhere((p) => p.playlistId == playListId);
        if (index < 0) return;
        final videos =
            playlists[index].videos.where((v) => v.videoId != indexId).toList();
        playlists[index] = playlists[index]
            .copyWith(videos: videos, videoCount: videos.length);
      }, database: owner);
      return;
    }
    final req = await buildRequest(urlDeleteUserPlaylistVideo,
        pathParams: {':id': playListId, ':index': indexId},
        authenticated: true,
        forceJson: true,
        serverOverride:
            serverOverride ?? await owner.getCurrentlySelectedServer());

    final response = await httpClient.delete(req.uri, headers: req.headers);
    handleResponse(response);
  }

  Future<List<String>> getUserHistory(int page, int maxResults) async {
    final owner = db.forProfile(db.profileId);
    final account = await _historyAccount(owner);
    if (account == null) {
      return _localHistoryPage(owner, page, maxResults);
    }
    final req = await buildRequest(urlGetClearHistory,
        query: {'page': page.toString(), 'max_results': maxResults.toString()},
        authenticated: true,
        serverOverride: account);

    final response = await _get(req);
    Iterable i = handleResponse(response);

    return List<String>.from(i.map((e) => e as String));
  }

  Future<List<String>> getLocalHistoryPage(int page, int maxResults) async =>
      _localHistoryPage(db.forProfile(db.profileId), page, maxResults);

  List<String> _localHistoryPage(IDbClient owner, int page, int maxResults) =>
      owner
          .getLocalHistory()
          .skip((page - 1) * maxResults)
          .take(maxResults)
          .map((v) => v.videoId)
          .toList();

  final Map<String, WatchHistorySync> _watchSynchronizers = {};

  bool isVideoWatched(String videoId) =>
      WatchRepository.forDatabase(db)?.isWatched(videoId) ??
      db.getVideoProgress(videoId) >= watchedProgressThreshold;

  Future<void> markVideoWatched(Video video, bool watched) async {
    final database = db.forProfile(db.profileId);
    final repository = WatchRepository.forDatabase(database);
    if (repository == null) throw StateError('Watch storage is unavailable');
    Server? account;
    try {
      account = await database.getCurrentlySelectedServer();
    } catch (_) {
      // A person's local library also works before an instance is configured.
    }
    await repository.mark(video.videoId, watched, account: account);
    if (account != null) {
      unawaited(syncAccountHistory(account, database: database, pull: false));
    }
  }

  Future<void> syncHistory() async {
    final database = db.forProfile(db.profileId);
    try {
      final account = await database.getCurrentlySelectedServer();
      await syncAccountHistory(account, database: database);
    } catch (_) {
      // Startup without a configured server is an ordinary local-only state.
    }
  }

  Future<void> syncAccountHistory(Server account,
      {IDbClient? database, bool force = false, bool pull = true}) async {
    final source = database ?? db;
    if (source is SembastSqfDb && !source.profileExists(account.profileId)) {
      return;
    }
    final owner = source.forProfile(account.profileId);
    try {
      if (NerdVpnAccess.supports(account)) {
        account = await _migrateNerdVpnKey(account);
        if (owner is SembastSqfDb && !owner.isProfileAvailable) return;
        if (!(await NerdVpnAccess.instance.status(account)).ready) return;
      }
      if (owner is SembastSqfDb && !owner.isProfileAvailable) return;
      final worker = _watchSynchronizer(account, database: owner);
      await worker?.run(account, force: force, pull: pull);
    } on NerdVpnAccessRequired {
      return;
    } on StateError {
      // A late background reply after deletion is cancellation. Other storage
      // errors still surface instead of being mistaken for an absent person.
      if (owner is! SembastSqfDb || owner.isProfileAvailable) rethrow;
    }
  }

  WatchHistorySync? _watchSynchronizer(Server account, {IDbClient? database}) {
    final source = database ?? db;
    if (source is SembastSqfDb && !source.profileExists(account.profileId)) {
      return null;
    }
    final scoped = source.forProfile(account.profileId);
    if (scoped is! SembastSqfDb || !hasHistoryAccount(account)) return null;
    final key = '${identityHashCode(scoped.db)}:${account.profileId}';
    return _watchSynchronizers.putIfAbsent(
        key,
        () => WatchHistorySync(
              repository: WatchRepository(scoped),
              readPage: (server, page, size) async {
                final req = await buildRequest(urlGetClearHistory,
                    query: {'page': '$page', 'max_results': '$size'},
                    authenticated: true,
                    serverOverride: server);
                final response = await _get(req);
                return List<String>.from(handleResponse(response) as List);
              },
              changeHistory: (server, videoId, present) async {
                final req = await buildRequest(urlAddDeleteHistory,
                    pathParams: {':id': videoId},
                    authenticated: true,
                    forceJson: true,
                    serverOverride: server);
                final response = present
                    ? await httpClient.post(req.uri, headers: req.headers)
                    : await httpClient.delete(req.uri, headers: req.headers);
                handleResponse(response);
              },
              accountIsCurrent: (server) async {
                final saved = (await scoped.getServers())
                    .where(
                        (candidate) => candidate.accountId == server.accountId)
                    .firstOrNull;
                return saved != null &&
                    saved.url == server.url &&
                    saved.authToken == server.authToken &&
                    saved.sidCookie == server.sidCookie &&
                    mapEquals(saved.customHeaders, server.customHeaders);
              },
            ));
  }

  Future<void> clearUserHistory() async {
    final owner = db.forProfile(db.profileId);
    final account = await _historyAccount(owner);
    if (account == null) return owner.clearLocalHistory();
    Future<void> deleteRemote() async {
      final req = await buildRequest(urlGetClearHistory,
          authenticated: true, forceJson: true, serverOverride: account);
      final response = await httpClient.delete(req.uri, headers: req.headers);
      handleResponse(response);
    }

    final worker = _watchSynchronizer(account, database: owner);
    if (worker == null) return deleteRemote();
    await worker.deleteHistory(account, deleteRemote: deleteRemote);
  }

  Future<void> deleteFromUserHistory(String videoId) async {
    final owner = db.forProfile(db.profileId);
    final account = await _historyAccount(owner);
    if (account == null) return owner.deleteLocalHistory(videoId);
    Future<void> deleteRemote() async {
      final req = await buildRequest(urlAddDeleteHistory,
          pathParams: {':id': videoId},
          authenticated: true,
          forceJson: true,
          serverOverride: account);
      final response = await httpClient.delete(req.uri, headers: req.headers);
      handleResponse(response);
    }

    final worker = _watchSynchronizer(account, database: owner);
    if (worker == null) return deleteRemote();
    await worker.deleteHistory(account,
        videoId: videoId, deleteRemote: deleteRemote);
  }

  Future<void> addToUserHistory(String videoId) async {
    var req = await buildRequest(urlAddDeleteHistory,
        pathParams: {':id': videoId}, authenticated: true, forceJson: true);

    final response = await httpClient.post(req.uri, headers: req.headers);
    handleResponse(response);
  }

  Future<Server?> _historyAccount(IDbClient owner) async {
    try {
      return await _authenticatedAccount(owner);
    } catch (_) {
      return null;
    }
  }

  /// A dynamic mix returns a current batch, without a total or playlist author.
  /// Request its native endpoint instead of parsing the playlist redirect as a
  /// finite public playlist.
  Future<Playlist> getMix(String mixId, {Server? serverOverride}) async {
    final req = await buildRequest(urlGetMix,
        pathParams: {':id': mixId}, serverOverride: serverOverride);
    final data = handleResponse(await _get(req));
    if (data is! Map<String, dynamic> ||
        data['mixId'] != mixId ||
        data['title'] is! String ||
        (data['title'] as String).trim().isEmpty ||
        data['videos'] is! List) {
      throw InvidiousServiceError('The server returned an invalid mix');
    }
    final source = (data['videos'] as List)
        .map((value) => Video.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
    final videos = await postProcessVideos(source);
    return Playlist(
        playlistId: mixId,
        title: data['title'] as String,
        author: '',
        videoCount: source.length,
        videos: videos,
        removedByFilter: source.length - videos.length);
  }

  Future<Playlist> getPublicPlaylists(String playlistId,
      {int? page, bool saveLastSeen = true, Server? serverOverride}) async {
    if (playlistId.startsWith('local:')) {
      return getUserPlaylist(playlistId, serverOverride: serverOverride);
    }
    final req = await buildRequest(urlGetPublicPlaylist,
        pathParams: {':id': playlistId},
        query: {'page': page?.toString()},
        serverOverride: serverOverride);

    final response = await _get(req);
    var playlist = Playlist.fromJson(handleResponse(response));
    var oldLength = playlist.videos.length;
    final videos = await postProcessVideos(playlist.videos);
    playlist = playlist.copyWith(
        videos: videos, removedByFilter: oldLength - videos.length);

    if (saveLastSeen) {
      await fileDb
          .forAccount(req.server!)
          .setPlaylistNotificationLastViewedVideo(
              playlist.playlistId, playlist.videoCount);
    }

    return playlist;
  }

  Future<Playlist> getUserPlaylist(String playlistId,
      {int? page, Server? serverOverride}) async {
    if (playlistId.startsWith('local:')) {
      final playlist = getLocalPlaylists(
              database: serverOverride == null
                  ? null
                  : db.forProfile(serverOverride.profileId))
          .firstWhere((p) => p.playlistId == playlistId);
      return playlist.copyWith(
          videos: await VideoFilter.filterVideos(playlist.videos));
    }
    final req = await buildRequest(urlGetUserPlaylist,
        pathParams: {':id': playlistId},
        query: {'page': page?.toString()},
        authenticated: true,
        serverOverride: serverOverride);

    final response = await _get(req);
    var playlist = Playlist.fromJson(handleResponse(response))
        .copyWith(type: invidiousPlaylist);
    var oldLength = playlist.videos.length;
    final videos = await postProcessVideos(playlist.videos);
    playlist = playlist.copyWith(
        videos: videos, removedByFilter: oldLength - videos.length);

    return playlist;
  }

  Future<Dislike> getDislikes(String videoId) async {
    final customUrl =
        db.getSettings(returnYoutubeDislikeUrlSettingName)?.value ?? '';

    Uri uri = Uri.parse((customUrl.trim().isNotEmpty
            ? '${customUrl}votes?videoId='
            : urlGetDislikes) +
        videoId);

    // Don't let the dislike service hold up the video.
    final response =
        await httpClient.get(uri).timeout(const Duration(seconds: 3));
    return Dislike.fromJson(handleResponse(response));
  }
}

class ServerRequest {
  final Uri uri;
  final Server? server;
  final Map<String, String> headers;
  final String _cacheKey;

  ServerRequest(
      {required this.uri, required Map<String, String> headers, this.server})
      : headers = Map.unmodifiable(headers),
        _cacheKey = jsonEncode([
          uri.toString(),
          server?.profileId,
          server?.accountId,
          server?.authToken,
          server?.sidCookie,
          SplayTreeMap.of({
            for (final entry in headers.entries)
              entry.key.toLowerCase(): entry.value,
          })
        ]);
}
