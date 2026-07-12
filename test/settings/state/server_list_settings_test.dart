import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/server_list_settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';

void main() {
  late AppCubit app;
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
  });

  tearDown(() => db.close());

  test('switching server', () async {
    const first = Server(url: 'https://first.example');
    const second = Server(url: 'https://second.example');
    final state = ServerListSettingsState(dbServers: [first, second]);
    expect(state, ServerListSettingsState(dbServers: [first, second]));
    expect(() => state.dbServers.clear(), throwsUnsupportedError);

    final servers =
        ServerListSettingsCubit(ServerListSettingsState(dbServers: []), app);
    await servers.saveServer(first);
    await db.upsertServer(second);

    for (final server in [first, second]) {
      await servers.switchServer(server);

      expect((await db.getCurrentlySelectedServer()).url, server.url);
      expect(servers.state.dbServers.where((s) => s.inUse).length, 1);
      expect(app.state.server?.url, server.url);
    }
  });
}
