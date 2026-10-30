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

  Future<Server> _saveDiscoveredBackends(BackendSelector selector) async {
    // Discovery may finish after another settings edit. Preserve all current
    // credentials, routing cookies and the user's automatic-fallback setting.
    final latest = db.getServer(state.server.url);
    if (latest == null) throw StateError('Server no longer exists');
    final updated = latest.copyWith(
        backendSelector: selector.copyWith(
            automaticFallback:
                latest.backendSelector?.automaticFallback ?? false));
    await _saveBackendServer(updated);
    return updated;
  }

  Future<void> setBackend(String? value, bool automaticFallback) async {
    // Read the saved record so another settings change cannot lose its headers
    // or credentials when this screen was opened with an older snapshot.
    final saved = db.getServer(state.server.url);
    if (saved == null) throw StateError('Server no longer exists');
    final selector = saved.backendSelector;
    if (selector == null) throw StateError('Discover available backends first');
    final updated = selector
        .copyWith(automaticFallback: automaticFallback)
        .withSelection(saved, value);
    await _saveBackendServer(updated);
  }

  Future<void> _saveBackendServer(Server updated) async {
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
    final Map<String, String> headers = Map.from(state.server.customHeaders);
    headers[key] = value;
    emit(state.copyWith.server(customHeaders: headers));
    await db.upsertServer(state.server);
    await fileDb.upsertServer(state.server);
  }

  Future<void> removeHeader(String key) async {
    final Map<String, String> headers = Map.from(state.server.customHeaders);
    headers.remove(key);
    emit(state.copyWith.server(customHeaders: headers));
    await db.upsertServer(state.server);
    await fileDb.upsertServer(state.server);
  }

  Future<void> logOut() async {
    Server s = state.server.copyWith(sidCookie: null, authToken: null);
    await db.upsertServer(s);
    if (s.inUse) {
      await fileDb.useServer(s);
    }
    emit(state.copyWith(server: s));
    // we only refresh the app if the app is currently on this server
    if (app.state.server?.url == s.url) {
      app.setServer(s.copyWith());
    }
  }

  Future<void> logInWithToken() async {
    var s = state.server.copyWith();
    await service.logIn(s.url);
    Server server = db.getServer(s.url)!;
    emit(state.copyWith(server: s));
    // we only refresh the app if the app is currently on this server
    if (app.state.server?.url == server.url) {
      app.setServer(server.copyWith());
    }
  }

  Future<void> logInWithCookie(String username, String password) async {
    var s = state.server.copyWith();
    String cookie = await service.loginWithCookies(s.url, username, password,
        headers: s.customHeaders);
    s = s.copyWith(sidCookie: cookie);
    await db.upsertServer(s);
    if (s.inUse) {
      fileDb.useServer(s);
    }
    emit(state.copyWith(server: s));
    // we only refresh the app if the app is currently on this server
    if (app.state.server?.url == s.url) {
      app.setServer(s);
    }
  }

  Future<void> deleteServer() async {
    await db.deleteServer(state.server);

    Server currentServer = await db.getCurrentlySelectedServer();
    emit(state.copyWith());
    app.setServer(currentServer);
  }

  Future<void> canDelete() async {
    bool canDelete = (await db.getServers()).length > 1;
    emit(state.copyWith(canDelete: canDelete));
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
