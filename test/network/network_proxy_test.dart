import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/reloadable_http_client.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _DirectHttpOverrides extends HttpOverrides {}

class _StatsSocksProxy {
  final ServerSocket server;
  final bool redirect;
  final destinations = <String>[];
  final receivedAccessHeaders = <bool>[];
  final sockets = <Socket>[];

  _StatsSocksProxy._(this.server, {required this.redirect}) {
    server.listen((socket) {
      sockets.add(socket);
      var phase = 0;
      var pending = <int>[];
      socket.listen((chunk) {
        pending.addAll(chunk);
        if (phase == 0) {
          if (pending.length < 2 || pending.length < 2 + pending[1]) return;
          pending = pending.sublist(2 + pending[1]);
          socket.add([5, 0]);
          phase = 1;
        }
        if (phase == 1) {
          if (pending.length < 5) return;
          // Test requests use hostnames, never local origin DNS or IP routes.
          expect(pending[3], 3);
          final length = pending[4];
          if (pending.length < 7 + length) return;
          destinations.add(ascii.decode(pending.sublist(5, 5 + length)));
          pending = pending.sublist(7 + length);
          socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
          phase = 2;
        }
        if (phase == 2) {
          final request = latin1.decode(pending);
          if (!request.contains('\r\n\r\n')) return;
          receivedAccessHeaders
              .add(request.toLowerCase().contains('\r\nx-instance-access:'));
          phase = 3;
          final headers = redirect
              ? 'HTTP/1.1 302 Found\r\n'
                  'Location: http://other-origin.invalid/api/v1/stats\r\n'
                  'Content-Length: 0\r\n'
              : 'HTTP/1.1 200 OK\r\n'
                  'Content-Type: application/json\r\n'
                  'Content-Length: 2\r\n';
          socket.add(ascii.encode(
              '$headers' 'Connection: close\r\n\r\n${redirect ? '' : '{}'}'));
          unawaited(socket.flush().then((_) => socket.close()));
        }
      }, onError: (Object _) {});
    });
  }

  static Future<_StatsSocksProxy> start({required bool redirect}) async =>
      _StatsSocksProxy._(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
          redirect: redirect);

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

class _NoSettingsWrites extends Fake implements IDbClient {
  @override
  Future<void> upsertServer(Server server) async =>
      throw StateError('No database writes are expected.');

  @override
  Future<void> insertLogs(AppLog log) async =>
      throw StateError('No database writes are expected.');

