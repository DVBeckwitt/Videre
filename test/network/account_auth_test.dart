import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../test_app_cubit.dart';

const _webAuth = MethodChannel('flutter_web_auth_2');
const _gatewaySessions = MethodChannel('videre/gateway_sessions');
const _gatewayBrowser = MethodChannel('videre/gateway_auth');
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _disabledGateway = {
  'supported': true,
  'enabled': false,
  'needsSignIn': false,
};

Uri _callback(MethodCall call) {
  final arguments = Map<String, dynamic>.from(call.arguments as Map);
  final authorization = Uri.parse(arguments['url'] as String);
  expect(authorization.path, '/authorize_token');
  return Uri.parse(authorization.queryParameters['callback_url']!);
}

String _tokenCallback(Uri callback, String token) => callback.replace(
    queryParameters: {...callback.queryParameters, 'token': token}).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SembastSqfDb database;
  late Directory documents;
  late Service api;
  late MockClient client;
  final requests = <http.Request>[];
  const account = Server(url: 'https://instance.example', id: 'person-account');

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    documents = await Directory.systemTemp.createTemp('videre-account-auth-');
    messenger.setMockMethodCallHandler(
        _pathProvider, (_) async => documents.path);
    messenger.setMockMethodCallHandler(
        _gatewaySessions, (_) async => _disabledGateway);
    messenger.setMockMethodCallHandler(_gatewayBrowser, (_) async => null);
    db = database = await SembastSqfDb.createInMemory();
    await database.upsertServer(account);
    await fileDb.useServer(await database.getCurrentlySelectedServer());
    requests.clear();
    client = MockClient((request) async {
      requests.add(request);
      expect(request.url.path, '/api/v1/auth/history');
      return http.Response('[]', 200);
    });
    service = api = Service(httpClient: client);
  });

  tearDown(() async {
    service = Service();
    client.close();
    await database.close();
    for (final channel in [
      _webAuth,
      _gatewaySessions,
      _gatewayBrowser,
      _pathProvider
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
    await documents.delete(recursive: true);
  });

  test('logout cancels an older pending token callback', () async {
    final opened = Completer<Uri>();
    final response = Completer<String>();
    messenger.setMockMethodCallHandler(_webAuth, (call) {
      opened.complete(_callback(call));
      return response.future;
    });
    final pending = api.logIn(account.accountId);
    final rejected =
        expectLater(pending, throwsA(isA<InvidiousServiceError>()));
    final callback = await opened.future;

    await api.logOutProtected(database.getServer(account.accountId)!);
    response.complete(_tokenCallback(callback, 'late-token'));
    await rejected;

    expect(database.getServer(account.accountId)!.authToken, isNull);
    expect((await fileDb.getCurrentlySelectedServer()).authToken, isNull);
    expect(requests, isEmpty);
  });

  test('sign-in for a removed URL-key account cannot target its replacement',
      () async {
    const removed = Server(url: 'https://legacy.example');
    final replacement = removed.copyWith(
        id: 'replacement-account', authToken: 'replacement-token');
    await database.upsertServer(removed);
    await database.upsertServer(replacement);
    await database.deleteServer(removed);
    var browserOpened = false;
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      browserOpened = true;
      return _tokenCallback(_callback(call), 'unexpected-login');
    });

    await expectLater(
        api.logIn(removed.accountId), throwsA(isA<InvidiousServiceError>()));

    expect(browserOpened, isFalse);
    expect(database.getAccount(replacement.accountId)!.authToken,
        'replacement-token');
    expect(database.getAccount(removed.accountId), isNull);
  });

  test('the newest token login wins and preserves intervening account edits',
      () async {
    final opened = Completer<Uri>();
    final oldResponse = Completer<String>();
    var calls = 0;
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      final callback = _callback(call);
      if (calls++ == 0) {
        opened.complete(callback);
        return oldResponse.future;
      }
      return _tokenCallback(callback, 'fresh%2Fliteral');
    });
    final pending = api.logIn(account.accountId);
    final rejected =
        expectLater(pending, throwsA(isA<InvidiousServiceError>()));
    final oldCallback = await opened.future;
    await database.upsertServer(database.getServer(account.accountId)!.copyWith(
        name: 'Updated name', customHeaders: {'X-Preference': 'kept'}));

    await api.logIn(account.accountId);
    oldResponse.complete(_tokenCallback(oldCallback, 'stale-token'));
    await rejected;

    final saved = database.getServer(account.accountId)!;
    expect(saved.authToken, 'fresh%2Fliteral');
    expect(saved.name, 'Updated name');
    expect(saved.customHeaders, {'X-Preference': 'kept'});
    expect((await fileDb.getCurrentlySelectedServer()).authToken,
        'fresh%2Fliteral');
  });

  test('late cookie login cannot replace a newer token login', () async {
    final cookieStarted = Completer<void>();
    final cookieResponse = Completer<http.Response>();
    final delayedClient = MockClient((request) async {
      if (request.url.path == '/login') {
        cookieStarted.complete();
        return cookieResponse.future;
      }
      expect(request.url.path, '/api/v1/auth/history');
      return http.Response('[]', 200);
    });
    addTearDown(delayedClient.close);
    service = api = Service(httpClient: delayedClient);
    messenger.setMockMethodCallHandler(
        _webAuth, (call) async => _tokenCallback(_callback(call), 'new-token'));
    final pending = api.logInAccountWithCookie(
        database.getServer(account.accountId)!, 'person', 'password');
    final rejected =
        expectLater(pending, throwsA(isA<InvidiousServiceError>()));
    await cookieStarted.future;

    await api.logIn(account.accountId);
    cookieResponse.complete(http.Response('', 302,
        headers: {'set-cookie': 'SID=late-cookie; Secure; HttpOnly'}));
    await rejected;

    final saved = database.getServer(account.accountId)!;
    expect(saved.authToken, 'new-token');
    expect(saved.sidCookie, isNull);
  });

  test('same-ID accounts in different profiles keep independent sign-ins',
      () async {
    final origin = database.forProfile(database.profileId);
    final other = await database.createProfile('Second person');
    final otherOwner = database.forProfile(other.id);
    await otherOwner.upsertServer(account.copyWith(profileId: other.id));
    final opened = Completer<Uri>();
    final firstResponse = Completer<String>();
    var calls = 0;
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      final callback = _callback(call);
      if (calls++ == 0) {
        opened.complete(callback);
        return firstResponse.future;
      }
      return _tokenCallback(callback, 'second-person-token');
    });

    final firstLogin = api.logIn(account.accountId);
    final firstCallback = await opened.future;
    await database.useProfile(other.id);
    await fileDb.useProfile(other.id);
    await fileDb.useServer(await otherOwner.getCurrentlySelectedServer());
    await api.logIn(account.accountId);
    firstResponse.complete(_tokenCallback(firstCallback, 'first-person-token'));
    await firstLogin;

    expect(
        origin.getServer(account.accountId)!.authToken, 'first-person-token');
    expect(otherOwner.getServer(account.accountId)!.authToken,
        'second-person-token');
    final background = await fileDb.getCurrentlySelectedServer();
    expect(background.profileId, other.id);
    expect(background.authToken, 'second-person-token');
    // Inactive credentials are mirrored only when that person is selected.
    await database.useProfile(origin.profileId);
    await fileDb.syncWithDb();
    expect((await fileDb.getCurrentlySelectedServer()).authToken,
        'first-person-token');
  });

  test('an old unauthorized check cannot clear a login during gateway status',
      () async {
    await database.upsertServer(database
        .getServer(account.accountId)!
        .copyWith(authToken: 'old-token'));
    final statusStarted = Completer<void>();
    final statusResponse = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(_gatewaySessions, (call) {
      expect(call.method, 'status');
      statusStarted.complete();
      return statusResponse.future;
    });
    final validationClient = MockClient((request) async => http.Response(
        request.url.path.endsWith('/subscriptions') ? '{}' : '[]',
        request.url.path.endsWith('/subscriptions') ? 401 : 200));
    addTearDown(validationClient.close);
    service = api = Service(httpClient: validationClient);
    messenger.setMockMethodCallHandler(_webAuth,
        (call) async => _tokenCallback(_callback(call), 'fresh-token'));

    final validation = api.validateCurrentSession();
    await statusStarted.future;
    await api.logIn(account.accountId);
    await database.upsertServer(database
        .getServer(account.accountId)!
        .copyWith(customHeaders: {'X-After-Login': 'preserved'}));
    statusResponse.complete(_disabledGateway);
    expect(await validation, isFalse);

    final saved = database.getServer(account.accountId)!;
    expect(saved.authToken, 'fresh-token');
    expect(saved.customHeaders, {'X-After-Login': 'preserved'});
  });

  test('an old unauthorized response cannot clear a reissued identical token',
      () async {
    await database.upsertServer(database
        .getServer(account.accountId)!
        .copyWith(authToken: 'same-token'));
    final requested = Completer<void>();
    final unauthorized = Completer<http.Response>();
    final validationClient = MockClient((request) async {
      if (request.url.path.endsWith('/subscriptions')) {
        requested.complete();
        return unauthorized.future;
      }
      return http.Response('[]', 200);
    });
    addTearDown(validationClient.close);
    service = api = Service(httpClient: validationClient);
    messenger.setMockMethodCallHandler(_webAuth,
        (call) async => _tokenCallback(_callback(call), 'same-token'));

    final validation = api.validateCurrentSession();
    await requested.future;
    await api.logIn(account.accountId);
    unauthorized.complete(http.Response('{}', 401));
    expect(await validation, isFalse);

    expect(database.getServer(account.accountId)!.authToken, 'same-token');
    expect((await fileDb.getCurrentlySelectedServer()).authToken, 'same-token');
  });

  test('a delayed logout cannot clear a newer login from reopened settings',
      () async {
    final selected = await database.getCurrentlySelectedServer();
    final app = TestAppCubit(AppState(0, selected, HomeLayout()));
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    final oldSettings =
        ServerSettingsCubit(ServerSettingsState(server: selected), app);
    final reopened =
        ServerSettingsCubit(ServerSettingsState(server: selected), app);
    addTearDown(() async {
      await oldSettings.close();
      await reopened.close();
      await app.close();
    });
    final statusStarted = Completer<void>();
    final statusResponse = Completer<Map<String, Object>>();
    var statusReads = 0;
    messenger.setMockMethodCallHandler(_gatewaySessions, (call) {
      expect(call.method, 'status');
      if (statusReads++ == 0) {
        statusStarted.complete();
        return statusResponse.future;
      }
      // Closing an installing gateway browser is followed by a fresh status
      // read. The native session remains disabled after this ordinary login.
      return Future.value(_disabledGateway);
    });
    messenger.setMockMethodCallHandler(_webAuth,
        (call) async => _tokenCallback(_callback(call), 'newer-login'));

    final loggingOut = oldSettings.logOut();
    await statusStarted.future;
    await reopened.logInWithToken();
    statusResponse.complete(_disabledGateway);
    await loggingOut;

    expect(statusReads, 2);
    expect(database.getServer(account.accountId)!.authToken, 'newer-login');
    expect(
        (await fileDb.getCurrentlySelectedServer()).authToken, 'newer-login');
  });

  test('a token callback with the wrong state does not persist credentials',
      () async {
    messenger.setMockMethodCallHandler(_webAuth, (call) async {
      final callback = _callback(call);
      return callback.replace(queryParameters: {
        'state': 'wrong-state',
        'token': 'untrusted-token',
      }).toString();
    });

    await expectLater(
        api.logIn(account.accountId), throwsA(isA<InvidiousServiceError>()));

    expect(database.getServer(account.accountId)!.authToken, isNull);
    expect(requests, isEmpty);
  });
}
