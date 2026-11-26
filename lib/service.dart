import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/http.dart';
import 'package:clipious/player/dash_manifest_resolver.dart';
import 'package:clipious/player/media_source.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/extensions.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/local_playlist_entries.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
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
import 'package:clipious/videos/models/db/history_video_cache.dart';
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
import 'music/models/deleted_music_playlist.dart';
import 'music/services/music_library_service.dart';
import 'music/services/music_playlist_covers.dart';
import 'music/models/device_playlist_track.dart';
import 'notifications/models/db/subscription_notifications.dart';
import 'network/content_link.dart';
import 'network/native_proxy_http_client.dart';
import 'network/network_proxy.dart';
import 'network/origin_scoped_http_client.dart';
import 'network/gateway_context.dart';
import 'network/gateway_session_bridge.dart';
import 'network/nerdvpn_access.dart';
import 'network/youtube_privacy.dart';
import 'recommendations/subscription_revision.dart';
import 'settings/services/gateway_auth.dart';
import 'settings/services/media_companion_probe.dart';
import 'search/models/search_suggestion.dart';
import 'settings/models/db/server.dart';
import 'subscription_management/models/subscription.dart';
import 'videos/models/sponsor_segment_types.dart';
import 'videos/models/music_metadata.dart';
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
const urlResolveContent = '/api/v1/resolveurl';
const urlStats = '/api/v1/stats';
const urlGetSubscriptions = '/api/v1/auth/subscriptions';
const urlAddDeleteSubscriptions = '/api/v1/auth/subscriptions/:ucid';
const urlGetComments = '/api/v1/comments/:id';
const urlGetChannel = '/api/v1/channels/:id';
const urlGetChannelVideos = '/api/v1/channels/:id/videos';
const urlGetChannelSearch = '/api/v1/channels/:id/search';
const urlGetChannelStreams = '/api/v1/channels/:id/streams';
const urlGetChannelShorts = '/api/v1/channels/:id/shorts';
const urlGetSponsorSegments =
    'https://sponsor.ajay.app/api/skipSegments?videoID=:id';
const urlGetDeArrow = 'https://sponsor.ajay.app/api/branding?videoID=:id';
const urlGetUserPlaylists = '/api/v1/auth/playlists';
const urlGetUserPlaylist = '/api/v1/auth/playlists/:id';
const urlPostUserPlaylists = '/api/v1/auth/playlists';
const urlGetChannelPlaylists = '/api/v1/channels/:id/playlists';
const urlGetChannelReleases = '/api/v1/channels/:id/releases';
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

