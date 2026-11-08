import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../app/states/app.dart';
import '../../globals.dart';
import '../../network/nerdvpn_access.dart';
import '../../utils/interfaces/db.dart';
import '../models/db/server.dart';
import '../models/backend_selector.dart';
import '../services/backend_discovery.dart';

part 'server_settings.freezed.dart';

class ServerSettingsCubit extends Cubit<ServerSettingsState> {
  final AppCubit app;
  final IDbClient _profileDb;
  Future<void> _serverUpdates = Future.value();

  ServerSettingsCubit(super.initialState, this.app)
      : _profileDb = db.forProfile(initialState.server.profileId) {
    canDelete();
  }

  Future<void> useServer(bool value) async {
    final server = await app.switchServer(state.server);
    if (!isClosed && server != null) emit(state.copyWith(server: server));
  }

  Future<Server> discoverBackends() async {
    final saved = _profileDb.getAccount(state.server.accountId);
    if (saved == null) throw StateError('Server no longer exists');
    final selector = await BackendDiscovery(service.httpClient).discover(saved);
    return _saveDiscoveredBackends(selector);
  }

  Future<Server> discoverBrowserBackends(
      {required Uri pageUri, required String source}) async {
    final saved = _profileDb.getAccount(state.server.accountId);
    if (saved == null) throw StateError('Server no longer exists');
    final selector = await BackendDiscovery(service.httpClient)
        .discoverBrowserPage(saved, pageUri: pageUri, source: source);
    return _saveDiscoveredBackends(selector);
  }

  Future<Server> _saveDiscoveredBackends(BackendSelector selector) {
    // Discovery may finish after another settings edit. Preserve all current
    // credentials, routing cookies and the user's automatic-fallback setting.
    return _updateServer((latest) => latest.copyWith(
        backendSelector: selector.copyWith(
            automaticFallback:
                latest.backendSelector?.automaticFallback ?? true)));
  }

  Future<void> setBackend(String? value, bool automaticFallback) async {
    // Read the saved record so another settings change cannot lose its headers
    // or credentials when this screen was opened with an older snapshot.
    await _updateServer((saved) {
      final selector = saved.backendSelector;
      if (selector == null) {
        throw StateError('Discover available backends first');
      }
      return selector
          .copyWith(automaticFallback: automaticFallback)
          .withSelection(saved, value);
    });
  }

  Server _savedServer() {
    final saved = _profileDb.getAccount(state.server.accountId);
    if (saved == null) throw StateError('Server no longer exists');
    return saved;
  }

