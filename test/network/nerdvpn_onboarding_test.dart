import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _origin = 'https://invidious.nerdvpn.de';
const _onionOrigin =
    'http://nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion';
const _access = MethodChannel('videre/nerdvpn_access');
const _manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';

class _OnboardingService extends Service {
  bool cancelled = false;
  bool failValidation = false;
  Object? validationError;
  Object? videoError;
  Completer<void>? signInWait;
  Completer<void>? validationWait;
  final events = <String>[];
  final signedOut = <Server>[];
  Server? authorized;
  Map<String, String>? validationHeaders;
  String? validationUrl;
  Server? videoServer;

  @override
  Future<Server?> authenticateNerdVpn(Server original) async {
    events.add('token-sign-in');
    await signInWait?.future;
    if (cancelled) return null;
    return authorized = original.copyWith(authToken: 'test-account-token');
  }

  @override
  Future<Server?> authenticateProtected(Server original) async {
    events.add('protected-sign-in');
    if (cancelled) return null;
    return authorized = original.copyWith(
        authToken: 'test-account-token', gatewayEnabled: true);
  }

  @override
  Future<void> validateServer(
      String serverUrl, Map<String, String>? headers) async {
    events.add('stats');
    validationHeaders = headers;
    validationUrl = serverUrl;
    await validationWait?.future;
    if (validationError != null) throw validationError!;
    if (failValidation) throw StateError('Invalid instance response');
  }

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest}) async {
    events.add('video');
    videoServer = serverOverride;
    if (videoError != null) throw videoError!;
    return Video(videoId: videoId);
  }

  @override
  Future<Server?> logOutProtected(Server server) async {
    signedOut.add(server);
    return server;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SembastSqfDb database;
  late AddServerCubit cubit;
  late _OnboardingService api;
  final calls = <MethodCall>[];
  var accessState = 'ready';
  Completer<void>? setKeyWait;
  Object? setKeyError;

  setUp(() async {
    db = database = await SembastSqfDb.createInMemory();
    api = _OnboardingService();
    service = api;
    cubit = AddServerCubit(const AddServerState());
    cubit.selectPublicInstance(_origin);
    accessState = 'ready';
    setKeyWait = null;
    setKeyError = null;
    calls.clear();
    messenger.setMockMethodCallHandler(_access, (call) async {
      calls.add(call);
      if (call.method == 'setKey') {
        await setKeyWait?.future;
        if (setKeyError != null) throw setKeyError!;
      }
      return {
        'state': accessState,
        if (accessState == 'waiting') 'availableAt': '2031-02-18T09:30:00Z',
      };
    });
  });

  tearDown(() async {
    if (!cubit.isClosed) await cubit.close();
    await database.close();
    service = Service();
    messenger.setMockMethodCallHandler(_access, null);
  });

  for (final state in ['waiting', 'disabled']) {
    for (final protected in [false, true]) {
      test(
          '$state account can be saved after ${protected ? 'protected' : 'token'} sign-in without API probes',
          () async {
        accessState = state;
        cubit.setProtectedServer(protected);
        final account = await cubit.validateServer();

        expect(account, isNotNull);
        expect(account!.authToken, 'test-account-token');
        expect(account.gatewayEnabled, protected);
        expect(api.events, [protected ? 'protected-sign-in' : 'token-sign-in']);
        expect(api.signedOut, isEmpty);
        expect(cubit.state.loading, isFalse);
        await database.upsertServer(account);
        expect(database.getAccount(account.accountId)?.authToken,
            'test-account-token');

        final statusCall = calls.singleWhere((call) => call.method == 'status');
        final context = GatewayRequestContext.tryParse(
            (statusCall.arguments as Map)['context'] as String);
        expect(
            context?.key,
            GatewayRequestContext.forAccount(
                    account.profileId, account.accountId, account.url)
                ?.key);
      });
    }
  }

  test('ready account signs in before checking public API endpoints', () async {
    final account = await cubit.validateServer();
    expect(account!.authToken, 'test-account-token');
    expect(api.events, ['token-sign-in', 'stats', 'video']);
    expect(api.validationHeaders?[gatewayContextHeader], isNotNull);
    expect(api.signedOut, isEmpty);
  });

  test('NerdVPN ignores an account label hidden after changing the address',
      () async {
    cubit.nameController.text = 'x' * 81;
    final account = await cubit.validateServer();
    expect(account!.name, isEmpty);
    expect(api.events, ['token-sign-in', 'stats', 'video']);
  });

  for (final onionOrigin in [
    _onionOrigin,
    _onionOrigin.replaceFirst('http:', 'https:')
  ]) {
    test('manual setup validates $onionOrigin without launching a browser',
        () async {
      cubit.urlController.text = onionOrigin;
      cubit.apiKeyController.text = '  $_manualKey  ';
      cubit.setProtectedServer(true);
      cubit.setAdvancedTest(false);
      final account = await cubit.validateServer();

      expect(cubit.usesNerdVpnOnion, isTrue);
      expect(account!.url, onionOrigin);
      expect(account.authToken, isNull);
      expect(account.gatewayEnabled, isFalse);
      expect(api.events, ['stats', 'video']);
      expect(api.validationUrl, onionOrigin);
      expect(api.videoServer, account);
      final context = GatewayRequestContext.tryParse(
          api.validationHeaders![gatewayContextHeader]!);
      expect(context!.origin.origin, onionOrigin);
      expect(
          context.key,
          GatewayRequestContext.forAccount(
                  account.profileId, account.accountId, account.url)
              ?.key);
      expect(calls.map((call) => call.method), ['setKey', 'status']);
      expect((calls.first.arguments as Map)['key'], _manualKey);
      expect((calls.first.arguments as Map)['context'], context.encoded);
      expect(cubit.state.toString(), isNot(contains(_manualKey)));
      expect(api.validationHeaders.toString(), isNot(contains(_manualKey)));
      await database.upsertServer(account);
      expect(database.getAccount(account.accountId)!.toJson().toString(),
          isNot(contains(_manualKey)));
      expect(api.signedOut, isEmpty);
    });
  }

  for (final entry in ['', ' ', 'nvpn_short', '${_manualKey}extra'].indexed) {
    test(
        'missing or malformed onion key is rejected before storage (${entry.$1})',
        () async {
      cubit.urlController.text = _onionOrigin;
      cubit.apiKeyController.text = entry.$2;
      await expectLater(
          cubit.validateServer(), throwsA(isA<NerdVpnApiKeyException>()));
      expect(calls, isEmpty);
      expect(api.events, isEmpty);
      expect(await database.getServers(), isEmpty);
      expect(cubit.state.loading, isFalse);
    });
  }

  for (final state in ['waiting', 'disabled', 'proxyRequired']) {
    test('onion $state status rejects setup and removes the unsaved key',
        () async {
      cubit.urlController.text = _onionOrigin;
      cubit.apiKeyController.text = _manualKey;
      accessState = state;
      await expectLater(
          cubit.validateServer(),
          throwsA(isA<NerdVpnAccessRequired>()
              .having((e) => e.state, 'state', state)));
      expect(api.events, isEmpty);
      expect(api.signedOut.single.url, _onionOrigin);
      expect(api.signedOut.single.customHeaders, isEmpty);
      expect(await database.getServers(), isEmpty);
      expect(cubit.state.loading, isFalse);
    });
  }

  test('onion manual key is stored securely with an onion-scoped context',
      () async {
    cubit.urlController.text = _onionOrigin;
    await cubit.addHeader('X-Invidious-Token', _manualKey);
    final account = await cubit.validateServer();
    expect(account!.url, _onionOrigin);
    expect(account.authToken, isNull);
    expect(account.customHeaders, isEmpty);
    expect(api.events, ['stats', 'video']);
    expect(calls.map((call) => call.method), ['setKey', 'status']);
    final context = GatewayRequestContext.tryParse(
        (calls.first.arguments as Map)['context'] as String);
    expect(context!.origin.origin, _onionOrigin);
    expect(api.validationHeaders!.containsKey('X-Invidious-Token'), isFalse);
    await database.upsertServer(account);
    expect(database.getAccount(account.accountId)!.toJson().toString(),
        isNot(contains(_manualKey)));
  });

  test(
      'matching onion key field and legacy header are accepted without saving either',
      () async {
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    await cubit.addHeader('x-invidious-token', ' $_manualKey ');
    await cubit.addHeader('X-Other', 'keep');
    final account = await cubit.validateServer();
    expect(account!.customHeaders, {'X-Other': 'keep'});
    expect(api.events, ['stats', 'video']);
    expect(calls.where((call) => call.method == 'setKey'), hasLength(1));
    expect(account.toJson().toString(), isNot(contains(_manualKey)));
  });

  test('conflicting onion keys fail without exposing either key in the error',
      () async {
    const otherKey = 'nvpn_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345';
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    await cubit.addHeader('X-Invidious-Token', otherKey);
    await expectLater(
        cubit.validateServer(),
        throwsA(isA<NerdVpnApiKeyException>().having(
            (e) => e.toString(),
            'safe message',
            allOf(isNot(contains(_manualKey)), isNot(contains(otherKey))))));
    expect(calls, isEmpty);
    expect(api.events, isEmpty);
    expect(cubit.state.loading, isFalse);
  });

  test('key survives equivalent addresses but is cleared on an origin change',
      () async {
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    cubit.urlController.text = ' $_onionOrigin/ ';
    expect(cubit.apiKeyController.text, _manualKey);
    cubit.urlController.text = '$_onionOrigin:80';
    expect(cubit.apiKeyController.text, _manualKey);
    cubit.urlController.text = _onionOrigin.replaceFirst('http:', 'https:');
    expect(cubit.apiKeyController.text, isEmpty);
    cubit.apiKeyController.text = _manualKey;
    cubit.urlController.text = _origin;
    expect(cubit.apiKeyController.text, isEmpty);
    expect(cubit.usesNerdVpnOnion, isFalse);
  });

  test('an invalid intermediate address cannot carry a key to another origin',
      () async {
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    cubit.urlController.text = 'http://';
    expect(cubit.apiKeyController.text, isEmpty);
    cubit.urlController.text = 'https://private.example';
    expect(cubit.apiKeyController.text, isEmpty);
    expect(cubit.usesNerdVpnOnion, isFalse);
  });

  for (final error in [
    const NerdVpnAccessRequired('proxyRequired'),
    const NerdVpnAccessRequired('denied'),
    InvidiousServiceError('API access denied',
        statusCode: 403, isGatewayResponse: true, errorCode: 'access_denied'),
    StateError('Invalid instance response'),
  ]) {
    test('onion API validation failure cleans the unsaved key: $error',
        () async {
      cubit.urlController.text = _onionOrigin;
      cubit.apiKeyController.text = _manualKey;
      api.validationError = error;
      await expectLater(cubit.validateServer(), throwsA(same(error)));
      expect(api.events, ['stats']);
      expect(api.signedOut.single.url, _onionOrigin);
      expect(api.signedOut.single.customHeaders, isEmpty);
      expect(await database.getServers(), isEmpty);
      expect(cubit.state.loading, isFalse);
    });
  }

  test('closing onion setup while storing its key cleans the unsaved key',
      () async {
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    setKeyWait = Completer<void>();
    final pending = cubit.validateServer();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((call) => call.method), ['setKey']);
    await cubit.close();
    setKeyWait!.complete();
    expect(await pending, isNull);
    expect(api.signedOut.single.url, _onionOrigin);
    expect(api.events, isEmpty);
    expect(calls.map((call) => call.method), ['setKey']);
    expect(await database.getServers(), isEmpty);
  });

  test('failed native key response clears any partially stored unsaved key',
      () async {
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    setKeyError = PlatformException(code: 'STORAGE_FAILURE');
    await expectLater(
        cubit.validateServer(), throwsA(isA<NerdVpnAccessRequired>()));
    expect(api.signedOut.single.url, _onionOrigin);
    expect(api.signedOut.single.customHeaders, isEmpty);
    expect(api.events, isEmpty);
    expect(await database.getServers(), isEmpty);
    expect(cubit.state.loading, isFalse);
  });

  test('successful onion stats alone cannot hide a failed video API', () async {
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    cubit.setAdvancedTest(false);
    api.videoError = const NerdVpnAccessRequired('denied');
    await expectLater(
        cubit.validateServer(), throwsA(isA<NerdVpnAccessRequired>()));
    expect(api.events, ['stats', 'video']);
    expect(api.signedOut.single.url, _onionOrigin);
    expect(await database.getServers(), isEmpty);
    expect(cubit.state.loading, isFalse);
  });

  test('closing onion setup during API validation cleans the unsaved key',
      () async {
    cubit.urlController.text = _onionOrigin;
    cubit.apiKeyController.text = _manualKey;
    api.validationWait = Completer<void>();
    final pending = cubit.validateServer();
    await Future<void>.delayed(Duration.zero);
    expect(api.events, ['stats']);
    await cubit.close();
    api.validationWait!.complete();
    expect(await pending, isNull);
    expect(api.signedOut.single.url, _onionOrigin);
    expect(api.events, ['stats']);
    expect(await database.getServers(), isEmpty);
  });

  test('cancelled sign-in returns no account and sends no probes', () async {
    api.cancelled = true;
    expect(await cubit.validateServer(), isNull);
    expect(api.events, ['token-sign-in']);
    expect(calls, isEmpty);
    expect(await database.getServers(), isEmpty);
    expect(cubit.state.loading, isFalse);
  });

  test(
      'closing onboarding while sign-in finishes revokes only the unsaved account',
      () async {
    api.signInWait = Completer<void>();
    final pending = cubit.validateServer();
    await Future<void>.delayed(Duration.zero);
    await cubit.close();
    api.signInWait!.complete();
    expect(await pending, isNull);
    expect(api.signedOut.single.accountId, api.authorized!.accountId);
    expect(api.events, ['token-sign-in']);
    expect(calls, isEmpty);
  });

  test('access restriction during a probe retains the signed-in account',
      () async {
    api.validationError = const NerdVpnAccessRequired('denied');
    final account = await cubit.validateServer();
    expect(account!.authToken, 'test-account-token');
    expect(api.events, ['token-sign-in', 'stats']);
    expect(api.signedOut, isEmpty);
    expect(cubit.state.loading, isFalse);
  });

  test('cancelled protected sign-in cleans up a newly entered manual key',
      () async {
    await cubit.addHeader('X-Invidious-Token', _manualKey);
    cubit.setProtectedServer(true);
    api.cancelled = true;
    expect(await cubit.validateServer(), isNull);
    expect(api.signedOut, hasLength(1));
    expect(api.signedOut.single.customHeaders, isEmpty);
    expect(api.events, ['protected-sign-in']);
  });

  test(
      'manual key is stored for the new account and removed from saved headers',
      () async {
    await cubit.addHeader('x-invidious-token', _manualKey);
    await cubit.addHeader('X-Other', 'keep');
    final account = await cubit.validateServer();

    expect(api.events, ['stats', 'video']);
    expect(account!.authToken, isNull);
    expect(account.customHeaders, {'X-Other': 'keep'});
    expect(api.validationHeaders?.containsKey('x-invidious-token'), isFalse);
    expect(calls.map((call) => call.method), ['setKey', 'status']);
    expect((calls.first.arguments as Map)['key'], _manualKey);
    final context = GatewayRequestContext.tryParse(
        (calls.first.arguments as Map)['context'] as String);
    expect(
        context?.key,
        GatewayRequestContext.forAccount(
                account.profileId, account.accountId, account.url)
            ?.key);
    await database.upsertServer(account);
    expect(database.getAccount(account.accountId)!.toJson().toString(),
        isNot(contains(_manualKey)));
  });

  test('duplicate key headers are rejected before native storage or sign-in',
      () async {
    await cubit.addHeader('X-Invidious-Token', _manualKey);
    await cubit.addHeader('x-invidious-token', _manualKey);
    await expectLater(cubit.validateServer(), throwsFormatException);
    expect(calls, isEmpty);
    expect(api.events, isEmpty);
    expect(cubit.state.loading, isFalse);
  });

  test('an ordinary instance keeps anonymous setup and custom headers',
      () async {
    cubit.urlController.text = 'https://private.example';
    await cubit.addHeader('X-Invidious-Token', 'private-instance-header');
    final account = await cubit.validateServer();
    expect(api.events, ['stats', 'video']);
    expect(calls, isEmpty);
    expect(
        account!.customHeaders['X-Invidious-Token'], 'private-instance-header');
  });

  test('unrelated probe failure revokes the new unsaved session', () async {
    api.failValidation = true;
    await expectLater(cubit.validateServer(), throwsStateError);
    expect(api.signedOut.single.accountId, api.authorized!.accountId);
    expect(await database.getServers(), isEmpty);
    expect(cubit.state.loading, isFalse);
  });
}
