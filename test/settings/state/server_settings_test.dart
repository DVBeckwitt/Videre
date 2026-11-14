import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../globals.dart';
import '../../test_app_cubit.dart';

class _LiveNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  // AppCubit needs a binding, while this test still uses the real Invidious API.
  _LiveNetworkBinding();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late AppCubit app;
  setUp(() async {
    documents =
        await Directory.systemTemp.createTemp('videre-live-server-test-');
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

  test('test server setting', () async {
    const account = Server(url: localInvidiousServer);
    await db.upsertServer(account);
    final server =
        ServerSettingsCubit(const ServerSettingsState(server: account), app);
    addTearDown(server.close);
    await server.useServer(true);
    expect(
        (await db.getCurrentlySelectedServer()).accountId, account.accountId);

    await server.logInWithCookie('test', 'test');
    expect(server.state.server.sidCookie, isNotEmpty);
    expect((await db.getCurrentlySelectedServer()).sidCookie,
        server.state.server.sidCookie);

    // test deleting the server from db
    expect((await db.getServers()).length, 1);
    await server.deleteServer();
    // we can't delete a server if there's only one
    expect((await db.getServers()).length, 1);

    const otherAccount = Server(url: 'https://anotherServer');
    await db.upsertServer(otherAccount);
    expect((await db.getServers()).length, 2);
    await server.deleteServer();
    expect((await db.getServers()).length, 1);
    expect((await db.getCurrentlySelectedServer()).accountId,
        otherAccount.accountId);
    expect(app.state.server?.accountId, otherAccount.accountId);
  });
}
