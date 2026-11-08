import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _origin = 'https://invidious.nerdvpn.de';
const _access = MethodChannel('videre/nerdvpn_access');
const _manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';

class _OnboardingService extends Service {
  bool cancelled = false;
  bool failValidation = false;
  Object? validationError;
  Completer<void>? signInWait;
  final events = <String>[];
  final signedOut = <Server>[];
  Server? authorized;
  Map<String, String>? validationHeaders;

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
    if (validationError != null) throw validationError!;
    if (failValidation) throw StateError('Invalid instance response');
  }

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest}) async {
    events.add('video');
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

  setUp(() async {
    db = database = await SembastSqfDb.createInMemory();
    api = _OnboardingService();
    service = api;
    cubit = AddServerCubit(const AddServerState());
    cubit.selectPublicInstance(_origin);
    accessState = 'ready';
    calls.clear();
    messenger.setMockMethodCallHandler(_access, (call) async {
      calls.add(call);
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
