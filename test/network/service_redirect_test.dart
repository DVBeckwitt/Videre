import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/network/native_proxy_http_client.dart';
import 'package:clipious/service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

class _DirectOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HttpServer> server(Future<void> Function(HttpRequest) handle) async {
    final result = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => result.close(force: true));
    result.listen((request) => unawaited(handle(request)));
    return result;
  }

  Uri url(HttpServer server, [String path = '/']) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');

  http.Client client() {
    final result =
        Service(httpClient: IOClient(_DirectOverrides().createHttpClient(null)))
            .httpClient;
    addTearDown(result.close);
    return result;
  }

  test('instance headers do not cross origins through an API redirect',
      () async {
    Map<String, List<String>>? received;
    final destination = await server((request) async {
      received = {};
      request.headers.forEach((name, values) => received![name] = values);
      request.response.write('ok');
      await request.response.close();
    });
    final origin = await server((request) async {
      expect(request.headers.value('X-Instance-Access'), 'synthetic-access');
      await request.response.redirect(url(destination));
    });

    final response = await client().get(url(origin), headers: {
      'X-Instance-Access': 'synthetic-access',
      'Authorization': 'Bearer synthetic-token',
      'Cookie': 'SID=synthetic-session',
    });

    expect(response.body, 'ok');
    expect(received, isNot(contains('x-instance-access')));
    expect(received, isNot(contains('authorization')));
    expect(received, isNot(contains('cookie')));
  });

  test('same-origin redirects retain instance headers', () async {
    final visited = <String>[];
    final origin = await server((request) async {
      visited.add(request.uri.path);
      expect(request.headers.value('X-Instance-Access'), 'synthetic-access');
      if (request.uri.path == '/') {
        await request.response.redirect(Uri.parse('/next'));
      } else {
        request.response.write('ok');
        await request.response.close();
      }
    });

    expect(
        (await client().get(url(origin),
                headers: {'X-Instance-Access': 'synthetic-access'}))
            .body,
        'ok');
    expect(visited, ['/', '/next']);
  });

  test('POST see-other redirects drop the body and cross-origin headers',
      () async {
    String? method;
    String? body;
    String? access;
    final destination = await server((request) async {
      method = request.method;
      body = await utf8.decoder.bind(request).join();
      access = request.headers.value('X-Instance-Access');
      request.response.write('ok');
      await request.response.close();
    });
    final origin = await server((request) async {
      expect(request.method, 'POST');
      expect(await utf8.decoder.bind(request).join(), 'name=value');
      await request.response
          .redirect(url(destination), status: HttpStatus.seeOther);
    });

    expect(
        (await client().post(url(origin),
                headers: {'X-Instance-Access': 'synthetic-access'},
                body: {'name': 'value'}))
            .body,
        'ok');
    expect(method, 'GET');
    expect(body, isEmpty);
    expect(access, isNull);
  });

  test('an explicit no-follow request preserves the redirect response',
      () async {
    var requests = 0;
    final inner = MockClient((request) async {
      requests++;
      return http.Response('', 302, headers: {'location': '/next'});
    });
    addTearDown(inner.close);
    final request = http.Request('GET', Uri.parse('https://instance.invalid/'))
      ..followRedirects = false;
    final response = await Service(httpClient: inner).httpClient.send(request);
    await response.stream.drain<void>();

    expect(response.statusCode, 302);
    expect(requests, 1);
  });

  test('redirect limits bound loops without forwarding credentials back',
      () async {
    final received = <http.Request>[];
    final inner = MockClient((request) async {
      received.add(request);
      return http.Response('', 302, headers: {
        'location': request.url.host == 'instance.invalid'
            ? 'https://other.invalid/'
            : 'https://instance.invalid/',
      });
    });
    addTearDown(inner.close);
    final request = http.Request('GET', Uri.parse('https://instance.invalid/'))
      ..maxRedirects = 2
      ..headers['X-Instance-Access'] = 'synthetic-access';

    await expectLater(Service(httpClient: inner).httpClient.send(request),
        throwsA(isA<http.ClientException>()));
    expect(received, hasLength(3));
    expect(received.first.headers['X-Instance-Access'], 'synthetic-access');
    for (final redirected in received.skip(1)) {
      expect(redirected.headers, isNot(contains('X-Instance-Access')));
    }
  });

  test('POST redirects that would replay a mutation remain responses',
      () async {
    for (final status in [301, 302, 307, 308]) {
      var requests = 0;
      final inner = MockClient((request) async {
        requests++;
        return http.Response('', status, headers: {'location': '/next'});
      });
      addTearDown(inner.close);

      final response = await Service(httpClient: inner)
          .httpClient
          .post(Uri.parse('https://instance.invalid/'), body: 'mutation');
      expect(response.statusCode, status);
      expect(requests, 1);
    }
  });

  test('native transport retains one redirect chain and its total timeout',
      () async {
    const channel = MethodChannel('videre/proxy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map;
      expect(arguments['followRedirects'], isTrue);
      expect(arguments['maxRedirects'], 5);
      return {
        'statusCode': 200,
        'headers': <String, String>{},
        'body': Uint8List(0),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final transport = NativeProxyHttpClient();
    addTearDown(transport.close);

    final response = await Service(httpClient: transport)
        .httpClient
        .get(Uri.parse('https://instance.invalid/'));
    expect(response.statusCode, 200);
  });
}
