import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipious/network/socks_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Orbot defaults and saved settings round trip', () {
    final config = SocksProxyConfig();
    expect(config.enabled, isFalse);
    expect(config.host, '127.0.0.1');
    expect(config.port, 9050);
    expect(
        SocksProxyConfig.fromJson(config.toJson()).toJson(), config.toJson());
  });

  test('malformed persisted configuration cannot enable direct networking', () {
    for (final json in [
      {'enabled': true, 'host': ''},
      {'enabled': true, 'host': 'http://127.0.0.1'},
      {'enabled': true, 'host': '127.0.0.1:9050'},
      {'enabled': true, 'host': 'user@host'},
      {'enabled': true, 'port': 0},
      {'enabled': true, 'port': 65536},
      {'enabled': true, 'port': '9050'},
      {'enabled': 'true'},
    ]) {
      expect(() => SocksProxyConfig.fromJson(json), throwsFormatException);
    }
    expect(SocksProxyConfig(enabled: true, host: '::1').host, '::1');
  });

  test('only literal loopback and localhost bypass the proxy', () {
    for (final host in ['127.0.0.1', '127.4.5.6', '::1', 'LOCALHOST']) {
      expect(isProxyLoopback(host), isTrue, reason: host);
    }
    for (final host in [
      'localhost.example.org',
      '192.168.1.2',
      '10.0.0.1',
      'example.org',
    ]) {
      expect(isProxyLoopback(host), isFalse, reason: host);
    }
  });

  test('fragmented SOCKS negotiation sends destination hostname to proxy',
      () async {
    final proxy = await _FakeSocks.start(fragment: true);
    addTearDown(proxy.close);
    final client = _client(proxy);
    addTearDown(() => client.close(force: true));

    final request = await client
        .getUrl(Uri.parse('http://no-local-dns.invalid:8432/video'));
    final response = await request.close();
    expect(await utf8.decodeStream(response), 'proxied');
    expect(await proxy.destination.future, ('no-local-dns.invalid', 8432, 3));
  });

  test('coalesced SOCKS reply retains all tunneled HTTP bytes', () async {
    final proxy = await _FakeSocks.start(earlyResponse: true);
    addTearDown(proxy.close);
    final client = _client(proxy);
    addTearDown(() => client.close(force: true));

    final request =
        await client.getUrl(Uri.parse('http://unresolvable.invalid/'));
    final response = await request.close();
    expect(await utf8.decodeStream(response), 'proxied');
  });

  for (final target in [
    ('192.0.2.7', 1),
    ('2001:db8::7', 4),
  ]) {
    test('SOCKS encodes literal destination ${target.$1}', () async {
      final proxy = await _FakeSocks.start();
      addTearDown(proxy.close);
      final client = _client(proxy);
      addTearDown(() => client.close(force: true));
      final request = await client
          .getUrl(Uri(scheme: 'http', host: target.$1, path: '/video'));
      await (await request.close()).drain<void>();
      expect(await proxy.destination.future, (target.$1, 80, target.$2));
    });
  }

  test('rejected SOCKS connection never falls back to destination', () async {
    final proxy = await _FakeSocks.start(reply: [5, 5, 0, 1]);
    addTearDown(proxy.close);
    final client = _client(proxy);
    addTearDown(() => client.close(force: true));
    await expectLater(client.getUrl(Uri.parse('http://192.0.2.8:80/')),
        throwsA(isA<SocketException>()));
    expect(await proxy.destination.future, ('192.0.2.8', 80, 1));
    expect(proxy.connections, 1);
  });

  test('unsupported authentication and truncated replies fail promptly',
      () async {
    for (final method in [
      [5, 2],
      [5],
    ]) {
      final proxy = await _FakeSocks.start(method: method);
      final client = _client(proxy);
      try {
        await expectLater(client.getUrl(Uri.parse('http://example.invalid/')),
            throwsA(isA<SocketException>()));
      } finally {
        client.close(force: true);
        await proxy.close();
      }
    }
  });

  test('stalled proxy times out and closes its socket', () async {
    final proxy = await _FakeSocks.start(stall: true);
    addTearDown(proxy.close);
    final client = _client(proxy, timeout: const Duration(milliseconds: 80));
    addTearDown(() => client.close(force: true));
    await expectLater(client.getUrl(Uri.parse('http://example.invalid/')),
        throwsA(isA<SocketException>()));
    await proxy.closed.future.timeout(const Duration(seconds: 2));
  });

  test('closing HttpClient cancels a pending SOCKS negotiation', () async {
    final proxy = await _FakeSocks.start(stall: true);
    addTearDown(proxy.close);
    final client = _client(proxy);
    final request = client.getUrl(Uri.parse('http://example.invalid/'));
    final failed = expectLater(request, throwsA(isA<SocketException>()));
    await proxy.connected.future;
    client.close(force: true);
    await failed;
    await proxy.closed.future.timeout(const Duration(seconds: 2));
  });

  test('timeout closes a SOCKS tunnel whose TLS handshake stalls', () async {
    final proxy = await _FakeSocks.start(stallTls: true);
    addTearDown(proxy.close);
    final client = _client(proxy, timeout: const Duration(seconds: 1));
    addTearDown(() => client.close(force: true));
    await expectLater(client.getUrl(Uri.parse('https://example.invalid/')),
        throwsA(isA<SocketException>()));
    expect(proxy.tlsStarted.isCompleted, isTrue);
    await proxy.closed.future.timeout(const Duration(seconds: 2));
  });

  test('cancellation closes a SOCKS tunnel whose TLS handshake stalls',
      () async {
    final proxy = await _FakeSocks.start(stallTls: true);
    addTearDown(proxy.close);
    final client = _client(proxy);
    final request = client.getUrl(Uri.parse('https://example.invalid/'));
    final failed = expectLater(request, throwsA(isA<SocketException>()));
    await proxy.tlsStarted.future;
    client.close(force: true);
    await failed;
    await proxy.closed.future.timeout(const Duration(seconds: 2));
  });

  test('player loopback forwarding remains direct', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write('local player');
      request.response.close();
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    configureSocksHttpClient(client, SocksProxyConfig(enabled: true, port: 1));
    final response = await (await client
            .getUrl(Uri.parse('http://127.0.0.1:${server.port}/')))
        .close();
    expect(await utf8.decodeStream(response), 'local player');
  });

  test('HTTPS uses TLS with certificate verification and explicit policy',
      () async {
    // The repository-pinned SDK supplies an intentionally untrusted test key.
    const fixture =
        'submodules/flutter/packages/flutter_tools/test/data/asset_test/tls_cert';
    final context = SecurityContext()
      ..useCertificateChain('$fixture/dummy-cert.pem')
      ..usePrivateKey('$fixture/dummy-key.pem');
    for (final allowCertificate in [false, true]) {
      final proxy = await _FakeSocks.start(tlsContext: context);
      final client = HttpClient();
      configureSocksHttpClient(
        client,
        SocksProxyConfig(enabled: true, port: proxy.server.port),
        badCertificateCallback: allowCertificate
            ? (cert, host, port) => host == 'secure.invalid' && port == 443
            : null,
      );
      try {
        final request = client.getUrl(Uri.parse('https://secure.invalid/'));
        if (allowCertificate) {
          final response = await (await request).close();
          expect(await utf8.decodeStream(response), 'proxied');
        } else {
          await expectLater(request, throwsA(isA<HandshakeException>()));
        }
      } finally {
        client.close(force: true);
        await proxy.close();
      }
    }
  });
}

