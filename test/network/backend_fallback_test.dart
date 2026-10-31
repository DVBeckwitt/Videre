import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/dash_manifest_resolver.dart';
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
  late Server instance;
  late Service api;
  late MockClient client;

  Server configured({bool enabled = true, bool preferences = false}) {
    final selector = BackendSelector(
        preferences ? 'PREFS' : 'ROUTE',
        const [
          BackendOption('0', 'First'),
          BackendOption('1', 'Second'),
          BackendOption('2', 'Third'),
          BackendOption('3', 'Fourth'),
        ],
        automaticFallback: enabled,
        preferenceField: preferences ? 'current_companion' : null);
    return selector.withSelection(
        Server(
            url: 'https://instance.example',
            customHeaders: {
              'Cookie':
                  'SID=manual-session; PREFS=${Uri.encodeQueryComponent('{"theme":"dark","volume":35}')}',
              'X-Instance': 'preserved',
            },
            sidCookie: 'SID=account-session'),
        '0');
  }

  void respond(Future<http.Response> Function(http.Request) handler) {
    client = MockClient(handler);
    api = Service(httpClient: client);
    addTearDown(client.close);
  }

  http.Response ok() => http.Response(_videoJson, 200,
      headers: {'content-type': 'application/json'});
  http.Response failed(int code) =>
      http.Response('{"error":"unavailable"}', code,
          headers: {'content-type': 'application/json'});

  test('request snapshots retain their attempt index as retries advance', () {
    final first = BackendPlayback(configured());
    final second = first.next()!;
    final third = second.next()!;
    expect([first.retryIndex, second.retryIndex, third.retryIndex], [0, 1, 2]);
    expect(
        [first.label, second.label, third.label], ['First', 'Second', 'Third']);
    expect(first.canRetry, isFalse);
    expect(first.retries, 2);
  });

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    instance = configured();
    await db.upsertServer(instance);
    instance = await db.getCurrentlySelectedServer();
  });
  tearDown(() => db.close());

  test('temporary metadata failure retries with isolated alternate headers',
      () async {
    final routes = <String?>[];
    respond((request) async {
      routes.add(requestCookieValue(request.headers, 'ROUTE'));
      expect(requestCookieValue(request.headers, 'SID'), 'manual-session');
      expect(request.headers['x-instance'], 'preserved');
      return routes.length == 1 ? failed(502) : ok();
    });
    final video = await api.getVideo('test-video');
    expect(routes, ['0', '1']);
    expect(
        video.backendPlayback!.server.backendSelector!
            .selectedValue(video.backendPlayback!.server),
        '1');
    expect(video.backendPlayback!.retries, 1);
    expect((await db.getCurrentlySelectedServer()).customHeaders,
        instance.customHeaders);
    final serialized = jsonEncode(video.toJson());
    expect(serialized, isNot(contains('backendPlayback')));
    expect(serialized, isNot(contains('manual-session')));
    expect(serialized, isNot(contains('account-session')));
  });

  for (final status in [401, 403, 404, 429, 500]) {
    test('HTTP $status is not a backend failover signal', () async {
      var calls = 0;
      respond((_) async {
        calls++;
        return failed(status);
      });
      await expectLater(
          api.getVideo('test-video'), throwsA(isA<InvidiousServiceError>()));
      expect(calls, 1);
    });
  }

  test(
      'explicit fallback opt-out prevents retries and preserves the preference',
      () async {
    await db.upsertServer(configured(enabled: false).copyWith(inUse: true));
    var calls = 0;
    respond((_) async {
      calls++;
      return failed(503);
    });
    await expectLater(
        api.getVideo('test-video'), throwsA(isA<InvidiousServiceError>()));
    expect(calls, 1);
    expect(
        requestCookieValue(
            (await db.getCurrentlySelectedServer()).customHeaders, 'ROUTE'),
        '0');
  });

  test('initial load exhausts at most two different alternatives', () async {
    final routes = <String?>[];
    respond((request) async {
      routes.add(requestCookieValue(request.headers, 'ROUTE'));
      return failed(504);
    });
    await expectLater(
        api.getVideo('test-video'), throwsA(isA<InvidiousServiceError>()));
    expect(routes, ['0', '1', '2']);
  });

  test('explicit server callers retain their routing and retry ownership',
      () async {
    final routes = <String?>[];
    respond((request) async {
      routes.add(requestCookieValue(request.headers, 'ROUTE'));
      return failed(503);
    });
    await expectLater(api.getVideo('test-video', serverOverride: instance),
        throwsA(isA<InvidiousServiceError>()));
    expect(routes, ['0']);
  });

  test('metadata and media recovery share one budget and preserve PREFS',
      () async {
    instance = configured(preferences: true).copyWith(inUse: true);
    await db.upsertServer(instance);
    final choices = <int>[];
    respond((request) async {
      final prefs = jsonDecode(Uri.decodeQueryComponent(
          requestCookieValue(request.headers, 'PREFS')!)) as Map;
      expect(prefs['theme'], 'dark');
      expect(prefs['volume'], 35);
      expect(requestCookieValue(request.headers, 'SID'), 'manual-session');
      choices.add(prefs['current_companion'] as int);
      return choices.length == 2 ? failed(503) : ok();
    });
    final first = await api.getVideo('test-video');
    final recoveringLabels = <String>[];
    final recovered = await api.retryVideoBackend(first,
        isCurrent: () => true,
        onRetry: (request) => recoveringLabels.add(request.label));
    expect(choices, [0, 1, 2]);
    expect(recoveringLabels, ['Second', 'Third']);
    expect(recovered!.backendPlayback!.retries, 2);
    expect(
        instance.backendSelector!.selectedValue(first.backendPlayback!.server),
        '0');
    expect(
        instance.backendSelector!
            .selectedValue(recovered.backendPlayback!.server),
        '2');
    expect(
        await api.retryVideoBackend(recovered, isCurrent: () => true), isNull);
    expect(choices, hasLength(3));
    expect((await db.getCurrentlySelectedServer()).customHeaders,
        instance.customHeaders);
  });

  test('a server change during failed metadata stops retries', () async {
    var calls = 0;
    respond((_) async {
      calls++;
      await db.useServer(const Server(url: 'https://other.example'));
      return failed(503);
    });
    await expectLater(
        api.getVideo('test-video'), throwsA(isA<InvidiousServiceError>()));
    expect(calls, 1);
  });

  test('changed settings invalidate recovery even on the same instance',
      () async {
    var calls = 0;
    respond((_) async {
      calls++;
      return ok();
    });
    final video = await api.getVideo('test-video');
    await db.upsertServer(instance.copyWith(sidCookie: 'SID=new-session'));
    expect(await api.retryVideoBackend(video, isCurrent: () => true), isNull);
    expect(calls, 1);
  });

  test('successful metadata from an old selected server is discarded',
      () async {
    respond((_) async {
      await db.useServer(const Server(url: 'https://other.example'));
      return ok();
    });
    await expectLater(api.getVideo('test-video'), throwsStateError);
  });

  test('a new proxy policy invalidates the old playback recovery context',
      () async {
    respond((_) async => ok());
    final video = await api.getVideo('test-video');
    final savedPolicy = jsonEncode(NetworkProxy.instance.config.toJson());
    await NetworkProxy.instance
        .initialize(saved: savedPolicy, configureNative: false);
    expect(video.backendPlayback!.canRetry, isFalse);
    expect(await api.retryVideoBackend(video, isCurrent: () => true), isNull);
  });

  test(
      'duplicate errors cannot launch simultaneous recovery or revive a stopped video',
      () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var active = true;
    var calls = 0;
    respond((_) async {
      calls++;
      if (calls > 1) {
        started.complete();
        await finish.future;
      }
      return ok();
    });
    final video = await api.getVideo('test-video');
    final recovery = api.retryVideoBackend(video, isCurrent: () => active);
    await started.future;
    expect(await api.retryVideoBackend(video, isCurrent: () => active), isNull);
    active = false;
    finish.complete();
    expect(await recovery, isNull);
    expect(calls, 2);
    expect(video.backendPlayback!.retries, 1);
  });

  test(
      'transport classification excludes TLS, malformed data and unknown errors',
      () {
    expect(isBackendRetryable(const SocketException('unreachable')), isTrue);
    expect(isBackendRetryable(TimeoutException('timeout')), isTrue);
    expect(
        isBackendRetryable(const HandshakeException('certificate')), isFalse);
    expect(isBackendRetryable(const FormatException('bad json')), isFalse);
    expect(isBackendRetryable(StateError('unknown')), isFalse);
  });

  for (final status in [403, 404, 429, 500, 502, 503, 504]) {
    test(
        'DASH classifier preserves ordinary fallback and identifies HTTP $status',
        () async {
      respond((_) async => failed(status));
      final resolver = DashManifestResolver(client);
      const manifest =
          'https://instance.example/api/manifest/dash/id/test-video';
      expect(await resolver.resolve(manifest, 'test-video', instance), isNull);
      if ([502, 503, 504].contains(status)) {
        await expectLater(
            resolver.resolve(manifest, 'test-video', instance,
                throwRetryable: true),
            throwsA(isA<BackendPlaybackFailure>()));
      } else {
        expect(
            await resolver.resolve(manifest, 'test-video', instance,
                throwRetryable: true),
            isNull);
      }
    });
  }
}
