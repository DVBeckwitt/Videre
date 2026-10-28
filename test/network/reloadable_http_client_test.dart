import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/network/reloadable_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<HttpServer> proxy(String label) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write(
          '$label|${request.headers.value(HttpHeaders.userAgentHeader)}');
      unawaited(request.response.close());
    });
    return server;
  }

  Future<String> read(HttpClient client) async {
    final request =
        await client.getUrl(Uri.parse('http://unresolvable.invalid/video'));
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  test('a retained wrapper uses the new transport and retains caller settings',
      () async {
    final first = await proxy('first');
    final second = await proxy('second');
    var selectedPort = first.port;
    var created = 0;
    final client = ReloadableHttpClient(() {
      created++;
      return HttpClient()
        ..userAgent = 'factory/$created'
        ..findProxy = (_) => 'PROXY 127.0.0.1:$selectedPort';
    })
      ..userAgent = 'consumer'
      ..connectionTimeout = const Duration(seconds: 2)
      ..maxConnectionsPerHost = 3;
    addTearDown(() => client.close(force: true));

    expect(await read(client), 'first|consumer');
    expect(await read(client), 'first|consumer');
    expect(created, 1);

    selectedPort = second.port;
    ReloadableHttpClient.resetAll();
    expect(await read(client), 'second|consumer');
    expect(created, 2);
    expect(client.connectionTimeout, const Duration(seconds: 2));
    expect(client.maxConnectionsPerHost, 3);
  });

  test('reset immediately aborts an in-flight request under the old policy',
      () async {
    final received = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      received.complete();
      // Leave the response pending to exercise a live connection at reset.
    });
    final client = ReloadableHttpClient(HttpClient.new);
    addTearDown(() => client.close(force: true));
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
    final aborted = expectLater(request.close(), throwsA(isA<Exception>()));
    await received.future;

    ReloadableHttpClient.resetAll();
    await aborted;
  });

  test('normal close remains terminal after a policy reset', () async {
    var created = 0;
    final client = ReloadableHttpClient(() {
      created++;
      return HttpClient();
    });
    // Access a property to instantiate the underlying client.
    expect(client.autoUncompress, isTrue);
    client.close(force: true);
    ReloadableHttpClient.resetAll();

    expect(
        () => client.getUrl(Uri.parse('http://127.0.0.1/')), throwsStateError);
    expect(created, 1);
  });

  test('reset aborts a live response after its wrapper is normally closed',
      () async {
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
    });
    server.listen((request) async {
      try {
        request.response.bufferOutput = false;
        request.response.write('before');
        await request.response.flush();
        await release.future;
        request.response.write('after');
        await request.response.close();
      } on IOException {
        // Reset intentionally closes the connection before its body finishes.
      }
    });
    final client = ReloadableHttpClient(HttpClient.new);
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))
        .timeout(const Duration(seconds: 3));
    final response = await request.close().timeout(const Duration(seconds: 3));
    final chunks = StreamIterator(response);
    addTearDown(chunks.cancel);
    expect(await chunks.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect(utf8.decode(chunks.current), 'before');

    // Normal close lets active responses finish, and unregisters the wrapper.
    // A subsequent routing change must still abort those old connections.
    client.close();
    final aborted = expectLater(
        chunks.moveNext().timeout(const Duration(seconds: 3)),
        throwsA(isA<HttpException>()));
    ReloadableHttpClient.resetAll();
    await aborted.timeout(const Duration(seconds: 5));
  });
}
