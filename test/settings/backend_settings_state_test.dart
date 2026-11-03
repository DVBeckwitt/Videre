import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../test_app_cubit.dart';

class _TokenLoginService extends Service {
  @override
  Future<String?> logIn(String accountId, {String? profileId}) async {
    final owner = db.forProfile(profileId ?? db.profileId);
    final server = owner.getServer(accountId)!.copyWith(authToken: 'new-token');
    await owner.upsertServer(server);
    return server.authToken;
  }
}

class _PendingCookieLoginService extends Service {
  final started = Completer<void>();
  final result = Completer<String>();

  @override
  Future<void> syncAccountHistory(Server account,
      {IDbClient? database, bool force = false, bool pull = true}) async {}

  @override
  Future<String> loginWithCookies(
      String serverUrl, String username, String password,
      {Map<String, String>? headers}) {
    started.complete();
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final selector = BackendSelector('COMPANION_ID', const [
    BackendOption('0', 'First'),
    BackendOption('2', 'Third'),
    BackendOption('3', 'Fourth'),
    BackendOption('5', 'Sixth'),
  ]);
  final instance =
      Server(url: 'https://instance.example', backendSelector: selector);
  const other = Server(url: 'https://other.example');

  group('saved backend selection', () {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory documents;
    late TestAppCubit app;
    late ServerSettingsCubit settings;

    setUp(() async {
      documents = await Directory.systemTemp.createTemp('videre-backend-test-');
      messenger.setMockMethodCallHandler(
          pathProvider, (_) async => documents.path);
      db = await SembastSqfDb.createInMemory();
      await db.upsertServer(instance);
      await db.upsertServer(other);
      final selected = await db.getCurrentlySelectedServer();
      await fileDb.useServer(selected);
      app = TestAppCubit(AppState(0, selected, HomeLayout()));
      app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
      settings =
          ServerSettingsCubit(ServerSettingsState(server: selected), app);
    });

    tearDown(() async {
      await settings.close();
      await app.close();
      await db.close();
      messenger.setMockMethodCallHandler(pathProvider, null);
      await documents.delete(recursive: true);
    });

    test('deleting the selected server synchronizes the background server',
        () async {
      final deleting = settings.deleteServer();
      await settings.close();
      await deleting;

      expect(db.getServer(instance.url), isNull);
      expect((await db.getCurrentlySelectedServer()).url, other.url);
      expect((await fileDb.getCurrentlySelectedServer()).url, other.url);
      expect(app.state.server?.url, other.url);
    });

    test(
        'selected instance saves to foreground and background; survives reopen',
        () async {
      await settings.setBackend('5', true);
      expect(
          selector.selectedValue(await db.getCurrentlySelectedServer()), '5');
      expect(selector.selectedValue(await fileDb.getCurrentlySelectedServer()),
          '5');
      expect(selector.selectedValue(app.state.server!), '5');
      expect(app.state.server!.backendSelector!.automaticFallback, isTrue);
      expect(
          (await fileDb.getCurrentlySelectedServer())
              .backendSelector!
              .automaticFallback,
          isTrue);
      final reopened = ServerSettingsCubit(
          ServerSettingsState(server: db.getServer(instance.url)!), app);
      addTearDown(reopened.close);
      expect(selector.selectedValue(reopened.state.server), '5');
      expect(reopened.state.server.backendSelector!.automaticFallback, isTrue);
      await reopened.setBackend(null, false);
      expect(selector.selectedValue(await db.getCurrentlySelectedServer()),
          isNull);
      expect(selector.selectedValue(await fileDb.getCurrentlySelectedServer()),
          isNull);
      expect(
          (await db.getCurrentlySelectedServer())
              .backendSelector!
              .automaticFallback,
          isFalse);
    });

    test('editing inactive server never changes the active background server',
        () async {
      await db.useServer(other);
      final selected = await db.getCurrentlySelectedServer();
      await fileDb.useServer(selected);
      app.setServer(selected);
      await settings.setBackend('2', true);
      expect(selector.selectedValue(db.getServer(instance.url)!), '2');
      expect(db.getServer(instance.url)!.backendSelector!.automaticFallback,
          isTrue);
      expect((await db.getCurrentlySelectedServer()).url, other.url);
      expect((await fileDb.getCurrentlySelectedServer()).url, other.url);
      expect(app.state.server!.url, other.url);
    });

    test('settings stay bound to their original person after a profile switch',
        () async {
      final originalOwner = db.forProfile('default');
      final second = await db.createProfile('Second person');
      await db.useProfile(second.id);
      final secondAccount = Server(
          id: 'same-server-second-person',
          profileId: second.id,
          url: instance.url,
          authToken: 'second-person-token');
      await db.upsertServer(secondAccount);
      await fileDb.useProfile(second.id);
      await fileDb.useServer(await db.getCurrentlySelectedServer());
      app.setServer(await db.getCurrentlySelectedServer());

      await settings.addHeader('X-First-Person', 'first');
      expect(originalOwner.getServer(instance.accountId)!.customHeaders,
          {'X-First-Person': 'first'});
      expect(db.getServer(secondAccount.accountId)!.customHeaders, isEmpty);
      expect(app.state.server!.profileId, second.id);
      expect((await fileDb.getCurrentlySelectedServer()).authToken,
          'second-person-token');
    });

    test('same-server account edits cannot change the selected account',
        () async {
      final secondAccount = instance.copyWith(
          id: 'second-account', authToken: 'second-token', name: 'Second');
      await db.upsertServer(secondAccount);
      await db.useServer(secondAccount);
      final selected = await db.getCurrentlySelectedServer();
      await fileDb.useServer(selected);
      app.setServer(selected);

      await settings.renameAccount('First');
      expect(db.getServer(instance.accountId)!.name, 'First');
      expect(db.getServer(secondAccount.accountId)!.name, 'Second');
      expect(app.state.server!.accountId, secondAccount.accountId);
      expect((await fileDb.getCurrentlySelectedServer()).accountId,
          secondAccount.accountId);
    });

    test('stale legacy settings cannot edit or authenticate a replacement',
        () async {
      final replacement = instance.copyWith(
          id: 'replacement', authToken: 'replacement-token', name: 'Kept');
      await db.upsertServer(replacement);
      await db.useServer(replacement);
      await db.deleteServerById(instance);

      await expectLater(
          settings.renameAccount('Wrong account'), throwsStateError);
      await expectLater(
          settings.addHeader('X-Stale', 'wrong'), throwsStateError);
      await expectLater(settings.logOut(), throwsStateError);
      await expectLater(settings.logInWithToken(), throwsStateError);
      await expectLater(settings.logInProtected(), throwsStateError);
      await expectLater(settings.discoverBackends(), throwsStateError);
      final saved = db.getAccount(replacement.accountId)!;
      expect(saved.name, 'Kept');
      expect(saved.authToken, 'replacement-token');
      expect(saved.customHeaders, isEmpty);
    });

    test('cookie callback cannot log back in after logout', () async {
      final previousService = service;
      final login = _PendingCookieLoginService();
      service = login;
      addTearDown(() => service = previousService);
      final pending = settings.logInWithCookie('person', 'password');
      await login.started.future;
      await settings.logOut();
      final rejected =
          expectLater(pending, throwsA(isA<InvidiousServiceError>()));
      login.result.complete('SID=late');
      await rejected;
      expect(db.getServer(instance.accountId)!.sidCookie, isNull);
      expect(settings.state.authenticating, isFalse);
    });

    test(
        'cookie callback from a closed screen cannot undo logout on a new screen',
        () async {
      final previousService = service;
      final login = _PendingCookieLoginService();
      service = login;
      addTearDown(() => service = previousService);
      final pending = settings.logInWithCookie('person', 'password');
      await login.started.future;
      await settings.close();
      final reopened = ServerSettingsCubit(
          ServerSettingsState(server: db.getServer(instance.accountId)!), app);
      addTearDown(reopened.close);
      await reopened.logOut();
      final rejected =
          expectLater(pending, throwsA(isA<InvidiousServiceError>()));
      login.result.complete('SID=late-from-closed-screen');
      await rejected;
      expect(db.getServer(instance.accountId)!.sidCookie, isNull);
      expect(app.state.server!.sidCookie, isNull);
    });

    test('older screen preserves newly saved credentials and headers',
        () async {
      final latest = db.getServer(instance.url)!.copyWith(
          sidCookie: 'SID=new-session',
          customHeaders: {'Cookie': 'PREFS=new-preferences', 'X-New': 'kept'});
      await db.upsertServer(latest);
      await settings.setBackend('3', false);
      final saved = db.getServer(instance.url)!;
      expect(saved.sidCookie, 'SID=new-session');
      expect(saved.customHeaders,
          {'Cookie': 'PREFS=new-preferences; COMPANION_ID=3', 'X-New': 'kept'});
    });

    test('token login updates the screen and survives a later header edit',
        () async {
      final previousService = service;
      service = _TokenLoginService();
      addTearDown(() => service = previousService);

      await settings.logInWithToken();
      expect(settings.state.server.authToken, 'new-token');
      expect(app.state.server!.authToken, 'new-token');
      await settings.addHeader('X-Instance', 'kept');
      expect(db.getServer(instance.url)!.authToken, 'new-token');
      expect(
          (await fileDb.getCurrentlySelectedServer()).authToken, 'new-token');
    });

    test('header edits preserve newer credentials and active server selection',
        () async {
      await db.upsertServer(db.getServer(instance.url)!.copyWith(
          authToken: 'new-token', customHeaders: {'X-Existing': 'kept'}));
      await db.useServer(other);
      await fileDb.useServer(await db.getCurrentlySelectedServer());
      app.setServer(await db.getCurrentlySelectedServer());

      await settings.addHeader('X-Added', 'new');
      expect(db.getServer(instance.url)!.authToken, 'new-token');
      expect(db.getServer(instance.url)!.customHeaders,
          {'X-Existing': 'kept', 'X-Added': 'new'});
      expect((await db.getServers()).where((server) => server.inUse),
          hasLength(1));
      expect((await fileDb.getCurrentlySelectedServer()).url, other.url);

      await settings.removeHeader('X-Added');
      expect(db.getServer(instance.url)!.customHeaders, {'X-Existing': 'kept'});
    });

    test('pending cookie login preserves edits and a different active server',
        () async {
      final previousService = service;
      final login = _PendingCookieLoginService();
      service = login;
      addTearDown(() => service = previousService);
      final saving = settings.logInWithCookie('username', 'password');
      await login.started.future;
      await db.upsertServer(db
          .getServer(instance.url)!
          .copyWith(customHeaders: {'X-New': 'kept'}));
      await db.useServer(other);
      await fileDb.useServer(await db.getCurrentlySelectedServer());
      app.setServer(await db.getCurrentlySelectedServer());
      await settings.close();
      login.result.complete('SID=new-cookie');
      await saving;

      expect(db.getServer(instance.url)!.sidCookie, 'SID=new-cookie');
      expect(db.getServer(instance.url)!.customHeaders, {'X-New': 'kept'});
      expect((await db.getServers()).where((server) => server.inUse),
          hasLength(1));
      expect((await db.getCurrentlySelectedServer()).url, other.url);
      expect((await fileDb.getCurrentlySelectedServer()).url, other.url);
    });

    test('overlapping header edits retain both changes', () async {
      await Future.wait([
        settings.addHeader('X-First', 'first'),
        settings.addHeader('X-Second', 'second'),
      ]);

      expect(db.getServer(instance.url)!.customHeaders,
          {'X-First': 'first', 'X-Second': 'second'});
      expect((await fileDb.getCurrentlySelectedServer()).customHeaders,
          {'X-First': 'first', 'X-Second': 'second'});
    });

    test('pending cookie login cannot recreate a deleted server', () async {
      final previousService = service;
      final login = _PendingCookieLoginService();
      service = login;
      addTearDown(() => service = previousService);
      final saving = settings.logInWithCookie('username', 'password');
      await login.started.future;
      await db.deleteServerById(instance);
      final failed = expectLater(saving, throwsA(isA<InvidiousServiceError>()));
      login.result.complete('SID=new-cookie');
      await failed;

      expect(db.getServer(instance.url), isNull);
    });
    test('deleted server is not recreated by an open selector', () async {
      await db.deleteServerById(instance);
      await expectLater(settings.setBackend('5', true), throwsStateError);
      expect(db.getServer(instance.url), isNull);
    });

    test('server without discovered configuration cannot change a cookie',
        () async {
      await db.upsertServer(instance.copyWith(backendSelector: null));
      await expectLater(settings.setBackend('0', false), throwsStateError);
      expect(db.getServer(instance.url)!.customHeaders, isEmpty);
    });

    test('discovery refresh preserves newer credentials, cookies and fallback',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final client = MockClient((request) async {
        started.complete();
        await release.future;
        return http.Response(
          '<title>Invidious</title>'
          '<a href="/switchbackend?backend_id=0">Fresh first</a>'
          '<a href="/switchbackend?backend_id=5">Fresh sixth</a>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final previousService = service;
      service = Service(httpClient: client);
      addTearDown(() {
        service = previousService;
        client.close();
      });

      final discovery = settings.discoverBackends();
      await started.future;
      final latest = db.getServer(instance.url)!.copyWith(
            authToken: 'fresh-token',
            sidCookie: 'SID=fresh-session',
            customHeaders: {
              'Cookie': 'COMPANION_ID=5; PREFS=unchanged',
              'X-New': 'kept',
            },
            backendSelector: selector.copyWith(automaticFallback: false),
          );
      await db.upsertServer(latest);
      release.complete();
      final discovered = await discovery;

      expect(discovered.customHeaders, latest.customHeaders);
      expect(discovered.authToken, latest.authToken);
      expect(discovered.sidCookie, latest.sidCookie);
      expect(discovered.backendSelector!.automaticFallback, isFalse);
      expect(discovered.backendSelector!.labelFor('5'), 'Fresh sixth');
      expect(discovered.backendSelector!.selectedValue(discovered), '5');
      expect(db.getServer(instance.url), discovered);
      expect(await fileDb.getCurrentlySelectedServer(), discovered);
      expect(app.state.server, discovered);
    });

    for (final browser in [false, true]) {
      for (final savedFallback in <bool?>[null, false, true]) {
        test(
            '${browser ? 'browser' : 'direct'} discovery ${savedFallback == null ? 'enables fallback by default' : 'preserves saved fallback $savedFallback'}',
            () async {
          final saved = instance.copyWith(
            url: 'https://invidious.nerdvpn.de',
            backendSelector: savedFallback == null
                ? null
                : selector.copyWith(automaticFallback: savedFallback),
          );
          await db.upsertServer(saved);
          final discovering =
              ServerSettingsCubit(ServerSettingsState(server: saved), app);
          addTearDown(discovering.close);
          const source = '<title>Invidious</title>'
              '<a href="/switchbackend?backend_id=0">First</a>'
              '<a href="/switchbackend?backend_id=5">Sixth</a>';
          final client = MockClient((_) async => http.Response(source, 200,
              headers: {'content-type': 'text/html'}));
          final previousService = service;
          service = Service(httpClient: client);
          addTearDown(() {
            service = previousService;
            client.close();
          });

          final discovered = browser
              ? await discovering.discoverBrowserBackends(
                  pageUri: Uri.parse('${saved.url}/'), source: source)
              : await discovering.discoverBackends();
          expect(discovered.backendSelector!.automaticFallback,
              savedFallback ?? true);
          expect(db.getServer(saved.url), discovered);
          expect(discovering.state.server, discovered);
        });
      }
    }
    test('a server deleted during discovery is not recreated', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final client = MockClient((request) async {
        started.complete();
        await release.future;
        return http.Response(
          '<title>Invidious</title>'
          '<a href="/switchbackend?backend_id=0">First</a>'
          '<a href="/switchbackend?backend_id=5">Sixth</a>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final previousService = service;
      service = Service(httpClient: client);
      addTearDown(() {
        service = previousService;
        client.close();
      });

      final discovery = settings.discoverBackends();
      final result = expectLater(discovery, throwsStateError);
      await started.future;
      await db.deleteServerById(instance);
      release.complete();
      await result;
      expect(db.getServer(instance.url), isNull);
    });

    test('browser discovery preserves saved preference and login data',
        () async {
      final nerd = instance.copyWith(url: 'https://invidious.nerdvpn.de');
      await db.upsertServer(nerd);
      final browserSettings =
          ServerSettingsCubit(ServerSettingsState(server: nerd), app);
      addTearDown(browserSettings.close);
      final latest = nerd.copyWith(
        authToken: 'latest-token',
        sidCookie: 'SID=latest-login',
        customHeaders: {
          'Cookie': 'COMPANION_ID=5; PREFS=kept',
          'X-New': 'kept',
        },
        backendSelector: selector.copyWith(automaticFallback: true),
      );
      await db.upsertServer(latest);
      final imported = await browserSettings.discoverBrowserBackends(
        pageUri: Uri.parse('${nerd.url}/'),
        source: '<div id="backend-selector">'
            '<a class="backend-selected" href="/switchbackend?backend_id=0">Fresh first</a>'
            '<a href="/switchbackend?backend_id=5">Fresh sixth</a></div>',
      );
      expect(imported.authToken, latest.authToken);
      expect(imported.sidCookie, latest.sidCookie);
      expect(imported.customHeaders, latest.customHeaders);
      expect(imported.backendSelector!.selectedValue(imported), '5');
      expect(imported.backendSelector!.labelFor('5'), 'Fresh sixth');
      expect(imported.backendSelector!.automaticFallback, isTrue);
      expect(db.getServer(nerd.url), imported);
      expect(browserSettings.state.server, imported);
      // Importing an inactive server must not move foreground/background jobs.
      expect(app.state.server!.url, instance.url);
      expect((await fileDb.getCurrentlySelectedServer()).url, instance.url);
    });

    test('browser discovery cannot recreate a deleted server', () async {
      final nerd = instance.copyWith(url: 'https://invidious.nerdvpn.de');
      await db.upsertServer(nerd);
      final browserSettings =
          ServerSettingsCubit(ServerSettingsState(server: nerd), app);
      addTearDown(browserSettings.close);
      await db.deleteServerById(nerd);
      await expectLater(
          browserSettings.discoverBrowserBackends(
              pageUri: Uri.parse('${nerd.url}/'), source: ''),
          throwsStateError);
      expect(db.getServer(nerd.url), isNull);
    });

    test('changing backend does not reuse an in-flight metadata request',
        () async {
      final cookies = <String?>[];
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final releaseResponses = Completer<void>();
      final client = MockClient((request) async {
        cookies.add(request.headers['cookie']);
        if (cookies.length == 1) firstStarted.complete();
        if (cookies.length == 2) secondStarted.complete();
        await releaseResponses.future;
        return http.Response(
            '{"videoId":"backend-video","title":"test","adaptiveFormats":[],"formatStreams":[],"captions":[]}',
            200,
            headers: {'content-type': 'application/json'});
      });
      addTearDown(client.close);
      final api = Service(httpClient: client);
      await settings.setBackend('0', false);
      final first = api.getVideo('backend-video');
      final firstResult = expectLater(first, throwsStateError);
      await firstStarted.future;
      await settings.setBackend('5', false);
      final second = api.getVideo('backend-video');
      try {
        await secondStarted.future.timeout(const Duration(seconds: 3));
      } finally {
        releaseResponses.complete();
        await firstResult;
        final fresh = await second;
        expect(fresh.videoId, 'backend-video');
        expect(fresh.backendPlayback!.server.customHeaders['Cookie'],
            'COMPANION_ID=5');
      }
      expect(cookies, ['COMPANION_ID=0', 'COMPANION_ID=5']);
    });
  });
}
