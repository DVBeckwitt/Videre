import 'dart:async';

import 'package:clipious/globals.dart' as globals;
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/gateway_auth.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sessions = MethodChannel('videre/gateway_sessions');
  const browser = MethodChannel('videre/gateway_auth');
  const access = MethodChannel('videre/nerdvpn_access');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const onionOrigin =
      'http://nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion';

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
    messenger.setMockMethodCallHandler(access, null);
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
    expect(events, ['status', 'close:null', 'status', 'revoke-start']);
    revokeComplete.complete();
    await logout;
    expect(await login, 'replacement-fixture-token');
    expect(events, [
      'status',
      'close:null',
      'status',
      'revoke-start',
      'revoke-complete',
      'close:null',
      'signIn',
    ]);
  });

  test('logout closes a pending login and ignores its late token', () async {
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
      if (loginStarted.isCompleted) {
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
      {'context': context},
    ]);
    expect(revocations, [
      {'context': context, 'revision': 11}
    ]);
  });

  for (final hadSession in [false, true]) {
    for (final completesDuringClose in [false, true]) {
      test(
          '${hadSession ? 'Existing' : 'New'} account: ${completesDuringClose ? 'logout revokes a login completed after its status snapshot' : 'logout waits for a browser still installing its proxy to close'}',
          () async {
        final account = server(
            'installing-login-$hadSession-$completesDuringClose',
            gatewayEnabled: hadSession);
        final context = GatewayRequestContext.forAccount(
                account.profileId, account.accountId, account.url)!
            .encoded;
        final loginStarted = Completer<void>();
        final loginResult = Completer<String?>();
        final closeStarted = Completer<void>();
        final closeResult = Completer<void>();
        final revocations = <Map<Object?, Object?>>[];
        var statusReads = 0;
        messenger.setMockMethodCallHandler(sessions, (call) async {
          if (call.method == 'status') {
            statusReads++;
            if (hadSession) {
              return enabled(statusReads == 1
                  ? 7
                  : completesDuringClose
                      ? 8
                      : 9);
            }
            if (statusReads > 1 && completesDuringClose) return enabled(1);
            return {
              'supported': true,
              'enabled': false,
              'needsSignIn': false,
              'revision': statusReads == 1 ? 0 : 2,
            };
          }
          expect(call.method, 'signOut');
          revocations.add(Map.from(call.arguments as Map));
          return null;
        });
        messenger.setMockMethodCallHandler(browser, (call) async {
          if (call.method == 'signIn') {
            loginStarted.complete();
            return loginResult.future;
          }
          expect(call.method, 'close');
          expect(call.arguments, {'context': context});
          if (loginStarted.isCompleted) {
            // The native request can gain a revision after status returned. A
            // pre-install revision must not prevent closing this same request.
            closeStarted.complete();
            await closeResult.future;
            loginResult.complete('stale-installing-fixture-token');
          }
          return null;
        });

        final login = GatewayAuth.signIn(account);
        await loginStarted.future;
        var logoutFinished = false;
        final logout =
            GatewayAuth.signOut(account).then((_) => logoutFinished = true);
        await closeStarted.future;
        expect(logoutFinished, isFalse);
        expect(revocations, isEmpty);
        closeResult.complete();
        await logout;
        expect(await login, isNull);
        expect(statusReads, 2);
        expect(
            revocations,
            hadSession || completesDuringClose
                ? [
                    {
                      'context': context,
                      'revision':
                          hadSession ? (completesDuringClose ? 8 : 9) : 1
                    }
                  ]
                : isEmpty);
      });
    }
  }

  test('failure to close an installing browser prevents successful logout',
      () async {
    final account =
        server('installing-browser-close-failure', gatewayEnabled: false);
    messenger.setMockMethodCallHandler(sessions, (call) async {
      expect(call.method, 'status');
      return {
        'supported': true,
        'enabled': false,
        'needsSignIn': false,
        'revision': 0,
      };
    });
    messenger.setMockMethodCallHandler(browser, (call) async {
      expect(call.method, 'close');
      throw PlatformException(code: 'GATEWAY_UNAVAILABLE');
    });

    await expectLater(GatewayAuth.signOut(account),
        throwsA(isA<GatewayTransportUnavailable>()));
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
    expect(calls.map((call) => call.method), ['status', 'status', 'signOut']);
    expect((calls.last.arguments as Map)['revision'], 13);
  });

  test('an expired PKCE exchange provides a safe sign-in action', () async {
    const account = Server(
        url: 'https://invidious.nerdvpn.de', id: 'expired-pkce-exchange');
    messenger.setMockMethodCallHandler(
        access, (call) async => {'state': 'missing'});
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method == 'signIn') {
        throw PlatformException(
            code: 'GATEWAY_TOKEN_EXPIRED', message: 'secret-response-body');
      }
      return null;
    });
    await expectLater(
        GatewayAuth.signIn(account),
        throwsA(isA<GatewaySignInFailed>().having(
            (error) => error.toString(),
            'message',
            'The sign-in code expired or was already used. Sign in again.')));
  });

  test('missing WebView routing protection explains how to repair sign-in',
      () async {
    final account = server('missing-browser-protection');
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method == 'signIn') {
        throw PlatformException(code: 'GATEWAY_PROXY_UNSUPPORTED');
      }
      return null;
    });
    await expectLater(
        GatewayAuth.signIn(account),
        throwsA(isA<GatewayUnsupported>().having((error) => error.toString(),
            'repair guidance', contains('Update Android System WebView'))));
  });

  test('onion sign-in keeps the selected origin and native context together',
      () async {
    const account = Server(
        url: onionOrigin,
        id: 'onion-selected-origin',
        profileId: 'tor-profile');
    final context = GatewayRequestContext.forAccount(
        account.profileId, account.accountId, account.url)!;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(access, (call) async {
      expect((call.arguments as Map)['context'], context.encoded);
      return {'state': 'missing'};
    });
    messenger.setMockMethodCallHandler(browser, (call) async {
      calls.add(call);
      return call.method == 'signIn' ? 'onion-fixture-token' : null;
    });
    expect(await GatewayAuth.signIn(account), 'onion-fixture-token');
    expect(calls.map((call) => call.method), ['close', 'signIn']);
    expect((calls.last.arguments as Map)['context'], context.encoded);
    expect((calls.last.arguments as Map)['serverUrl'], onionOrigin);
    expect(context.origin.origin, onionOrigin);
  });

  test('onion sign-in without SOCKS gives safe actionable guidance', () async {
    const account = Server(url: onionOrigin, id: 'onion-proxy-required');
    messenger.setMockMethodCallHandler(
        access, (call) async => {'state': 'proxyRequired'});
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method == 'signIn') {
        throw PlatformException(
            code: 'GATEWAY_ONION_PROXY_REQUIRED',
            message: 'private-proxy-configuration');
      }
      return null;
    });
    await expectLater(
        GatewayAuth.signIn(account),
        throwsA(isA<GatewaySignInFailed>().having(
            (error) => error.toString(),
            'message',
            'Enable SOCKS5/Orbot in Network proxy to use this onion server.')));
  });

  test('onion logout rejects its late token without cancelling another profile',
      () async {
    const first = Server(
        url: onionOrigin, id: 'same-onion-account', profileId: 'first-profile');
    final second = first.copyWith(profileId: 'second-profile');
    String contextFor(Server account) => GatewayRequestContext.forAccount(
            account.profileId, account.accountId, account.url)!
        .encoded;
    final firstContext = contextFor(first);
    final secondContext = contextFor(second);
    final started = <String, Completer<void>>{
      firstContext: Completer<void>(),
      secondContext: Completer<void>(),
    };
    final tokens = <String, Completer<String>>{
      firstContext: Completer<String>(),
      secondContext: Completer<String>(),
    };
    final revoked = <String>[];
    messenger.setMockMethodCallHandler(
        access, (call) async => {'state': 'missing'});
    messenger.setMockMethodCallHandler(sessions, (call) async {
      if (call.method == 'status') return enabled(17);
      revoked.add((call.arguments as Map)['context'] as String);
      return null;
    });
    messenger.setMockMethodCallHandler(browser, (call) async {
      final arguments = call.arguments as Map;
      final context = arguments['context'] as String;
      if (call.method == 'signIn') {
        started[context]!.complete();
        return tokens[context]!.future;
      }
      if (started[context]!.isCompleted) {
        expect(context, firstContext);
        tokens[context]!.complete('stale-onion-fixture-token');
      }
      return null;
    });
    final firstLogin = GatewayAuth.signIn(first);
    await started[firstContext]!.future;
    final secondLogin = GatewayAuth.signIn(second);
    await started[secondContext]!.future;
    await GatewayAuth.signOut(first);
    tokens[secondContext]!.complete('other-profile-fixture-token');
    expect(await firstLogin, isNull);
    expect(await secondLogin, 'other-profile-fixture-token');
    expect(revoked, [firstContext]);
    expect(firstContext, isNot(secondContext));
  });

  test('protected sign-in observes the persisted Retry-After before opening',
      () async {
    const account = Server(
        url: 'https://invidious.nerdvpn.de', id: 'rate-limited-pkce-exchange');
    final accessCalls = <MethodCall>[];
    Map<String, dynamic> status = {'state': 'missing', 'revision': 7};
    messenger.setMockMethodCallHandler(access, (call) async {
      accessCalls.add(call);
      if (call.method == 'recover') {
        status = {
          'state': 'unavailable',
          'revision': 8,
          'retryAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        };
      }
      return status;
    });
    var opened = 0;
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method == 'signIn') {
        opened++;
        throw PlatformException(code: 'GATEWAY_TOKEN_UNAVAILABLE', details: {
          'statusCode': 429,
          'retryAfter': '3600',
        });
      }
      return null;
    });
    await expectLater(
        GatewayAuth.signIn(account), throwsA(isA<GatewaySignInFailed>()));
    expect(accessCalls.map((call) => call.method), ['status', 'recover']);
    expect((accessCalls.last.arguments as Map)['retryAfter'], '3600');
    expect((accessCalls.last.arguments as Map)['revision'], 7);
    expect((accessCalls.last.arguments as Map)['retry'], isFalse);
    await expectLater(
        GatewayAuth.signIn(account), throwsA(isA<GatewaySignInFailed>()));
    expect(opened, 1);
  });

  test('late onion token cooldown cannot block a newer credential', () async {
    const account = Server(url: onionOrigin, id: 'onion-late-cooldown');
    final loginStarted = Completer<void>();
    final oldExchange = Completer<String?>();
    var status = <String, Object>{
      'state': 'ready',
      'revision': 7,
      'apiKeyIntent': 3,
    };
    messenger.setMockMethodCallHandler(access, (call) async {
      if (call.method == 'setKey') {
        status = {'state': 'ready', 'revision': 8, 'apiKeyIntent': 4};
      } else if (call.method == 'recover') {
        final failedIntent = (call.arguments as Map)['failedIntent'];
        // The native manager ignores responses tied to replaced credentials.
        if (failedIntent == null || failedIntent == status['apiKeyIntent']) {
          status = {
            ...status,
            'state': 'unavailable',
            'retryAt': DateTime.now()
                .add(const Duration(hours: 1))
                .toUtc()
                .toIso8601String(),
          };
        }
      } else {
        expect(call.method, 'status');
      }
      return status;
    });
    var opened = 0;
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method != 'signIn') return null;
      if (++opened != 1) return 'new-fixture-token';
      loginStarted.complete();
      return oldExchange.future;
    });

    final login = expectLater(
        GatewayAuth.signIn(account), throwsA(isA<GatewaySignInFailed>()));
    await loginStarted.future;
    await NerdVpnAccess.instance
        .setKey(account, 'nvpn_0123456789abcdefghijklmnopqrstuv');
    oldExchange.completeError(
        PlatformException(code: 'GATEWAY_TOKEN_UNAVAILABLE', details: {
      'statusCode': 429,
      'retryAfter': '3600',
    }));
    await login;

    expect((await NerdVpnAccess.instance.status(account)).ready, isTrue);
    expect(await GatewayAuth.signIn(account), 'new-fixture-token');
    expect(opened, 2);
  });

  test('proxy save cancels pending sign-in before its browser can open',
      () async {
    final store = await SembastSqfDb.createInMemory();
    globals.db = store;
    final proxy = NetworkProxy.instance;
    await proxy.initialize(configureNative: false);
    addTearDown(() async {
      await proxy.initialize(
          saved: '{"enabled":false}', configureNative: false);
      await store.close();
    });

    const account = Server(url: onionOrigin, id: 'onion-pending-proxy-save');
    final statusStarted = Completer<void>();
    final status = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(access, (call) async {
      expect(call.method, 'status');
      statusStarted.complete();
      return status.future;
    });
    var opened = 0;
    messenger.setMockMethodCallHandler(browser, (call) async {
      if (call.method != 'signIn') return null;
      opened++;
      return 'fixture-token';
    });

    final applyStarted = Completer<void>();
    final releaseApply = Completer<void>();
    Future<void> holdSave() {
      applyStarted.complete();
      return releaseApply.future;
    }

    proxy.addBeforeApply(holdSave);
    addTearDown(() => proxy.removeBeforeApply(holdSave));
    final login = GatewayAuth.signIn(account);
    await statusStarted.future;
    final applying = proxy.apply(SocksProxyConfig(enabled: true));
    try {
      await applyStarted.future;
      status.complete({'state': 'ready'});
      expect(await login, isNull);
      expect(await GatewayAuth.signIn(server('during-proxy-save')), isNull);
      expect(opened, 0);
    } finally {
      releaseApply.complete();
      await applying;
    }
    expect(
        await GatewayAuth.signIn(server('after-proxy-save')), 'fixture-token');
    expect(opened, 1);
  });
}
