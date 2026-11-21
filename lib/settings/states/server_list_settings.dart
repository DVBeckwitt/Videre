import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';

import '../../app/states/app.dart';
import '../../globals.dart';
import '../../network/media_companion.dart';
import '../../utils/interfaces/db.dart';
import '../models/db/server.dart';

class ServerListSettingsCubit extends Cubit<ServerListSettingsState> {
  final AppCubit appCubit;
  final IDbClient _profileDb = db.forProfile(db.profileId);

  ServerListSettingsCubit(super.initialState, this.appCubit) {
    refreshServers();
  }

  Future<void> refreshServers() async {
    final servers = await _profileDb.getServers();
    if (!isClosed) emit(state.copyWith(dbServers: servers));
  }

  bool isLoggedInToServer(String accountId) {
    Server server = state.dbServers.firstWhere((s) => s.accountId == accountId,
        orElse: () => const Server(url: 'notFound'));

    return (server.authToken?.isNotEmpty ?? false) ||
        (server.sidCookie?.isNotEmpty ?? false);
  }

  Future<Server?> saveServer(Server server,
      {bool Function()? isRouteCurrent, Set<String>? setupDecision}) async {
    bool current() =>
        !isClosed &&
        db.profileId == server.profileId &&
        server.profileId == _profileDb.profileId &&
        (isRouteCurrent?.call() ?? true);
    final Server? saved;
    try {
      saved = current()
          ? await _profileDb.addAccountWithMediaCompanions(server,
              isCurrent: current, setupDecision: setupDecision)
          : null;
    } catch (_) {
      try {
        await service.discardUnsavedSetupSession(server);
      } catch (_) {
        // An unreadable account store cannot establish whether the save
        // committed. Preserve the original save error for the route.
      }
      rethrow;
    }
    if (saved == null) {
      await service.discardUnsavedSetupSession(server);
      return null;
    }
    if (!current()) return null;
    // The database knows whether this was the first account. The on-screen
    // list may still be refreshing when setup is opened.
    if (saved.inUse) {
      await switchServer(saved);
    } else {
      await refreshServers();
      final active = appCubit.state.server;
      if (current() &&
          !appCubit.isClosed &&
          setupDecision != null &&
          active != null &&
          active.profileId == saved.profileId &&
          mediaCompanionInstanceAddress(active) ==
              mediaCompanionInstanceAddress(saved)) {
        final latest = _profileDb.getAccount(active.accountId);
        if (latest != null && latest.inUse) appCubit.setServer(latest);
      }
    }
    return saved;
  }

  Future<void> switchServer(Server s) async {
    if (isClosed || state.switching || db.profileId != s.profileId) return;
    emit(state.copyWith(switching: true));
    try {
      await appCubit.switchServer(s);
      await refreshServers();
    } finally {
      if (!isClosed) emit(state.copyWith(switching: false));
    }
  }
}

class ServerListSettingsState {
  final List<Server> dbServers;
  final bool switching;

  ServerListSettingsState(
      {required List<Server> dbServers, this.switching = false})
      : dbServers = List.unmodifiable(dbServers);

  ServerListSettingsState copyWith(
          {List<Server>? dbServers, bool? switching}) =>
      ServerListSettingsState(
          dbServers: dbServers ?? this.dbServers,
          switching: switching ?? this.switching);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerListSettingsState &&
          switching == other.switching &&
          listEquals(dbServers, other.dbServers);

  @override
  int get hashCode =>
      Object.hash(runtimeType, switching, Object.hashAll(dbServers));

  @override
  String toString() =>
      'ServerListSettingsState(accounts: ${dbServers.length}, switching: $switching)';
}
