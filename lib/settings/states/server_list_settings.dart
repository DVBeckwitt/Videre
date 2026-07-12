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
    emit(state.copyWith(dbServers: await db.getServers()));
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
    await db.useServer(s);
    await fileDb.useServer(s);
    await refreshServers();
    appCubit.setServer(s);
  }
}

class ServerListSettingsState {
  final List<Server> dbServers;

  ServerListSettingsState({required List<Server> dbServers})
      : dbServers = List.unmodifiable(dbServers);

  ServerListSettingsState copyWith({List<Server>? dbServers}) =>
      ServerListSettingsState(dbServers: dbServers ?? this.dbServers);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerListSettingsState &&
          listEquals(dbServers, other.dbServers);

  @override
  int get hashCode => Object.hash(runtimeType, Object.hashAll(dbServers));

  @override
  String toString() => 'ServerListSettingsState(dbServers: $dbServers)';
}
