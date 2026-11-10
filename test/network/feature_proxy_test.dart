import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/errors/cannot_add_server_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _NetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _NetworkBinding();
  final proxy = NetworkProxy.instance;
  final previousOverrides = HttpOverrides.current;
  const body = '{"software":{"name":"invidious"}}';

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await proxy.initialize(saved: '{}', configureNative: false);
    HttpOverrides.global = MyHttpOverrides();
  });

  tearDown(() async {
    await proxy.initialize(saved: '{}', configureNative: false);
    HttpOverrides.global = previousOverrides;
    await db.close();
  });

  for (final feature in ['API', 'downloads', 'cached artwork']) {
    test('$feature follows SOCKS changes and fails with an unavailable proxy',
        () async {
      final first = await _FeatureSocks.start(body);
      final second = await _FeatureSocks.start(body);
      addTearDown(first.close);
      addTearDown(second.close);
      await proxy
          .apply(SocksProxyConfig(enabled: true, port: first.server.port));

      // Construct the same default clients used by the app, without injecting
      // an HTTP client or configuring their routing individually.
      const host = 'feature-without-local-dns.invalid';
      const url = 'http://$host';
      late Future<void> Function() fetch;
      late Matcher failure;
      switch (feature) {
        case 'API':
          final client = Service();
          addTearDown(client.httpClient.close);
          fetch = () => client.validateServer(url, null);
          failure = isA<CannotAddServerError>();
        case 'downloads':
          final client = Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30)));
          final directory = await Directory.systemTemp.createTemp('proxy-');
          final file = File('${directory.path}/media');
          addTearDown(() => client.close(force: true));
          addTearDown(() => directory.delete(recursive: true));
          fetch = () async {
            await client.download('$url/media', file.path);
            expect(await file.readAsString(), body);
          };
          failure = isA<DioException>();
        case 'cached artwork':
          // HttpFileService is the default network layer of the cache used by
          // CachedNetworkImage and audio_service's notification artwork.
          final client = HttpFileService();
          fetch = () async {
            final response = await client.get('$url/cover.jpg');
            expect(response.statusCode, 200);
            expect(await response.content.transform(utf8.decoder).join(), body);
          };
          failure = isA<http.ClientException>();
      }

      await fetch();
      expect(first.destinations, [host]);
      await proxy
          .apply(SocksProxyConfig(enabled: true, port: second.server.port));
      await fetch();
      expect(first.destinations, [host]);
      expect(second.destinations, [host]);

      // Retain the same clients after their active endpoint disappears. A
      // successful response or continued use of the old endpoint is a failure.
      await second.close();
      await expectLater(fetch(), throwsA(failure));
      expect(first.destinations, [host]);
      expect(second.destinations, [host]);
    });
  }
}

class _FeatureSocks {
  final ServerSocket server;
  final String body;
  final destinations = <String>[];
  final _sockets = <Socket>[];
  bool _closed = false;

  _FeatureSocks(this.server, this.body) {
    server.listen((socket) {
      _sockets.add(socket);
      var phase = 0;
      var pending = <int>[];
      socket.listen((chunk) {
        pending.addAll(chunk);
        if (phase == 0) {
          if (pending.length < 3) return;
          expect(pending.take(3), [5, 1, 0]);
          pending = pending.sublist(3);
          socket.add([5, 0]);
          phase = 1;
        }
        if (phase == 1) {
          if (pending.length < 5) return;
          // SOCKS receives the unresolved destination rather than a locally
          // resolved IP, including when a retained client changes endpoints.
          expect(pending.take(4), [5, 1, 0, 3]);
          final length = pending[4];
          if (pending.length < 7 + length) return;
          destinations.add(ascii.decode(pending.sublist(5, 5 + length)));
          pending = pending.sublist(7 + length);
          socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
          phase = 2;
        }
        if (phase == 2 && latin1.decode(pending).contains('\r\n\r\n')) {
          phase = 3;
          socket.add(utf8.encode('HTTP/1.1 200 OK\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: ${utf8.encode(body).length}\r\n'
              'Connection: close\r\n\r\n$body'));
          unawaited(socket.flush().then((_) => socket.close()));
        }
      }, onError: (Object _) {});
    });
  }

  static Future<_FeatureSocks> start(String body) async => _FeatureSocks(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), body);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close();
  }
}
