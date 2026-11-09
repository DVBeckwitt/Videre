import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/services/gateway_auth.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _webAuth = MethodChannel('flutter_web_auth_2');
const _access = MethodChannel('videre/nerdvpn_access');
const _gatewaySessions = MethodChannel('videre/gateway_sessions');
const _gatewayBrowser = MethodChannel('videre/gateway_auth');
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _account =
    Server(url: 'https://invidious.nerdvpn.de', id: 'nerdvpn-account');

Uri _authorization(MethodCall call) {
  final arguments = Map<String, dynamic>.from(call.arguments as Map);
  return Uri.parse(arguments['url'] as String);
}

Uri _callback(Uri authorization) =>
    Uri.parse(authorization.queryParameters['callback_url']!);

String _codeCallback(Uri callback, String code) => callback.replace(
    queryParameters: {...callback.queryParameters, 'code': code}).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SembastSqfDb database;
  late Directory documents;
  late MockClient client;
  late Service api;
  late Map<String, Object> accessStatus;
  late Future<http.Response> Function(http.Request) respond;
  final requests = <http.Request>[];
  final authorizations = <Map<String, dynamic>>[];
  final nativeIntents = <String, int>{};

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    documents = await Directory.systemTemp.createTemp('videre-nerdvpn-auth-');
    messenger.setMockMethodCallHandler(
        _pathProvider, (_) async => documents.path);
    messenger.setMockMethodCallHandler(_gatewaySessions, (_) async {
      return {'supported': true, 'enabled': false, 'needsSignIn': false};
    });
    messenger.setMockMethodCallHandler(_gatewayBrowser, (_) async => null);
    accessStatus = {
      'state': 'waiting',
      'availableAt': '2026-11-14T09:30:00Z',
    };
    authorizations.clear();
    nativeIntents.clear();
    messenger.setMockMethodCallHandler(_access, (call) async {
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final context = arguments['context'] as String;
      if (call.method == 'beginAuth' || call.method == 'clear') {
        final intent = nativeIntents.update(context, (value) => value + 1,
            ifAbsent: () => 1);
        return call.method == 'beginAuth'
            ? {'intent': intent}
            : {'state': 'missing'};
      }
      if (call.method == 'authorize') {
        expect(arguments['intent'], nativeIntents[context]);
        authorizations.add(arguments);
      }
      return accessStatus;
    });
    messenger.setMockMethodCallHandler(
        _webAuth,
        (call) async =>
            _codeCallback(_callback(_authorization(call)), 'one-use-code'));
    db = database = await SembastSqfDb.createInMemory();
    await database.upsertServer(_account);
    await fileDb.useServer(await database.getCurrentlySelectedServer());
    requests.clear();
    respond = (request) async {
      if (request.url.path == '/api/v1/token') {
        return http.Response(
            jsonEncode({'token': 'account-token', 'username': 'person'}), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'});
    };
    client = MockClient((request) async {
      requests.add(request);
      return respond(request);
    });
    service = api = Service(httpClient: client);
  });

  tearDown(() async {
    service = Service();
    client.close();
    await database.close();
    for (final channel in [
      _webAuth,
      _access,
      _gatewaySessions,
      _gatewayBrowser,
      _pathProvider,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
    await documents.delete(recursive: true);
  });

  test('PKCE binds the browser challenge, verifier and exact callback',
      () async {
    late Uri authorization;
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      authorization = _authorization(call);
      return _codeCallback(_callback(authorization), 'one-use-code');
    });

    await api.logIn(_account.accountId);

    expect(authorization.origin, _account.url);
    expect(authorization.path, '/authorize_token');
    expect(authorization.queryParameters['scopes']!.split(','),
        contains(':api_key'));
    expect(authorization.queryParameters['code_challenge_method'], 'S256');
    final exchange = requests.single;
    expect(exchange.method, 'POST');
    expect(exchange.url.toString(), '${_account.url}/api/v1/token');
    expect(exchange.headers['content-type'], contains('application/json'));
    final body = jsonDecode(exchange.body) as Map<String, dynamic>;
    expect(body['code'], 'one-use-code');
    expect(body['callback_url'], authorization.queryParameters['callback_url']);
    final verifier = body['code_verifier'] as String;
    expect(verifier, matches(RegExp(r'^[A-Za-z0-9._~-]{43,128}$')));
    expect(
        authorization.queryParameters['code_challenge'],
        base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', ''));
    expect(authorization.queryParameters.containsKey('code_verifier'), isFalse);
    expect(authorizations.single['token'], 'account-token');
    expect(
        authorizations.single['context'],
        GatewayRequestContext.forAccount(
                _account.profileId, _account.accountId, _account.url)!
            .encoded);
    expect(database.getAccount(_account.accountId)!.authToken, 'account-token');
    expect(
        (await fileDb.getCurrentlySelectedServer()).authToken, 'account-token');
  });

  for (final state in ['waiting', 'disabled']) {
    test('$state access keeps the account signed in and pauses history sync',
        () async {
      accessStatus = {
        'state': state,
        if (state == 'waiting') 'availableAt': '2026-11-14T09:30:00Z',
      };

      await api.logIn(_account.accountId);

      expect(
          database.getAccount(_account.accountId)!.authToken, 'account-token');
      expect(authorizations, hasLength(1));
      expect(requests.map((request) => request.url.path), ['/api/v1/token']);
    });
  }

  test('an unsuccessful code exchange preserves the previous account login',
      () async {
    await database.upsertServer(_account.copyWith(authToken: 'previous-token'));
    respond = (_) async => http.Response('{"error":"invalid_grant"}', 400,
        headers: {'content-type': 'application/json'});

    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<InvidiousServiceError>()));

    expect(
        database.getAccount(_account.accountId)!.authToken, 'previous-token');
    expect(authorizations, isEmpty);
    expect(requests, hasLength(1));
  });

  test('a code exchange redirect cannot supply credentials from another origin',
      () async {
    respond = (request) async => request.url.host == 'invidious.nerdvpn.de'
        ? http.Response('', 303,
            headers: {'location': 'https://other.example/token'})
        : http.Response('{"token":"untrusted-token"}', 200);

    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<InvidiousServiceError>()));

    expect(requests, hasLength(1));
    expect(requests.single.url.origin, _account.url);
    expect(database.getAccount(_account.accountId)!.authToken, isNull);
    expect(authorizations, isEmpty);
  });

  for (final failure in <Exception>[
    http.ClientException('private transport detail'),
    TimeoutException('private transport detail'),
    const SocketException('private transport detail'),
    const HttpException('private transport detail'),
    const HandshakeException('private transport detail'),
  ]) {
    test('${failure.runtimeType} during exchange asks for a fresh sign-in',
        () async {
      final previous = _account.copyWith(authToken: 'previous-token');
      await database.upsertServer(previous);
      await fileDb.useServer(previous);
      respond = (_) async => throw failure;

      await expectLater(
          api.logIn(_account.accountId),
          throwsA(isA<GatewaySignInFailed>()
              .having(
                  (error) => error.message, 'advice', contains('sign in again'))
              .having((error) => error.toString(), 'safe message',
                  isNot(contains('private transport detail')))));

      expect(requests, hasLength(1));
      expect(authorizations, isEmpty);
      expect(
          database.getAccount(_account.accountId)!.authToken, 'previous-token');
      expect((await fileDb.getCurrentlySelectedServer()).authToken,
          'previous-token');
    });
  }

  test('an interrupted token response requires a fresh sign-in', () async {
    client.close();
    var exchanges = 0;
    client = MockClient.streaming((_, __) async {
      exchanges++;
      return http.StreamedResponse(
          Stream<List<int>>.error(
              http.ClientException('private response detail')),
          200);
    });
    service = api = Service(httpClient: client);

    await expectLater(
        api.logIn(_account.accountId),
        throwsA(isA<GatewaySignInFailed>().having(
            (error) => error.message, 'advice', contains('sign in again'))));

    expect(exchanges, 1);
    expect(authorizations, isEmpty);
    expect(database.getAccount(_account.accountId)!.authToken, isNull);
  });

  test('retrying a failed exchange opens the browser for a new one-use code',
      () async {
    var browserOpens = 0;
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      browserOpens++;
      return _codeCallback(
          _callback(_authorization(call)), 'one-use-code-$browserOpens');
    });
    final successfulResponse = respond;
    respond = (request) async {
      if (requests.length == 1) {
        throw http.ClientException('Connection closed before full header');
      }
      return successfulResponse(request);
    };

    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<GatewaySignInFailed>()));
    expect(browserOpens, 1);
    expect(requests, hasLength(1));
    expect(database.getAccount(_account.accountId)!.authToken, isNull);

    await api.logIn(_account.accountId);

    expect(browserOpens, 2);
    expect(requests.map((request) => jsonDecode(request.body)['code']),
        ['one-use-code-1', 'one-use-code-2']);
    expect(authorizations, hasLength(1));
    expect(database.getAccount(_account.accountId)!.authToken, 'account-token');
  });

  test('a rate-limited code exchange pauses subsequent browser sign-in',
      () async {
    final now = DateTime.utc(2026, 11, 8, 12);
    service = api = Service(httpClient: client, now: () => now);
    accessStatus = {'state': 'missing', 'revision': 0};
    var browserOpens = 0;
    var intent = 0;
    final recoveries = <Map<String, dynamic>>[];
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      browserOpens++;
      return _codeCallback(_callback(_authorization(call)), 'one-use-code');
    });
    messenger.setMockMethodCallHandler(_access, (call) async {
      if (call.method == 'beginAuth') return {'intent': ++intent};
      if (call.method == 'recover') {
        recoveries.add(Map<String, dynamic>.from(call.arguments as Map));
        accessStatus = {
          'state': 'unavailable',
          'revision': 1,
          'retryAt': now.add(const Duration(seconds: 17)).toIso8601String(),
        };
      }
      return accessStatus;
    });
    respond = (_) async => http.Response('{"error":"rate_limited"}', 429,
        headers: {'content-type': 'application/json', 'retry-after': '17'});

    await expectLater(
        api.logIn(_account.accountId),
        throwsA(isA<InvidiousServiceError>()
            .having((error) => error.statusCode, 'status', 429)));
    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<NerdVpnAccessRequired>()));

    expect(recoveries.single['error'], 'rate_limited');
    expect(recoveries.single['retryAfter'], '17');
    expect(recoveries.single['revision'], 0);
    expect(recoveries.single['retry'], isFalse);
    expect(browserOpens, 1);
    expect(requests, hasLength(1));
    expect(database.getAccount(_account.accountId)!.authToken, isNull);
  });

  final invalidCallbacks = <String, String Function(Uri)>{
    'wrong state': (callback) => callback.replace(queryParameters: {
          'state': 'different-state',
          'code': 'one-use-code',
        }).toString(),
    'wrong host': (callback) =>
        _codeCallback(callback.replace(host: 'different-host'), 'one-use-code'),
    'unexpected path': (callback) =>
        _codeCallback(callback.replace(path: '/unexpected'), 'one-use-code'),
    'duplicate code': (callback) =>
        '${_codeCallback(callback, 'first-code')}&code=second-code',
    'raw token without a code': (callback) =>
        callback.replace(queryParameters: {
          ...callback.queryParameters,
          'token': 'unprotected-token',
        }).toString(),
  };
  for (final entry in invalidCallbacks.entries) {
    test('${entry.key} is rejected before exchanging or saving credentials',
        () async {
      messenger.setMockMethodCallHandler(_webAuth,
          (call) async => entry.value(_callback(_authorization(call))));

      await expectLater(
          api.logIn(_account.accountId), throwsA(isA<InvidiousServiceError>()));

      expect(database.getAccount(_account.accountId)!.authToken, isNull);
      expect(requests, isEmpty);
      expect(authorizations, isEmpty);
    });
  }

  test('logout supersedes a pending PKCE callback', () async {
    final opened = Completer<Uri>();
    final returned = Completer<String>();
    messenger.setMockMethodCallHandler(_webAuth, (call) {
      opened.complete(_callback(_authorization(call)));
      return returned.future;
    });
    final pending = api.logIn(_account.accountId);
    final rejected =
        expectLater(pending, throwsA(isA<InvidiousServiceError>()));
    final callback = await opened.future;

    await api.logOutProtected(database.getAccount(_account.accountId)!);
    returned.complete(_codeCallback(callback, 'late-code'));
    await rejected;

    expect(database.getAccount(_account.accountId)!.authToken, isNull);
    expect(authorizations, isEmpty);
  });

  test('a newer PKCE sign-in supersedes an older callback', () async {
    final opened = Completer<Uri>();
    final firstResult = Completer<String>();
    var calls = 0;
    messenger.setMockMethodCallHandler(_webAuth, (call) {
      final callback = _callback(_authorization(call));
      if (calls++ == 0) {
        opened.complete(callback);
        return firstResult.future;
      }
      return Future.value(_codeCallback(callback, 'new-code'));
    });
    respond = (request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
          jsonEncode({'token': '${body['code']}-token', 'username': 'person'}),
          200,
          headers: {'content-type': 'application/json'});
    };
    final firstLogin = api.logIn(_account.accountId);
    final rejected =
        expectLater(firstLogin, throwsA(isA<InvidiousServiceError>()));
    final callback = await opened.future;

    await api.logIn(_account.accountId);
    firstResult.complete(_codeCallback(callback, 'old-code'));
    await rejected;

    expect(
        database.getAccount(_account.accountId)!.authToken, 'new-code-token');
    expect(authorizations.map((value) => value['token']), ['new-code-token']);
  });

  for (final rejection in [
    (403, 'Invalid scope'),
    (401, 'Unknown upstream rejection'),
    (403, 'access_denied'),
  ]) {
    test('${rejection.$1} ${rejection.$2} preserves the NerdVPN login',
        () async {
      await database
          .upsertServer(_account.copyWith(authToken: 'existing-token'));
      accessStatus = {'state': 'ready'};
      respond = (_) async => http.Response(
          jsonEncode({'error': rejection.$2}), rejection.$1,
          headers: {'content-type': 'application/json'});

      try {
        await api.validateCurrentSession();
      } on InvidiousServiceError {
        // A surfaced server error is acceptable, while erasing the login is not.
      }

      expect(
          database.getAccount(_account.accountId)!.authToken, 'existing-token');
      expect(authorizations, isEmpty);
    });
  }

  test('a new account can finish sign-in while API access is pending',
      () async {
    const added =
        Server(url: 'https://invidious.nerdvpn.de', id: 'new-account');

    final authenticated = await api.authenticateNerdVpn(added);

    expect(authenticated?.accountId, added.accountId);
    expect(authenticated?.authToken, 'account-token');
    expect(database.getAccount(added.accountId), isNull);
    expect(
        authorizations.single['context'],
        GatewayRequestContext.forAccount(
                added.profileId, added.accountId, added.url)!
            .encoded);
    expect(requests.map((request) => request.url.path), ['/api/v1/token']);
  });

  test('accounts with the same ID in separate profiles use distinct key stores',
      () async {
    final other = await database.createProfile('Another person');
    final otherOwner = database.forProfile(other.id);
    await otherOwner.upsertServer(_account.copyWith(profileId: other.id));

    await api.logIn(_account.accountId);
    await api.logIn(_account.accountId, profileId: other.id);

    expect(authorizations, hasLength(2));
    expect(
        authorizations.first['context'], isNot(authorizations.last['context']));
    expect(
        authorizations.last['context'],
        GatewayRequestContext.forAccount(
                other.id, _account.accountId, _account.url)!
            .encoded);
    expect(database.getAccount(_account.accountId)!.authToken, 'account-token');
    expect(
        otherOwner.getAccount(_account.accountId)!.authToken, 'account-token');
    expect((await fileDb.getCurrentlySelectedServer()).profileId,
        _account.profileId);
  });

  test('a lookalike hostname retains the existing token sign-in protocol',
      () async {
    const other = Server(
        url: 'https://invidious.nerdvpn.de.attacker.example',
        id: 'other-instance');
    await database.upsertServer(other);
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      final authorization = _authorization(call);
      expect(
          authorization.queryParameters.containsKey('code_challenge'), isFalse);
      expect(authorization.queryParameters['scopes']!.split(','),
          isNot(contains(':api_key')));
      final callback = _callback(authorization);
      return callback.replace(queryParameters: {
        ...callback.queryParameters,
        'token': 'legacy-token',
      }).toString();
    });

    await api.logIn(other.accountId);

    expect(database.getAccount(other.accountId)!.authToken, 'legacy-token');
    expect(authorizations, isEmpty);
    expect(requests.map((request) => request.url.path),
        everyElement(isNot('/api/v1/token')));
  });

  test('a legacy manual key moves out of account and worker JSON after import',
      () async {
    const manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';
    final saved = database
        .getAccount(_account.accountId)!
        .copyWith(authToken: 'existing-token', customHeaders: {
      'x-invidious-token': manualKey,
      'X-Preference': 'retained',
    });
    await database.upsertServer(saved);
    await fileDb.useServer(saved);
    final imported = <Map<String, dynamic>>[];
    messenger.setMockMethodCallHandler(_access, (call) async {
      if (call.method == 'status') return {'state': 'missing'};
      expect(call.method, 'setKey');
      imported.add(Map<String, dynamic>.from(call.arguments as Map));
      return {'state': 'ready'};
    });

    final request = await api.buildRequest(urlGetSubscriptions,
        authenticated: true, serverOverride: saved);

    expect(imported.single['key'], manualKey);
    expect(imported.single['expectedRevision'], 0);
    expect(
        imported.single['context'],
        GatewayRequestContext.forAccount(
                saved.profileId, saved.accountId, saved.url)!
            .encoded);
    expect(request.headers.keys.where(NerdVpnAccess.isKeyHeader), isEmpty);
    expect(request.headers['X-Preference'], 'retained');
    expect(request.headers['Authorization'], 'Bearer existing-token');
    expect(database.getAccount(saved.accountId)!.customHeaders,
        {'X-Preference': 'retained'});
    expect((await fileDb.getCurrentlySelectedServer()).customHeaders,
        {'X-Preference': 'retained'});
    expect(jsonEncode(database.getAccount(saved.accountId)!.toJson()),
        isNot(contains(manualKey)));
  });

  test('a failed secure import retains the legacy key for another attempt',
      () async {
    const manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';
    final saved = database
        .getAccount(_account.accountId)!
        .copyWith(customHeaders: {'X-Invidious-Token': manualKey});
    await database.upsertServer(saved);
    await fileDb.useServer(saved);
    messenger.setMockMethodCallHandler(_access, (call) async {
      if (call.method == 'status') return {'state': 'missing'};
      throw PlatformException(code: 'SECURE_STORAGE_UNAVAILABLE');
    });

    await expectLater(
        api.buildRequest(urlGetSubscriptions, serverOverride: saved),
        throwsA(isA<NerdVpnAccessRequired>()));

    expect(database.getAccount(saved.accountId)!.customHeaders,
        {'X-Invidious-Token': manualKey});
    expect((await fileDb.getCurrentlySelectedServer()).customHeaders,
        {'X-Invidious-Token': manualKey});
    expect(requests, isEmpty);
  });

  test('a superseded secure import preserves the legacy key', () async {
    const manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';
    final saved = database
        .getAccount(_account.accountId)!
        .copyWith(customHeaders: {'X-Invidious-Token': manualKey});
    await database.upsertServer(saved);
    await fileDb.useServer(saved);
    messenger.setMockMethodCallHandler(_access, (call) async {
      if (call.method == 'status') return {'state': 'missing', 'revision': 0};
      expect(call.method, 'setKey');
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      expect(arguments['expectedRevision'], 0);
      return {'state': 'missing', 'revision': 1, 'superseded': true};
    });

    await expectLater(
        api.buildRequest(urlGetSubscriptions, serverOverride: saved),
        throwsA(isA<NerdVpnAccessRequired>()
            .having((error) => error.state, 'state', 'superseded')));

    expect(database.getAccount(saved.accountId)!.customHeaders,
        {'X-Invidious-Token': manualKey});
    expect((await fileDb.getCurrentlySelectedServer()).customHeaders,
        {'X-Invidious-Token': manualKey});
    expect(requests, isEmpty);
  });

  for (final state in ['disabled', 'unavailable']) {
    test('$state access retains a legacy key until migration succeeds',
        () async {
      const manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';
      final saved = database
          .getAccount(_account.accountId)!
          .copyWith(customHeaders: {'X-Invidious-Token': manualKey});
      await database.upsertServer(saved);
      await fileDb.useServer(saved);
      final methods = <String>[];
      messenger.setMockMethodCallHandler(_access, (call) async {
        methods.add(call.method);
        return {'state': state};
      });

      await api.buildRequest(urlGetSubscriptions, serverOverride: saved);

      expect(methods, ['status']);
      expect(database.getAccount(saved.accountId)!.customHeaders,
          {'X-Invidious-Token': manualKey});
      expect((await fileDb.getCurrentlySelectedServer()).customHeaders,
          {'X-Invidious-Token': manualKey});
    });
  }

  for (final scheme in ['http', 'https']) {
    test('$scheme onion setup uses the proxied protected browser', () async {
      final onion = Server(url: '$scheme://$nerdVpnOnionHost', id: 'onion');
      messenger.setMockMethodCallHandler(_webAuth, (_) async {
        fail('Onion sign-in must not open the external browser');
      });
      var browserOpens = 0;
      messenger.setMockMethodCallHandler(_gatewayBrowser, (call) async {
        if (call.method == 'close') return null;
        expect(call.method, 'signIn');
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        expect(arguments['serverUrl'], onion.url);
        expect(GatewayRequestContext.tryParse(arguments['context'])!.origin,
            Uri.parse(onion.url));
        browserOpens++;
        return 'onion-account-token';
      });

      final authenticated = await api.authenticateNerdVpn(onion);

      expect(browserOpens, 1);
      expect(authenticated!.authToken, 'onion-account-token');
      expect(authenticated.gatewayEnabled, isTrue);
      expect(authorizations.single['token'], 'onion-account-token');
      expect(requests, isEmpty);
    });

    test('$scheme onion account login keeps the protected session', () async {
      final onion = Server(url: '$scheme://$nerdVpnOnionHost', id: 'onion');
      await database.upsertServer(onion);
      messenger.setMockMethodCallHandler(_webAuth, (_) async {
        fail('Onion sign-in must not open the external browser');
      });
      messenger.setMockMethodCallHandler(_gatewayBrowser,
          (call) async => call.method == 'signIn' ? 'onion-token' : null);

      expect(await api.logIn(onion.accountId), 'onion-token');

      final saved = database.getAccount(onion.accountId)!;
      expect(saved.authToken, 'onion-token');
      expect(saved.gatewayEnabled, isTrue);
      expect(database.getAccount(_account.accountId)!.authToken, isNull);
      expect(authorizations, hasLength(1));
    });
  }

  test('cancelled onion browser sign-in preserves the previous login',
      () async {
    const onion = Server(
        url: 'http://$nerdVpnOnionHost',
        id: 'onion',
        authToken: 'previous-onion-token');
    await database.upsertServer(onion);
    messenger.setMockMethodCallHandler(_webAuth, (_) async {
      fail('Onion sign-in must not open the external browser');
    });

    expect(await api.logIn(onion.accountId), isNull);

    expect(database.getAccount(onion.accountId)!.authToken,
        'previous-onion-token');
    expect(authorizations, isEmpty);
  });

  test('automatic key access is limited to the official NerdVPN roots', () {
    expect(NerdVpnAccess.supportsUrl('https://invidious.nerdvpn.de'), isTrue);
    expect(
        NerdVpnAccess.supportsUrl('https://invidious.nerdvpn.de:443/'), isTrue);
    for (final origin in [
      'http://$nerdVpnOnionHost',
      'http://$nerdVpnOnionHost:80/',
      'https://$nerdVpnOnionHost',
      'https://$nerdVpnOnionHost:443/',
    ]) {
      expect(NerdVpnAccess.supportsUrl(origin), isTrue, reason: origin);
    }
    for (final url in [
      'http://invidious.nerdvpn.de',
      'https://www.invidious.nerdvpn.de',
      'https://invidious.nerdvpn.de:8443',
      'https://invidious.nerdvpn.de/another-instance',
      'https://invidious.nerdvpn.de?query=true',
      'https://invidious.nerdvpn.de#fragment',
      'https://user@invidious.nerdvpn.de',
      'https://invidious.nerdvpn.de.attacker.example',
      'https://other.example',
      'http://other.onion',
      'http://sub.$nerdVpnOnionHost',
      'http://$nerdVpnOnionHost.attacker.example',
      'http://$nerdVpnOnionHost:81',
      'https://$nerdVpnOnionHost:8443',
      'http://user@$nerdVpnOnionHost',
      'http://$nerdVpnOnionHost/another-instance',
      'http://$nerdVpnOnionHost?query=true',
      'http://$nerdVpnOnionHost#fragment',
    ]) {
      expect(NerdVpnAccess.supportsUrl(url), isFalse, reason: url);
    }
  });
}
