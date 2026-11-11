import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/invidious_music_catalog_service.dart';
import 'support/legacy_music_catalog.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _CatalogNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _CatalogNetworkBinding();
  final proxy = NetworkProxy.instance;
  final previousOverrides = HttpOverrides.current;
  const sessions = MethodChannel('videre/gateway_sessions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Service previousService;

  setUp(() async {
    messenger.setMockMethodCallHandler(
        sessions,
        (call) async => call.method == 'resolve'
            ? {'enabled': false, 'needsSignIn': false}
            : false);
    previousService = service;
    db = await SembastSqfDb.createInMemory();
    // Trust only the local fixture for this test, through the existing setting.
    // Production TLS verification is covered by socks_proxy_test.dart.
    await db.saveSetting(SettingsValue(skipSslVerificationSettingName, 'true'));
    await proxy.initialize(saved: '{}', configureNative: false);
    HttpOverrides.global = MyHttpOverrides();
    service = Service();
  });

  tearDown(() async {
    service.httpClient.close();
    service = previousService;
    await proxy.initialize(saved: '{}', configureNative: false);
    HttpOverrides.global = previousOverrides;
    await db.close();
    messenger.setMockMethodCallHandler(sessions, null);
  });

  for (final proxyVideos in [false, true]) {
    test(
        'Invidious Music uses SOCKS and denies Google with saved proxy=$proxyVideos',
        () async {
      await db.saveSetting(
          SettingsValue(useProxySettingName, proxyVideos.toString()));
      final first = await _CatalogSocks.start('first-route-visitor');
      final second = await _CatalogSocks.start('second-route-visitor');
      addTearDown(first.close);
      addTearDown(second.close);
      await proxy
          .apply(SocksProxyConfig(enabled: true, port: first.server.port));

      const instance = Server(url: 'https://music-instance.example');
      await db.upsertServer(instance);
      final catalog = InvidiousMusicCatalogService(api: service);
      expect((await catalog.searchSongs('Get Lucky')).single.title,
          'first-route-visitor');
      expect(await catalog.getTrendingSongs(), hasLength(1));
      expect(
          first.destinations, List.filled(2, ('music-instance.example', 443)));
      expect(first.paths, ['/api/v1/search', '/api/v1/trending']);

      // The retired direct client exists only as a test fixture. Even an
      // explicit attempt through the app transport cannot contact Google.
      final retired = LegacyMusicCatalogFixture(httpClient: service.httpClient);
      await expectLater(retired.searchSongs('Get Lucky'),
          throwsA(isA<MusicCatalogException>()));
      expect(first.destinations, hasLength(2));

      await proxy
          .apply(SocksProxyConfig(enabled: true, port: second.server.port));
      expect((await catalog.searchSongs('Another song')).single.title,
          'second-route-visitor');
      expect(second.paths, ['/api/v1/search']);
      expect(second.destinations, [('music-instance.example', 443)]);
      expect(first.paths, hasLength(2));

      await second.close();
      await expectLater(catalog.searchSongs('Uncached song'), throwsException);
      expect(first.paths, hasLength(2));
      expect(second.paths, hasLength(1));
    });
  }
}

class _CatalogSocks {
  final ServerSocket server;
  final SecurityContext tls;
  final String visitor;
  final destinations = <(String, int)>[];
  final paths = <String>[];
  final _sockets = <Socket>[];
  bool _closed = false;

  _CatalogSocks(this.server, this.tls, this.visitor) {
    server.listen((socket) {
      _sockets.add(socket);
      unawaited(_handle(socket));
    });
  }

  static Future<_CatalogSocks> start(String visitor) async {
    // Public dummy test certificate supplied by the repository-pinned SDK.
    const fixture =
        'submodules/flutter/packages/flutter_tools/test/data/asset_test/tls_cert';
    final tls = SecurityContext()
      ..useCertificateChain('$fixture/dummy-cert.pem')
      ..usePrivateKey('$fixture/dummy-key.pem');
    return _CatalogSocks(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), tls, visitor);
  }

  Future<void> _handle(Socket socket) async {
    var input = _SocketReader(socket);
    try {
      expect(await input.read(3), [5, 1, 0]);
      socket.add([5, 0]);
      await socket.flush();
      // SOCKS receives the Invidious hostname without local DNS resolution.
      expect(await input.read(4), [5, 1, 0, 3]);
      final host = ascii.decode(await input.read((await input.read(1)).single));
      final port = await input.read(2);
      destinations.add((host, port[0] * 256 + port[1]));
      socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
      await socket.flush();
      input.subscription.pause();
      socket = await SecureSocket.secureServer(socket, tls);
      _sockets.add(socket);
      input = _SocketReader(socket);
      final header = <int>[];
      while (!latin1.decode(header).endsWith('\r\n\r\n')) {
        header.addAll(await input.read(1));
      }
      final lines = latin1.decode(header).split('\r\n');
      final path = Uri.parse(lines.first.split(' ')[1]).path;
      final headers = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).toLowerCase()] =
              line.substring(colon + 1).trim();
        }
      }
      await input.read(int.parse(headers['content-length'] ?? '0'));
      expect(headers['host'], 'music-instance.example');
      expect(headers.containsKey('authorization'), isFalse);
      expect(headers.containsKey('cookie'), isFalse);
      paths.add(path);
      expect(headers.containsKey('x-goog-visitor-id'), isFalse);
      expect(['/api/v1/search', '/api/v1/trending'], contains(path));
      final response = jsonEncode([
        {
          'type': 'video',
          'videoId': '4D7u5KF7SP8',
          'title': visitor,
          'author': 'Fixture artist',
          'lengthSeconds': 370,
          'videoThumbnails': [],
        },
      ]);
      final bytes = utf8.encode(response);
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${bytes.length}\r\n'
          'Connection: close\r\n\r\n'));
      socket.add(bytes);
      await socket.flush();
    } on SocketException {
      // Closing a fixture endpoint intentionally interrupts its connections.
    } finally {
      socket.destroy();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

class _SocketReader {
  final _bytes = <int>[];
  late final StreamSubscription<Uint8List> subscription;
  Completer<void>? _changed;
  bool _closed = false;

  _SocketReader(Socket socket) {
    subscription = socket.listen((data) {
      _bytes.addAll(data);
      _wake();
    }, onError: (Object _) => _close(), onDone: _close);
  }

  void _wake() {
    _changed?.complete();
    _changed = null;
  }

  void _close() {
    _closed = true;
    _wake();
  }

  Future<List<int>> read(int count) async {
    while (_bytes.length < count) {
      if (_closed) throw const SocketException('Test socket closed');
      _changed = Completer<void>();
      await _changed!.future;
    }
    final result = _bytes.sublist(0, count);
    _bytes.removeRange(0, count);
    return result;
  }
}