HttpClient _client(_FakeSocks proxy,
    {Duration timeout = const Duration(seconds: 2)}) {
  final client = HttpClient();
  configureSocksHttpClient(
      client, SocksProxyConfig(enabled: true, port: proxy.server.port),
      timeout: timeout);
  return client;
}

class _FakeSocks {
  final ServerSocket server;
  final bool fragment;
  final bool earlyResponse;
  final bool stall;
  final bool stallTls;
  final List<int> method;
  final List<int> reply;
  final SecurityContext? tlsContext;
  final destination = Completer<(String, int, int)>();
  final connected = Completer<void>();
  final closed = Completer<void>();
  final tlsStarted = Completer<void>();
  final List<Socket> _sockets = [];
  int connections = 0;

  _FakeSocks(this.server,
      {required this.fragment,
      required this.earlyResponse,
      required this.stall,
      required this.stallTls,
      required this.method,
      required this.reply,
      this.tlsContext}) {
    server.listen((socket) {
      connections++;
      _sockets.add(socket);
      if (!connected.isCompleted) connected.complete();
      unawaited(_handle(socket));
    });
  }

  static Future<_FakeSocks> start({
    bool fragment = false,
    bool earlyResponse = false,
    bool stall = false,
    bool stallTls = false,
    List<int> method = const [5, 0],
    List<int> reply = const [5, 0, 0, 1, 127, 0, 0, 1, 0, 80],
    SecurityContext? tlsContext,
  }) async =>
      _FakeSocks(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
          fragment: fragment,
          earlyResponse: earlyResponse,
          stall: stall,
          stallTls: stallTls,
          method: method,
          reply: reply,
          tlsContext: tlsContext);

