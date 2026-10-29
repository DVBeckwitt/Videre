import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/network/onion_verification.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _origin =
    'http://nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion';
final _stats = Uri.parse('$_origin/api/v1/stats');
const _json = '{"software":{"name":"invidious"}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/onion-verification');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var now = DateTime(2026, 10, 28);
  late OnionVerification verifier;
  var verifies = 0;
  Map<String, Object?> saved = {};
  Future<Object?> Function()? verification;

  Map<String, Object?> session({String cookie = 'gandalf=test-session'}) => {
        'headers': {
          'Cookie': cookie,
          'User-Agent': 'system-webview-test',
          'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          'Accept-Encoding': 'identity',
        },
        'expiresAt': now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      };

  http.Response challenge() => http.Response(
        '<!doctype html><title>Gandalf verification</title>',
        403,
        headers: {'content-type': 'text/html'},
      );

  setUp(() async {
    now = DateTime(2026, 10, 28);
    verifies = 0;
    saved = {};
    verification = null;
    verifier = OnionVerification.forTesting(channel: channel, now: () => now);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getOnionSessions') return saved;
      expect(call.method, 'verifyOnionSession');
      expect(call.arguments, {'url': _origin});
      verifies++;
      return verification == null ? session() : await verification!();
    });
    await verifier.initialize(proxyEnabled: true);
  });

  tearDown(() {
    verifier.reset();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'only eligible proxy-routed HTTP v3 onion origins receive sessions',
    () async {
      saved = {_origin: session()};
      await verifier.initialize(proxyEnabled: true);
      expect(verifier.headersFor(_stats, {})['cookie'], 'gandalf=test-session');
      for (final url in [
        'https://${_stats.host}/api/v1/stats',
        'http://${_stats.host}:8080/api/v1/stats',
        'http://sub.${_stats.host}/api/v1/stats',
        'http://user@${_stats.host}/api/v1/stats',
        'http://other.onion/api/v1/stats',
        'http://localhost/api/v1/stats',
        'https://example.org/api/v1/stats',
      ]) {
        expect(verifier.headersFor(Uri.parse(url), {}), isEmpty, reason: url);
        expect(
          verifier.needsVerification(Uri.parse(url), challenge()),
          isFalse,
        );
      }
      await verifier.initialize(proxyEnabled: false);
      expect(verifier.headersFor(_stats, {}), isEmpty);
      expect(verifier.needsVerification(_stats, challenge()), isFalse);
    },
  );

  test(
    'merges fingerprints and cookies without replacing the account SID',
    () async {
      saved = {_origin: session(cookie: 'gandalf=new; SID=anonymous')};
      await verifier.initialize(proxyEnabled: true);
      final headers = verifier.headersFor(_stats, {
        'aCcEpT': 'application/json',
        'USER-agent': 'Videre',
        'Cookie': 'SID=account; private=keep; gandalf=old',
        'Authorization': 'Bearer test-token',
      });
      expect(headers['accept'], contains('text/html'));
      expect(headers['user-agent'], 'system-webview-test');
      expect(headers['authorization'], 'Bearer test-token');
      expect(headers['cookie'], 'SID=account; private=keep; gandalf=new');
      expect(
        headers.keys.where((name) => name.toLowerCase() == 'accept'),
        hasLength(1),
      );
      now = now.add(const Duration(hours: 2));
      expect(verifier.headersFor(_stats, {}), isEmpty);
    },
  );

  test('ignores corrupt, unexpected and expired stored sessions', () async {
    for (final value in [
      null,
      {'headers': <String, String>{}, 'expiresAt': 1},
      {
        'headers': {'Cookie': 'bad\r\nvalue'},
        'expiresAt': 9999999999999,
      },
      {
        'headers': {
          'Cookie': 'g=x',
          'User-Agent': 'browser',
          'Authorization': 'x',
        },
        'expiresAt': 9999999999999,
      },
    ]) {
      saved = {_origin: value};
      await verifier.initialize(proxyEnabled: true);
      expect(verifier.headersFor(_stats, {}), isEmpty);
    }
  });

  test('recognizes only Gandalf HTML or same-origin challenge redirects', () {
    expect(verifier.needsVerification(_stats, challenge()), isTrue);
    expect(
      verifier.needsVerification(
        _stats,
        http.Response('', 307, headers: {'location': '/.gandalf/check?q=1'}),
      ),
      isTrue,
    );
    for (final response in [
      http.Response(
        '{"error":"Gandalf account unavailable"}',
        403,
        headers: {'content-type': 'application/json'},
      ),
      http.Response('<html>Forbidden</html>', 403),
      http.Response('<html>Gandalf</html>', 429),
      http.Response(
        '',
        307,
        headers: {'location': 'http://other.onion/.gandalf/check'},
      ),
    ]) {
      expect(verifier.needsVerification(_stats, response), isFalse);
    }
  });

  test(
    'validation completes the challenge once and retries with the session',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        expect(request.followRedirects, isFalse);
        return request.headers.containsKey('cookie')
            ? http.Response(_json, 200)
            : challenge();
      });
      addTearDown(client.close);
      await Service(
        httpClient: client,
        onionVerification: verifier,
      ).validateServer(_origin, {'X-Private': 'retained'});
      expect(verifies, 1);
      expect(requests, hasLength(2));
      expect(requests.last.headers['cookie'], 'gandalf=test-session');
      expect(requests.last.headers['user-agent'], 'system-webview-test');
      expect(requests.last.headers['accept'], contains('text/html'));
      expect(requests.last.headers['x-private'], 'retained');
    },
  );

  test(
    'rejected renewed session is not verified or retried in a loop',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return challenge();
      });
      addTearDown(client.close);
      await expectLater(
        Service(
          httpClient: client,
          onionVerification: verifier,
        ).validateServer(_origin, {}),
        throwsA(isA<InvidiousServiceError>()),
      );
      expect(verifies, 1);
      expect(requests, 2);
    },
  );

  test(
    'background reads reuse saved sessions without opening verification',
    () async {
      saved = {_origin: session()};
      await verifier.initialize(proxyEnabled: true);
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.headers['cookie'], 'gandalf=test-session');
        return challenge();
      });
      addTearDown(client.close);
      await expectLater(
        Service(
          httpClient: client,
          onionVerification: verifier,
          allowOnionVerification: false,
        ).validateServer(_origin, {}),
        throwsA(isA<InvidiousServiceError>()),
      );
      expect(verifies, 0);
      expect(requests, 1);
    },
  );

  test(
    'coalesces verification and reuses renewal for late rejected reads',
    () async {
      final pending = Completer<Object?>();
      verification = () => pending.future;
      final epoch = verifier.policyEpoch;
      final first = verifier.verify(
        _stats,
        previousSession: null,
        policyEpoch: epoch,
      );
      final second = verifier.verify(
        _stats,
        previousSession: null,
        policyEpoch: epoch,
      );
      pending.complete(session());
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(
        await verifier.verify(
          _stats,
          previousSession: null,
          policyEpoch: epoch,
        ),
        isTrue,
      );
      expect(verifies, 1);
    },
  );

  test(
    'a proxy change discards in-flight and delayed verification results',
    () async {
      final pending = Completer<Object?>();
      verification = () => pending.future;
      final epoch = verifier.policyEpoch;
      final result = verifier.verify(
        _stats,
        previousSession: null,
        policyEpoch: epoch,
      );
      verifier.reset();
      pending.complete(session());
      expect(await result, isFalse);
      expect(verifier.headersFor(_stats, {}), isEmpty);
      await verifier.initialize(proxyEnabled: true);
      expect(
        await verifier.verify(
          _stats,
          previousSession: null,
          policyEpoch: epoch,
        ),
        isFalse,
      );
      expect(verifies, 1);
    },
  );

  test(
    'cancelled verification preserves the HTTP error without secrets',
    () async {
      verification = () async => throw PlatformException(
            code: 'ONION_VERIFICATION_CANCELLED',
            message: 'Cookie: do-not-log',
          );
      final client = MockClient((_) async => challenge());
      addTearDown(client.close);
      await expectLater(
        Service(
          httpClient: client,
          onionVerification: verifier,
        ).validateServer(_origin, {}),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('do-not-log')),
          ),
        ),
      );
      expect(verifies, 1);
    },
  );

  test(
    'unsupported WebView reports a fixed safe error without retrying',
    () async {
      verification = () async => throw PlatformException(
            code: 'ONION_VERIFICATION_UNSUPPORTED_WEBVIEW',
            message: 'Cookie: do-not-log',
          );
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return challenge();
      });
      addTearDown(client.close);
      await expectLater(
        Service(httpClient: client, onionVerification: verifier)
            .validateServer(_origin, {}),
        throwsA(isA<InvidiousServiceError>().having(
          (error) => error.toString(),
          'message',
          'The system Android WebView needs an update to verify this onion '
              'instance securely.',
        )),
      );
      expect(requests, 1);
      expect(verifies, 1);
    },
  );

  test(
    'stops cross-origin redirects before cookies can leave the onion',
    () async {
      saved = {_origin: session()};
      await verifier.initialize(proxyEnabled: true);
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url, _stats);
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://example.org/api/v1/stats'},
        );
      });
      addTearDown(client.close);
      await expectLater(
        Service(
          httpClient: client,
          onionVerification: verifier,
        ).validateServer(_origin, {}),
        throwsA(isA<InvidiousServiceError>()),
      );
      expect(requests, 1);
      expect(verifies, 0);
    },
  );

  test(
    'mutations merge account cookies but never redirect, verify or retry',
    () async {
      db = await SembastSqfDb.createInMemory();
      addTearDown(db.close);
      await db.upsertServer(
        const Server(
          url: _origin,
          sidCookie: 'SID=account',
          customHeaders: {'cookie': 'private=keep'},
          inUse: true,
        ),
      );
      saved = {_origin: session()};
      await verifier.initialize(proxyEnabled: true);
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(
          request.headers['cookie'],
          'private=keep; SID=account; gandalf=test-session',
        );
        return challenge();
      });
      addTearDown(client.close);
      await expectLater(
        Service(
          httpClient: client,
          onionVerification: verifier,
        ).createPlayList('Test', 'private'),
        throwsA(isA<InvidiousServiceError>()),
      );
      expect(requests, 1);
      expect(verifies, 0);
    },
  );
}
