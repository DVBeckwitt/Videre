import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Invidious endpoint compatibility', () {
    test('keeps the current video and authenticated subscription endpoints',
        () {
      expect(urlGetVideo, '/api/v1/videos/:id');
      expect(urlGetUserFeed, '/api/v1/auth/feed');
      expect(urlGetSubscriptions, '/api/v1/auth/subscriptions');
    });
  });

  group('Service.handleResponse', () {
    final service = Service();

    test('reports an HTML reverse-proxy response before JSON decoding', () {
      final response = http.Response(
        '<a href="https://auth.example/login">Sign in</a>',
        302,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.message,
            'message',
            'The reverse proxy returned HTML instead of Invidious JSON',
          ),
        ),
      );
    });

    test('reports a successful HTML proxy login page as a proxy error', () {
      final response = http.Response(
        '<!doctype html><title>Sign in</title>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>()
              .having(
                (error) => error.message,
                'message',
                'The reverse proxy returned HTML instead of Invidious JSON',
              )
              .having(
                (error) => error.responseWasHtml,
                'responseWasHtml',
                isTrue,
              ),
        ),
      );
    });

    test('reports malformed JSON returned with a successful status', () {
      final response = http.Response(
        '{not-json',
        200,
        headers: {'content-type': 'application/json'},
      );

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.message,
            'message',
            'The server returned malformed JSON',
          ),
        ),
      );
    });

    test('reports a non-JSON HTTP error with its status', () {
      final response = http.Response('Unavailable', 503);

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.message,
            'message',
            'Request failed with HTTP 503',
          ),
        ),
      );
    });

    test('accepts an empty successful response', () {
      expect(service.handleResponse(http.Response('', 204)), isNull);
    });
  });

  group('subscription writes', () {
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      const server = Server(
        url: 'https://inv.example',
        authToken: 'invidious-token',
      );
      await db.upsertServer(server);
      await db.useServer(server);
    });

    tearDown(() async {
      service = Service();
      await db.close();
    });

    test('does not silently convert a 403 subscribe response to false',
        () async {
      final client = MockClient((request) async => http.Response(
            '{"error":"Invalid token"}',
            403,
            headers: {'content-type': 'application/json'},
          ));
      final testService = Service(httpClient: client);

      await expectLater(
        testService.subscribe('UC123'),
        throwsA(isA<InvidiousServiceError>()),
      );
    });

    test('accepts a 204 unsubscribe response', () async {
      final client = MockClient((request) async => http.Response('', 204));
      final testService = Service(httpClient: client);

      expect(await testService.unSubscribe('UC123'), isTrue);
    });

    test('validates stored credentials with the subscriptions endpoint',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final testService = Service(httpClient: client);

      expect(await testService.validateCurrentSession(), isTrue);
      expect(captured.url.path, '/api/v1/auth/subscriptions');
      expect(captured.headers['Authorization'], 'Bearer invidious-token');
    });

    test('clears stored credentials after an Invidious JSON 403', () async {
      final client = MockClient((request) async => http.Response(
            '{"error":"Invalid token"}',
            403,
            headers: {'content-type': 'application/json'},
          ));
      final testService = Service(httpClient: client);

      expect(await testService.validateCurrentSession(), isFalse);
      expect(db.getServer('https://inv.example')!.authToken, isNull);
    });

    test('keeps credentials when an outer proxy returns HTML', () async {
      final client = MockClient((request) async => http.Response(
            '<a href="https://auth.example/login">Sign in</a>',
            403,
            headers: {'content-type': 'text/html'},
          ));
      final testService = Service(httpClient: client);

      await expectLater(
        testService.validateCurrentSession(),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.responseWasHtml,
            'responseWasHtml',
            isTrue,
          ),
        ),
      );
      expect(
        db.getServer('https://inv.example')!.authToken,
        'invidious-token',
      );
    });
  });
}
