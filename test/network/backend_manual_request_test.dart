import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _videoJson =
    '{"videoId":"test-video","title":"Test","adaptiveFormats":[],"formatStreams":[],"captions":[]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Server preferred;

  http.Response response(int status) => http.Response(
      status == 200 ? _videoJson : '{"error":"Unavailable"}', status,
      headers: {'content-type': 'application/json'});

  Service apiFor(Future<http.Response> Function(http.Request) handler) {
    final client = MockClient(handler);
    addTearDown(client.close);
    return Service(httpClient: client);
  }

  String? choice(Map<String, String> headers) {
    final prefs = jsonDecode(
            Uri.decodeQueryComponent(requestCookieValue(headers, 'PREFS')!))
        as Map<String, dynamic>;
    return prefs['current_companion']?.toString();
  }

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
      'PREFS',
      const [
        BackendOption('0', 'First'),
        BackendOption('1', 'Second'),
        BackendOption('2', 'Third'),
        BackendOption('3', 'Fourth'),
      ],
      automaticFallback: true,
      preferenceField: 'current_companion',
    );
    preferred = selector.withSelection(
        Server(
            url: 'https://instance.example',
            customHeaders: {
              'Cookie':
                  'SID=manual-session; PREFS=${Uri.encodeQueryComponent('{"theme":"dark","volume":35}')}',
              'Authorization': 'Bearer custom-token',
              'X-Instance': 'preserved',
            },
            sidCookie: 'SID=account-session',
            authToken: 'account-token'),
        '0');
    await db.upsertServer(preferred);
    preferred = await db.getCurrentlySelectedServer();
  });
  tearDown(() => db.close());

  test(
      'manual request uses selected cookie and preserves saved preferences and authentication',
      () async {
    final observed = <BackendPlayback>[];
    final manual = BackendPlayback.manual(preferred, '2');
    var calls = 0;
    final api = apiFor((request) async {
      calls++;
      expect(observed, [manual]);
      expect(request.url.host, 'instance.example');
      expect(choice(request.headers), '2');
      final prefs = jsonDecode(Uri.decodeQueryComponent(
          requestCookieValue(request.headers, 'PREFS')!)) as Map;
      expect(prefs['theme'], 'dark');
      expect(prefs['volume'], 35);
      expect(requestCookieValue(request.headers, 'SID'), 'manual-session');
      expect(request.headers['authorization'], 'Bearer custom-token');
      expect(request.headers['x-instance'], 'preserved');
      return response(200);
    });
    final video = await api.getVideoForBackend('test-video', manual,
        onBackendRequest: observed.add);
    expect(calls, 1);
    expect(video.backendPlayback, same(manual));
    expect(manual.matches(preferred), isTrue);
    expect(manual.server.sidCookie, preferred.sidCookie);
    expect(manual.server.authToken, preferred.authToken);
    expect(await db.getCurrentlySelectedServer(), preferred);
    expect(choice(preferred.customHeaders), '0');
  });

  test(
      'manual metadata and subsequent media fallback share the two-alternative budget',
      () async {
    final routes = <String?>[];
    final api = apiFor((request) async {
      routes.add(choice(request.headers));
      return response(routes.length == 1 ? 503 : 200);
    });
    final manual = BackendPlayback.manual(preferred, '3');
    final video = await api.getVideoForBackend('test-video', manual);
    expect(routes, ['3', '0']);
    expect(video.backendPlayback!.retryIndex, 1);
    final recovered = await api.retryVideoBackend(video, isCurrent: () => true);
    expect(routes, ['3', '0', '1']);
    expect(recovered!.backendPlayback!.retryIndex, 2);
    expect(recovered.backendPlayback!.manualSelection, isTrue);
    expect(
        await api.retryVideoBackend(recovered, isCurrent: () => true), isNull);
    expect(routes, hasLength(3));
    expect(manual.retries, 2);
    expect(await db.getCurrentlySelectedServer(), preferred);
  });

  test('manual metadata exhaustion visits only two alternatives', () async {
    final routes = <String?>[];
    final observed = <BackendPlayback>[];
    final api = apiFor((request) async {
      routes.add(choice(request.headers));
      return response(502);
    });
    final manual = BackendPlayback.manual(preferred, '2');
    await expectLater(
        api.getVideoForBackend('test-video', manual,
            onBackendRequest: observed.add),
        throwsA(isA<InvidiousServiceError>()));
    expect(routes, ['2', '0', '1']);
    expect(observed.map((request) => request.retryIndex), [0, 1, 2]);
    expect(manual.canRetry, isFalse);
    expect(manual.next(), isNull);
    expect(await db.getCurrentlySelectedServer(), preferred);
  });

  test('manual HTTP403 stops without automatic rotation', () async {
    final routes = <String?>[];
    final api = apiFor((request) async {
      routes.add(choice(request.headers));
      return response(403);
    });
    final manual = BackendPlayback.manual(preferred, '2');
    await expectLater(api.getVideoForBackend('test-video', manual),
        throwsA(isA<InvidiousServiceError>()));
    expect(routes, ['2']);
    expect(manual.retries, 0);
    expect(await db.getCurrentlySelectedServer(), preferred);
  });

  test(
      'stale connection and cancelled video cannot send or continue manual requests',
      () async {
    var calls = 0;
    var active = true;
    final observed = <BackendPlayback>[];
    final api = apiFor((request) async {
      calls++;
      active = false;
      return response(503);
    });
    final staleServer = BackendPlayback.manual(preferred, '2');
    await db.upsertServer(preferred.copyWith(sidCookie: 'SID=changed-session'));
    await expectLater(
        api.getVideoForBackend('test-video', staleServer,
            onBackendRequest: observed.add),
        throwsStateError);
    expect(calls, 0);
    expect(observed, isEmpty);
    await db.upsertServer(preferred);

    final staleProxy = BackendPlayback.manual(preferred, '2');
    await NetworkProxy.instance.initialize(
        saved: jsonEncode(NetworkProxy.instance.config.toJson()),
        configureNative: false);
    await expectLater(
        api.getVideoForBackend('test-video', staleProxy,
            onBackendRequest: observed.add),
        throwsStateError);
    expect(calls, 0);
    expect(observed, isEmpty);

    final manual = BackendPlayback.manual(preferred, '2');
    await expectLater(
        api.getVideoForBackend('test-video', manual,
            isCurrent: () => false, onBackendRequest: observed.add),
        throwsStateError);
    expect(calls, 0);
    expect(observed, isEmpty);

    await expectLater(
        api.getVideoForBackend('test-video', manual,
            isCurrent: () => active, onBackendRequest: observed.add),
        throwsA(isA<InvidiousServiceError>()));
    expect(calls, 1);
    expect(observed, [manual]);
    expect(manual.retries, 0);
  });
}
