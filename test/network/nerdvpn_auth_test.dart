import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/music/services/invidious_music_catalog_service.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/services/gateway_auth.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
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
  final browserRequests = <Map<String, dynamic>>[];
  final nativeIntents = <String, int>{};

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    documents = await Directory.systemTemp.createTemp('videre-nerdvpn-auth-');
    messenger.setMockMethodCallHandler(
        _pathProvider, (_) async => documents.path);
    messenger.setMockMethodCallHandler(_gatewaySessions, (_) async {
      return {'supported': true, 'enabled': false, 'needsSignIn': false};
    });
    browserRequests.clear();
    messenger.setMockMethodCallHandler(_gatewayBrowser, (call) async {
      if (call.method != 'signIn') return null;
      browserRequests.add(Map<String, dynamic>.from(call.arguments as Map));
      return 'account-token';
    });
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
    messenger.setMockMethodCallHandler(_webAuth, (_) async {
      fail('Sign-in must stay in the native browser transport');
    });
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

  test(
      'ordinary NerdVPN login uses account-scoped native PKCE without saving a gateway session',
      () async {
    await api.logIn(_account.accountId);

    final context = GatewayRequestContext.forAccount(
            _account.profileId, _account.accountId, _account.url)!
        .encoded;
    expect(browserRequests, hasLength(1));
    expect(browserRequests.single['serverUrl'], _account.url);
    expect(browserRequests.single['context'], context);
    expect(browserRequests.single['persistSession'], isFalse);
    expect(requests, isEmpty);
    expect(authorizations.single['token'], 'account-token');
    expect(authorizations.single['context'], context);
    expect(authorizations.single['intent'], nativeIntents[context]);
    expect(database.getAccount(_account.accountId)!.authToken, 'account-token');
    expect(database.getAccount(_account.accountId)!.gatewayEnabled, isFalse);
    expect(
        (await fileDb.getCurrentlySelectedServer()).authToken, 'account-token');
  });

  // NerdVpnPkceTest.kt covers the native S256/verifier, exact nonce callback,
  // duplicate-code and token-downgrade checks. Dart observes only its result;
  // the one-use code and verifier must never return to the Dart HTTP client.
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
      expect(requests, isEmpty);
    });
  }

  for (final code in [
    'GATEWAY_TOKEN_EXPIRED',
    'GATEWAY_TOKEN_EXCHANGE_FAILED',
    'GATEWAY_TOKEN_UNAVAILABLE',
  ]) {
    test('$code preserves the previous login and redacts native details',
        () async {
      final previous = _account.copyWith(authToken: 'previous-token');
      await database.upsertServer(previous);
      await fileDb.useServer(previous);
      messenger.setMockMethodCallHandler(_gatewayBrowser, (call) async {
        if (call.method != 'signIn') return null;
        throw PlatformException(
            code: code, message: 'private transport detail');
      });

      await expectLater(
          api.logIn(_account.accountId),
          throwsA(isA<GatewaySignInFailed>().having((error) => error.toString(),
              'safe message', isNot(contains('private transport detail')))));
      expect(requests, isEmpty);
      expect(authorizations, isEmpty);
      expect(
          database.getAccount(_account.accountId)!.authToken, 'previous-token');
      expect((await fileDb.getCurrentlySelectedServer()).authToken,
          'previous-token');
    });
  }

  test('retrying a failed native exchange opens a fresh sign-in attempt',
      () async {
    var browserOpens = 0;
    messenger.setMockMethodCallHandler(_gatewayBrowser, (call) async {
      if (call.method != 'signIn') return null;
      browserOpens++;
      if (browserOpens == 1) {
        throw PlatformException(code: 'GATEWAY_TOKEN_EXCHANGE_FAILED');
      }
      return 'fresh-account-token';
    });
    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<GatewaySignInFailed>()));
    expect(browserOpens, 1);
    expect(database.getAccount(_account.accountId)!.authToken, isNull);

    await api.logIn(_account.accountId);
    expect(browserOpens, 2);
    expect(requests, isEmpty);
    expect(authorizations, hasLength(1));
    expect(authorizations.single['intent'], 2);
    expect(database.getAccount(_account.accountId)!.authToken,
        'fresh-account-token');
  });

  test('a rate-limited native exchange pauses subsequent browser sign-in',
      () async {
    final now = DateTime.now().toUtc();
    service = api = Service(httpClient: client, now: () => now);
    accessStatus = {'state': 'missing', 'revision': 0};
    var browserOpens = 0;
    var intent = 0;
    final recoveries = <Map<String, dynamic>>[];
    messenger.setMockMethodCallHandler(_gatewayBrowser, (call) async {
      if (call.method != 'signIn') return null;
      browserOpens++;
      throw PlatformException(
          code: 'GATEWAY_TOKEN_UNAVAILABLE',
          details: {'statusCode': 429, 'retryAfter': '17'});
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

    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<GatewaySignInFailed>()));
    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<NerdVpnAccessRequired>()));
    expect(recoveries.single['error'], 'rate_limited');
    expect(recoveries.single['retryAfter'], '17');
    expect(recoveries.single['revision'], 0);
    expect(recoveries.single['retry'], isFalse);
    expect(browserOpens, 1);
    expect(requests, isEmpty);
    expect(database.getAccount(_account.accountId)!.authToken, isNull);
  });

  test('native cancellation preserves the previous ordinary account login',
      () async {
    await database.upsertServer(_account.copyWith(authToken: 'previous-token'));
    messenger.setMockMethodCallHandler(_gatewayBrowser, (_) async => null);
    expect(await api.logIn(_account.accountId), isNull);
    expect(
        database.getAccount(_account.accountId)!.authToken, 'previous-token');
    expect(authorizations, isEmpty);
    expect(requests, isEmpty);
  });

  test('an empty native account token is rejected before saving credentials',
      () async {
    messenger.setMockMethodCallHandler(
        _gatewayBrowser, (call) async => call.method == 'signIn' ? '' : null);
    await expectLater(
        api.logIn(_account.accountId), throwsA(isA<InvidiousServiceError>()));
    expect(database.getAccount(_account.accountId)!.authToken, isNull);
    expect(authorizations, isEmpty);
    expect(requests, isEmpty);
  });

  test('logout supersedes a pending native PKCE result', () async {
    final opened = Completer<void>();
    final returned = Completer<String>();
    messenger.setMockMethodCallHandler(_gatewayBrowser, (call) {
      if (call.method != 'signIn') return Future.value(null);
      opened.complete();
      return returned.future;
    });
    final pending = api.logIn(_account.accountId);
    await opened.future;
    await api.logOutProtected(database.getAccount(_account.accountId)!);
    returned.complete('late-token');
    expect(await pending, isNull);
    expect(database.getAccount(_account.accountId)!.authToken, isNull);
    expect(authorizations, isEmpty);
  });

  test('a newer native PKCE sign-in supersedes an older result', () async {
    final opened = Completer<void>();
    final firstResult = Completer<String>();
    var calls = 0;
    messenger.setMockMethodCallHandler(_gatewayBrowser, (call) {
      if (call.method != 'signIn') return Future.value(null);
      if (calls++ == 0) {
        opened.complete();
        return firstResult.future;
      }
      return Future.value('new-account-token');
    });
    final firstLogin = api.logIn(_account.accountId);
    await opened.future;
    await api.logIn(_account.accountId);
    firstResult.complete('old-account-token');
    expect(await firstLogin, isNull);
    expect(database.getAccount(_account.accountId)!.authToken,
        'new-account-token');
    expect(
        authorizations.map((value) => value['token']), ['new-account-token']);
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
    expect(requests, isEmpty);
    expect(browserRequests.single['persistSession'], isFalse);
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

  test('a lookalike hostname does not gain managed NerdVPN authorization',
      () async {
    const other = Server(
        url: 'https://invidious.nerdvpn.de.attacker.example',
        id: 'other-instance');
    await database.upsertServer(other);
    messenger.setMockMethodCallHandler(_gatewayBrowser, (call) async {
      if (call.method != 'signIn') return null;
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      expect(arguments['serverUrl'], other.url);
      expect(arguments['persistSession'], isFalse);
      expect(GatewayRequestContext.tryParse(arguments['context'])!.origin,
          Uri.parse(other.url));
      return 'legacy-token';
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

  for (final interactive in [false, true]) {
    for (final withBackends in [false, true]) {
      test(
          'video load admits migrated credentials, interactive=$interactive backends=$withBackends',
          () async {
        const manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';
        var saved =
            database.getAccount(_account.accountId)!.copyWith(customHeaders: {
          'x-invidious-token': manualKey,
          'X-Preference': 'retained',
        });
        if (withBackends) {
          saved = BackendSelector('COMPANION_ID', const [
            BackendOption('0', 'First'),
            BackendOption('1', 'Second'),
          ]).withSelection(saved, '0');
        }
        await database.upsertServer(saved);
        await fileDb.useServer(saved);
        var imports = 0;
        messenger.setMockMethodCallHandler(_access, (call) async {
          if (call.method == 'status') {
            return {'state': 'missing', 'revision': 0};
          }
          expect(call.method, 'setKey');
          expect((call.arguments as Map)['expectedRevision'], 0);
          imports++;
          return {'state': 'ready', 'revision': 1};
        });
        respond = (request) async => http.Response(
            '{"videoId":"test-video","title":"Test","adaptiveFormats":[],"formatStreams":[]}',
            200,
            request: request,
            headers: {'content-type': 'application/json'});

        final video = await api.getVideo('test-video',
            loadObserver: interactive
                ? VideoLoadObserver(
                    isCurrent: () => true,
                    onRetry: () {
                      fail('Credential migration must not require a retry');
                    })
                : null);

        expect(imports, 1);
        expect(requests, hasLength(1));
        expect(requests.single.url.origin, saved.url);
        expect(requests.single.url.path, '/api/v1/videos/test-video');
        expect(requests.single.headers.keys.where(NerdVpnAccess.isKeyHeader),
            isEmpty);
        expect(requests.single.headers['X-Preference'], 'retained');
        final current = await database.getCurrentlySelectedServer();
        expect(video.playbackConnection!.matches(current), isTrue);
        expect(video.backendPlayback != null, withBackends);
        expect(current.customHeaders.keys.where(NerdVpnAccess.isKeyHeader),
            isEmpty);
        expect((await fileDb.getCurrentlySelectedServer()).customHeaders,
            current.customHeaders);
        expect(jsonEncode(video.toJson()), isNot(contains(manualKey)));
      });
    }
  }

  for (final operation in ['search', 'song', 'interactive song']) {
    test('first Music $operation admits migrated credentials', () async {
      const songId = 'dQw4w9WgXcQ';
      final saved =
          database.getAccount(_account.accountId)!.copyWith(customHeaders: {
        'X-Invidious-Token': 'nvpn_0123456789abcdefghijklmnopqrstuv',
        'X-Preference': 'retained',
      });
      await database.upsertServer(saved);
      await fileDb.useServer(saved);
      var imports = 0;
      messenger.setMockMethodCallHandler(_access, (call) async {
        if (call.method == 'status') {
          return {'state': 'missing', 'revision': 0};
        }
        expect(call.method, 'setKey');
        imports++;
        return {'state': 'ready', 'revision': 1};
      });
      respond = (request) async {
        final song = {'type': 'video', 'videoId': songId, 'title': 'Test song'};
        return http.Response(
            jsonEncode(operation == 'search' ? [song] : song), 200,
            request: request, headers: {'content-type': 'application/json'});
      };
      final catalog = InvidiousMusicCatalogService(api: api);

      final songs = operation == 'search'
          ? await catalog.searchSongs('test')
          : [
              await catalog.getSong(songId,
                  loadObserver: operation == 'interactive song'
                      ? VideoLoadObserver(
                          isCurrent: () => true,
                          onRetry: () {
                            fail(
                                'Credential migration must not require a retry');
                          })
                      : null)
            ];

      expect(songs.single.videoId, songId);
      expect(imports, 1);
      expect(requests, hasLength(1));
      expect(requests.single.url.origin, saved.url);
      expect(requests.single.headers.keys.where(NerdVpnAccess.isKeyHeader),
          isEmpty);
      expect(requests.single.headers['X-Preference'], 'retained');
      if (operation == 'interactive song') {
        expect(
            songs.single.playbackVideo!.playbackConnection!
                .matches(await database.getCurrentlySelectedServer()),
            isTrue);
      }
    });
  }

  for (final operation in ['video', 'music']) {
    for (final change in ['proxy', 'session', 'account']) {
      test('$operation key migration cannot admit a changed $change context',
          () async {
        const manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';
        final saved = database
            .getAccount(_account.accountId)!
            .copyWith(customHeaders: {'X-Invidious-Token': manualKey});
        await database.upsertServer(saved);
        await fileDb.useServer(saved);
        final beforeProxy = jsonEncode(NetworkProxy.instance.config.toJson());
        addTearDown(() => NetworkProxy.instance
            .initialize(saved: beforeProxy, configureNative: false));
        final started = Completer<void>();
        final ready = Completer<void>();
        messenger.setMockMethodCallHandler(_access, (call) async {
          if (call.method == 'status') {
            started.complete();
            await ready.future;
            return {'state': 'missing', 'revision': 0};
          }
          return {'state': 'ready', 'revision': 1};
        });
        respond = (request) async => http.Response(
            operation == 'video'
                ? '{"videoId":"test-video","title":"Test"}'
                : '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'});
        final request = operation == 'video'
            ? api.getVideo('test-video')
            : InvidiousMusicCatalogService(api: api).searchSongs('test');
        final rejected = expectLater(request,
            throwsA(anyOf(isA<StateError>(), isA<MusicCatalogException>())));
        await started.future;
        switch (change) {
          case 'proxy':
            await NetworkProxy.instance
                .initialize(saved: beforeProxy, configureNative: false);
          case 'session':
            api.clearSessionCaches();
          case 'account':
            await database.upsertServer(saved.copyWith(authToken: 'new-token'));
        }
        ready.complete();
        await rejected;
        expect(requests, isEmpty);
      });
    }
  }

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
        expect(arguments['persistSession'], isTrue);
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
    messenger.setMockMethodCallHandler(_gatewayBrowser, (_) async => null);

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
