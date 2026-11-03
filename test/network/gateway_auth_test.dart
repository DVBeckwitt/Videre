import 'dart:async';

import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/gateway_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sessions = MethodChannel('videre/gateway_sessions');
  const browser = MethodChannel('videre/gateway_auth');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Server server(String id, {bool gatewayEnabled = true}) => Server(
      url: 'https://instance.example',
      id: id,
      profileId: 'person-fixture',
      gatewayEnabled: gatewayEnabled);

  Map<String, Object> enabled(int revision) => {
        'supported': true,
        'enabled': true,
        'needsSignIn': false,
        'revision': revision,
      };

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(sessions, null);
    messenger.setMockMethodCallHandler(browser, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('a newer sign-in supersedes logout still awaiting session status',
      () async {
    final account = server('delayed-status');
    final statusStarted = Completer<void>();
    final statusResult = Completer<Map<String, Object>>();
    final sessionCalls = <String>[];
    final browserCalls = <String>[];
    messenger.setMockMethodCallHandler(sessions, (call) async {
      sessionCalls.add(call.method);
      if (call.method == 'status') {
        statusStarted.complete();
        return statusResult.future;
      }
      fail('The superseded logout must not revoke a newer sign-in.');
    });
    messenger.setMockMethodCallHandler(browser, (call) async {
      browserCalls.add(call.method);
      return call.method == 'signIn' ? 'new-fixture-token' : null;
    });

    final logout = GatewayAuth.signOut(account);
    await statusStarted.future;
    final login = GatewayAuth.signIn(account);
    await Future<void>.delayed(Duration.zero);
    expect(browserCalls, isEmpty);
    statusResult.complete(enabled(5));
    await logout;
    expect(await login, 'new-fixture-token');
    expect(sessionCalls, ['status']);
    expect(browserCalls, ['close', 'signIn']);
  });

  test(
      'a new sign-in waits until an already-started native revocation finishes',
      () async {
    final account = server('started-revocation');
    final revokeStarted = Completer<void>();
    final revokeComplete = Completer<void>();
    final events = <String>[];
    messenger.setMockMethodCallHandler(sessions, (call) async {
      if (call.method == 'status') {
        events.add('status');
        return enabled(7);
      }
      expect(call.method, 'signOut');
      expect((call.arguments as Map)['revision'], 7);
      events.add('revoke-start');
      revokeStarted.complete();
      await revokeComplete.future;
      events.add('revoke-complete');
      return null;
    });
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method == 'close') {
        events.add('close:${(call.arguments as Map)['revision']}');
        return null;
      }
      expect(call.method, 'signIn');
      events.add('signIn');
      return 'replacement-fixture-token';
    });

    final logout = GatewayAuth.signOut(account);
    await revokeStarted.future;
    final login = GatewayAuth.signIn(account);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['status', 'close:7', 'revoke-start']);
    revokeComplete.complete();
    await logout;
    expect(await login, 'replacement-fixture-token');
    expect(events, [
      'status',
      'close:7',
      'revoke-start',
      'revoke-complete',
      'close:null',
      'signIn',
    ]);
  });

  test(
      'logout closes a pending login with its revision and ignores its late token',
      () async {
    final account = server('pending-login');
    final context = GatewayRequestContext.forAccount(
            account.profileId, account.accountId, account.url)!
        .encoded;
    final loginStarted = Completer<void>();
    final loginResult = Completer<String?>();
    final revocations = <Map<Object?, Object?>>[];
    final closes = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(sessions, (call) async {
      if (call.method == 'status') return enabled(11);
      expect(call.method, 'signOut');
      revocations.add(Map.from(call.arguments as Map));
      return null;
    });
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method == 'signIn') {
        expect((call.arguments as Map)['context'], context);
        loginStarted.complete();
        return loginResult.future;
      }
      expect(call.method, 'close');
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      closes.add(arguments);
      if (arguments['revision'] == 11) {
        loginResult.complete('stale-fixture-token');
      }
      return null;
    });

    final login = GatewayAuth.signIn(account);
    await loginStarted.future;
    await GatewayAuth.signOut(account);
    expect(await login, isNull);
    expect(closes, [
      {'context': context},
      {'context': context, 'revision': 11},
    ]);
    expect(revocations, [
      {'context': context, 'revision': 11}
    ]);
  });

  test(
      'missing native session plugin fails closed only for a protected account',
      () async {
    final protected = server('missing-protected');
    await expectLater(GatewayAuth.status(protected),
        throwsA(isA<GatewayTransportUnavailable>()));
    await expectLater(GatewayAuth.signOut(protected),
        throwsA(isA<GatewayTransportUnavailable>()));

    final ordinary = server('missing-ordinary', gatewayEnabled: false);
    final status = await GatewayAuth.status(ordinary);
    expect(status.supported, isFalse);
    expect(status.enabled, isFalse);
    expect(status.needsSignIn, isFalse);
    await expectLater(GatewayAuth.signOut(ordinary), completes);
  });

  test('a worker can revoke its session without an attached login Activity',
      () async {
    final account = server('worker-without-activity');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(sessions, (call) async {
      calls.add(call);
      return call.method == 'status' ? enabled(13) : null;
    });
    await GatewayAuth.signOut(account);
    expect(calls.map((call) => call.method), ['status', 'signOut']);
    expect((calls.last.arguments as Map)['revision'], 13);
  });
}
