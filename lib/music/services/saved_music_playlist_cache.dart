part of 'invidious_music_catalog_service.dart';

const _temporaryPlaylistAccessErrors = {'rateLimited', 'unavailable'};

typedef _PlaylistGatewayIdentity = (bool, int?, int?, int?);
typedef _SavedPlaylistScopeKey = ({
  Object owner,
  Service api,
  int sessionRevision,
  int proxyRevision,
  String connection,
  _PlaylistGatewayIdentity? gateway,
});

/// The cache key holds only a fingerprint of the server credentials and headers.
String _playlistConnection(Server server) {
  final headers = server.customHeaders.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return sha256
      .convert(utf8.encode(jsonEncode([
        server.profileId,
        server.accountId,
        server.url,
        server.gatewayEnabled,
        server.authToken,
        server.sidCookie,
        for (final header in headers) [header.key, header.value],
        server.backendSelector?.toJson(),
      ])))
      .toString();
}

Future<_PlaylistGatewayIdentity?> _playlistGatewayIdentity(
    Server server) async {
  final nerdVpn = NerdVpnAccess.supports(server);
  if (!server.gatewayEnabled && !nerdVpn) return null;
  final context = GatewayRequestContext.forAccount(
      server.profileId, server.accountId, server.url);
  if (context == null) return null;
  final state = await GatewaySessionBridge.instance
      .resolve(context.encoded, context.origin);
  final manualKey = state.apiKeyRevision == 0 &&
      const {'missing', 'signInRequired'}.contains(state.accessError) &&
      server.customHeaders.entries.any((header) =>
          header.key.toLowerCase() == nerdVpnKeyHeader.toLowerCase() &&
          header.value.isNotEmpty);
  if (state.needsSignIn ||
      nerdVpn &&
          state.accessError != null &&
          !_temporaryPlaylistAccessErrors.contains(state.accessError) &&
          !manualKey) {
    throw const MusicPlaylistAccessChanged();
  }
  if (_temporaryPlaylistAccessErrors.contains(state.accessError) &&
      state.apiKeyIntent == null) {
    throw NerdVpnAccessRequired(state.accessError!);
  }
  // Recovery can replace a key without changing the credential owner's intent.
  return (
    state.enabled,
    state.revision,
    state.apiKeyIntent,
    state.apiKeyIntent == null ? state.apiKeyRevision : null
  );
}

bool _retiresSavedPlaylist(Object error) => switch (error) {
      MusicPlaylistAccessChanged() || GatewayAuthenticationRequired() => true,
      NerdVpnAccessRequired(:final state) =>
        !_temporaryPlaylistAccessErrors.contains(state),
      InvidiousServiceError() => error.isAuthenticationFailure ||
          const {403, 404, 410}.contains(error.statusCode) ||
          error.isGatewayAccessFailure &&
              !const {'rate_limited', 'unavailable'}.contains(error.errorCode),
      _ => false,
    };

/// Holds only the active connection's playlist metadata. Refresh stages its
/// result until every page has been validated.
class _SavedPlaylistScope {
  static const freshness = Duration(minutes: 15);
  static const _maximumSnapshots = 8;
  static const _maximumTracks = 10000;

  final _SavedPlaylistScopeKey key;
  final MusicLibraryService _library;
  final _entries = <String, _SavedPlaylistEntry>{};
  bool _disposed = false;

  _SavedPlaylistScope(this.key, this._library) {
    _library.changes.addListener(_pruneBookmarks);
  }

  _SavedPlaylistEntry entry(String id) {
    final entry = _entries.remove(id) ?? _SavedPlaylistEntry();
    return _entries[id] = entry;
  }

  bool owns(String id, _SavedPlaylistEntry entry) =>
      !_disposed &&
      !entry.invalidated &&
      _library.contains(MusicLibraryKind.playlist, id);

  bool canFinish(String id, _SavedPlaylistEntry entry) =>
      !_disposed &&
      (!entry.invalidated || !_library.contains(MusicLibraryKind.playlist, id));

  void store(String id, _SavedPlaylistEntry entry, MusicCollection? collection,
      DateTime time) {
    if (!identical(_entries[id], entry) || !owns(id, entry)) return;
    entry.snapshot =
        collection == null ? null : (collection: collection, time: time);
    _entries.remove(id);
    _entries[id] = entry;
    final cached =
        _entries.entries.where((item) => item.value.snapshot != null).toList();
    var tracks = cached.fold<int>(0,
        (total, item) => total + item.value.snapshot!.collection.tracks.length);
    var count = cached.length;
    for (final item in cached) {
      if (count <= _maximumSnapshots && tracks <= _maximumTracks) break;
      tracks -= item.value.snapshot!.collection.tracks.length;
      count--;
      item.value.snapshot = null;
      removeEmpty(item.key, item.value);
    }
  }

  void removeEmpty(String id, _SavedPlaylistEntry entry) {
    if (entry.snapshot == null &&
        entry.request == null &&
        identical(_entries[id], entry)) {
      _entries.remove(id);
    }
  }

  void _pruneBookmarks() {
    _entries.removeWhere((id, entry) {
      if (owns(id, entry)) return false;
      entry.invalidated = true;
      entry.snapshot = null;
      return true;
    });
  }

  void dispose() {
    _disposed = true;
    _library.changes.removeListener(_pruneBookmarks);
    _entries.clear();
  }
}

class _SavedPlaylistEntry {
  ({MusicCollection collection, DateTime time})? snapshot;
  _SavedPlaylistRequest? request;
  bool invalidated = false;
}

class _SavedPlaylistRequest {
  Future<MusicCollection>? result;
  MusicCollection? prefix;
  final observers = <void Function(MusicCollection)>{};

  void publish(MusicCollection collection) {
    prefix = collection;
    for (final observer in observers.toList()) {
      observer(collection);
    }
  }
}
