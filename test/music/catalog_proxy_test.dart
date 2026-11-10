import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

class _CatalogNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _CatalogNetworkBinding();
  final proxy = NetworkProxy.instance;
  final previousOverrides = HttpOverrides.current;
  late Service previousService;

  setUp(() async {
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
  });

  for (final proxyVideos in [false, true]) {
    test(
        'Music uses SOCKS with Proxy videos=$proxyVideos and refreshes identity',
        () async {
      await db.saveSetting(
          SettingsValue(useProxySettingName, proxyVideos.toString()));
      final first = await _CatalogSocks.start('first-route-visitor');
      final second = await _CatalogSocks.start('second-route-visitor');
      addTearDown(first.close);
      addTearDown(second.close);
      await proxy
          .apply(SocksProxyConfig(enabled: true, port: first.server.port));

      // No injected client or replacement origin: these are the production
      // catalog requests to https://music.youtube.com over a local SOCKS tunnel.
      final catalog = MusicCatalogService();
      expect(await catalog.searchSongs('Get Lucky'), hasLength(2));
      expect(await catalog.getNewReleases(), hasLength(3));
      expect(first.destinations, List.filled(3, ('music.youtube.com', 443)));
      expect(first.paths, ['/', '/youtubei/v1/search', '/youtubei/v1/browse']);
      expect(
          first.visitors, [null, 'first-route-visitor', 'first-route-visitor']);

      await proxy
          .apply(SocksProxyConfig(enabled: true, port: second.server.port));
      expect(await catalog.searchSongs('Get Lucky'), hasLength(2));
      // A new Tor route must not reuse the previous route's visitor identity.
      expect(second.paths, ['/', '/youtubei/v1/search']);
      expect(second.visitors, [null, 'second-route-visitor']);
      expect(second.destinations, List.filled(2, ('music.youtube.com', 443)));
      expect(first.paths, hasLength(3));

      await second.close();
      await expectLater(catalog.searchSongs('Get Lucky'),
          throwsA(isA<MusicCatalogException>()));
      expect(first.paths, hasLength(3));
      expect(second.paths, hasLength(2));
    });
  }
}

class _CatalogSocks {
  final ServerSocket server;
  final SecurityContext tls;
  final String visitor;
  final destinations = <(String, int)>[];
  final paths = <String>[];
  final visitors = <String?>[];
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
      // SOCKS must receive the hostname, never a locally resolved Google IP.
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
      expect(headers['host'], 'music.youtube.com');
      expect(headers.containsKey('authorization'), isFalse);
      expect(headers.containsKey('cookie'), isFalse);
      paths.add(path);
      visitors.add(headers['x-goog-visitor-id']);
      final String response;
      if (path == '/') {
        response = jsonEncode({
          'INNERTUBE_CLIENT_VERSION': '1.20261108.01.00',
          'VISITOR_DATA': visitor,
        });
      } else {
        final fixture =
            path.endsWith('/search') ? 'songs' : 'discovery/new_releases';
        response =
            await File('test/music/fixtures/$fixture.json').readAsString();
      }
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
