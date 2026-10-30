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

class _BeforeRequestService extends Service {
  final Future<void> Function() beforeRequest;

  _BeforeRequestService(http.Client httpClient, this.beforeRequest)
      : super(httpClient: httpClient);

  @override
  Future<ServerRequest> buildRequest(String baseUrl,
      {Map<String, String>? pathParams,
      Map<String, String?>? query,
      bool authenticated = false,
      String accept = 'application/json',
      bool forceJson = false,
      Server? serverOverride}) async {
    final request = await super.buildRequest(baseUrl,
        pathParams: pathParams,
        query: query,
        authenticated: authenticated,
        accept: accept,
        forceJson: forceJson,
        serverOverride: serverOverride);
    await beforeRequest();
    return request;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Server instance;
  const videoJson =
      '{"videoId":"test-video","title":"Test","adaptiveFormats":[],"formatStreams":[],"captions":[]}';

  http.Response response(int status) => http.Response(
      status == 200 ? videoJson : '{"error":"Unavailable"}', status,
      headers: {'content-type': 'application/json'});

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
        'ROUTE',
        const [
          BackendOption('0', 'First'),
          BackendOption('1', 'Second'),
          BackendOption('2', 'Third'),
          BackendOption('3', 'Fourth'),
        ],
        automaticFallback: true);
    instance = selector.withSelection(
        const Server(url: 'https://instance.example'), '0');
    await db.upsertServer(instance);
    instance = await db.getCurrentlySelectedServer();
  });
  tearDown(() => db.close());

  test(
      'notifies initial and alternate snapshots before their metadata requests',
      () async {
    final order = <String>[];
    final observed = <BackendPlayback>[];
    final client = MockClient((request) async {
      final route = requestCookieValue(request.headers, 'ROUTE');
      order.add('request $route');
      expect(requestCookieValue(observed.last.server.customHeaders, 'ROUTE'),
          route);
      return response(route == '0' ? 503 : 200);
    });
    addTearDown(client.close);
    final api = Service(httpClient: client);
    final video = await api.getVideo('test-video', onBackendRequest: (request) {
      observed.add(request);
      order.add(
          'observer ${request.server.backendSelector!.selectedValue(request.server)}');
    });
    expect(order, ['observer 0', 'request 0', 'observer 1', 'request 1']);
    expect(video.backendPlayback, same(observed.last));
    expect(observed.first.server, instance);
    expect((await db.getCurrentlySelectedServer()).customHeaders,
        instance.customHeaders);
  });

  test('exhaustion leaves the last actual request observable', () async {
    final observed = <BackendPlayback>[];
    final routes = <String?>[];
    final client = MockClient((request) async {
      routes.add(requestCookieValue(request.headers, 'ROUTE'));
      expect(observed, hasLength(routes.length));
      return response(502);
    });
    addTearDown(client.close);
    await expectLater(
        Service(httpClient: client)
            .getVideo('test-video', onBackendRequest: observed.add),
        throwsA(isA<InvidiousServiceError>()));
    expect(routes, ['0', '1', '2']);
    expect(
        observed.map((request) => request.label), ['First', 'Second', 'Third']);
  });

  for (final changeProxy in [false, true]) {
    test(
        'stale ${changeProxy ? 'proxy' : 'server'} snapshot is not announced or sent',
        () async {
      final observed = <BackendPlayback>[];
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return response(503);
      });
      addTearDown(client.close);
      var built = 0;
      final api = _BeforeRequestService(client, () async {
        built++;
        if (built != 2) return;
        if (changeProxy) {
          await NetworkProxy.instance.initialize(
              saved: jsonEncode(NetworkProxy.instance.config.toJson()),
              configureNative: false);
        } else {
          await db.useServer(const Server(url: 'https://changed.example'));
        }
      });
      await expectLater(
          api.getVideo('test-video', onBackendRequest: observed.add),
          throwsStateError);
      expect(requests, 1);
      expect(observed, hasLength(1));
      expect(observed.single.label, 'First');
    });
  }

  test('server change before initial dispatch does not publish an old request',
      () async {
    final observed = <BackendPlayback>[];
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return response(200);
    });
    addTearDown(client.close);
    final api = _BeforeRequestService(client,
        () => db.useServer(const Server(url: 'https://changed.example')));
    await expectLater(
        api.getVideo('test-video', onBackendRequest: observed.add),
        throwsStateError);
    expect(observed, isEmpty);
    expect(requests, 0);
  });

  test('unsupported instance still publishes its initial request snapshot',
      () async {
    await db.useServer(const Server(url: 'https://plain.example'));
    final observed = <BackendPlayback>[];
    final client = MockClient((request) async {
      expect(observed, hasLength(1));
      expect(observed.single.server.url, 'https://plain.example');
      return response(200);
    });
    addTearDown(client.close);
    final video = await Service(httpClient: client)
        .getVideo('test-video', onBackendRequest: observed.add);
    expect(video.backendPlayback, isNull);
    expect(observed.single.server.backendSelector, isNull);
  });
}
