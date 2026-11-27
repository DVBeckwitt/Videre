import 'dart:async';
import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/wrong_thumbnail_url.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/settings/views/components/media_companion_dialog.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/media_companion_transport.dart';

class _ValidationService extends Service {
  _ValidationService({this.thumbnails = const [], this.dashUrl});

  final List<ImageObject> thumbnails;
  final String? dashUrl;
  final checked = <Server>[];
  final response = Completer<void>();

  @override
  Future<void> validateServer(String url, Map<String, String>? headers) {
    checked.add(Server(url: url, customHeaders: headers ?? {}));
    return response.future;
  }

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    checked.add(serverOverride!);
    return Video(
        videoId: videoId, videoThumbnails: thumbnails, dashUrl: dashUrl);
  }
}

class _ProtectedValidationService extends Service {
  final bool cancel;
  final bool failValidation;
  Server? signedIn;
  Server? signedOut;
  int validations = 0;

  _ProtectedValidationService(
      {this.cancel = false, this.failValidation = false});

  @override
  Future<Server?> authenticateProtected(Server server) async {
    signedIn = server;
    return cancel ? null : server.copyWith(authToken: 'protected-token');
  }

  @override
  Future<Server?> authenticateNerdVpn(Server server) =>
      authenticateProtected(server);

  @override
  Future<void> validateServer(
      String serverUrl, Map<String, String>? headers) async {
    expect(signedIn, isNotNull);
    expect(serverUrl, signedIn!.url);
    validations++;
    if (failValidation) throw StateError('validation failed');
  }

  @override
  Future<Server?> logOutProtected(Server server) async {
    signedOut = server;
    return server;
  }
}

class _UnavailableCommunityList implements CommunityListStore {
  @override
  Future<CommunitySnapshot?> load(CommunityList list) async => null;