  Future<Server> _updateServer(Server Function(Server) update) {
    final result = _serverUpdates.then((_) async {
      final updated = update(_savedServer());
      await _saveServer(updated);
      return updated;
    });
    // Keep later edits usable after a failed save; callers still receive errors.
    _serverUpdates = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _saveServer(Server updated) async {
    await _profileDb.upsertServer(updated);

    // Editing an inactive server must not switch background jobs to it.
    if (db.profileId != updated.profileId) {
      if (!isClosed) emit(state.copyWith(server: updated));
      return;
    }
    final selected = await db.getCurrentlySelectedServer();
    if (selected.accountId == updated.accountId &&
        selected.profileId == updated.profileId) {
      await fileDb.refreshAccount(selected);
      if (!app.isClosed && _isActive(selected)) {
        app.setServer(selected);
      }
    }
    if (!isClosed) emit(state.copyWith(server: updated));
  }

  Future<void> addHeader(String key, String value) async {
    if (NerdVpnAccess.supports(state.server) &&
        key.toLowerCase() == 'x-invidious-token') {
      await setApiKey(value);
      return;
    }
    await _updateServer((saved) => saved.copyWith(customHeaders: {
          ...saved.customHeaders,
          key: value,
        }));
  }

  Future<void> setApiKey(String value) => _authenticate(() async {
        final server = _savedServer();
        await NerdVpnAccess.instance.setKey(server, value.trim());
        await _updateServer((saved) => saved.copyWith(
            customHeaders: Map<String, String>.from(saved.customHeaders)
              ..removeWhere(
                  (name, _) => name.toLowerCase() == 'x-invidious-token')));
        service.clearSessionCaches();
      });

  Future<void> checkApiAccess() => _authenticate(() async {
        await service.checkNerdVpnAccess(_savedServer());
        final saved = _savedServer();
        if (!isClosed) emit(state.copyWith(server: saved));
        if (!app.isClosed && _isActive(saved)) app.setServer(saved);
      });

  Future<void> removeHeader(String key) async {
    await _updateServer((saved) => saved.copyWith(
        customHeaders: Map<String, String>.from(saved.customHeaders)
          ..remove(key)));
  }

  Future<void> logOut() async {
    // Logout must also invalidate an in-progress sign-in. Do not use the
    // authentication guard, which would ignore logout while that flow is busy.
    if (isClosed) return;
    emit(state.copyWith(authenticating: true));
    try {
      await service.logOutProtected(_savedServer());
      final latest = _savedServer();
      if (!isClosed) emit(state.copyWith(server: latest));
      if (!app.isClosed && _isActive(latest)) app.setServer(latest);
    } finally {
      // A manual-key-only logout leaves the server record equal; this state
      // transition still refreshes the separately stored API-access status.
      if (!isClosed) emit(state.copyWith(authenticating: false));
    }
  }

  Future<void> _authenticate(Future<void> Function() action) async {
    if (isClosed || state.authenticating) return;
    emit(state.copyWith(authenticating: true));
    try {
      await action();
    } finally {
      if (!isClosed) emit(state.copyWith(authenticating: false));
    }
  }

  Future<void> logInWithToken() => _authenticate(() async {
        final serverAtStart = _savedServer();
        await service.logIn(serverAtStart.accountId,
            profileId: serverAtStart.profileId);
        final server = _savedServer();
        if (!isClosed) emit(state.copyWith(server: server));
        // Only refresh the app if it is still on the authenticated server.
        if (!app.isClosed && _isActive(server)) {
          app.setServer(server);
        }
      });

  Future<void> logInWithCookie(String username, String password) =>
      _authenticate(() async {
        final saved = _savedServer();
        await service.logInAccountWithCookie(saved, username, password);
        final latest = _savedServer();
        if (!isClosed) emit(state.copyWith(server: latest));
        if (!app.isClosed && _isActive(latest)) app.setServer(latest);
      });

  Future<void> logInProtected() => _authenticate(() async {
        await service.logInProtected(_savedServer());
        final saved = _savedServer();
        if (!isClosed) emit(state.copyWith(server: saved));
        if (!app.isClosed && _isActive(saved)) app.setServer(saved);
      });

  Future<void> renameAccount(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 80) {
      throw const FormatException(
          'Account name must contain 1 to 80 characters');
    }
    await _updateServer((saved) => saved.copyWith(name: clean));
  }

  bool _isActive(Server server) =>
      db.profileId == server.profileId &&
      app.state.server?.profileId == server.profileId &&
      app.state.server?.accountId == server.accountId;

  bool get isActiveProfile => db.profileId == state.server.profileId;

  Future<void> _deleteGatewaySession(Server server) async {
    await service.logOutProtected(server);
  }

  Future<void> deleteServer() async {
    if ((await _profileDb.getServers()).length < 2) return;
    await _deleteGatewaySession(_savedServer());
    await _profileDb.deleteServer(state.server);

    if (!isActiveProfile) return;
    final currentServer = await _profileDb.getCurrentlySelectedServer();
    if (!app.isClosed) await app.switchServer(currentServer);
  }

  Future<void> canDelete() async {
    bool canDelete = (await _profileDb.getServers()).length > 1;
    if (!isClosed) emit(state.copyWith(canDelete: canDelete));
  }
}

@freezed
sealed class ServerSettingsState with _$ServerSettingsState {
  const factory ServerSettingsState(
      {required Server server,
      @Default(false) bool authenticating,
      @Default(false) bool canDelete}) = _ServerSettingsState;

  const ServerSettingsState._();

  bool get hasBasicAuth => server.customHeaders.containsKey("Authorization");
}