  Future<void> _send(Socket socket, List<int> bytes) async {
    if (fragment) {
      for (final byte in bytes) {
        socket.add([byte]);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    } else {
      socket.add(bytes);
      await socket.flush();
    }
  }

  static final _response = ascii.encode(
      'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nproxied');

  Future<void> _handle(Socket socket) async {
    var input = _TestReader(socket);
    try {
      expect(await input.read(3), [5, 1, 0]);
      if (stall) {
        await input.closed.future;
        return;
      }
      await _send(socket, method);
      if (method.length < 2 || method[1] != 0) return;
      final head = await input.read(4);
      expect(head.take(3), [5, 1, 0]);
      final type = head[3];
      final String host;
      if (type == 3) {
        host = ascii.decode(await input.read((await input.read(1)).single));
      } else {
        host = InternetAddress.fromRawAddress(
                Uint8List.fromList(await input.read(type == 1 ? 4 : 16)))
            .address;
      }
      final port = await input.read(2);
      destination.complete((host, port[0] * 256 + port[1], type));
      await _send(socket, [...reply, if (earlyResponse) ..._response]);
      if (reply[1] != 0) return;
      if (stallTls) {
        // Wait for a TLS record before cancelling, proving the client has
        // transferred ownership to its TLS negotiator.
        await input.read(1);
        tlsStarted.complete();
        await input.closed.future;
        return;
      }
      if (tlsContext != null) {
        input.pause();
        socket = await SecureSocket.secureServer(socket, tlsContext!);
        _sockets.add(socket);
        input = _TestReader(socket);
      }
      final header = <int>[];
      while (!ascii.decode(header).endsWith('\r\n\r\n')) {
        header.addAll(await input.read(1));
      }
      if (!earlyResponse) await _send(socket, _response);
    } on HandshakeException {
      // Expected when the client rejects our untrusted certificate.
    } on SocketException {
      // The timeout/cancellation tests intentionally destroy the client socket.
    } finally {
      socket.destroy();
      if (!closed.isCompleted) closed.complete();
    }
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

class _TestReader {
  final List<int> bytes = [];
  final closed = Completer<void>();
  late final StreamSubscription<Uint8List> subscription;
  Completer<void>? _changed;

  _TestReader(Socket socket) {
    subscription = socket.listen((data) {
      bytes.addAll(data);
      _changed?.complete();
      _changed = null;
    }, onError: (Object error) {
      if (!closed.isCompleted) closed.complete();
      _changed?.complete();
      _changed = null;
    }, onDone: () {
      if (!closed.isCompleted) closed.complete();
      _changed?.complete();
      _changed = null;
    });
  }

  Future<List<int>> read(int count) async {
    while (bytes.length < count) {
      if (closed.isCompleted) throw const SocketException('Test socket closed');
      _changed = Completer<void>();
      await _changed!.future;
    }
    final result = bytes.sublist(0, count);
    bytes.removeRange(0, count);
    return result;
  }

  void pause() => subscription.pause();
}
