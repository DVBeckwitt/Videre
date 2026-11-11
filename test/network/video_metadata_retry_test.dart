import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _videoId = '9bZkp7q19f0';
const _account = Server(
    url: 'https://instance.example',
    id: 'metadata-account',
    customHeaders: {'X-Test-Account': 'fixture', 'Cookie': 'COMPANION_ID=1'});

class _DirectHttpOverrides extends HttpOverrides {}

http.Response _response(http.Request request, int status,
        {String error = 'Temporary metadata failure',
        Map<String, String> headers = const {}}) =>
    http.Response(
        jsonEncode(status == 200
            ? {'videoId': _videoId, 'title': 'Test video'}
            : {'error': error}),
        status,
        request: request,
        headers: {'content-type': 'application/json', ...headers});

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late Service api;
  late DateTime now;
  late bool current;
  late int retries;
  late Future<void> Function(Duration) wait;
  late Future<http.Response> Function(http.Request) respond;
  final requests = <http.Request>[];
  final delays = <Duration>[];

  Future<Video> load({VideoLoadObserver? observer}) => api.getVideo(_videoId,
      loadObserver: observer ??
          VideoLoadObserver(
              isCurrent: () => current, onRetry: () => retries++));

  Future<Server> selectFallbacks() async {
    final selector = BackendSelector(
        'ROUTE',
        const [
          BackendOption('0', 'Preferred'),
          BackendOption('1', 'Second'),
          BackendOption('2', 'Third'),
        ],
        automaticFallback: true);
    final selected = selector.withSelection(_account, '0');
    await database.upsertServer(selected);
    await database.useServer(selected);
    return selected;
  }

  setUp(() async {
    db = database = await SembastSqfDb.createInMemory();
    await database.upsertServer(_account);
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    now = DateTime.utc(2026, 11, 10);
    current = true;
    retries = 0;
    requests.clear();
    delays.clear();
    wait = (delay) async => now = now.add(delay);
    respond =
        (request) async => _response(request, requests.length == 1 ? 503 : 200);
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

  for (final status in [500, 502, 503, 504, 408]) {
    test('interactive HTTP $status retries the exact metadata route once',
        () async {
      respond = (request) async =>
          _response(request, requests.length == 1 ? status : 200);
      expect((await load()).videoId, _videoId);
      expect(requests, hasLength(2));
      expect(requests.last.method, 'GET');
      expect(requests.last.url, requests.first.url);
      expect(requests.last.headers, requests.first.headers);
      expect(requests.last.url.path, '/api/v1/videos/$_videoId');
      expect(requests.last.url.queryParameters['local'], 'true');
      expect(requests.last.headers['Cookie'], 'COMPANION_ID=1');
      expect(delays, [const Duration(seconds: 1)]);
      expect(retries, 1);
    });
  }

  test('interactive NerdVPN generic 500 can recover without startup wording',
      () async {
    final nerd = _account.copyWith(url: 'https://invidious.nerdvpn.de');
    await database.upsertServer(nerd);
    await database.useServer(nerd);
    respond =
        (request) async => _response(request, requests.length == 1 ? 500 : 200);
    expect((await load()).videoId, _videoId);
    expect(requests, hasLength(2));
    expect(requests.map((request) => request.url.origin), [nerd.url, nerd.url]);
    expect(retries, 1);
  });

  for (final header in ['2', 'date']) {
    test('interactive short 429 Retry-After $header shares the one retry',
        () async {
      final value = header == 'date'
          ? HttpDate.format(now.add(const Duration(seconds: 2)))
          : header;
      respond = (request) async => requests.length == 1
          ? _response(request, 429, headers: {'retry-after': value})
          : _response(request, 200);
      await load();
      expect(requests, hasLength(2));
      expect(delays, [const Duration(seconds: 2)]);
      expect(retries, 1);
    });
  }

  for (final statuses in [
    [503, 429],
    [429, 503],
    [500, 500],
  ]) {
    test('interactive exhaustion $statuses never stacks another GET retry',
        () async {
      respond = (request) async => _response(
          request, requests.length == 1 ? statuses.first : statuses.last,
          headers: const {'retry-after': '0'});
      await expectLater(
          load(),
          throwsA(isA<InvidiousServiceError>()
              .having((error) => error.statusCode, 'status', statuses.last)));
      expect(requests, hasLength(2));
      expect(retries, 1);
      expect(delays.length, lessThanOrEqualTo(1));
    });
  }

  for (final status in [401, 403, 404, 429]) {
    test('interactive HTTP $status without a short cooldown is terminal',
        () async {
      respond = (request) async => _response(request, status);
      await expectLater(load(), throwsA(isA<InvidiousServiceError>()));
      expect(requests, hasLength(1));
      expect(retries, 0);
      expect(delays, isEmpty);
    });
  }

  for (final status in [429, 503]) {
    test('interactive HTTP $status never shortens a long cooldown', () async {
      respond = (request) async =>
          _response(request, status, headers: const {'retry-after': '60'});
      await expectLater(load(), throwsA(isA<InvidiousServiceError>()));
      expect(requests, hasLength(1));
      expect(retries, 0);
      expect(delays, isEmpty);
    });
  }

  for (final (status, error) in [
    (500, 'access_denied'),
    (503, 'unavailable')
  ]) {
    test('interactive NerdVPN access failure $error is terminal', () async {
      final nerd = _account.copyWith(url: 'https://invidious.nerdvpn.de');
      await database.upsertServer(nerd);
      await database.useServer(nerd);
      respond = (request) async => _response(request, status, error: error);
      await expectLater(
          load(),
          throwsA(isA<InvidiousServiceError>().having(
              (error) => error.isGatewayAccessFailure, 'access', true)));
      expect(requests, hasLength(1));
      expect(retries, 0);
    });
  }

  for (final failure in [
    TimeoutException('Fixture timeout'),
    const SocketException('Fixture connection reset',
        osError: OSError('Connection reset', 10054)),
  ]) {
    test('interactive ${failure.runtimeType} retries once on the same route',
        () async {
      respond = (request) async =>
          requests.length == 1 ? throw failure : _response(request, 200);
      await load();
      expect(requests, hasLength(2));
      expect(requests.last.url, requests.first.url);
      expect(requests.last.headers, requests.first.headers);
      expect(retries, 1);
    });
  }

  for (final failure in [
    const HandshakeException('Fixture TLS refusal'),
    const NerdVpnAccessRequired('cooldown'),
    const GatewayAuthenticationRequired(),
    http.ClientException('A message mentioning timeout is not a typed timeout'),
  ]) {
    test('interactive ${failure.runtimeType} is not a transport retry',
        () async {
      respond = (_) async => throw failure;
      await expectLater(load(), throwsA(same(failure)));
      expect(requests, hasLength(1));
      expect(retries, 0);
      expect(delays, isEmpty);
    });
  }

  test('the actual official-host privacy refusal cannot trigger a retry',
      () async {
    await selectFallbacks();
    final guarded = _DirectHttpOverrides().createHttpClient(null);
    Object? refusal;
    try {
      configureSocksHttpClient(guarded, SocksProxyConfig());
      guarded.connectionFactory = (_, __, ___) =>
          throw StateError('The guard must run before any connection');
      try {
        await guarded.getUrl(Uri.parse('https://music.youtube.com/'));
      } catch (error) {
        refusal = error;
      }
    } finally {
      guarded.close(force: true);
    }
    expect(refusal, isNotNull);
    expect(refusal, isNot(isA<StateError>()));
    respond = (_) async => throw refusal!;
    await expectLater(load(), throwsA(same(refusal)));
    expect(requests, hasLength(1));
    expect(retries, 0);
  });

  for (final entry in ['interactive', 'plain', 'manual', 'recovery']) {
    for (final cooldown in ['60', 'not-a-date']) {
      test('$entry does not bypass $cooldown cooldown with another backend',
          () async {
        final selected = await selectFallbacks();
        final route = BackendPlayback(selected);
        respond = (request) async =>
            _response(request, 503, headers: {'retry-after': cooldown});
        final Future<Video?> result = switch (entry) {
          'interactive' => load(),
          'plain' => api.getVideo(_videoId),
          'manual' => api.getVideoForBackend(
              _videoId, BackendPlayback.manual(selected, '0')),
          _ => api.retryVideoBackend(
              Video(videoId: _videoId, backendPlayback: route),
              isCurrent: () => true),
        };
        await expectLater(result, throwsA(isA<InvidiousServiceError>()));
        expect(requests, hasLength(1));
        expect(delays, isEmpty);
      });
    }
  }

  test('an elapsed cooldown does not disable subsequent backend fallback',
      () async {
    await selectFallbacks();
    respond = (request) async {
      if (requests.length == 1) {
        return _response(request, 503, headers: {'retry-after': '1'});
      }
      return _response(request,
          requestCookieValue(request.headers, 'ROUTE') == '1' ? 200 : 503);
    };
    await load();
    expect(
        requests.map((request) => requestCookieValue(request.headers, 'ROUTE')),
        ['0', '0', '1']);
    expect(delays, [const Duration(seconds: 1)]);
  });

  test('an expired server cooldown still allows backend fallback', () async {
    final selected = await selectFallbacks();
    respond = (request) async =>
        requestCookieValue(request.headers, 'ROUTE') == '1'
            ? _response(request, 200)
            : _response(request, 503, headers: {'retry-after': '0'});
    await api.getVideoForBackend(
        _videoId, BackendPlayback.manual(selected, '0'));
    expect(
        requests.map((request) => requestCookieValue(request.headers, 'ROUTE')),
        ['0', '1']);
  });

  test('noninteractive generic failures retain their existing single request',
      () async {
    respond = (request) async => _response(request, 500);
    await expectLater(
        api.getVideo(_videoId), throwsA(isA<InvidiousServiceError>()));
    expect(requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('only the preferred backend receives a same-route retry', () async {
    final selector = BackendSelector(
        'ROUTE',
        const [
          BackendOption('0', 'Preferred'),
          BackendOption('1', 'Second'),
          BackendOption('2', 'Third'),
        ],
        automaticFallback: true);
    final selected = selector.withSelection(_account, '0');
    await database.upsertServer(selected);
    await database.useServer(selected);
    respond = (request) async => _response(request,
        requestCookieValue(request.headers, 'ROUTE') == '2' ? 200 : 503);
    final result = await load();
    expect(
        requests.map((request) => requestCookieValue(request.headers, 'ROUTE')),
        ['0', '0', '1', '2']);
    expect(result.backendPlayback!.retries, 2);
    expect(retries, 1);
    expect((await database.getCurrentlySelectedServer()).customHeaders,
        selected.customHeaders);
  });

  for (final change in [
    'listener',
    'proxy',
    'account',
    'selection',
    'session'
  ]) {
    test('interactive $change change invalidates pending retry', () async {
      wait = (_) async {
        switch (change) {
          case 'listener':
            current = false;
          case 'proxy':
            await NetworkProxy.instance.initialize(
                saved: '{"enabled":true,"host":"127.0.0.1","port":19050}',
                configureNative: false);
          case 'account':
            await database
                .upsertServer(_account.copyWith(authToken: 'changed'));
          case 'selection':
            const other = Server(url: 'https://other.example', id: 'other');
            await database.upsertServer(other);
            await database.useServer(other);
          case 'session':
            api.clearSessionCaches();
        }
      };
      await expectLater(load(), throwsA(isA<StateError>()));
      expect(requests, hasLength(1));
    });
  }

  test('interactive retry cannot exceed the shared fifteen-second budget',
      () async {
    respond = (request) async {
      now = now.add(const Duration(milliseconds: 14500));
      return _response(request, 503);
    };
    await expectLater(load(), throwsA(isA<InvidiousServiceError>()));
    expect(requests, hasLength(1));
    expect(retries, 0);
    expect(delays, isEmpty);
  });

  test('interactive wait that outlives the deadline cannot dispatch again',
      () async {
    wait = (_) async => now = now.add(const Duration(seconds: 16));
    await expectLater(load(), throwsA(isA<TimeoutException>()));
    expect(requests, hasLength(1));
    expect(retries, 1);
  });

  test('concurrent same-key listeners share one retry and each receive notice',
      () async {
    final firstResponse = Completer<http.Response>();
    final firstRequest = Completer<http.Request>();
    final waiting = Completer<void>();
    final releaseWait = Completer<void>();
    var firstRetries = 0;
    var secondRetries = 0;
    respond = (request) async {
      if (requests.length == 1) {
        firstRequest.complete(request);
        return firstResponse.future;
      }
      return _response(request, 200);
    };
    wait = (_) {
      if (!waiting.isCompleted) waiting.complete();
      return releaseWait.future;
    };
    final first = load(
        observer: VideoLoadObserver(
            isCurrent: () => true, onRetry: () => firstRetries++));
    final request =
        await firstRequest.future.timeout(const Duration(seconds: 2));
    final second = load(
        observer: VideoLoadObserver(
            isCurrent: () => true, onRetry: () => secondRetries++));
    await _flush();
    firstResponse.complete(_response(request, 503));
    await waiting.future.timeout(const Duration(seconds: 2));
    await _flush();
    final pendingRequestCount = requests.length;
    final retryNotices = [firstRetries, secondRetries];
    releaseWait.complete();
    expect((await first).videoId, _videoId);
    expect((await second).videoId, _videoId);
    expect(pendingRequestCount, 1);
    expect(retryNotices, [1, 1]);
    expect(requests, hasLength(2));
    expect(delays, hasLength(1));
  });

  test('one stale listener cannot cancel another listener shared retry',
      () async {
    final waiting = Completer<void>();
    final releaseWait = Completer<void>();
    var firstActive = true;
    var secondRetries = 0;
    wait = (_) {
      if (!waiting.isCompleted) waiting.complete();
      return releaseWait.future;
    };
    final first = load(
        observer:
            VideoLoadObserver(isCurrent: () => firstActive, onRetry: () {}));
    final firstResult = expectLater(first, throwsA(isA<StateError>()));
    await waiting.future.timeout(const Duration(seconds: 2));
    final second = load(
        observer: VideoLoadObserver(
            isCurrent: () => true, onRetry: () => secondRetries++));
    await _flush();
    firstActive = false;
    releaseWait.complete();
    await firstResult;
    expect((await second).videoId, _videoId);
    expect(requests, hasLength(2));
    expect(secondRetries, 1);
    expect(delays, hasLength(1));
  });
}
