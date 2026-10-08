import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/server_list_settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import '../../test_app_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late AppCubit app;
  setUp(() async {
    documents = await Directory.systemTemp.createTemp('videre-server-test-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    await app.initState();
  });

  tearDown(() async {
    await app.close();
    await db.close();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  test('guest startup honors the selected local-library tab', () async {
    for (final index in [2, 3]) {
      await db.saveSetting(SettingsValue(onOpenSettingName, '$index'));
      await app.initState();
      expect(app.state.firstIndex, index);
    }
  });

  test('switching server', () async {
    const first = Server(url: 'https://first.example');
    const second = Server(url: 'https://second.example');
    final state = ServerListSettingsState(dbServers: [first, second]);
    expect(state, ServerListSettingsState(dbServers: [first, second]));
    expect(() => state.dbServers.clear(), throwsUnsupportedError);

    final servers =
        ServerListSettingsCubit(ServerListSettingsState(dbServers: []), app);
    addTearDown(servers.close);
    await servers.saveServer(first);
    await db.upsertServer(second);

    for (final server in [first, second]) {
      await servers.switchServer(server);

      expect((await db.getCurrentlySelectedServer()).url, server.url);
      expect(servers.state.dbServers.where((s) => s.inUse).length, 1);
      expect(app.state.server?.url, server.url);
      expect((await fileDb.getCurrentlySelectedServer()).url, server.url);
    }
  });
}