enum _MetadataRetry { sameRoute, preferAlternate, none }

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
  final bool _usesDefaultTransport;
  late final Client _instanceHttpClient =
      OriginScopedHttpClient(httpClient, sameOriginOnly: true);
  Client _instanceReader(Future<void> Function()? beforeRedirect) =>
      beforeRedirect == null
          ? _instanceHttpClient
          : OriginScopedHttpClient(httpClient,
              sameOriginOnly: true, beforeRedirect: beforeRedirect);
  late final dashManifestResolver = DashManifestResolver(httpClient);
  final DateTime Function() _now;
  late BackendHealth _backendHealth = BackendHealth(now: _now);
  BackendHealth get backendHealth => _backendHealth;
  final Future<void> Function(Duration) _wait;
  final _getRequests = <Object, Future<Response>>{};
  final _interactiveVideoRequests = <(
    String,
    Server,
    Object,
    int,
    _MetadataRetry
  ),
      _InteractiveVideoRequest>{};
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
    _backendHealth.retire();
    _backendHealth = BackendHealth(now: _now);
    _getRequests.clear();
    _interactiveVideoRequests.clear();
    _browseCache.clear();
  }

  Service(
      {Client? httpClient,
      DateTime Function()? now,
      Future<void> Function(Duration)? wait})
      // Android's worker transport already scopes redirects natively, with a
      // single timeout for the entire chain rather than one timeout per hop.
      : httpClient = _scopedClient(httpClient),
        _usesDefaultTransport = httpClient == null,
        _now = now ?? DateTime.now,
        _wait = wait ?? Future<void>.delayed;

  static Client _scopedClient([Client? client]) =>
      client is NativeProxyHttpClient
          ? client
          : OriginScopedHttpClient(client ?? http.Client());

  Future<Set<String>> findMediaCompanions(Server server,
      {required bool Function() isCurrent}) async {
    final database = db;
    final owner = database.forProfile(server.profileId);
    final revision = _sessionRevision;
    final proxy = NetworkProxy.instance.config;
    bool sessionCurrent() =>
        isCurrent() &&
        identical(db, database) &&
        database.profileId == server.profileId &&
        revision == _sessionRevision &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config);
    if (!sessionCurrent()) throw StateError('Media host check cancelled');
    // Secure key import can remove a legacy header from this account.
    // Compare the prepared connection with the saved record after migration.
    final prepared = await preparePlaybackServer(serverOverride: server);
    final connection = BackendPlayback(prepared);
    bool current() {
      if (!sessionCurrent()) return false;
      final saved = owner.getAccount(server.accountId);
      return saved != null && connection.matchesConnection(saved);
    }

    final video =
        await _getScopedVideoMetadata(setupSampleVideoId, prepared, () {
      if (!current()) throw StateError('Media host check cancelled');
    });
    return _probeMediaCompanions(prepared, video,
        isCurrent: current, reportUnavailable: true);
  }

  Future<Set<String>> discoverMediaCompanionsForSetup(
          Server server, Video video, {required bool Function() isCurrent}) =>
      _probeMediaCompanions(server, video,
          isCurrent: isCurrent, reportUnavailable: false);

  Future<Set<String>> _probeMediaCompanions(Server server, Video video,
      {required bool Function() isCurrent,
      required bool reportUnavailable}) async {
    // The foreground transport can own and abort its optional request without
    // closing the main service's pool. Preserve injected and worker routing.
    final owned = _usesDefaultTransport ? _scopedClient() : null;
    try {
      return await discoverSetupMediaCompanions(
          server, video, owned ?? httpClient,
          isCurrent: isCurrent, reportUnavailable: reportUnavailable);
    } finally {
      owned?.close();
    }
  }

  Duration? _retryAfter(http.BaseResponse response) =>
      retryAfterDelay(response.headers['retry-after']);

  Duration? retryAfterDelay(String? header) {
    final value = header?.trim();
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

  Future<Response> _sendGet(ServerRequest request,
      {Future<void> Function()? beforeRequest}) async {
    if (beforeRequest != null) await beforeRequest();
    final client = _instanceReader(beforeRequest);
    var response = await client.get(request.uri, headers: request.headers);
    if (response.statusCode == 429) {
      final delay = _retryAfter(response);
      // A long server cooldown belongs in the UI, not a hidden retry loop.
      if (delay != null && delay <= const Duration(seconds: 2)) {
        if (delay > Duration.zero) await _wait(delay);
        if (beforeRequest != null) await beforeRequest();
        response = await client.get(request.uri, headers: request.headers);
      }
    }
    return response;
  }

  Future<Response> _get(ServerRequest request,
      {bool cache = false,
      bool coalesce = false,
      Server? sharedPlaybackOwner,
      Future<void> Function()? beforeRequest}) async {
    final key = request._cacheKey;
    if (cache) {
      _browseCache.removeWhere((_, entry) => !entry.expires.isAfter(_now()));
      final cached = _browseCache[key];
      if (cached != null) {
        if (beforeRequest != null) await beforeRequest();
        return cached.response;
      }
    }
    Future<Response> send() {
      const timeout = Duration(seconds: 15);
      if (beforeRequest == null) return _sendGet(request).timeout(timeout);
      var expired = false;
      return _sendGet(request, beforeRequest: () async {
        await beforeRequest();
        if (expired) throw TimeoutException('Request expired.');
      }).timeout(timeout, onTimeout: () {
        expired = true;
        throw TimeoutException('Request expired.');
      });
    }

    // Operation-specific cancellation must not govern another caller. Plain
    // playback reads share the same saved account and connection lifetime.
    if (beforeRequest != null && sharedPlaybackOwner == null) return send();
    if (coalesce || cache) {
      // Share only the HTTP work. Each caller decodes and applies its settings.
      final requestKey = sharedPlaybackOwner == null
          ? key
          : (
              key,
              sharedPlaybackOwner,
              db,
              NetworkProxy.instance.config,
              _sessionRevision
            );
      return _getRequests.putIfAbsent(requestKey, () {
        late final Future<Response> pending;
        pending = send().whenComplete(() {
          if (identical(_getRequests[requestKey], pending)) {
            _getRequests.remove(requestKey);
          }
        });
        return pending;
      });
    }
    return _sendGet(request);
  }

  void _cacheBrowse(ServerRequest request, Response response, Iterable results,
      int revision) {
    if (revision != _sessionRevision ||
        results.isEmpty ||
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
    if (uri?.path.endsWith(urlSearchSuggestions) == true) {
      return urlSearchSuggestions;
    }
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

  dynamic handleResponse(Response response) => _handleResponse(response);

  dynamic _handleResponse(Response response, {bool privateSuggestion = false}) {
    final body = utf8
        .decode(response.bodyBytes, allowMalformed: response.statusCode == 429)
        .trim();
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final isSuccessful =
        response.statusCode >= 200 && response.statusCode < 300;
    final isHtml = contentType.contains('html') || body.startsWith('<');

    final routeForLog = privateSuggestion
        ? 'GET $urlSearchSuggestions'
        : '${response.request?.method} ${urlFormatForLog(response.request?.url)}';
    log.info('Response from $routeForLog, status: ${response.statusCode}');

    final json = _decodeJsonResponse(
      body,
      contentType,
      response.statusCode,
    );
    final errorCode =
        !privateSuggestion && json is Map && json['error'] is String
            ? json['error'] as String
            : null;
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
      final message = _errorMessage(
          privateSuggestion ? null : json, isHtml, response.statusCode);

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
        privateSuggestion
            ? 'Expected a JSON response.'
            : 'Expected JSON but received '
                '${contentType.isEmpty ? 'an unknown content type' : contentType}',
        statusCode: response.statusCode);
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
      final logUri = baseUrl == urlSearch ||
              baseUrl == urlGetChannelSearch ||
              baseUrl == urlResolveContent
          ? uri.replace(query: '')
          : uri;
      log.info('calling ${urlFormatForLog(logUri)}');

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
      log.severe(
          'Couldn\'t build url', baseUrl == urlSearchSuggestions ? null : err);
      rethrow;
    }
  }

  /// Resolve opaque YouTube identifiers through the captured instance only.
  /// The original address is a query value, never a network destination.
  Future<ContentLink?> resolveContentLink(ContentLink link,
      {required Server server, bool Function()? isCurrent}) async {
    final owner = db;
    final profileId = owner.profileId;
    final revision = _sessionRevision;
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        isCurrent?.call() != false &&
        identical(owner, db) &&
        owner.profileId == profileId &&
        revision == _sessionRevision &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config);
    if (!current()) return null;
    final source = Uri.tryParse(link.id);
    final instance = Uri.tryParse(server.url);
    if (link.kind != ContentLinkKind.unresolved ||
        source == null ||
        source.scheme != 'https' ||
        !youtubeHosts.contains(source.host) ||
        source.userInfo.isNotEmpty ||
        source.port != 443 ||
        ContentLink.parse(source)?.kind != ContentLinkKind.unresolved ||
        instance == null ||
        !const {'http', 'https'}.contains(instance.scheme) ||
        instance.host.isEmpty ||
        instance.userInfo.isNotEmpty ||
        isOfficialYoutubeUrl(instance)) {
      return null;
    }
    try {
      final request = await buildRequest(urlResolveContent,
          query: {'url': link.id},
          authenticated: hasHistoryAccount(server),
          serverOverride: server);
      if (!current()) return null;
      final get = http.Request('GET', request.uri)..followRedirects = false;
      get.headers.addAll(request.headers);
      final response = await _instanceHttpClient
          .send(get)
          .then(Response.fromStream)
          .timeout(const Duration(seconds: 15));
      if (!current() || response.statusCode != 200) return null;
      // Do not log a resolver response: its URL and error body may echo a
      // person's original address. Only validated identifiers leave here.
      return ContentLink.fromResolution(
          link, jsonDecode(utf8.decode(response.bodyBytes)));
    } on Exception {
      // Not every instance implements resolution or can resolve every page.
      // Let the caller keep the user inside Videre with its landing fallback.
      return null;
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
      if (!current() ||
          !BackendPlayback(server).matchesConnection(selectedNow)) {
        throw StateError('The playback connection changed.');
      }
    }
    return server;
  }

  /// Discovery inspects categories without enriching the video or its related
  /// videos. Keep its bounded lookup budget entirely on the selected instance.
  Future<Video> getDiscoveryVideoMetadata(String videoId,
      {required Server serverOverride, bool Function()? isCurrent}) async {
    final owner = db;
    final profileId = owner.profileId;
    final revision = _sessionRevision;
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        isCurrent?.call() != false &&
        identical(owner, db) &&
        owner.profileId == profileId &&
        revision == _sessionRevision &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config);
    final server = await preparePlaybackServer(serverOverride: serverOverride);
    final route = BackendPlayback(server);
    Future<void> check() async {
      if (!current()) throw StateError('The discovery connection changed.');
      final selected = await owner.getCurrentlySelectedServer();
      if (!current() || !route.matchesConnection(selected)) {
        throw StateError('The discovery connection changed.');
      }
    }

    await check();
    final video = await _getVideoMetadata(videoId, server,
        beforeRequest: isCurrent == null ? null : check);
    await check();
    return video;
  }

  /// Performs one metadata request for a format picker or queued download.
  /// The caller owns its retry budget and its saved account may be unselected.
  Future<Video> getDownloadVideo(String videoId,
          {required BackendPlayback route,
          required void Function() checkCurrent}) =>
      _getScopedVideoMetadata(videoId, route.server, checkCurrent);

  Future<Video> _getScopedVideoMetadata(
      String videoId, Server server, void Function() checkCurrent) async {
    final revision = _sessionRevision;
    var expired = false;
    void check() {
      checkCurrent();
      if (expired || _sessionRevision != revision) {
        throw StateError('The metadata connection changed.');
      }
    }

    check();
    final request = await buildRequest(urlGetVideo,
        pathParams: {':id': videoId}, serverOverride: server);
    check();
    final response = await _instanceReader(() async => check())
        .get(request.uri, headers: request.headers)
        .timeout(const Duration(seconds: 15), onTimeout: () {
      expired = true;
      throw TimeoutException('Video metadata request expired.');
    });
    check();
    final video = _decodeVideoMetadata(response);
    if (video.videoId != videoId) {
      throw const FormatException('The server returned another video.');
    }
    return video;
  }

  Future<Video> getVideo(String videoId,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest,
          VideoLoadObserver? loadObserver}) =>
      _getPlaybackVideo(videoId,
          enrichResults: true,
          serverOverride: serverOverride,
          onBackendRequest: onBackendRequest,
          loadObserver: loadObserver);

  /// Music uses the same playback admission and retries, with the original
  /// metadata from the selected instance on every route.
  Future<Video> getMusicVideo(String videoId,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest,
          VideoLoadObserver? loadObserver}) =>
      _getPlaybackVideo(videoId,
          enrichResults: false,
          serverOverride: serverOverride,
          onBackendRequest: onBackendRequest,
          loadObserver: loadObserver);

  Future<Video> getCatalogSongVideo(String videoId, Server server,
          VideoLoadObserver? observer, Future<void> Function() beforeRequest) =>
      _getPlaybackVideo(videoId,
          enrichResults: false,
          serverOverride: observer == null ? server : null,
          loadObserver: observer,
          beforeRequest: beforeRequest);

  Future<Video> _getPlaybackVideo(String videoId,
      {required bool enrichResults,
      Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver,
      Future<void> Function()? beforeRequest}) async {
    if (videoId.startsWith('device:')) {
      throw StateError('Device files have no online playback source');
    }
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
        serverOverride != null ||
        (connectionCurrent() && (observer?.isCurrent() ?? true));
    // Import legacy credentials before freezing the admitted header snapshot.
    // Keep the original context across that await; migration must not bless a
    // concurrent profile, session, or proxy change as a new playback request.
    final server = await preparePlaybackServer(serverOverride: serverOverride);
    if (beforeRequest != null) await beforeRequest();
    if (!connectionCurrent()) {
      throw StateError('The playback connection changed.');
    }
    if (!enrichResults && beforeRequest == null && serverOverride != null) {
      // Downloads can belong to an unselected account. Keep that account and
      // its proxy policy across rate-limit waits, including after a deletion.
      final owner = originalDb.forProfile(server.profileId);
      final route = BackendPlayback(server);
      beforeRequest = () async {
        final saved = owner.getAccount(server.accountId);
        if (!connectionCurrent() ||
            saved == null ||
            !route.matchesConnection(saved)) {
          throw StateError('The download connection changed.');
        }
      };
    }
    // Explicit callers (downloads and connection tests) own their server snapshot
    // and subsequent request headers. Only normal playback may change routes.
    final initialRequest = serverOverride == null
        ? BackendPlayback(server, health: backendHealth)
        : null;
    final connection = initialRequest ?? BackendPlayback(server);
    var playback = server.backendSelector == null ? null : initialRequest;
    final firstRetry = playback?.canRetry == true
        ? _MetadataRetry.preferAlternate
        : _MetadataRetry.sameRoute;
    Video video;
    while (true) {
      if (!active()) throw StateError('The video load was cancelled.');
      try {
        video = await _getVideoMetadata(videoId, playback?.server ?? server,
            backendRequest: playback ?? initialRequest,
            onBackendRequest: onBackendRequest,
            loadObserver: observer,
            beforeRequest: beforeRequest,
            metadataRetry: (playback?.retryIndex ?? 0) == 0
                ? firstRetry
                : _MetadataRetry.none);
        break;
      } catch (error) {
        if (!active() || !isBackendRetryable(error) || playback == null) {
          rethrow;
        }
        if (!playback.matches(await db.getCurrentlySelectedServer()) ||
            !active()) {
          rethrow;
        }
        playback.recordFailure(error);
        final next = playback.next();
        if (next == null) rethrow;
        playback = next;
      }
    }
    if (!active()) throw StateError('The video load was cancelled.');
    final processed = await _processVideo(
        video.copyWith(
            backendPlayback: playback,
            playbackConnection: playback ?? connection,
            playbackSourceId: Object()),
        enrichResults: enrichResults);
    if (initialRequest != null &&
        !initialRequest.matches(await db.getCurrentlySelectedServer())) {
      throw StateError(
          'The playback connection changed while loading this video.');
    }
    if (!active()) throw StateError('The video load was cancelled.');
    _recordPlayableBackend(playback, processed);
    return processed;
  }

  /// A player-side choice uses a transient routing snapshot while retaining the
  /// saved server as its admission baseline. It never bypasses proxy/auth checks.
  Future<Video> getVideoForBackend(String videoId, BackendPlayback request,
          {void Function(BackendPlayback request)? onBackendRequest,
          bool Function()? isCurrent}) =>
      _getVideoForBackend(videoId, request,
          enrichResults: true,
          onBackendRequest: onBackendRequest,
          isCurrent: isCurrent);

  Future<Video> getMusicVideoForBackend(String videoId, BackendPlayback request,
          {void Function(BackendPlayback request)? onBackendRequest,
          bool Function()? isCurrent}) =>
      _getVideoForBackend(videoId, request,
          enrichResults: false,
          onBackendRequest: onBackendRequest,
          isCurrent: isCurrent);

  Future<Video> _getVideoForBackend(String videoId, BackendPlayback request,
      {required bool enrichResults,
      void Function(BackendPlayback request)? onBackendRequest,
      bool Function()? isCurrent}) async {
    var playback = request;
    final database = db;
    final revision = _sessionRevision;
    bool active() =>
        identical(db, database) &&
        _sessionRevision == revision &&
        (isCurrent?.call() ?? true);
    while (true) {
      if (!active() ||
          !playback.matches(await db.getCurrentlySelectedServer())) {
        throw StateError('The playback connection changed.');
      }
      if (!active()) throw StateError('The video changed.');
      Video loaded;
      try {
        loaded = await _getVideoMetadata(videoId, playback.server,
            backendRequest: playback,
            onBackendRequest: onBackendRequest,
            metadataRetry: playback.canRetry
                ? _MetadataRetry.preferAlternate
                : _MetadataRetry.sameRoute,
            beforeRequest: () => _requirePlaybackRoute(playback, active));
      } catch (error) {
        if (!active() || !isBackendRetryable(error)) {
          rethrow;
        }
        if (!playback.matches(await db.getCurrentlySelectedServer()) ||
            !active()) {
          rethrow;
        }
        playback.recordFailure(error);
        final next = playback.next();
        if (next == null) rethrow;
        playback = next;
        continue;
      }
      final processed = await _processVideo(
          loaded.copyWith(
              backendPlayback: playback,
              playbackConnection: playback,
              playbackSourceId: Object()),
          enrichResults: enrichResults);
      if (!active() ||
          !playback.matches(await db.getCurrentlySelectedServer()) ||
          !active()) {
        throw StateError('The playback connection changed.');
      }
      _recordPlayableBackend(playback, processed);
      return processed;
    }
  }

  Future<void> _requirePlaybackRoute(
      BackendPlayback route, bool Function() active) async {
    if (!active() ||
        NetworkProxy.instance.isChanging ||
        !route.matches(await db.getCurrentlySelectedServer()) ||
        !active() ||
        NetworkProxy.instance.isChanging) {
      throw StateError('The playback connection changed.');
    }
  }

  void _recordPlayableBackend(BackendPlayback? route, Video video) {
    if (route == null || route.server.backendSelector == null) return;
    bool admits(String? candidate, {bool manifest = false}) {
      final url = parseMediaUrl(candidate);
      return url != null &&
          validatedMediaUrl(
                  proxyMediaUrl(url, route.server, adaptive: manifest),
                  route.server) !=
              null;
    }

    if (admits(video.hlsUrl, manifest: true) ||
        admits(video.dashUrl, manifest: true) ||
        (video.formatStreams?.any((stream) =>
                !stream.isLegacyHd720 &&
                (stream.type.startsWith('video/') ||
                    stream.type.startsWith('audio/')) &&
                admits(stream.url)) ??
            false) ||
        (video.adaptiveFormats?.any((format) =>
                format.type.startsWith('audio/') && admits(format.url)) ??
            false)) {
      route.recordSuccess();
    }
  }

  Future<Video> _getVideoMetadata(String videoId, Server server,
      {BackendPlayback? backendRequest,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver,
      Future<void> Function()? beforeRequest,
      _MetadataRetry metadataRetry = _MetadataRetry.sameRoute}) async {
    final video = await _loadVideoMetadata(videoId, server,
        backendRequest: backendRequest,
        onBackendRequest: onBackendRequest,
        loadObserver: loadObserver,
        beforeRequest: beforeRequest,
        metadataRetry: metadataRetry);
    // A successful HTTP response can still belong to another cache key. Reject
    // it before source admission, post-processing, or any backend retry.
    if (video.videoId != videoId) {
      throw const FormatException('The server returned another video.');
    }
    return video;
  }

  Video _decodeVideoMetadata(Response response) {
    InvidiousServiceError invalidMetadata() => InvidiousServiceError(
          'The server returned incomplete or invalid video details. '
          'Try again later or choose another server.',
          statusCode: response.statusCode,
        );

    final Object? json;
    try {
      json = handleResponse(response);
    } on InvidiousServiceError catch (error) {
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          error.responseWasHtml) {
        rethrow;
      }
      throw invalidMetadata();
    }
    // Empty responses are valid for mutations, but a video load requires an
    // object. Keep its actual HTTP status so invalid data cannot grant a retry.
    if (json is! Map<String, dynamic>) throw invalidMetadata();
    try {
      return Video.fromJson(json);
    } on TypeError {
      throw invalidMetadata();
    } on FormatException {
      throw invalidMetadata();
    }
  }

  Future<Video> _loadVideoMetadata(String videoId, Server server,
      {BackendPlayback? backendRequest,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver,
      Future<void> Function()? beforeRequest,
      required _MetadataRetry metadataRetry}) async {
    final originalDb = db;
    final profileId = originalDb.profileId;
    final sessionRevision = _sessionRevision;
    final proxy = NetworkProxy.instance.config;
    final request = await buildRequest(urlGetVideo,
        pathParams: {':id': videoId}, serverOverride: server);
    Server? sharedPlaybackOwner;
    if (backendRequest != null) {
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
      Future<void> checkConnection() async {
        if (!await unchanged()) {
          throw StateError('The playback connection changed.');
        }
      }

      await checkConnection();
      if (loadObserver?.isCurrent() == false) {
        throw StateError('The video load was cancelled.');
      }
      onBackendRequest?.call(backendRequest);
      if (loadObserver != null) {
        return _getInteractiveVideoMetadata(
            request, backendRequest, loadObserver,
            unchanged: unchanged, retry: metadataRetry);
      }
      if (beforeRequest == null) {
        beforeRequest = checkConnection;
        sharedPlaybackOwner = backendRequest.preferredServer;
      }
    }
    Future<Response> get() => _get(request,
        coalesce: true,
        sharedPlaybackOwner: sharedPlaybackOwner,
        beforeRequest: beforeRequest);
    if (!isNerdVpnUrl(request.uri.toString())) {
      final response = await get();
      return _decodeVideoMetadata(response);
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
      final response = await get();
      try {
        return _decodeVideoMetadata(response);
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
        // Playback can switch immediately on a confirmed backend outage.
        // An instance cooldown still applies across all its backends.
        if (metadataRetry == _MetadataRetry.none ||
            (metadataRetry == _MetadataRetry.preferAlternate &&
                isBackendRetryable(error))) {
          rethrow;
        }
        if (delay > Duration.zero) await _wait(delay);
        if (!await unchanged()) {
          throw StateError('The playback connection changed.');
        }
        if (beforeRequest != null) await beforeRequest();
        if (expired || remaining() <= Duration.zero) {
          throw TimeoutException('Video metadata request expired.');
        }
        // One additional request only, even if it returns another retryable
        // status. Do not restart the usual GET retry or its timeout budget.
        final retried = await _instanceReader(beforeRequest)
            .get(request.uri, headers: request.headers)
            .timeout(remaining());
        if (!await unchanged()) {
          throw StateError('The playback connection changed.');
        }
        return _decodeVideoMetadata(retried);
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
      required _MetadataRetry retry}) async {
    final key = (
      request._cacheKey,
      route.preferredServer,
      NetworkProxy.instance.config,
      _sessionRevision,
      retry
    );
    final existing = _interactiveVideoRequests[key];
    final pending = existing ?? _InteractiveVideoRequest();
    pending.observers.add(observer);
    if (existing == null) {
      _interactiveVideoRequests[key] = pending;
      pending.result = _loadInteractiveVideoMetadata(request, pending,
              unchanged: unchanged, retry: retry)
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
      {required Future<bool> Function() unchanged,
      required _MetadataRetry retry}) {
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
      final client = _instanceReader(checkCurrent);
      Response? response;
      try {
        response = await client.get(request.uri, headers: request.headers);
        await checkCurrent();
        return _decodeVideoMetadata(response);
      } catch (error) {
        final delay = retry == _MetadataRetry.none
            ? null
            : _videoRetryDelay(error, response, request, retry);
        if (expired || delay == null || remaining() <= delay) rethrow;
        await checkCurrent();
        pending.announceRetry();
        if (delay > Duration.zero) await _wait(delay);
        await checkCurrent();
        // Keep one budget for transient failures and rate limits. The follow-up
        // uses the exact original request, with no second retry wrapper.
        final retried = await client.get(request.uri, headers: request.headers);
        await checkCurrent();
        return _decodeVideoMetadata(retried);
      }
    }

    return load().timeout(budget, onTimeout: () {
      expired = true;
      throw TimeoutException('Video metadata request expired.');
    });
  }

  Duration? _videoRetryDelay(Object error, Response? response,
      ServerRequest request, _MetadataRetry retry) {
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
    // An explicit backend failure can advance playback immediately when the
    // playback attempt has an alternate. The caller owns the fallback budget.
    if (retry == _MetadataRetry.preferAlternate &&
        isUnavailableBackend(error) &&
        isBackendRetryable(error)) {
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
    final database = db;
    final revision = _sessionRevision;
    bool active() =>
        identical(db, database) && _sessionRevision == revision && isCurrent();
    if (playback == null || !active() || !playback.acquireRecovery()) {
      return null;
    }
    final original = playback;
    try {
      while (active() &&
          playback!.matches(await db.getCurrentlySelectedServer())) {
        if (!active()) return null;
        final next = playback.next();
        if (next == null) return null;
        playback = next;
        Video loaded;
        try {
          loaded = await _getVideoMetadata(video.videoId, next.server,
              backendRequest: next,
              onBackendRequest: onRetry,
              metadataRetry: next.canRetry
                  ? _MetadataRetry.preferAlternate
                  : _MetadataRetry.sameRoute,
              beforeRequest: () => _requirePlaybackRoute(next, active));
        } catch (error) {
          if (!isBackendRetryable(error)) rethrow;
          if (!active() ||
              !next.matches(await db.getCurrentlySelectedServer()) ||
              !active()) {
            return null;
          }
          next.recordFailure(error);
          continue;
        }
        if (!active() || !next.matches(await db.getCurrentlySelectedServer())) {
          return null;
        }
        final processed = await _processVideo(
            loaded.copyWith(
                backendPlayback: next,
                playbackConnection: next,
                playbackSourceId: Object()),
            enrichResults: video.musicMetadata == null);
        if (!active() ||
            !next.matches(await db.getCurrentlySelectedServer()) ||
            !active()) {
          return null;
        }
        _recordPlayableBackend(next, processed);
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
    final Video loaded;
    try {
      loaded = await _getVideoMetadata(video.videoId, connection.server,
          backendRequest: connection,
          loadObserver: VideoLoadObserver(isCurrent: active, onRetry: () {}),
          metadataRetry: _MetadataRetry.none);
    } catch (error) {
      await check();
      connection.recordFailure(error);
      rethrow;
    }
    await check();
    if (loaded.videoId != video.videoId) {
      throw const FormatException('The server returned another video.');
    }
    _recordPlayableBackend(connection, loaded);
    return video.copyWith(
        downloadPlaybackOnly: false,
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

  Future<Video> _processVideo(Video video,
      {required bool enrichResults}) async {
    if (enrichResults) video = (await DeArrow.processVideos([video]))[0];
    video = video.copyWith(
        recommendedVideos: (await postProcessVideos(video.recommendedVideos,
                enrichResults: enrichResults))
            .cast());
    return video;
  }

  Future<VideoTranscript> getTranscript(
    String videoId,
    Caption caption, {
    Server? serverOverride,
  }) async {
    final server = serverOverride ?? await db.getCurrentlySelectedServer();
    try {
      return await _getTranscript(videoId, caption, serverOverride: server);
    } catch (error) {
      if (_captionAccessFailure(error)) rethrow;
      return _getWatchCaptionTranscript(videoId, caption, server);
    }
  }

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
      return (await _getWatchCaptionTranscript(videoId, caption, server,
              forPlayback: true))
          .toWebVtt();
    }
  }

  bool _captionAccessFailure(Object error) =>
      error is NerdVpnAccessRequired ||
      error is GatewayAuthenticationRequired ||
      error is GatewayTransportUnavailable ||
      error is StateError ||
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
      final response = await _instanceHttpClient.send(get);
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

  Future<VideoTranscript> _getWatchCaptionTranscript(
      String videoId, Caption caption, Server server,
      {bool forPlayback = false}) async {
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
      final tracks = document
          .querySelectorAll('video#player track')
          .where((track) =>
              const {'captions', 'subtitles'}
                  .contains(track.attributes['kind']) &&
              track.attributes['label'] == caption.label)
          .toList();
      for (final track in tracks) {
        final language = track.attributes['srclang'];
        // Some instance player pages omit srclang. Infer it from the exact
        // selected label only when no other same-label track can conflict,
        // including tracks whose URL will fail admission below.
        if (language == null
            ? tracks.length != 1
            : language.isEmpty || language != caption.languageCode) {
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
      final transcript = _webVttTranscript(response, caption,
          preserveRepeatedLines: forPlayback);
      if (transcript.lines.isEmpty) {
        throw const FormatException('Transcript has no usable lines');
      }
      if (forPlayback) transcript.toWebVtt();
      return transcript;
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
      final response = await _captionResponse(request);
      return validate(VideoTranscript.fromJson(handleResponse(response),
          preserveRepeatedLines: forPlayback));
    } catch (error) {
      if (_captionAccessFailure(error)) rethrow;
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
      final request = _playbackCaptionRequest(canonicalRequest, caption,
          requireMatchingTrack: !forPlayback);
      final response = await _captionResponse(request);
      return validate(_webVttTranscript(response, caption,
          preserveRepeatedLines: forPlayback));
    } on InvidiousServiceError {
      rethrow;
    } catch (error) {
      if (_captionAccessFailure(error)) rethrow;
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
      ServerRequest canonical, Caption caption,
      {bool requireMatchingTrack = false}) {
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
      if (requireMatchingTrack) {
        final prefix = origin.path.replaceFirst(RegExp(r'/$'), '');
        final companionPath = canonical.uri.path.replaceFirst(
            '$prefix/api/v1/captions/', '$prefix/companion/api/v1/captions/');
        final query = advertised.queryParametersAll;
        final labels = query['label'];
        if (!{canonical.uri.path, companionPath}.contains(advertised.path) ||
            labels == null ||
            labels.length != 1 ||
            labels.single != caption.label) {
          return canonical;
        }
        for (final key in ['lang', 'tlang']) {
          final languages = query[key];
          if (languages != null &&
              (languages.length != 1 ||
                  caption.languageCode?.isNotEmpty != true ||
                  languages.single != caption.languageCode)) {
            return canonical;
          }
        }
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

      final response = await _instanceHttpClient.post(Uri.parse(url),
          body: map, headers: headers);
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

  Future<String?> _browserToken(Server original,
      {bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return null;
    final origin = Uri.tryParse(original.url);
    if (origin == null ||
        !const {'http', 'https'}.contains(origin.scheme) ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        isOfficialYoutubeUrl(origin)) {
      throw InvidiousServiceError('Select an Invidious instance to sign in.');
    }
    final access = NerdVpnAccess.supports(original)
        ? await NerdVpnAccess.instance.status(original)
        : null;
    // A logout or newer sign-in can finish while native access is being read.
    // Reject it before a browser launch, not only when its token comes back.
    if (isCurrent?.call() == false) return null;
    final retryAt = access?.retryAt;
    if (retryAt != null && retryAt.isAfter(_now())) {
      throw NerdVpnSignInFailed(NerdVpnSignInProblem.cooldown, retryAt);
    }
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        GatewayRequestContext.forAccount(
                original.profileId, original.accountId, original.url) ==
            null) {
      throw const GatewayUnsupported();
    }
    // Token login uses the same guarded native browser as protected login,
    // without turning an ordinary account into a persistent gateway session.
    return GatewayAuth.signIn(original,
        persistSession: original.gatewayEnabled,
        title: 'Sign in to Invidious',
        help:
            'Sign in, then authorize this Invidious account. Page scripts are '
            'disabled for privacy; sign-in pages that require JavaScript are unsupported.');
  }

  /// Used before a newly added account has a database record. Pending access is
  /// saved in the native account store, and the caller saves the returned token.
  Future<Server?> authenticateNerdVpn(Server original) async {
    if (!NerdVpnAccess.supports(original)) {
      throw ArgumentError('This server does not support NerdVPN sign-in');
    }
    if (isNerdVpnOnionUrl(original.url)) {
      // Onion gateway cookies remain account-owned alongside the API token.
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
    bool isCurrent() {
      final saved = owner.getAccount(original.accountId);
      return _authenticationAttempts[_accountKey(original)] == generation &&
          saved != null &&
          saved.url == original.url &&
          saved.authToken == original.authToken &&
          saved.sidCookie == original.sidCookie;
    }

    final intent = NerdVpnAccess.supports(original)
        ? await NerdVpnAccess.instance.beginAuth(original)
        : null;
    final token = await _browserToken(original, isCurrent: isCurrent);

    if (token == null) return null;

    Server? server = owner.getAccount(original.accountId);

    if (server != null) {
      if (!isCurrent()) {
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

  /// Protected setup creates account-scoped native credentials before the
  /// add-server route can save its new account. A failed save may already have
  /// committed, so only clear a session whose account is verifiably absent.
  Future<void> discardUnsavedSetupSession(Server server) async {
    if (server.id == null ||
        (!server.gatewayEnabled && !NerdVpnAccess.supports(server))) {
      return;
    }
    Future<void> clear() async {
      _beginAuthentication(server);
      try {
        await NerdVpnAccess.instance.clear(server);
      } finally {
        await GatewayAuth.signOut(server);
      }
    }

    if ((await db.getProfiles())
        .any((profile) => profile.id == server.profileId)) {
      final owner = db.forProfile(server.profileId);
      if (owner is SembastSqfDb) {
        // Serialize with another pending save of the same account.
        await owner.db.transaction((txn) async {
          if (!await owner.serversStore.record(server.accountId).exists(txn)) {
            await clear();
          }
        });
        return;
      }
      if (owner.getAccount(server.accountId) != null) return;
    }
    await clear();
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
    final revision = _sessionRevision;
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
    _cacheBrowse(req, response, list, revision);
    list = (await postProcessVideos(list));
    return list;
  }

  Future<List<Video>> getPopular() async {
    final revision = _sessionRevision;
    var req = await buildRequest(urlGetPopular);
    final response = await _get(req, cache: true);
    Iterable i = handleResponse(response);
    var list = List<Video>.from(i.map((e) => Video.fromJson(e)));
    _cacheBrowse(req, response, list, revision);
    list = (await postProcessVideos(list)).cast();
    return list;
  }

  Future<SearchResults> search(String query,
          {SearchType? type,
          int? page,
          SearchSortBy? sortBy,
          SearchDate date = SearchDate.any,
          SearchDuration duration = SearchDuration.any,
          Server? serverOverride,
          bool enrichResults = true}) =>
      _search(query,
          type: type,
          page: page,
          sortBy: sortBy,
          date: date,
          duration: duration,
          serverOverride: serverOverride,
          enrichResults: enrichResults);

  Future<SearchResults> searchMusic(String query, SearchType type,
          Server server, Future<void> Function() beforeRequest) =>
      _search(query,
          type: type,
          serverOverride: server,
          enrichResults: false,
          beforeRequest: beforeRequest);

  /// Music paging uses wire order and counts unsupported rows as page progress.
  Future<List<Object?>> searchMusicPage(
    String query,
    SearchType type,
    int page, {
    required Server server,
    required Future<void> Function() beforeRequest,
  }) async {
    final owner = db;
    final revision = _sessionRevision;
    final region = owner.getSettings(browsingCountry)?.value ?? 'US';
    Future<void> check() async {
      await beforeRequest();
      if (revision != _sessionRevision ||
          !identical(db, owner) ||
          (owner.getSettings(browsingCountry)?.value ?? 'US') != region) {
        throw StateError('The music search connection changed.');
      }
    }

    await check();
    final request = await _searchRequest(query,
        type: type, page: page, region: region, serverOverride: server);
    final response = await _get(request, cache: true, beforeRequest: check);
    await check();
    final data = handleResponse(response);
    if (data is! List<Object?>) {
      throw const FormatException('Invalid music search results.');
    }
    // A mixed page may contain malformed rows the Music adapter skips.
    // Keep those responses out of the shared typed browse cache.
    return data;
  }

  Future<ServerRequest> _searchRequest(String query,
          {SearchType? type,
          int? page,
          SearchSortBy? sortBy,
          SearchDate date = SearchDate.any,
          SearchDuration duration = SearchDuration.any,
          Server? serverOverride,
          required String region}) =>
      buildRequest(urlSearch, serverOverride: serverOverride, query: {
        'q': query,
        'type': type?.name,
        'page': page?.toString() ?? '1',
        'sort': sortBy?.name,
        'region': region,
        'date': date != SearchDate.any ? date.name : null,
        'duration': duration != SearchDuration.any ? duration.name : null,
      });

  Future<SearchResults> _search(String query,
      {SearchType? type,
      int? page,
      SearchSortBy? sortBy,
      SearchDate date = SearchDate.any,
      SearchDuration duration = SearchDuration.any,
      Server? serverOverride,
      required bool enrichResults,
      Future<void> Function()? beforeRequest}) async {
    final revision = _sessionRevision;
    final req = await _searchRequest(query,
        type: type,
        page: page,
        sortBy: sortBy,
        date: date,
        duration: duration,
        serverOverride: serverOverride,
        region: db.getSettings(browsingCountry)?.value ?? 'US');
    final response = await _get(req, cache: true, beforeRequest: beforeRequest);
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
    _cacheBrowse(
        req,
        response,
        [...results.videos, ...results.playlists, ...results.channels],
        revision);

    results.videos = enrichResults
        ? await postProcessVideos(results.videos)
        : await VideoFilter.filterVideos(results.videos
            .where((video) => video.title != privateVideoString)
            .toList());
    return results;
  }

  /// One admitted Invidious request for a recommendation pool. The guard runs
  /// immediately before dispatch, including on an HTTP 429 retry.
  Future<List<Video>> getVideoRecommendationCandidates({
    required Server server,
    required Future<void> Function() beforeRequest,
    String? query,
    String? channelId,
  }) async {
    assert(query == null || channelId == null);
    var expired = false;
    Future<void> check() async {
      await beforeRequest();
      if (expired) throw TimeoutException('Discovery request expired.');
    }

    Future<List<Video>> load() async {
      final request = query != null
          ? await buildRequest(urlSearch, serverOverride: server, query: {
              'q': query,
              'type': SearchType.video.name,
              'page': '1',
              'region': db.getSettings(browsingCountry)?.value ?? 'US',
            })
          : channelId != null
              ? await buildRequest(urlGetChannelVideos,
                  pathParams: {':id': channelId}, serverOverride: server)
              : await buildRequest(urlGetUserFeed,
                  authenticated: true,
                  serverOverride: server,
                  query: {'max_results': '20', 'page': '1'});
      final response = await _get(request, beforeRequest: check);
      await check();
      final data = handleResponse(response);
      if (query != null) {
        if (data is! List) {
          throw const FormatException('Invalid search results.');
        }
        return [
          for (final row in data)
            if (row is Map<String, dynamic> && row['type'] == 'video')
              Video.fromJson(row),
        ];
      }
      if (channelId != null) {
        return VideosWithContinuation.fromJson(data).videos.take(20).toList();
      }
      final feed = UserFeed.fromJson(data);
      return [...?feed.notifications, ...?feed.videos];
    }

    await check();
    return load().timeout(const Duration(seconds: 6), onTimeout: () {
      expired = true;
      throw TimeoutException('Discovery request expired.');
    });
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

  Future<SearchSuggestion> getSearchSuggestion(String query) =>
      _getSearchSuggestion(query);

  Future<SearchSuggestion> getMusicSearchSuggestion(String query,
      {required Server server,
      required Future<void> Function() beforeRequest}) {
    final owner = db;
    final revision = _sessionRevision;
    return _getSearchSuggestion(query, server: server, beforeRequest: () async {
      await beforeRequest();
      if (revision != _sessionRevision || !identical(db, owner)) {
        throw StateError('The music search connection changed.');
      }
    });
  }

  Future<SearchSuggestion> _getSearchSuggestion(String query,
      {Server? server, Future<void> Function()? beforeRequest}) async {
    if (query.isEmpty) return SearchSuggestion(query, []);
    await beforeRequest?.call();
    try {
      final request = await buildRequest(urlSearchSuggestions,
          query: {'q': query}, serverOverride: server);
      final response = await _get(request, beforeRequest: beforeRequest);
      await beforeRequest?.call();
      final search = SearchSuggestion.fromJson(
          _handleResponse(response, privateSuggestion: true));
      // Suggestions are text. Escape literal markup before decoding entities.
      search.suggestions = search.suggestions
          .map((suggestion) => suggestion.contains('&')
              ? html.parseFragment(suggestion.replaceAll('<', '&lt;')).text ??
                  suggestion
              : suggestion)
          .toList();
      return search;
    } on InvidiousServiceError {
      rethrow;
    } catch (_) {
      await beforeRequest?.call();
      // Transport and parsing errors can contain the draft in a URI or body.
      throw InvidiousServiceError('Search suggestions are unavailable.');
    }
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
      // Startup must remain usable when the instance stalls. Bound the response
      // before handling it so a late rejection cannot clear saved credentials.
      final response = await _get(req).timeout(const Duration(seconds: 5));
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

    final response =
        await _instanceHttpClient.post(req.uri, headers: req.headers);
    handleResponse(response);
    await _subscriptionsCommitted(owner);
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

    final response =
        await _instanceHttpClient.delete(req.uri, headers: req.headers);
    handleResponse(response);
    await _subscriptionsCommitted(owner);
    return true;
  }

  Future<void> _subscriptionsCommitted(IDbClient owner) =>
      invalidateStoredSubscriptionRecommendations(owner);

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

  /// Reads the follows of one already-admitted Invidious account. The caller
  /// checks ownership before dispatch, on a retry, and before using the reply.
  Future<List<Subscription>> getRecommendationSubscriptions({
    required Server server,
    required Future<void> Function() beforeRequest,
  }) async {
    if (!hasHistoryAccount(server)) return const [];
    var expired = false;
    Future<void> check() async {
      await beforeRequest();
      if (expired) throw TimeoutException('Subscription request expired.');
    }

    Future<List<Subscription>> load() async {
      await check();
      final request = await buildRequest(urlGetSubscriptions,
          authenticated: true, serverOverride: server);
      final response = await _get(request, beforeRequest: check);
      await check();
      final data = handleResponse(response);
      if (data is! List) {
        throw const FormatException('Invalid Invidious subscriptions.');
      }
      return [
        for (final entry in data)
          if (entry is Map<String, dynamic> &&
              entry['authorId'] is String &&
              entry['author'] is String)
            Subscription.fromJson(entry),
      ];
    }

    return load().timeout(const Duration(seconds: 6), onTimeout: () {
      expired = true;
      throw TimeoutException('Subscription request expired.');
    });
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

  Future<Channel> getChannel(String channelId,
          {bool saveLastSeen = true, Server? serverOverride}) =>
      _getChannel(channelId,
          saveLastSeen: saveLastSeen,
          serverOverride: serverOverride,
          enrichResults: true);

  Future<Channel> getMusicChannel(String channelId, Server server,
          Future<void> Function() beforeRequest) =>
      _getChannel(channelId,
          saveLastSeen: false,
          serverOverride: server,
          enrichResults: false,
          beforeRequest: beforeRequest);

  Future<Map<String, dynamic>> getMusicChannelReleases(
      String channelId, Server server, Future<void> Function() beforeRequest,
      {String? continuation}) async {
    final req = await buildRequest(urlGetChannelReleases,
        pathParams: {':id': channelId},
        query: {'continuation': continuation},
        serverOverride: server);
    final data = handleResponse(await _get(req, beforeRequest: beforeRequest));
    if (data is! Map<String, dynamic> || data['playlists'] is! List) {
      throw InvidiousServiceError('The server returned invalid releases');
    }
    return data;
  }

  Future<Channel> _getChannel(String channelId,
      {required bool saveLastSeen,
      required Server? serverOverride,
      required bool enrichResults,
      Future<void> Function()? beforeRequest}) async {
    // sometimes the api gives the channel with /channel/<channelid> format
    channelId = channelId.replaceAll("/channel/", '');
    var req = await buildRequest(urlGetChannel,
        pathParams: {':id': channelId}, serverOverride: serverOverride);

    final response = await _get(req, beforeRequest: beforeRequest);

    var channel = Channel.fromJson(handleResponse(response));
    channel.latestVideos = (await postProcessVideos(channel.latestVideos ?? [],
            enrichResults: enrichResults))
        .cast();

    if (saveLastSeen && channel.latestVideos!.isNotEmpty) {
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
          ChannelSortBy sortBy = ChannelSortBy.newest}) =>
      _getChannelVideos(channelId, continuation,
          saveLastSeen: saveLastSeen,
          serverOverride: serverOverride,
          sortBy: sortBy,
          enrichResults: true);

  Future<VideosWithContinuation> getMusicChannelVideos(String channelId,
          Server server, Future<void> Function() beforeRequest) =>
      _getChannelVideos(channelId, null,
          saveLastSeen: false,
          serverOverride: server,
          sortBy: ChannelSortBy.popular,
          enrichResults: false,
          beforeRequest: beforeRequest);

  Future<VideosWithContinuation> _getChannelVideos(
      String channelId, String? continuation,
      {required bool saveLastSeen,
      required Server? serverOverride,
      required ChannelSortBy sortBy,
      required bool enrichResults,
      Future<void> Function()? beforeRequest}) async {
    final req = await buildRequest(urlGetChannelVideos,
        pathParams: {':id': channelId},
        query: {
          'continuation': continuation,
          'sort_by': sortBy.name,
        },
        serverOverride: serverOverride);
    final response = await _get(req, beforeRequest: beforeRequest);

    var videosWithContinuation =
        VideosWithContinuation.fromJson(handleResponse(response));
    videosWithContinuation.videos = (await postProcessVideos(
            videosWithContinuation.videos,
            enrichResults: enrichResults))
        .cast();

    if (saveLastSeen && videosWithContinuation.videos.isNotEmpty) {
      await fileDb
          .forAccount(req.server!)
          .setChannelNotificationLastViewedVideo(
              channelId, videosWithContinuation.videos.first.videoId);
    }
    return videosWithContinuation;
  }

  static const channelSearchMaximumPage = 20;
  static final _channelSearchId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');

  static bool canSearchChannel(String channelId) =>
      _channelSearchId.hasMatch(channelId);

  /// The channel endpoint can return a mixed page containing playlist rows.
  /// Count the raw page so skipping those rows or hiding videos keeps paging.
  Future<({List<Video> videos, int rawCount})> searchChannelVideos(
    String channelId,
    String query, {
    required Server server,
    required int page,
    required Future<void> Function() beforeRequest,
  }) async {
    if (!canSearchChannel(channelId) ||
        query.trim().isEmpty ||
        query.runes.length > 200 ||
        page < 1 ||
        page > channelSearchMaximumPage) {
      throw ArgumentError('Invalid channel search parameters.');
    }
    final revision = _sessionRevision;
    Future<void> check() async {
      await beforeRequest();
      if (revision != _sessionRevision) {
        throw StateError('The channel search connection changed.');
      }
    }

    await check();
    final request = await buildRequest(urlGetChannelSearch,
        pathParams: {':id': channelId},
        serverOverride: server,
        query: {'q': query.trim(), 'page': page.toString()});
    final response = await _get(request, beforeRequest: check);
    await check();
    final data = handleResponse(response);
    if (data is! List) {
      throw const FormatException('Invalid channel search results.');
    }
    final videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
    final videos = <Video>[
      for (final row in data)
        if (row is Map<String, dynamic> &&
            row['videoId'] is String &&
            videoId.hasMatch(row['videoId'] as String) &&
            row['title'] != privateVideoString)
          Video.fromJson(row),
    ];
    final filtered = await VideoFilter.filterVideos(videos);
    await check();
    return (videos: filtered, rawCount: data.length);
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

  List<Playlist> getLocalPlaylists({IDbClient? database}) =>
      _localPlaylistsFromSetting(
          (database ?? db).getSettings(localPlaylistsSetting)?.value);

  static List<Playlist> _localPlaylistsFromSetting(String? stored) {
    final playlists = stored == null
        ? <Playlist>[]
        : (jsonDecode(stored) as List)
            .map((item) => Playlist.fromJson(Map<String, dynamic>.from(item)))
            .map(normalizeLocalPlaylistEntries)
            .map((playlist) => playlist.copyWith(
                videos: assignPlaylistEntryIds(playlist.videos)))
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

  Future<void> _updateLocalPlaylists(bool Function(List<Playlist>) update,
          {IDbClient? database, String? unlockingPlaylistId}) =>
      _updateLocalPlaylistStorage((playlists, _, __) => update(playlists),
          database: database, unlockingPlaylistId: unlockingPlaylistId);

  Future<void> _updateLocalPlaylistStorage(
      bool Function(List<Playlist>, List<DeletedMusicPlaylist>, DateTime)
          update,
      {IDbClient? database,
      bool Function()? isCurrent,
      String? unlockingPlaylistId}) async {
    final owner = database ?? db.forProfile(db.profileId);
    final profileId = owner.profileId;
    var recoveryChanged = false;
    Map<String, String?> apply(String? storedPlaylists, String? storedDeleted) {
      if (isCurrent?.call() == false) return {};
      final playlists = _localPlaylistsFromSetting(storedPlaylists);
      final activeIds =
          playlists.map((playlist) => playlist.playlistId).toSet();
      final now = _now().toUtc();
      final stored = DeletedMusicPlaylist.decode(storedDeleted);
      final deleted = _retainedMusicPlaylists(stored, activeIds, now);
      final playlistsChanged = _applyLocalPlaylistUpdate(
          playlists, (items) => update(items, deleted, now),
          unlockingPlaylistId: unlockingPlaylistId);
      recoveryChanged = !listEquals(stored, deleted);

      final purged = {
        for (final entry in stored)
          if (!now.isBefore(entry.expiresAt) &&
              !activeIds.contains(entry.playlist.playlistId))
            entry.playlist.playlistId,
        if (playlistsChanged)
          ...activeIds.difference({
            for (final playlist in playlists) playlist.playlistId,
            for (final entry in deleted) entry.playlist.playlistId,
          }),
      };
      return {
        if (playlistsChanged) localPlaylistsSetting: jsonEncode(playlists),
        if (recoveryChanged) deletedMusicPlaylistsSetting: jsonEncode(deleted),
        for (final id in purged.where(MusicPlaylistCovers.supports))
          MusicPlaylistCovers.settingName(id): null,
      };
    }

    if (owner is SembastSqfDb) {
      await owner.updateLocalPlaylistStorage(apply);
    } else {
      await (_localPlaylistWrite =
          _localPlaylistWrite.catchError((_) {}).then((_) async {
        final values = apply(owner.getSettings(localPlaylistsSetting)?.value,
            owner.getSettings(deletedMusicPlaylistsSetting)?.value);
        final saved = <SettingsValue>[];
        for (final entry in values.entries) {
          if (entry.value case final value?) {
            saved.add(SettingsValue(entry.key, value));
          }
        }
        if (saved.length == 1) await owner.saveSetting(saved.single);
        if (saved.length > 1) await owner.saveSettings(saved);
        for (final entry in values.entries) {
          if (entry.value == null && owner.getSettings(entry.key) != null) {
            await owner.deleteSetting(entry.key);
          }
        }
      }));
    }
    if (recoveryChanged) {
      MusicLibraryService.forProfile(owner, profileId).notifyChanged();
    }
  }

  List<DeletedMusicPlaylist> _retainedMusicPlaylists(
      List<DeletedMusicPlaylist> stored, Set<String> activeIds, DateTime now) {
    if (stored.isEmpty) return [];
    final retained = <DeletedMusicPlaylist>[];
    var dropped = 0;
    for (final entry in stored) {
      if (!now.isBefore(entry.expiresAt) ||
          activeIds.contains(entry.playlist.playlistId)) {
        dropped++;
      } else {
        retained.add(dropped == 0
            ? entry
            : entry.atPosition(
                (entry.position - dropped).clamp(0, entry.position)));
      }
    }
    return retained;
  }

  List<DeletedMusicPlaylist> getRecentlyDeletedMusicPlaylists(
      {IDbClient? database}) {
    final owner = database ?? db.forProfile(db.profileId);
    final deleted = DeletedMusicPlaylist.decode(
        owner.getSettings(deletedMusicPlaylistsSetting)?.value);
    if (deleted.isEmpty) return deleted;
    final activeIds = getLocalPlaylists(database: owner)
        .map((playlist) => playlist.playlistId)
        .toSet();
    return _retainedMusicPlaylists(deleted, activeIds, _now())
      ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  }

  bool _isRecoverableMusicPlaylist(Playlist playlist, IDbClient owner) =>
      playlist.playlistId != localWatchLaterId &&
      MusicLibraryService.forProfile(owner, owner.profileId)
          .isMusicPlaylist(playlist);

  bool canRecoverMusicPlaylist(String playlistId, {IDbClient? database}) {
    if (!playlistId.startsWith('local:') || playlistId == localWatchLaterId) {
      return false;
    }
    final owner = database ?? db.forProfile(db.profileId);
    return getLocalPlaylists(database: owner).any((playlist) =>
        playlist.playlistId == playlistId &&
        _isRecoverableMusicPlaylist(playlist, owner));
  }

  Future<bool> deleteMusicPlaylist(String playlistId,
          {required bool Function() isCurrent}) =>
      _deleteLocalPlaylist(playlistId,
          database: db.forProfile(db.profileId),
          requireMusic: true,
          isCurrent: isCurrent);

  Future<bool> _deleteLocalPlaylist(String playlistId,
      {required IDbClient database,
      bool requireMusic = false,
      bool Function()? isCurrent}) async {
    if (!playlistId.startsWith('local:') || playlistId == localWatchLaterId) {
      return false;
    }
    var removed = false;
    await _updateLocalPlaylistStorage((playlists, deleted, now) {
      final index = playlists.indexWhere((p) => p.playlistId == playlistId);
      if (index < 0) return false;
      final playlist = playlists[index];
      final recoverable = _isRecoverableMusicPlaylist(playlist, database);
      if (requireMusic && !recoverable) return false;
      var position = index;
      var slot = 0;
      while (slot < deleted.length && deleted[slot].position <= position) {
        position++;
        slot++;
      }
      if (recoverable) {
        deleted.insert(
            slot,
            DeletedMusicPlaylist(
                playlist: playlist,
                deletionId: const Uuid().v4(),
                deletedAt: now,
                position: position));
      } else {
        // Permanent deletion closes this slot for later restorations.
        for (var i = slot; i < deleted.length; i++) {
          deleted[i] = deleted[i].atPosition(deleted[i].position - 1);
        }
      }
      playlists.removeAt(index);
      removed = true;
      return true;
    }, database: database, isCurrent: isCurrent);
    return removed;
  }

  Future<bool> restoreMusicPlaylist(DeletedMusicPlaylist selection,
      {required bool Function() isCurrent}) async {
    var restored = false;
    await _updateLocalPlaylistStorage((playlists, deleted, _) {
      final index = deleted
          .indexWhere((entry) => entry.deletionId == selection.deletionId);
      if (index < 0) return false;
      final entry = deleted.removeAt(index);
      final position = (entry.position - index).clamp(0, playlists.length);
      playlists.insert(position, entry.playlist);
      restored = true;
      return true;
    }, isCurrent: isCurrent);
    return restored;
  }

  static bool _applyLocalPlaylistUpdate(
      List<Playlist> playlists, bool Function(List<Playlist>) update,
      {String? unlockingPlaylistId}) {
    final locked =
        playlists.where((playlist) => playlist.isEditLocked).toList();
    if (!update(playlists)) return false;
    if (locked.isEmpty) return true;

    final updated = {
      for (final playlist in playlists) playlist.playlistId: playlist
    };
    for (final before in locked) {
      final allowed = before.playlistId == unlockingPlaylistId
          ? before.copyWith(localEditLocked: false)
          : before;
      if (updated[before.playlistId] != allowed) {
        throw StateError('Playlist editing is locked');
      }
    }
    return true;
  }

  Future<bool> setLocalPlaylistEditLocked(PlaylistReference source,
      {required bool locked, required bool Function() isCurrent}) async {
    if (!_canEditLocalPlaylist(source)) return false;
    final owner = db.forProfile(source.profileId);
    var found = false;
    await _updateLocalPlaylists((playlists) {
      if (!_canEditLocalPlaylist(source) || !isCurrent()) return false;
      final index = playlists
          .indexWhere((p) => p.isLocal && p.playlistId == source.playlistId);
      if (index < 0) return false;
      found = true;
      final playlist = playlists[index];
      if (playlist.isEditLocked == locked) return false;
      playlists[index] = playlist.copyWith(localEditLocked: locked);
      return true;
    }, database: owner, unlockingPlaylistId: locked ? null : source.playlistId);
    return found;
  }

  /// Commit a permutation only if the draft still describes the stored list.
  Future<bool> reorderLocalPlaylist(PlaylistReference source,
      {required List<String> expectedOrder,
      required List<String> order,
      required bool Function() isCurrent}) async {
    if (!_canEditLocalPlaylist(source)) return false;
    final expected = List.of(expectedOrder);
    final proposed = List.of(order);
    if (listEquals(expected, proposed) ||
        proposed.length != expected.length ||
        proposed.toSet().length != expected.length) {
      return false;
    }

    final owner = db.forProfile(source.profileId);
    var moved = false;
    await _updateLocalPlaylists((playlists) {
      if (!_canEditLocalPlaylist(source) || !isCurrent()) return false;
      final index = playlists
          .indexWhere((p) => p.isLocal && p.playlistId == source.playlistId);
      if (index < 0) return false;
      final playlist = playlists[index];
      if (playlist.isEditLocked ||
          !listEquals(expected,
              playlist.videos.map((video) => video.indexId).toList())) {
        return false;
      }
      final byId = {for (final video in playlist.videos) video.indexId: video};
      if (!proposed.every(byId.containsKey)) return false;
      playlists[index] = playlist.copyWith(
        videos: [for (final id in proposed) byId[id]!],
        updated: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      moved = true;
      return true;
    }, database: owner);
    return moved;
  }

  bool _canEditLocalPlaylist(PlaylistReference source) =>
      source.kind == PlaylistSourceKind.local &&
      source.playlistId != localWatchLaterId &&
      source.matchesOwner(db);

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
    if (type == 'local') {
      return createLocalPlaylistWithEntries(name, const []);
    }
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('Enter a playlist name');
    return createServerPlaylist(
        name, type, await db.getCurrentlySelectedServer());
  }

  /// Save an ordered playlist and its initial occurrences in one write.
  Future<String?> createLocalPlaylistWithEntries(
      String title, List<Video> videos,
      {IDbClient? database, bool Function()? isCurrent}) async {
    final name = title.trim();
    if (name.isEmpty) throw ArgumentError('Enter a playlist name');
    final id = 'local:${const Uuid().v4()}';
    final entries = videos.map(_newLocalPlaylistEntry).toList();
    var created = false;
    await _updateLocalPlaylists((playlists) {
      if (isCurrent?.call() == false) return false;
      playlists.add(Playlist(
          title: name,
          playlistId: id,
          author: '',
          videos: entries,
          videoCount: entries.length,
          updated: DateTime.now().millisecondsSinceEpoch ~/ 1000));
      created = true;
      return true;
    }, database: database);
    return created ? id : null;
  }

  Future<String> createServerPlaylist(
      String name, String privacy, Server server) async {
    var req = await buildRequest(urlPostUserPlaylists,
        authenticated: true, forceJson: true, serverOverride: server);

    Map<String, String> body = {
      'title': name,
      'privacy': privacy,
    };

    final response = await _instanceHttpClient.post(req.uri,
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
      await appendLocalPlaylistEntries(
          playListId, [savedVideo.copyWith(videoId: videoId)],
          database: owner);
      return;
    }
    await addVideoToServerPlaylist(
        playListId, videoId, await owner.getCurrentlySelectedServer());
  }

  /// Append in source order with a fresh identity for each admitted copy.
  /// Membership is checked against the latest list within the write.
  Future<int> appendLocalPlaylistEntries(String playlistId, List<Video> videos,
      {bool allowDuplicates = false,
      IDbClient? database,
      bool Function()? isCurrent}) async {
    if (!playlistId.startsWith('local:')) {
      throw ArgumentError('Choose a local playlist');
    }
    final requested = List<Video>.of(videos);
    var added = 0;
    await _updateLocalPlaylists((playlists) {
      if (isCurrent?.call() == false) return false;
      final index = playlists.indexWhere((p) => p.playlistId == playlistId);
      if (index < 0) throw StateError('Playlist no longer exists');
      final playlist = playlists[index];
      final recorded = playlist.videos.map((entry) => entry.videoId).toSet();
      final entries = [
        for (final video in requested)
          if (allowDuplicates || recorded.add(video.videoId))
            _newLocalPlaylistEntry(video),
      ];
      if (entries.isEmpty) return false;
      added = entries.length;
      final updated = [...playlist.videos, ...entries];
      playlists[index] = playlist.copyWith(
          videos: updated,
          videoCount: updated.length,
          updated: DateTime.now().millisecondsSinceEpoch ~/ 1000);
      return true;
    }, database: database);
    return added;
  }

  // Persist display metadata only. Obtain transport URLs at playback.
  static Video _newLocalPlaylistEntry(Video video) {
    if (video.videoId.startsWith('device:')) {
      final music = video.musicMetadata;
      if (devicePlaylistFileProof(video.videoId) == null ||
          music == null ||
          music.title.trim().isEmpty) {
        throw ArgumentError('Invalid device playlist entry');
      }
      return Video(
        videoId: video.videoId,
        indexId: const Uuid().v4(),
        title: music.title,
        author: music.artist,
        lengthSeconds: video.lengthSeconds,
        musicMetadata: MusicMetadata(
            title: music.title, artist: music.artist, album: music.album),
      );
    }
    return Video(
      videoId: video.videoId,
      indexId: const Uuid().v4(),
      title: video.title,
      author: video.author,
      authorId: video.authorId,
      authorUrl: video.authorUrl,
      lengthSeconds: video.lengthSeconds,
      videoThumbnails: video.videoThumbnails,
      musicMetadata: video.musicMetadata,
    );
  }

  Future<void> addVideoToServerPlaylist(
      String playListId, String videoId, Server server) async {
    if (videoId.startsWith('device:')) {
      throw ArgumentError('Device files can only be saved in local playlists');
    }
    var req = await buildRequest(urlPostUserPlaylistVideo,
        pathParams: {":id": playListId},
        authenticated: true,
        forceJson: true,
        serverOverride: server);

    Map<String, String> body = {
      'videoId': videoId,
    };

    final response = await _instanceHttpClient.post(req.uri,
        headers: req.headers, body: jsonEncode(body));
    handleResponse(response);
  }

  Future<void> deleteUserPlaylist(String playListId,
      {IDbClient? database, Server? serverOverride}) async {
    final owner = database ?? db.forProfile(db.profileId);
    if (playListId.startsWith('local:')) {
      await _deleteLocalPlaylist(playListId, database: owner);
      return;
    }
    var req = await buildRequest(urlDeleteUserPlaylist,
        pathParams: {":id": playListId},
        authenticated: true,
        forceJson: true,
        serverOverride:
            serverOverride ?? await owner.getCurrentlySelectedServer());

    final response =
        await _instanceHttpClient.delete(req.uri, headers: req.headers);
    handleResponse(response);
  }

  Future<bool> renameLocalPlaylist(PlaylistReference source, String name,
      {required bool Function() isCurrent}) async {
    final title = name.trim();
    if (title.isEmpty) throw ArgumentError('Enter a playlist name');
    if (source.kind != PlaylistSourceKind.local ||
        source.playlistId == localWatchLaterId ||
        !source.matchesOwner(db)) {
      return false;
    }
    final owner = db.forProfile(source.profileId);
    var found = false;
    await _updateLocalPlaylists((playlists) {
      if (!source.matchesOwner(db) || !isCurrent()) return false;
      final index =
          playlists.indexWhere((item) => item.playlistId == source.playlistId);
      if (index < 0) return false;
      found = true;
      final playlist = playlists[index];
      if (playlist.title == title) return false;
      playlists[index] = playlist.copyWith(title: title);
      return true;
    }, database: owner);
    return found;
  }

  Future<void> deleteUserPlaylistVideo(String playListId, String indexId,
      {IDbClient? database, Server? serverOverride}) async {
    final owner = database ?? db.forProfile(db.profileId);
    if (playListId.startsWith('local:')) {
      await _updateLocalPlaylists((playlists) {
        final index = playlists.indexWhere((p) => p.playlistId == playListId);
        if (index < 0) return true;
        final videos =
            playlists[index].videos.where((v) => v.videoId != indexId).toList();
        playlists[index] = playlists[index].copyWith(
            videos: videos,
            videoCount: videos.length,
            updated: DateTime.now().millisecondsSinceEpoch ~/ 1000);
        return true;
      }, database: owner);
      return;
    }
    final req = await buildRequest(urlDeleteUserPlaylistVideo,
        pathParams: {':id': playListId, ':index': indexId},
        authenticated: true,
        forceJson: true,
        serverOverride:
            serverOverride ?? await owner.getCurrentlySelectedServer());

    final response =
        await _instanceHttpClient.delete(req.uri, headers: req.headers);
    handleResponse(response);
  }

  /// The stored local playlist must contain exactly this source occurrence.
  Playlist? getLocalPlaylistWithUniqueEntry(
      PlaylistReference source, Video entry) {
    if (source.kind != PlaylistSourceKind.local || !source.matchesOwner(db)) {
      return null;
    }
    return _findLocalPlaylistOccurrence(
            getLocalPlaylists(database: db.forProfile(source.profileId)),
            source.playlistId,
            entry)
        ?.$1;
  }

  static (Playlist, Video)? _findLocalPlaylistOccurrence(
      List<Playlist> playlists, String id, Video entry) {
    final candidates = playlists
        .where((playlist) => playlist.isLocal && playlist.playlistId == id);
    final playlist = candidates.singleOrNull;
    if (playlist == null) return null;
    final saved = playlist.videos
        .where((video) => matchesLocalPlaylistEntryKey(
            id, video, entry.videoId, entry.queueEntryId))
        .singleOrNull;
    return saved == null ? null : (playlist, saved);
  }

  /// Keeps the final membership and player checks inside the playlist write.
  Future<bool> removeUniqueLocalPlaylistEntry(
      PlaylistReference source, Video entry, String expectedTitle,
      {required bool Function() isCurrent}) async {
    if (source.kind != PlaylistSourceKind.local || !source.matchesOwner(db)) {
      return false;
    }
    return _removeLocalPlaylistEntry(source.playlistId, entry,
        database: db.forProfile(source.profileId),
        expectedTitle: expectedTitle,
        isCurrent: () => source.matchesOwner(db) && isCurrent());
  }

  Future<bool> removeLocalPlaylistEntry(String playlistId, Video entry,
          {IDbClient? database, bool Function()? isCurrent}) =>
      _removeLocalPlaylistEntry(playlistId, entry,
          database: database, isCurrent: isCurrent);

  Future<bool> _removeLocalPlaylistEntry(String playlistId, Video entry,
      {IDbClient? database,
      String? expectedTitle,
      bool Function()? isCurrent}) async {
    if (!playlistId.startsWith('local:')) {
      throw ArgumentError('Choose a local playlist');
    }
    var removed = false;
    await _updateLocalPlaylists((playlists) {
      if (isCurrent?.call() == false) return false;
      final match = _findLocalPlaylistOccurrence(playlists, playlistId, entry);
      if (match == null) return false;
      final (playlist, saved) = match;
      if (expectedTitle != null && playlist.title != expectedTitle) {
        return false;
      }
      final videos = playlist.videos
          .where((video) => video.indexId != saved.indexId)
          .toList();
      playlists[playlists.indexOf(playlist)] = playlist.copyWith(
          videos: videos,
          videoCount: videos.length,
          updated: DateTime.now().millisecondsSinceEpoch ~/ 1000);
      removed = true;
      return true;
    }, database: database);
    return removed;
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

  Future<List<String>> getPlaybackHistoryPage(
          PlaybackHistoryOrigin origin, int page, int maxResults) async =>
      _localHistoryPage(db.forProfile(db.profileId), page, maxResults,
          origin: origin);

  List<String> _localHistoryPage(IDbClient owner, int page, int maxResults,
          {PlaybackHistoryOrigin? origin}) =>
      (origin == null
              ? owner.getLocalHistory()
              : owner.getPlaybackHistory(origin))
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
                    ? await _instanceHttpClient.post(req.uri,
                        headers: req.headers)
                    : await _instanceHttpClient.delete(req.uri,
                        headers: req.headers);
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
      final response =
          await _instanceHttpClient.delete(req.uri, headers: req.headers);
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
      final response =
          await _instanceHttpClient.delete(req.uri, headers: req.headers);
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

    final response =
        await _instanceHttpClient.post(req.uri, headers: req.headers);
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
  Future<Playlist> getMix(String mixId,
      {Server? serverOverride,
      bool enrichResults = true,
      Future<void> Function()? beforeRequest}) async {
    final req = await buildRequest(urlGetMix,
        pathParams: {':id': mixId}, serverOverride: serverOverride);
    final data = handleResponse(await _get(req, beforeRequest: beforeRequest));
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
    final videos =
        await postProcessVideos(source, enrichResults: enrichResults);
    return Playlist(
        playlistId: mixId,
        title: data['title'] as String,
        author: '',
        videoCount: source.length,
        videos: videos,
        removedByFilter: source.length - videos.length);
  }

  Future<Playlist> getPublicPlaylists(String playlistId,
          {int? page,
          bool saveLastSeen = true,
          Server? serverOverride,
          bool enrichResults = true}) =>
      _getPublicPlaylists(playlistId,
          page: page,
          saveLastSeen: saveLastSeen,
          serverOverride: serverOverride,
          enrichResults: enrichResults);

  Future<Playlist> getMusicPlaylistPage(String playlistId, int page,
          Server server, Future<void> Function() beforeRequest) =>
      _getPublicPlaylists(playlistId,
          page: page,
          saveLastSeen: false,
          serverOverride: server,
          enrichResults: false,
          beforeRequest: beforeRequest);

  Future<Playlist> _getPublicPlaylists(String playlistId,
      {int? page,
      required bool saveLastSeen,
      Server? serverOverride,
      required bool enrichResults,
      Future<void> Function()? beforeRequest}) async {
    if (playlistId.startsWith('local:')) {
      return getUserPlaylist(playlistId, serverOverride: serverOverride);
    }
    final req = await buildRequest(urlGetPublicPlaylist,
        pathParams: {':id': playlistId},
        query: {'page': page?.toString()},
        serverOverride: serverOverride);

    final response = await _get(req, beforeRequest: beforeRequest);
    final data = handleResponse(response);
    var playlist = Playlist.fromJson(data);
    // The public endpoint writes authorId. Keep the model's older internal
    // spelling for persisted playlists and decode this endpoint's wire key.
    if (data['authorId'] case final String authorId) {
      playlist = playlist.copyWith(authordId: authorId);
    }
    var oldLength = playlist.videos.length;
    final videos =
        await postProcessVideos(playlist.videos, enrichResults: enrichResults);
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
    var playlist = await getServerPlaylist(playlistId,
        page: page, serverOverride: serverOverride);
    var oldLength = playlist.videos.length;
    final videos = await postProcessVideos(playlist.videos);
    return playlist.copyWith(
        videos: videos, removedByFilter: oldLength - videos.length);
  }

  /// Read exact server entries when reconciling a partially completed copy.
  Future<Playlist> getServerPlaylist(String playlistId,
      {int? page, Server? serverOverride}) async {
    final req = await buildRequest(urlGetUserPlaylist,
        pathParams: {':id': playlistId},
        query: {'page': page?.toString()},
        authenticated: true,
        serverOverride: serverOverride);

    final response = await _get(req);
    return Playlist.fromJson(handleResponse(response))
        .copyWith(type: invidiousPlaylist);
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
