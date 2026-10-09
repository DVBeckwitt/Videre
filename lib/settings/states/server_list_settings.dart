import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';

import '../../app/states/app.dart';
import '../../globals.dart';
import '../models/db/server.dart';

class ServerListSettingsCubit extends Cubit<ServerListSettingsState> {
  final AppCubit appCubit;

  ServerListSettingsCubit(super.initialState, this.appCubit) {
    refreshServers();
  }

  Future<void> refreshServers() async {
    final servers = await db.getServers();
    if (!isClosed) emit(state.copyWith(dbServers: servers));
  }

  bool isLoggedInToServer(String url) {
    Server server = state.dbServers.firstWhere((s) => s.url == url,
        orElse: () => const Server(url: 'notFound'));

    return (server.authToken?.isNotEmpty ?? false) ||
        (server.sidCookie?.isNotEmpty ?? false);
  }

  Future<void> saveServer(Server server) async {
    await db.upsertServer(server);
    if (state.dbServers.isEmpty) {
      await switchServer(server);
    } else {
      await refreshServers();
    }
  }

  Future<void> switchServer(Server s) async {
    if (isClosed || state.switching) return;
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
  String toString() => 'ServerListSettingsState(dbServers: $dbServers)';
}