  @override
  Future<void> saveSetting(SettingsValue setting) async => throw StateError(
      'A redundant database write must not affect native policy.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final proxy = NetworkProxy.instance;

  HttpClient configuredClient() {
    // The binding's default HTTP override intentionally returns 400 responses;
    // exercise real local sockets while keeping all requests on loopback.
    final client = _DirectHttpOverrides().createHttpClient(null);
    proxy.configureClient(client);
    return client;
  }

  Future<HttpServer> localServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write('local response');
      unawaited(request.response.close());
    });
    return server;
  }

  Future<String> read(HttpClient client, HttpServer server) async {
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await proxy.initialize(configureNative: false);
  });

  tearDown(() async {
    await proxy.initialize(
        saved: jsonEncode(SocksProxyConfig().toJson()), configureNative: false);
    await db.close();
  });

  test('a fresh installation is disabled with the editable Orbot endpoint', () {
    expect(proxy.config.toJson(), {
      'enabled': false,
      'host': '127.0.0.1',
      'port': 9050,
    });
    expect(db.getSettings(networkSocksProxySettingName), isNull);
  });

  for (final redirect in [false, true]) {
    test(
        redirect
            ? 'proxy test rejects redirects before instance headers cross origins'
            : 'proxy test accepts instance stats through the unsaved endpoint',
        () async {
      const server = Server(
          url: 'http://instance.invalid',
          customHeaders: {'X-Instance-Access': 'synthetic-test-value'});
      await db.upsertServer(server);
      await db.useServer(server);
      final socks = await _StatsSocksProxy.start(redirect: redirect);
      addTearDown(socks.close);
      final unsaved = SocksProxyConfig(enabled: true, port: socks.server.port);
      if (redirect) {
        await expectLater(proxy.test(unsaved), throwsA(isA<HttpException>()));
      } else {
        await proxy.test(unsaved);
      }
      expect(socks.destinations, ['instance.invalid']);
      expect(socks.receivedAccessHeaders, [true]);
      expect(proxy.config.enabled, isFalse);
      expect(db.getSettings(networkSocksProxySettingName), isNull);
    });
  }

  test('apply persists the policy and foreground startup restores it',
      () async {
    final enabled =
        SocksProxyConfig(enabled: true, host: '127.0.0.1', port: 19050);
    await proxy.apply(enabled);

    final saved = db.getSettings(networkSocksProxySettingName)!.value;
    expect(jsonDecode(saved), enabled.toJson());
    expect(proxy.config.toJson(), enabled.toJson());

    await proxy.initialize(
        saved: jsonEncode(SocksProxyConfig().toJson()), configureNative: false);
    expect(proxy.config.enabled, isFalse);
    await proxy.initialize(configureNative: false);
    expect(proxy.config.toJson(), enabled.toJson());
  });

  test('corrupt saved configuration blocks traffic until explicitly repaired',
      () async {
    final server = await localServer();
    await db.saveSetting(SettingsValue(networkSocksProxySettingName,
        '{"enabled":true,"host":"127.0.0.1","port":0}'));
    await proxy.initialize(configureNative: false);
    final blocked = configuredClient();
    addTearDown(() => blocked.close(force: true));
    await expectLater(read(blocked, server), throwsA(isA<SocketException>()));

    await proxy.apply(SocksProxyConfig());
    final repaired = configuredClient();
    addTearDown(() => repaired.close(force: true));
    expect(await read(repaired, server), 'local response');
    expect(proxy.config.enabled, isFalse);
  });

  test('apply stops consumers before saving and resets retained HTTP clients',
      () async {
    final server = await localServer();
    var created = 0;
    final client = ReloadableHttpClient(() {
      created++;
      return configuredClient();
    });
    addTearDown(() => client.close(force: true));
    expect(await read(client, server), 'local response');
    expect(created, 1);

    final entered = Completer<void>();
    final release = Completer<void>();
    String? savedWhenStopped;
    Future<void> stopConsumer() async {
      savedWhenStopped = db.getSettings(networkSocksProxySettingName)?.value;
      entered.complete();
      await release.future;
    }

    proxy.addBeforeApply(stopConsumer);
    try {
      final applying = proxy.apply(SocksProxyConfig(enabled: true));
      await entered.future;
      final changing = configuredClient();
      addTearDown(() => changing.close(force: true));
      await expectLater(
          read(changing, server), throwsA(isA<SocketException>()));
      release.complete();
      await applying;
      expect(savedWhenStopped, isNull);

      // Loopback is an intentional internal-player exception even when enabled.
      expect(await read(client, server), 'local response');
      expect(created, 2);
      expect(proxy.config.enabled, isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      proxy.removeBeforeApply(stopConsumer);
    }
  });

  test('saving an unchanged healthy policy keeps playback and pools intact',
      () async {
    final server = await localServer();
    var created = 0;
    var stopped = 0;
    Future<void> stopConsumer() async => stopped++;
    final client = ReloadableHttpClient(() {
      created++;
      return configuredClient();
    });
    addTearDown(() => client.close(force: true));
    proxy.addBeforeApply(stopConsumer);
    addTearDown(() => proxy.removeBeforeApply(stopConsumer));
    expect(await read(client, server), 'local response');
    await proxy.apply(SocksProxyConfig.fromJson(proxy.config.toJson()));
    expect(await read(client, server), 'local response');
    expect(stopped, 0);
    expect(created, 1);
  });

  test(
      'native settings have one authoritative store even if the DB cannot write',
      () async {
    const channel = MethodChannel('videre/proxy-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var native = SocksProxyConfig(enabled: true).toJson();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConfiguration') return native;
      if (call.method == 'configure') {
        native = Map<String, dynamic>.from(call.arguments as Map);
        return null;
      }
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final manager = NetworkProxy.forTesting(useNative: true, channel: channel);
    await manager.initialize();
    final database = db;
    db = _NoSettingsWrites();
    try {
      await manager.apply(SocksProxyConfig());
      expect(manager.config.enabled, isFalse);
      expect(native['enabled'], isFalse);
      final restored =
          NetworkProxy.forTesting(useNative: true, channel: channel);
      await restored.initialize();
      expect(restored.config.enabled, isFalse);
    } finally {
      db = database;
    }
  });

  test('failed native save blocks traffic and an identical repair is retried',
      () async {
    const channel = MethodChannel('videre/proxy-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final active = SocksProxyConfig(enabled: true);
    var reject = true;
    var saves = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConfiguration') return active.toJson();
      saves++;
      if (reject) throw PlatformException(code: 'SAVE_FAILED');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final manager = NetworkProxy.forTesting(useNative: true, channel: channel);
    await manager.initialize();
    await expectLater(
        manager.apply(SocksProxyConfig()), throwsA(isA<PlatformException>()));
    expect(manager.config.enabled, isTrue);
    final client = _DirectHttpOverrides().createHttpClient(null);
    addTearDown(() => client.close(force: true));
    manager.configureClient(client);
    final server = await localServer();
    await expectLater(read(client, server), throwsA(isA<SocketException>()));
    reject = false;
    await manager.apply(active);
    expect(saves, 2);
    expect(manager.config.enabled, isTrue);
  });
}