  @override
  Future<CommunitySnapshot> refresh(CommunityList list,
          {required bool Function() isCurrent}) async =>
      throw StateError('Offline test');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizes copied instance addresses and preserves self-hosted paths',
      () {
    expect(
        AddServerCubit.normalizeUrl(' INV.example/// '), 'https://inv.example');
    expect(AddServerCubit.normalizeUrl('http://localhost:3000/invidious/'),
        'http://localhost:3000/invidious');
    expect(AddServerCubit.normalizeUrl('https://inv.nadeko.net/'),
        'https://inv.nadeko.net');
    expect(
        AddServerCubit.normalizeUrl('http://[::1]:3000/'), 'http://[::1]:3000');
    for (final address in [
      '',
      'https://',
      'not a host',
      'ftp://inv.example',
      'https://inv.example:65536',
      'https://user:password@inv.example',
      'https://inv.example/watch?v=video',
      'https://inv.example/#fragment',
      'https://www.youtube.com',
      'https://www.youtube.co.uk',
    ]) {
      expect(AddServerCubit.normalizeUrl(address), isNull, reason: address);
    }
  });

  group('public instance directory', () {
    dynamic entry(String url, {dynamic api = false, String type = 'https'}) => [
          Uri.parse(url).host,
          {'uri': url, 'api': api, 'type': type, 'monitor': {}}
        ];

    test('keeps HTTPS roots, deduplicates and puts reported APIs first', () {
      final parsed = AddServerCubit.parsePublicInstances([
        entry('https://z.example'),
        entry('https://a.example', api: null),
        entry('https://b.example/', api: true),
        entry('https://b.example', api: false),
        entry('http://plain.example'),
        entry('noscheme.example'),
        entry('https://path.example/api'),
        entry('https://login:secret@private.example'),
        entry('https://query.example/?query=1'),
        entry('https://fragment.example/#fragment'),
        entry('https://hidden.onion', type: 'onion'),
        [
          'special.example',
          {'uri': 'https://special.example', 'type': 'https'}
        ],
        ['broken'],
        [
          'broken',
          {'uri': 1}
        ],
        'unexpected',
        null,
      ]);
      expect(parsed, [
        (url: 'https://b.example', api: true),
        (url: 'https://a.example', api: false),
        (url: 'https://z.example', api: false),
      ]);
      expect(
          () => AddServerCubit.parsePublicInstances({}), throwsFormatException);
    });

    test('offers the project instance without sending server headers',
        () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), AddServerCubit.directoryUrl);
        expect(request.headers, isEmpty);
        return http.Response('[]', 200);
      });
      expect(await AddServerCubit.getPublicInstances(client: client), [
        (url: 'https://invidious.dvbeckwitt.duckdns.org', api: true),
      ]);
    });

    test('suggests only curated hosts regardless of API reporting', () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        return http.Response(
            jsonEncode([
              entry('https://invidious.f5.si'),
              entry('https://inv.nadeko.net', api: true),
              entry('https://invidious.dvbeckwitt.duckdns.org'),
              entry('https://invidious.nerdvpn.de', api: false),
              entry('https://yt.chocolatemoo53.com', api: true),
              entry('https://invidious.tiekoetter.com', api: true),
              entry('https://new.example', api: true),
            ]),
            200);
      });

      final instances = await AddServerCubit.getPublicInstances(client: client);
      expect(
          instances,
          unorderedEquals([
            (url: 'https://invidious.dvbeckwitt.duckdns.org', api: true),
            (url: 'https://invidious.nerdvpn.de', api: false),
            (url: 'https://yt.chocolatemoo53.com', api: true),
          ]));
      expect(requests, [Uri.parse(AddServerCubit.directoryUrl)]);
    });

    test('rejects HTTP failures and malformed directory data', () async {
      for (final response in [
        http.Response('Unavailable', 503),
        http.Response('<html>Challenge</html>', 200),
        http.Response('{}', 200),
      ]) {
        await expectLater(
            AddServerCubit.getPublicInstances(
                client: MockClient((_) async => response)),
            throwsFormatException);
      }
    });
  });

  group('adding an instance', () {
    late AddServerCubit cubit;
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      cubit = AddServerCubit(const AddServerState(advancedTest: false));
    });
    tearDown(() async {
      if (!cubit.isClosed) await cubit.close();
      await db.close();
      service = Service();
    });

    for (final allowFirst in [false, true]) {
      testWidgets(
          'a remembered setup choice (allowed=$allowFirst) is scoped to one instance and profile',
          (tester) async {
        const host = 'https://media.example:8443';
        const frontend = 'https://frontend.example';
        const address = '$frontend/a';
        final decision = {if (allowFirst) host};
        mockMediaCompanionTransport();
        await tester.runAsync(() => db.addAccountWithMediaCompanions(
            Server(
                id: 'first',
                url: address,
                mediaCompanionOrigins: decision.toList()),
            isCurrent: () => true,
            setupDecision: decision));
        final validation = _ValidationService(dashUrl: '$host/test.mpd')
          ..response.complete();
        service = validation;
        final router = RootStackRouter.build(routes: [
          NamedRouteDef(
              name: 'FixtureRoute',
              path: '/',
              builder: (_, __) => const Scaffold()),
          AutoRoute(page: AddServerRoute.page),
        ]);
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(
          routerConfig: router.config(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ));
        await tester.pumpAndSettle();

        Future<void> settleSetup() async {
          for (var attempt = 0; attempt < 8; attempt++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        Future<void> add(String url, {required bool offersHost}) async {
          ValidatedSetupAccount? result;
          unawaited(router
              .push<ValidatedSetupAccount>(const AddServerRoute())
              .then((value) => result = value));
          await tester.pumpAndSettle();
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text = url;
          await tester.pumpAndSettle();
          final submit = find.text('Test and add server');
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await settleSetup();
          final title = find.text('Allow a separate playback host?');
          if (offersHost) {
            expect(title, findsOneWidget);
            expect(find.textContaining('To play the test stream, $url asked'),
                findsOneWidget);
            expect(find.textContaining('once per instance in this profile'),
                findsOneWidget);
            expect(find.text(host), findsOneWidget);
            await tester.tap(find.text('Continue without allowing'));
            await settleSetup();
          } else {
            expect(title, findsNothing);
          }
          expect(result?.server.url, url);
          expect(result?.server.profileId, db.profileId);
          expect(result?.mediaCompanionDecision, offersHost ? isEmpty : isNull);
          final returned = result!;
          final saved = await tester.runAsync(() =>
              db.addAccountWithMediaCompanions(returned.server,
                  isCurrent: () => true,
                  setupDecision: returned.mediaCompanionDecision));
          expect(saved!.mediaCompanionOrigins,
              allowFirst && !offersHost ? [host] : isEmpty);
        }

        await add(address, offersHost: false); // Another account at /a.
        await add('$frontend/b', offersHost: true);
        await tester.runAsync(() async {
          final other = await db.createProfile('Other');
          await db.useProfile(other.id);
          await db.upsertServer(
              Server(profileId: other.id, url: 'https://existing.example'));
        });
        await add(address, offersHost: true);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('setup names each host and only approves the checked subset',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      const server = Server(url: 'https://inv.example');
      const audio = 'https://audio.example:7443';
      const media = 'https://media.example:8443';
      Set<String>? result;
      var completed = false;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
            onPressed: () async {
              result = await chooseSetupMediaCompanions(context, server, {
                media,
                audio,
                server.url,
                'https://media.example/signed?token=secret',
              });
              completed = true;
            },
            child: const Text('Set up instance'),
          );
        })),
      ));
      await tester.tap(find.text('Set up instance'));
      await tester.pumpAndSettle();
      expect(find.text('Allow separate playback hosts?'), findsOneWidget);
      expect(find.textContaining('token=secret'), findsNothing);
      final checkboxes = find.byType(CheckboxListTile);
      expect(checkboxes, findsNWidgets(2));
      expect(
          tester
              .widgetList<CheckboxListTile>(checkboxes)
              .every((box) => box.value == false),
          isTrue);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      await tester.ensureVisible(find.text(audio));
      await tester.tap(find.text(audio));
      await tester.pumpAndSettle();
      expect(completed, isFalse);
      await tester.tap(find.text('Allow selected hosts'));
      await tester.pumpAndSettle();
      expect(result, {audio});
      expect(tester.takeException(), isNull);

      completed = false;
      await tester.tap(find.text('Set up instance'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(media));
      await tester.tap(find.text(media));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a narrow screen keeps a long host and the decline action accessible',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 320);
      addTearDown(tester.view.reset);
      final origin = 'https://${List.filled(3, 'a' * 60).join('.')}.example';
      Set<String>? result;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
            onPressed: () async {
              result = await chooseSetupMediaCompanions(
                  context, const Server(url: 'https://inv.example'), {origin});
            },
            child: const Text('Set up instance'),
          );
        })),
      ));
      await tester.tap(find.text('Set up instance'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text(origin));
      expect(find.text(origin), findsOneWidget);
      final skip = find.text('Continue without allowing');
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(result, isEmpty);
    });

    testWidgets('TV remote can move from continue to the named approval',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 540);
      addTearDown(tester.view.reset);
      const origin = 'https://video.example:444';
      Set<String>? result;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
            onPressed: () async {
              result = await chooseSetupMediaCompanions(
                  context, const Server(url: 'https://inv.example'), {origin});
            },
            child: const Text('Set up instance'),
          );
        })),
      ));
      await tester.tap(find.text('Set up instance'));
      await tester.pumpAndSettle();
      final skip = tester.getCenter(find.text('Continue without allowing'));
      final allow = tester.getCenter(find.text('Allow $origin'));
      await tester.sendKeyEvent((allow.dy - skip.dy).abs() < 16
          ? LogicalKeyboardKey.arrowRight
          : allow.dy > skip.dy
              ? LogicalKeyboardKey.arrowDown
              : LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(result, {origin});
    });

    for (final (tv, leaveDuringValidation, mediaHost) in [
      (false, false, false),
      (true, false, false),
      (false, true, false),
      (false, false, true),
      (true, false, true),
    ]) {
      testWidgets(
          leaveDuringValidation
              ? 'leaving during first instance validation discards choices'
              : mediaHost
                  ? 'first instance offers the tested media host before saving (TV=$tv)'
                  : 'first instance offers AiSList choices before connecting (TV=$tv)',
          (tester) async {
        final original = communityFilters;
        communityFilters = CommunityFilters(
          database: () => db,
          repository: _UnavailableCommunityList(),
        );
        await tester.runAsync(communityFilters.reloadForProfile);
        app.isTv = tv;
        addTearDown(() {
          communityFilters = original;
          app.isTv = false;
        });
        const origin = 'https://media.example:9443';
        final validator = _ValidationService(
            dashUrl: mediaHost ? '$origin/manifest.mpd?check=signed' : null);
        service = validator;
        final router = RootStackRouter.build(routes: [
          NamedRouteDef(
            name: 'SetupFixtureRoute',
            path: '/',
            builder: (_, __) => const Scaffold(),
          ),
          if (tv)
            AutoRoute(page: TvAddServerRoute.page)
          else
            AutoRoute(page: AddServerRoute.page),
        ]);
        addTearDown(router.dispose);

        await tester.pumpWidget(MaterialApp.router(
          routerConfig: router.config(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ));
        await tester.pumpAndSettle();
        Server? addedServer;
        Set<String>? mediaDecision;
        unawaited(router
            .push<ValidatedSetupAccount>(
                tv ? const TvAddServerRoute() : const AddServerRoute())
            .then((result) {
          addedServer = result?.server;
          mediaDecision = result?.mediaCompanionDecision;
        }));
        await tester.pumpAndSettle();
        final url = tv
            ? tester
                .widget<TvTextField>(find.byType(TvTextField).first)
                .controller
            : tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!;
        url.text = 'https://test.example';
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);

        final submit = find.text('Test and add server');
        Future<void> settle() async {
          for (var attempt = 0; attempt < 8; attempt++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        Future<void> submitForm() async {
          await tester.ensureVisible(submit);
          await tester.runAsync(() async {
            await tester.tap(submit);
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pump();
        }

        await submitForm();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('YouTube channel filters'), findsOneWidget);
        expect(find.text('Hide matches'), findsOneWidget);
        expect(find.text('Label matches'), findsOneWidget);
        expect(find.text('Flow AI music list'), findsNothing);
        expect(validator.checked, isEmpty);

        if (tv) {
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(find.text('Cancel'));
          await settle();
          expect(communityFilters.needsYoutubeSetup, isTrue);
          expect(validator.checked, isEmpty);
          await submitForm();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('AiSList block list'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Off'));
        }
        await tester.pumpAndSettle();
        expect(find.text('Off'), findsOneWidget);

        await tester.runAsync(() async {
          await tester.tap(find.text('Continue'));
          await Future<void>.delayed(Duration.zero);
        });
        await settle();
        expect(validator.checked.single.url, 'https://test.example');
        expect(communityFilters.needsYoutubeSetup, isTrue);
        expect(addedServer, isNull);

        if (leaveDuringValidation) {
          final form = tester.element(find.byType(AddServerScreen));
          final route = ModalRoute.of(form)!;
          router.pop();
          expect(route.isCurrent, isFalse);
          expect(form.mounted, isTrue);
          validator.response.complete();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await settle();
          expect(communityFilters.needsYoutubeSetup, isTrue);
          expect(addedServer, isNull);
          expect(tester.takeException(), isNull);
          return;
        }

        validator.response.complete();
        await settle();
        if (mediaHost) {
          expect(find.text('Allow a separate playback host?'), findsOneWidget);
          expect(find.text(origin), findsOneWidget);
          expect(find.textContaining('https://test.example'), findsWidgets);
          expect(find.textContaining('the IP address you connect from'),
              findsOneWidget);
          expect(
              find.textContaining(
                  'Your account credentials stay on https://test.example.'),
              findsOneWidget);
          expect(find.textContaining('check=signed'), findsNothing);
          expect(addedServer, isNull);
          if (tv) {
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
          } else {
            await tester.tap(find.text('Allow $origin'));
          }
          await settle();
        }
        expect(addedServer?.mediaCompanionOrigins,
            mediaHost && !tv ? [origin] : isEmpty);
        expect(mediaDecision, mediaHost ? (tv ? isEmpty : {origin}) : isNull);
        expect(communityFilters.needsYoutubeSetup, isFalse);
        expect(addedServer?.url, 'https://test.example');
        expect(communityFilters.action(CommunityRule.youtubeBlock),
            CommunityAction.off);
        expect(communityFilters.action(CommunityRule.youtubeWarn),
            CommunityAction.label);
        expect(
            communityFilters.action(CommunityRule.music), CommunityAction.off);
        expect(tester.takeException(), isNull);
      });
    }

    for (final (scheme, legacyHeader) in [
      ('http', false),
      ('http', true),
      ('https', false),
      ('https', true),
    ]) {
      test(
          '$scheme onion without SOCKS rejects before credentials or requests '
          '(legacyHeader=$legacyHeader)', () async {
        await NetworkProxy.instance
            .initialize(saved: '{}', configureNative: false);
        const access = MethodChannel('videre/nerdvpn_access');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(access, (call) async {
          calls.add(call.method);
          return {'state': 'ready'};
        });
        addTearDown(() => messenger.setMockMethodCallHandler(access, null));
        final validator = _ValidationService()..response.complete();
        service = validator;
        cubit.urlController.text = '$scheme://$nerdVpnOnionHost';
        const key = 'nvpn_0123456789abcdefghijklmnopqrstuv';
        if (legacyHeader) {
          await cubit.addHeader(nerdVpnKeyHeader, key);
        } else {
          cubit.apiKeyController.text = key;
        }

        await expectLater(
            cubit.validateServer(),
            throwsA(isA<NerdVpnAccessRequired>()
                .having((error) => error.state, 'state', 'proxyRequired')));

        expect(calls, isEmpty);
        expect(validator.checked, isEmpty);
        expect(await db.getServers(), isEmpty);
        expect(cubit.state.loading, isFalse);
      });
    }

    test('advanced validation accepts usable relative thumbnails', () async {
      service = _ValidationService(thumbnails: [
        ImageObject('maxres', 'file:///cache/default.jpg', 800, 450),
        ImageObject('default', '/vi/test-id/default.jpg', 120, 90),
        ImageObject(
            'medium', '//i.ytimg.com/vi/test-id/mqdefault.jpg', 320, 180),
      ])
        ..response.complete();
      cubit.urlController.text = 'https://inv.example/invidious';
      cubit.setAdvancedTest(true);

      final server = await cubit.validateServer();

      expect(server?.url, 'https://inv.example/invidious');
      expect(cubit.state.loading, isFalse);
    });

    test('advanced validation rejects unusable thumbnail URLs', () async {
      service = _ValidationService(thumbnails: [
        ImageObject('default', 'file:///cache/default.jpg', 120, 90),
      ])
        ..response.complete();
      cubit.urlController.text = 'https://inv.example';
      cubit.setAdvancedTest(true);

      await expectLater(
          cubit.validateServer(), throwsA(isA<WrongThumbnailUrl>()));
      expect(cubit.state.loading, isFalse);
    });

    test(
        'advanced validation permits artwork intentionally omitted for privacy',
        () async {
      final validator = _ValidationService(thumbnails: [
        ImageObject('maxres',
            'https://i.ytimg.com/an_webp/video/mqdefault_6s.webp', 800, 450),
        ImageObject('default', 'https://yt4.ggpht.com/avatar', 120, 90),
      ])
        ..response.complete();
      service = validator;
      cubit.urlController.text = 'https://inv.example';
      cubit.setAdvancedTest(true);

      final server = await cubit.validateServer();

      expect(server?.url, 'https://inv.example');
      expect(validator.checked.map((request) => request.url),
          ['https://inv.example', 'https://inv.example']);
      expect(cubit.state.loading, isFalse);
    });

    test('omitted artwork does not mask remaining malformed thumbnail URLs',
        () async {
      service = _ValidationService(thumbnails: [
        ImageObject('maxres', 'https://yt4.ggpht.com/avatar', 800, 450),
        ImageObject('default', 'file:///cache/default.jpg', 120, 90),
      ])
        ..response.complete();
      cubit.urlController.text = 'https://inv.example';
      cubit.setAdvancedTest(true);

      await expectLater(
          cubit.validateServer(), throwsA(isA<WrongThumbnailUrl>()));
      expect(cubit.state.loading, isFalse);
    });

    test(
        'another account on the same server has a distinct ID and no old login',
        () async {
      const saved =
          Server(url: 'https://inv.example', authToken: 'saved-account');
      await db.upsertServer(saved);
      final before = db.getServer(saved.url);
      service = Service(httpClient: MockClient((request) async {
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response('{"software":{"name":"invidious"}}', 200);
      }));
      cubit.urlController.text = 'inv.example/';
      cubit.nameController.text = 'Other account';

      final added = await cubit.validateServer(
        prepareFirstInstance: () async => fail('Profile already has a server'),
      );
      expect(added!.accountId, isNot(saved.accountId));
      expect(added.name, 'Other account');
      expect(added.authToken, isNull);
      expect(added.sidCookie, isNull);
      await db.upsertServer(added);
      expect((await db.getServers()).length, 2);
      expect(db.getServer(saved.url), before);
      expect(cubit.state.loading, isFalse);
    });

    test('manual addresses omitted from suggestions can still use credentials',
        () async {
      service = Service(httpClient: MockClient((request) async {
        expect(request.url.toString(), 'https://private.example/api/v1/stats');
        expect(request.headers['Authorization'], 'Basic own-server');
        return http.Response('{"software":{"name":"invidious"}}', 200);
      }));
      cubit.urlController.text = 'private.example/';
      cubit.addHeader('Authorization', 'Basic own-server');

      final server = await cubit.validateServer();
      expect(server?.url, 'https://private.example');
      expect(server?.authToken, isNull);
      expect(server?.customHeaders['Authorization'], 'Basic own-server');
      expect(cubit.state.loading, isFalse);
      expect(await db.getServers(), isEmpty);
    });

    test('a failed connection leaves no server or AiSList choices', () async {
      service = Service(
          httpClient:
              MockClient((_) async => http.Response('Unavailable', 503)));
      cubit.urlController.text = 'inv.example';

      var saved = false;
      await expectLater(cubit.validateServer(prepareFirstInstance: () async {
        return () async => saved = true;
      }), throwsA(anything));
      expect(saved, isFalse);
      expect(cubit.state.loading, isFalse);
      expect(await db.getServers(), isEmpty);
    });

    test('leaving during a connection test does not emit to a closed cubit',
        () async {
      final response = Completer<http.Response>();
      service = Service(httpClient: MockClient((_) => response.future));
      cubit.urlController.text = 'inv.example';
      final pending = cubit.validateServer();
      await cubit.close();
      response
          .complete(http.Response('{"software":{"name":"invidious"}}', 200));
      expect((await pending)?.url, 'https://inv.example');
    });

    test('public selection clears private headers without contacting or saving',
        () async {
      service = Service(httpClient: MockClient((_) async {
        fail('Selecting an instance must not contact it');
      }));
      cubit.urlController.text = 'https://invidious.nerdvpn.de';
      cubit.apiKeyController.text = 'draft-api-key';
      cubit.addHeader('Authorization', 'Basic private');
      cubit.addHeader('X-Private', 'secret');
      cubit.selectPublicInstance('https://yt.chocolatemoo53.com');
      expect(cubit.urlController.text, 'https://yt.chocolatemoo53.com');
      expect(cubit.usesNerdVpn, isFalse);
      expect(cubit.apiKeyController.text, isEmpty);
      expect(cubit.state.headers, isEmpty);
      expect(cubit.state.advancedTest, isTrue);
      cubit.setAdvancedTest(false);
      expect(cubit.state.advancedTest, isTrue);
      expect(await db.getServers(), isEmpty);

      cubit.urlController.text = 'https://custom.example';
      expect(cubit.state.publicInstance, isNull);
      cubit.setAdvancedTest(false);
      expect(cubit.state.advancedTest, isFalse);
    });

    test('public choice cannot overwrite an already saved account', () async {
      const saved =
          Server(url: 'https://public.example', authToken: 'saved-account');
      await db.upsertServer(saved);
      final before = db.getServer(saved.url);
      final validator = _ValidationService();
      validator.response.complete();
      service = validator;
      cubit.selectPublicInstance(saved.url);
      final added = await cubit.validateServer();
      expect(added!.accountId, isNot(saved.accountId));
      expect(added.authToken, isNull);
      expect(db.getServer(saved.url), before);
    });

    test('validation uses one snapshot and public choices check the video API',
        () async {
      final validator = _ValidationService();
      service = validator;
      cubit.selectPublicInstance('https://public.example');
      final pending = cubit.validateServer();
      expect(await cubit.validateServer(), isNull);
      cubit.selectPublicInstance('https://different.example');
      cubit.addHeader('Authorization', 'Basic private');
      cubit.setAdvancedTest(false);
      // Even a controller edit outside the UI cannot retarget an active check.
      cubit.urlController.text = 'https://custom.example';
      validator.response.complete();

      final server = await pending;
      expect(server!.url, 'https://public.example');
      expect(server.id, isNotNull);
      expect(server.profileId, 'default');
      expect(validator.checked.length, 2);
      expect(validator.checked.first.url, server.url);
      expect(validator.checked.first.customHeaders,
          server.headersForUrl(server.url));
      expect(validator.checked.last, server);
      expect(await db.getServers(), isEmpty);
    });

    test('server validation remains owned by the profile that opened the form',
        () async {
      final validator = _ValidationService();
      service = validator;
      cubit.urlController.text = 'https://profile.example';
      final pending = cubit.validateServer();
      final other = await db.createProfile('Other');
      await db.useProfile(other.id);
      validator.response.complete();
      final server = await pending;
      expect(server!.profileId, 'default');
      expect(await db.getServers(), isEmpty);
    });

    test('protected onboarding signs in before testing and returns its account',
        () async {
      final protected = _ProtectedValidationService();
      service = protected;
      cubit.urlController.text = 'https://protected.example';
      cubit.setProtectedServer(true);
      final account = await cubit.validateServer();
      expect(account!.accountId, protected.signedIn!.accountId);
      expect(account.profileId, 'default');
      expect(account.authToken, 'protected-token');
      expect(protected.validations, 1);
      expect(protected.signedOut, isNull);
      expect(await db.getServers(), isEmpty);
    });

    test('cancelled protected onboarding neither validates nor saves',
        () async {
      final protected = _ProtectedValidationService(cancel: true);
      service = protected;
      cubit.urlController.text = 'https://protected.example';
      cubit.setProtectedServer(true);
      var saved = false;
      expect(
          await cubit.validateServer(prepareFirstInstance: () async {
            return () async => saved = true;
          }),
          isNull);
      expect(saved, isFalse);
      expect(protected.validations, 0);
      expect(cubit.state.loading, isFalse);
      expect(await db.getServers(), isEmpty);
    });

    test('failed protected onboarding revokes its unsaved session', () async {
      final protected = _ProtectedValidationService(failValidation: true);
      service = protected;
      cubit.urlController.text = 'https://protected.example';
      cubit.setProtectedServer(true);
      await expectLater(cubit.validateServer(), throwsStateError);
      expect(protected.signedOut!.accountId, protected.signedIn!.accountId);
      expect(await db.getServers(), isEmpty);
    });

    test('approval-pending NerdVPN can complete first-instance choices',
        () async {
      final protected = _ProtectedValidationService();
      service = protected;
      cubit.urlController.text = 'https://invidious.nerdvpn.de';
      const access = MethodChannel('videre/nerdvpn_access');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(access, (call) async {
        expect(call.method, 'status');
        return {'state': 'waiting'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(access, null));
      var saves = 0;

      final account = await cubit.validateServer(
        prepareFirstInstance: () async => () async {
          expect(protected.signedIn, isNotNull);
          saves++;
          return true;
        },
      );

      expect(account?.accountId, protected.signedIn?.accountId);
      expect(saves, 1);
      expect(protected.validations, 0);
      expect(protected.signedOut, isNull);
    });

    test('failed setup preference write discards the new protected session',
        () async {
      final protected = _ProtectedValidationService();
      service = protected;
      cubit.urlController.text = 'https://protected.example';
      cubit.setProtectedServer(true);

      await expectLater(
        cubit.validateServer(
          prepareFirstInstance: () async => () async {
            expect(protected.validations, 1);
            throw StateError('Settings write failed');
          },
        ),
        throwsStateError,
      );

      expect(protected.signedOut?.accountId, protected.signedIn?.accountId);
      expect(cubit.state.loading, isFalse);
      expect(await db.getServers(), isEmpty);
    });

    group('media companion setup', () {
      const instance = 'https://setup.example';
      const media = 'https://stream.example';
      const audio = 'https://audio.example';
      const sample = 'dQw4w9WgXcQ';
      final requests = <Uri>[];

      setUp(() {
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(
            () => debugDefaultTargetPlatformOverride = previousPlatform);
        requests.clear();
        service = Service(httpClient: MockClient((request) async {
          requests.add(request.url);
          if (request.url.origin != instance) return http.Response('', 404);
          final Map<String, Object> data;
          switch (request.url.path) {
            case '/api/v1/stats':
              data = {
                'software': {'name': 'invidious'}
              };
            case '/api/v1/videos/$sample':
              data = {
                'videoId': sample,
                'dashUrl': '$media/manifest.mpd?signed=private',
                'adaptiveFormats': [
                  {
                    'url': '$audio/videoplayback?itag=140&token=private',
                    'type': 'audio/mp4; codecs="mp4a.40.2"',
                    'itag': '140',
                    'clen': '300000',
                    'lmt': '1',
                    'projectionType': 'RECTANGULAR',
                  },
                ],
              };
            default:
              return http.Response('', 404);
          }
          return http.Response(jsonEncode(data), 200,
              headers: {'content-type': 'application/json'});
        }));
        cubit.urlController.text = instance;
        cubit.setAdvancedTest(true);
      });

      for (final decision in ['allow selected', 'skip', 'cancel']) {
        test('$decision preserves only the approved setup choices', () async {
          final events = <String>[];
          final candidate = await cubit.validateServer(
            prepareFirstInstance: () async {
              events.add('prepare');
              return () async {
                events.add('save');
                return true;
              };
            },
            chooseMediaCompanions: (account, offered) async {
              events.add('choose');
              expect(account.url, instance);
              expect(account.mediaCompanionOrigins, isEmpty);
              expect(offered, {media, audio});
              expect(() => offered.add('https://unobserved.example'),
                  throwsUnsupportedError);
              return switch (decision) {
                'allow selected' => {media, 'https://unobserved.example'},
                'skip' => <String>{},
                _ => null,
              };
            },
          );
          if (decision == 'cancel') {
            expect(candidate, isNull);
            expect(events, ['prepare', 'choose']);
          } else {
            expect(candidate?.url, instance);
            expect(candidate?.mediaCompanionOrigins,
                decision == 'skip' ? isEmpty : [media]);
            expect(events, ['prepare', 'choose', 'save']);
          }
          expect(requests.map((uri) => uri.path),
              ['/api/v1/stats', '/api/v1/videos/$sample']);
          expect(await db.getServers(), isEmpty);
          expect(cubit.state.loading, isFalse);
        });
      }

      for (final change in ['url', 'profile', 'route']) {
        test('a $change change while choosing discards approval', () async {
          final asked = Completer<void>();
          final answer = Completer<Set<String>?>();
          var current = true;
          var preferenceSaves = 0;
          final pending = cubit.validateServer(
            isRouteCurrent: () => current,
            prepareFirstInstance: () async => () async {
              preferenceSaves++;
              return true;
            },
            chooseMediaCompanions: (_, origins) {
              expect(origins, contains(media));
              asked.complete();
              return answer.future;
            },
          );
          await asked.future.timeout(const Duration(seconds: 2));
          switch (change) {
            case 'url':
              cubit.urlController.text = 'https://new.example';
            case 'profile':
              final other = await db.createProfile('Other');
              await db.useProfile(other.id);
            case 'route':
              current = false;
          }
          answer.complete({media});
          expect(await pending, isNull);
          expect(preferenceSaves, 0);
          expect(await db.forProfile('default').getServers(), isEmpty);
          expect(await db.getServers(), isEmpty);
          expect(cubit.state.loading, isFalse);
        });
      }

      test('the basic test makes no video or companion request', () async {
        cubit.setAdvancedTest(false);
        final candidate = await cubit.validateServer(
          chooseMediaCompanions: (_, __) async =>
              fail('Basic setup offered companion access'),
        );
        expect(candidate?.url, instance);
        expect(candidate?.mediaCompanionOrigins, isEmpty);
        expect(requests, [Uri.parse('$instance/api/v1/stats')]);
      });
    });
  });
}
