import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/server_list_settings.dart';
import 'package:clipious/settings/states/server_settings.dart';
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
  late Service originalService;
  setUp(() async {
    originalService = service;
    documents = await Directory.systemTemp.createTemp('videre-server-test-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    await app.initState();
  });

  tearDown(() async {
    service = originalService;
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

  test('rapid switches cannot mix the app and background server', () async {
    const first = Server(url: 'https://first.example');
    const second = Server(url: 'https://second.example');
    await db.upsertServer(first);
    await db.upsertServer(second);
    final pending = _PendingSessionService();
    service = pending;
    final servers =
        ServerListSettingsCubit(ServerListSettingsState(dbServers: []), app);
    addTearDown(servers.close);

    final switching = servers.switchServer(first);
    await pending.started.future;
    await servers.switchServer(second);
    expect((await db.getCurrentlySelectedServer()).url, first.url);
    expect(servers.state.switching, isTrue);
    pending.finish.complete();
    await switching;

    expect(pending.calls, 1);
    expect(servers.state.switching, isFalse);
    expect(app.state.server?.url, first.url);
    expect((await fileDb.getCurrentlySelectedServer()).url, first.url);
  });

  test('leaving settings during a switch still finishes synchronization',
      () async {
    const server = Server(url: 'https://custom.example');
    await db.upsertServer(server);
    final pending = _PendingSessionService();
    service = pending;
    final servers =
        ServerListSettingsCubit(ServerListSettingsState(dbServers: []), app);

    final switching = servers.switchServer(server);
    await pending.started.future;
    await servers.close();
    pending.finish.complete();
    await switching;

    expect(app.state.server?.url, server.url);
    expect((await fileDb.getCurrentlySelectedServer()).url, server.url);
    await servers.refreshServers();
  });

  test('reopened settings waits for the previous session check', () async {
    const first = Server(url: 'https://first.example');
    const second = Server(url: 'https://second.example');
    await db.upsertServer(first);
    await db.upsertServer(second);
    final pending = _PendingSessionService();
    service = pending;
    final list =
        ServerListSettingsCubit(ServerListSettingsState(dbServers: []), app);
    final firstSwitch = list.switchServer(first);
    await pending.started.future;
    await list.close();

    final details =
        ServerSettingsCubit(ServerSettingsState(server: second), app);
    addTearDown(details.close);
    final secondSwitch = details.useServer(true);
    await db.upsertServer(second.copyWith(
        authToken: 'updated-token', customHeaders: {'X-Server': 'updated'}));
    // The old request still owns the selected server until it finishes.
    expect((await db.getCurrentlySelectedServer()).url, first.url);
    pending.finish.complete();
    await Future.wait([firstSwitch, secondSwitch]);

    expect(pending.calls, 2);
    expect((await db.getServers()).where((s) => s.inUse).length, 1);
    expect(app.state.server?.url, second.url);
    expect((await fileDb.getCurrentlySelectedServer()).url, second.url);
    expect(db.getServer(second.url)?.authToken, 'updated-token');
    expect(app.state.server?.customHeaders, {'X-Server': 'updated'});
    expect(
        (await fileDb.getCurrentlySelectedServer()).authToken, 'updated-token');
  });

  test('a deleted queued server is not restored by the pending switch',
      () async {
    const first = Server(url: 'https://first.example');
    const second = Server(url: 'https://second.example');
    await db.upsertServer(first);
    await db.upsertServer(second);
    final pending = _PendingSessionService();
    service = pending;
    final firstSwitch = app.switchServer(first);
    await pending.started.future;
    final secondSwitch = app.switchServer(second);
    await db.deleteServer(second);
    pending.finish.complete();
    await firstSwitch;

    expect(await secondSwitch, isNull);
    expect(db.getServer(second.url), isNull);
    expect(app.state.server?.url, first.url);
    expect((await fileDb.getCurrentlySelectedServer()).url, first.url);
  });
}

class _PendingSessionService extends Service {
  final started = Completer<void>();
  final finish = Completer<void>();
  int calls = 0;

  @override
  Future<void> validateCurrentSessionSafely() async {
    calls++;
    if (!started.isCompleted) started.complete();
    await finish.future;
  }
}
