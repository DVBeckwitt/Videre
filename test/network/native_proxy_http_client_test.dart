import 'dart:async';
import 'dart:convert';

import 'package:clipious/network/native_proxy_http_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/proxy');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeProxyHttpClient client;

  Map<String, Object> response(
          {int status = 200,
          Map<String, String>? headers,
          String body = 'ok'}) =>
      {
        'statusCode': status,
        'headers': headers ?? <String, String>{},
        'body': Uint8List.fromList(utf8.encode(body)),
      };

  setUp(() {
    client = NativeProxyHttpClient();
  });
  tearDown(() {
    client.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
      'sends API requests through native policy and decodes buffered responses',
      () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return response(
          status: 201,
          headers: {'Content-Type': 'application/json', 'X-Test': 'value'},
          body: '{"saved":true}');
    });
    final uri = Uri.parse('https://api.invalid/api/v1/subscriptions');
    final result = await client.post(uri,
        headers: {'Authorization': 'Bearer test-token'}, body: '{"id":"abc"}');

    expect(captured!.method, 'request');
    final args = captured!.arguments as Map;
    expect(args['method'], 'POST');
    expect(args['url'], uri.toString());
    expect((args['headers'] as Map)['Authorization'], 'Bearer test-token');
    expect(utf8.decode(args['body'] as Uint8List), '{"id":"abc"}');
    expect(args['followRedirects'], isTrue);
    expect(args['maxRedirects'], 5);
    expect(result.statusCode, 201);
    expect(result.headers['content-type'], 'application/json');
    expect(result.headers['x-test'], 'value');
    expect(result.body, '{"saved":true}');
    expect(result.request!.url, uri);
    expect(result.contentLength, utf8.encode(result.body).length);
  });

  test('forwards explicit redirect options and retains redirect response',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      expect(args['followRedirects'], isFalse);
      expect(args['maxRedirects'], 2);
      return response(status: 302, headers: {'Location': '/next'}, body: '');
    });
    final request = http.Request('GET', Uri.parse('https://api.invalid/start'))
      ..followRedirects = false
      ..maxRedirects = 2;
    final result = await client.send(request);
    expect(result.statusCode, 302);
    expect(result.isRedirect, isTrue);
    expect(result.headers['location'], '/next');
  });

  test('platform failures never expose native messages or use a fallback',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      throw PlatformException(
          code: 'PROXY_REQUEST',
          message: 'Authorization: header-secret; Cookie: cookie-secret');
    });
    await expectLater(
        client.get(Uri.parse('https://never-resolved.invalid/'),
            headers: {'Authorization': 'header-secret'}),
        throwsA(isA<http.ClientException>()
            .having((error) => error.message, 'message',
                'Native proxy request failed.')
            .having((error) => error.toString(), 'redacted detail',
                isNot(contains('header-secret')))
            .having((error) => error.toString(), 'redacted cookie',
                isNot(contains('cookie-secret')))));
    expect(calls, 1);
  });

  test('missing native transport fails without any IO fallback', () async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw MissingPluginException());
    await expectLater(
        client.get(Uri.parse('https://never-resolved.invalid/')),
        throwsA(isA<http.ClientException>().having((error) => error.message,
            'message', 'Native proxy transport is unavailable.')));
  });

  test('rejects an oversized request before invoking the platform', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return response();
    });
    final body = Uint8List(NativeProxyHttpClient.maxBodyBytes + 1);
    await expectLater(
        client.post(Uri.parse('https://api.invalid/'), body: body),
        throwsA(isA<http.ClientException>().having((error) => error.message,
            'message', 'Native proxy request exceeds 4 MiB.')));
    expect(calls, 0);
  });

  test('rejects oversized and malformed native responses', () async {
    final malformed = <Object?>[
      null,
      'not a response',
      {'statusCode': '200', 'headers': {}, 'body': Uint8List(0)},
      {'statusCode': 99, 'headers': {}, 'body': Uint8List(0)},
      {'statusCode': 600, 'headers': {}, 'body': Uint8List(0)},
      {'statusCode': 200, 'headers': [], 'body': Uint8List(0)},
      {'statusCode': 200, 'headers': {}, 'body': <int>[]},
      {
        'statusCode': 200,
        'headers': {1: 'value'},
        'body': Uint8List(0)
      },
      {
        'statusCode': 200,
        'headers': {'x-value': 1},
        'body': Uint8List(0)
      },
      {
        'statusCode': 200,
        'headers': <String, String>{},
        'body': Uint8List(NativeProxyHttpClient.maxBodyBytes + 1),
      },
    ];
    for (final payload in malformed) {
      messenger.setMockMethodCallHandler(channel, (_) async => payload);
      await expectLater(client.get(Uri.parse('https://api.invalid/')),
          throwsA(isA<http.ClientException>()));
    }
  });

  test('closed clients and non-HTTP URLs do not invoke the platform', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return response();
    });
    await expectLater(client.get(Uri.parse('file:///private/data')),
        throwsA(isA<http.ClientException>()));
    client.close();
    await expectLater(client.get(Uri.parse('https://api.invalid/')),
        throwsA(isA<http.ClientException>()));
    expect(calls, 0);
  });

  test('closing while the platform works prevents response delivery', () async {
    final entered = Completer<void>();
    final pending = Completer<Object>();
    messenger.setMockMethodCallHandler(channel, (_) async {
      entered.complete();
      return pending.future;
    });
    final result = client.get(Uri.parse('https://api.invalid/'));
    final rejected = expectLater(result, throwsA(isA<http.ClientException>()));
    await entered.future;
    client.close();
    pending.complete(response());
    await rejected;
  });
}
