import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';

import '../../app/states/app.dart';
import '../../globals.dart';
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

  Future<void> saveServer(Server server) async {
    if (server.profileId != _profileDb.profileId) return;
    await _profileDb.upsertServer(server);
    if (state.dbServers.isEmpty && db.profileId == _profileDb.profileId) {
      await switchServer(server);
    } else {
      await refreshServers();
    }
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
