import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/music/services/invidious_music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/nerdvpn_origin.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _videoId = '4D7u5KF7SP8';
const _starting = 'This backend is still starting and not yet available. '
    'Please wait for a short time or use another backend.';
const _account = Server(
    url: 'https://invidious.nerdvpn.de',
    id: 'nerdvpn',
    customHeaders: {'X-Test-Account': 'fixture', 'Cookie': 'COMPANION_ID=1'});

http.Response _response(http.Request request, int status, Object body,
        {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, request: request, headers: {
      'content-type': 'application/json',
      ...headers,
    });

http.Response _success(http.Request request) =>
    _response(request, 200, {'videoId': _videoId, 'title': 'Test song'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late Service api;
  late DateTime now;
  late Future<void> Function(Duration) wait;
  late Future<http.Response> Function(http.Request) respond;
  final requests = <http.Request>[];
  final delays = <Duration>[];

  setUp(() async {
    db = database = await SembastSqfDb.createInMemory();
    await database.upsertServer(_account);
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    now = DateTime.utc(2026, 11, 10);
    requests.clear();
    delays.clear();
    wait = (delay) async => now = now.add(delay);
    respond = (request) async => requests.length == 1
        ? _response(request, 500, {'error': _starting})
        : _success(request);
    api = Service(
        httpClient: MockClient((request) async {
          requests.add(request);
          return respond(request);
        }),
        now: () => now,
        wait: (delay) async {
          delays.add(delay);
          await wait(delay);
        });
  });

  tearDown(() async {
    api.httpClient.close();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await database.close();
  });

  for (final origin in [
    _account.url,
    'http://$nerdVpnOnionHost',
    'https://$nerdVpnOnionHost',
  ]) {
    test('$origin retries only the same video and account', () async {
      final account = _account.copyWith(url: origin);
      await database.upsertServer(account);
      await database.useServer(account);
      expect((await api.getVideo(_videoId)).videoId, _videoId);
      expect(requests, hasLength(2));
      expect(requests.last.url, requests.first.url);
      expect(requests.last.url.origin, origin);
      expect(requests.last.headers, requests.first.headers);
      expect(requests.last.headers['Cookie'], 'COMPANION_ID=1');
      expect(delays, [const Duration(seconds: 1)]);
    });
  }

  test('an unsaved validation account can recover without being selected',
      () async {
    const selected = Server(url: 'https://selected.example', id: 'selected');
    await database.upsertServer(selected);
    await database.useServer(selected);
    final unsaved = _account.copyWith(id: 'unsaved');
    expect(database.getAccount(unsaved.accountId), isNull);
    expect((await api.getVideo(_videoId, serverOverride: unsaved)).videoId,
        _videoId);
    expect(requests, hasLength(2));
    expect(
        requests.every((request) => request.url.origin == unsaved.url), isTrue);
    expect((await database.getCurrentlySelectedServer()).accountId,
        selected.accountId);
    expect(database.getAccount(unsaved.accountId), isNull);
  });

  test('Music song metadata recovers through its explicit server snapshot',
      () async {
    final song = await InvidiousMusicCatalogService(api: api).getSong(_videoId);
    expect(song.videoId, _videoId);
    expect(requests, hasLength(2));
  });

  test('selecting the first account stops unsaved validation recovery',
      () async {
    await database.deleteServerById(_account);
    expect(await database.getServers(), isEmpty);
    wait = (_) async => database
        .upsertServer(const Server(url: 'https://new.example', id: 'new'));
    await expectLater(api.getVideo(_videoId, serverOverride: _account),
        throwsA(isA<StateError>()));
    expect(requests, hasLength(1));
  });

  test('a route change during the retry discards its successful response',
      () async {
    respond = (request) async {
      if (requests.length == 1) {
        return _response(request, 500, {'error': _starting});
      }
      await NetworkProxy.instance.initialize(
          saved: '{"enabled":true,"host":"127.0.0.1","port":19050}',
          configureNative: false);
      return _success(request);
    };
    await expectLater(api.getVideo(_videoId, serverOverride: _account),
        throwsA(isA<StateError>()));
    expect(requests, hasLength(2));
  });

  test('returning to an account does not revive a previous session retry',
      () async {
    const other = Server(url: 'https://other.example', id: 'other');
    await database.upsertServer(other);
    await database.useServer(_account);
    wait = (_) async {
      await database.useServer(other);
      api.clearSessionCaches();
      await database.useServer(_account);
      api.clearSessionCaches();
    };
    await expectLater(api.getVideo(_videoId), throwsA(isA<StateError>()));
    expect(requests, hasLength(1));
  });

  test('the startup error is retried only once', () async {
    respond = (request) async => _response(request, 500, {'error': _starting});
    await expectLater(
        api.getVideo(_videoId),
        throwsA(isA<InvidiousServiceError>()
            .having((error) => error.statusCode, 'status', 500)));
    expect(requests, hasLength(2));
    expect(delays, hasLength(1));
  });

  test('a rate limit after startup recovery cannot schedule a third request',
      () async {
    respond = (request) async => requests.length == 1
        ? _response(request, 500, {'error': _starting})
        : _response(request, 429, {'error': 'rate_limited'},
            headers: {'retry-after': '0'});
    await expectLater(
        api.getVideo(_videoId),
        throwsA(isA<InvidiousServiceError>()
            .having((error) => error.statusCode, 'status', 429)));
    expect(requests, hasLength(2));
    expect(delays, hasLength(1));
  });

  for (final (status, message) in [
    (500, 'Unrelated internal error'),
    (500, 'access_denied'),
    (503, 'unavailable'),
    (403, _starting),
    (429, 'rate_limited'),
  ]) {
    test('$status $message is not a startup retry', () async {
      respond =
          (request) async => _response(request, status, {'error': message});
      await expectLater(
          api.getVideo(_videoId), throwsA(isA<InvidiousServiceError>()));
      expect(requests, hasLength(1));
      expect(delays, isEmpty);
    });
  }

  for (final origin in [
    'https://other.example',
    'https://invidious.nerdvpn.de.example',
    'http://invidious.nerdvpn.de',
    'https://invidious.nerdvpn.de:8443',
  ]) {
    test('startup wording from $origin does not trigger recovery', () async {
      await expectLater(
          api.getVideo(_videoId,
              serverOverride: Server(url: origin, id: 'unsaved')),
          throwsA(isA<InvidiousServiceError>()));
      expect(requests, hasLength(1));
      expect(delays, isEmpty);
    });
  }

  test('an HTML gateway error is not retried', () async {
    respond = (request) async => http.Response('<html>$_starting</html>', 500,
        request: request, headers: {'content-type': 'text/html'});
    await expectLater(
        api.getVideo(_videoId), throwsA(isA<InvidiousServiceError>()));
    expect(requests, hasLength(1));
    expect(delays, isEmpty);
  });

  for (final header in ['2', 'date']) {
    test('a short Retry-After $header is honored', () async {
      final value = header == 'date'
          ? HttpDate.format(now.add(const Duration(seconds: 2)))
          : header;
      respond = (request) async => requests.length == 1
          ? _response(request, 500, {'error': _starting},
              headers: {'retry-after': value})
          : _success(request);
      await api.getVideo(_videoId);
      expect(requests, hasLength(2));
      expect(delays, [const Duration(seconds: 2)]);
    });
  }

  test('a long server cooldown is not clamped into an early retry', () async {
    respond = (request) async => _response(request, 500, {'error': _starting},
        headers: {'retry-after': '60'});
    await expectLater(
        api.getVideo(_videoId), throwsA(isA<InvidiousServiceError>()));
    expect(requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('a malformed server cooldown cannot become an immediate startup retry',
      () async {
    respond = (request) async => _response(request, 500, {'error': _starting},
        headers: {'retry-after': 'not-a-date'});
    await expectLater(
        api.getVideo(_videoId),
        throwsA(isA<InvidiousServiceError>()
            .having((error) => error.retryAfterIsInvalid, 'invalid', isTrue)));
    expect(requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('no retry fits after the first response consumes the request budget',
      () async {
    respond = (request) async {
      now = now.add(const Duration(milliseconds: 14500));
      return _response(request, 500, {'error': _starting});
    };
    await expectLater(
        api.getVideo(_videoId), throwsA(isA<InvidiousServiceError>()));
    expect(requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('a delayed wait cannot send a request after the deadline', () async {
    wait = (_) async => now = now.add(const Duration(seconds: 16));
    await expectLater(api.getVideo(_videoId), throwsA(isA<TimeoutException>()));
    expect(requests, hasLength(1));
  });

  testWidgets('an expired operation cannot retry when its wait completes late',
      (tester) async {
    final pendingWait = Completer<void>();
    wait = (_) => pendingWait.future;
    final completed =
        expectLater(api.getVideo(_videoId), throwsA(isA<TimeoutException>()));
    await tester.pump();
    expect(delays, hasLength(1));
    await tester.pump(const Duration(seconds: 15));
    await completed;
    pendingWait.complete();
    await tester.pump();
    expect(requests, hasLength(1));
  });

  for (final override in [false, true]) {
    for (final change in ['selection', 'account', 'profile', 'proxy']) {
      test('$change changes stop ${override ? 'override' : 'normal'} recovery',
          () async {
        final initial = await database.getCurrentlySelectedServer();
        wait = (_) async {
          switch (change) {
            case 'selection':
              const other = Server(url: 'https://other.example', id: 'other');
              await database.upsertServer(other);
              await database.useServer(other);
            case 'account':
              await database.upsertServer(initial.copyWith(authToken: 'new'));
            case 'profile':
              final other = await database.createProfile('Other');
              await database.useProfile(other.id);
            case 'proxy':
              await NetworkProxy.instance.initialize(
                  saved: '{"enabled":true,"host":"127.0.0.1","port":19050}',
                  configureNative: false);
          }
        };
        await expectLater(
            api.getVideo(_videoId, serverOverride: override ? initial : null),
            throwsA(isA<StateError>()));
        expect(requests, hasLength(1));
      });
    }
  }
}
