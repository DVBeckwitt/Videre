import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../app/states/app.dart';
import '../../globals.dart';
import '../models/db/server.dart';
import '../models/backend_selector.dart';
import '../services/backend_discovery.dart';

part 'server_settings.freezed.dart';

class ServerSettingsCubit extends Cubit<ServerSettingsState> {
  final AppCubit app;
  Future<void> _serverUpdates = Future.value();

  ServerSettingsCubit(super.initialState, this.app) {
    canDelete();
  }

  Future<void> useServer(bool value) async {
    final server = await app.switchServer(state.server);
    if (!isClosed && server != null) emit(state.copyWith(server: server));
  }

  Future<Server> discoverBackends() async {
    final saved = db.getServer(state.server.url);
    if (saved == null) throw StateError('Server no longer exists');
    final selector = await BackendDiscovery(service.httpClient).discover(saved);
    return _saveDiscoveredBackends(selector);
  }

  Future<Server> discoverBrowserBackends(
      {required Uri pageUri, required String source}) async {
    final saved = db.getServer(state.server.url);
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
    final saved = db.getServer(state.server.url);
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
    await db.upsertServer(updated);

    // Editing an inactive server must not switch background jobs to it.
    final selected = await db.getCurrentlySelectedServer();
    if (selected.url == updated.url) {
      await fileDb.useServer(selected);
      if (!app.isClosed && app.state.server?.url == selected.url) {
        app.setServer(selected);
      }
    }
    if (!isClosed) emit(state.copyWith(server: updated));
  }

  Future<void> addHeader(String key, String value) async {
    await _updateServer((saved) => saved.copyWith(customHeaders: {
          ...saved.customHeaders,
          key: value,
        }));
  }

  Future<void> removeHeader(String key) async {
    await _updateServer((saved) => saved.copyWith(
        customHeaders: Map<String, String>.from(saved.customHeaders)
          ..remove(key)));
  }

  Future<void> logOut() async {
    await _updateServer(
        (saved) => saved.copyWith(sidCookie: null, authToken: null));
  }

  Future<void> logInWithToken() async {
    final serverUrl = state.server.url;
    await service.logIn(serverUrl);
    final server = _savedServer();
    if (!isClosed) emit(state.copyWith(server: server));
    // Only refresh the app if it is still on the authenticated server.
    if (!app.isClosed && app.state.server?.url == server.url) {
      app.setServer(server);
    }
  }

  Future<void> logInWithCookie(String username, String password) async {
    final saved = _savedServer();
    final cookie = await service.loginWithCookies(saved.url, username, password,
        headers: saved.customHeaders);
    // Authentication can outlive this screen or another server edit/switch.
    await _updateServer((latest) => latest.copyWith(sidCookie: cookie));
  }

  Future<void> deleteServer() async {
    await db.deleteServer(state.server);

    final currentServer = await db.getCurrentlySelectedServer();
    await fileDb.useServer(currentServer);
    if (!app.isClosed) app.setServer(currentServer);
  }

  Future<void> canDelete() async {
    bool canDelete = (await db.getServers()).length > 1;
    if (!isClosed) emit(state.copyWith(canDelete: canDelete));
  }
}

@freezed
sealed class ServerSettingsState with _$ServerSettingsState {
  const factory ServerSettingsState(
      {required Server server,
      @Default(false) bool canDelete}) = _ServerSettingsState;

  const ServerSettingsState._();

  bool get hasBasicAuth => server.customHeaders.containsKey("Authorization");
}
