import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/services/gateway_auth.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _Launcher extends UrlLauncherPlatform {
  final calls = <({String url, LaunchOptions options})>[];
  bool succeeds = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    calls.add((url: url, options: options));
    return succeeds;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const torChannel = MethodChannel('videre/tor_browser');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final torCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  const server = Server(
      url: 'https://instance.example/invidious',
      customHeaders: {'Authorization': 'Basic private'},
      authToken: 'private-token');
  late _Launcher launcher;
  late UrlLauncherPlatform originalLauncher;

  setUp(() async {
    torCalls.clear();
    platformCalls.clear();
    messenger.setMockMethodCallHandler(torChannel, (call) async {
      torCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    app.isTv = false;
    db = await SembastSqfDb.createInMemory();
    await db.useServer(server);
    originalLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher = _Launcher();
  });
  tearDown(() async {
    app.isTv = false;
    service = Service();
    UrlLauncherPlatform.instance = originalLauncher;
    messenger.setMockMethodCallHandler(torChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    await db.close();
  });

  Future<void> pumpHelp(WidgetTester tester, {String? videoId}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
            onPressed: () =>
                AddServerScreen.showConnectionHelp(context, videoId: videoId),
            child: const Text('Help'));
      })),
    ));
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
  }

  Future<void> pumpError(WidgetTester tester, Object error) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
            onPressed: () => AddServerScreen.handleError(context, error),
            child: const Text('Show error'));
      })),
    ));
    await tester.tap(find.text('Show error'));
    await tester.pumpAndSettle();
  }

  for (final error in [
    const GatewaySignInFailed(
        'Enable SOCKS5/Orbot in Network proxy to use this onion server.'),
    const NerdVpnAccessRequired('proxyRequired'),
  ]) {
    testWidgets('${error.runtimeType} explains missing onion proxy only once',
        (tester) async {
      await pumpError(tester, error);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(error.toString()), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('connection error retains a distinct upstream detail',
      (tester) async {
    final error =
        InvidiousServiceError('fixture upstream rejection', statusCode: 403);
    await pumpError(tester, error);
    final locals =
        AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    expect(find.text(locals.instanceForbiddenHelp), findsOneWidget);
    expect(find.text(error.toString()), findsOneWidget);
  });

  testWidgets('pending API approval is explained without connection advice',
      (tester) async {
    await pumpError(tester, const NerdVpnAccessRequired('waiting'));
    expect(find.text('NerdVPN approval pending'), findsOneWidget);
    expect(find.textContaining('not approved API access'), findsOneWidget);
    expect(find.textContaining('Check eligibility'), findsOneWidget);
    final locals =
        AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    expect(find.text(locals.instanceConnectionHelp), findsNothing);
    expect(find.text(locals.error), findsNothing);
  });

  testWidgets('a connection failure is not presented as pending approval',
      (tester) async {
    await pumpError(tester, http.ClientException('Connection closed'));
    expect(find.text('NerdVPN approval pending'), findsNothing);
    expect(find.textContaining('not approved API access'), findsNothing);
    expect(find.text('Error'), findsOneWidget);
  });

  testWidgets('stats success does not hide a blocked video API',
      (tester) async {
    final requests = <Uri>[];
    service = Service(httpClient: MockClient((request) async {
      requests.add(request.url);
      return request.url.path.endsWith('/stats')
          ? http.Response('{"software":{"name":"invidious"}}', 200)
          : http.Response('{"error":"API disabled"}', 403);
    }));
    await pumpHelp(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(requests.map((url) => url.path), [
      '/invidious/api/v1/stats',
      '/invidious/api/v1/videos/dQw4w9WgXcQ',
    ]);
    expect(find.textContaining('denied API access'), findsOneWidget);
    expect(find.textContaining('video API responded'), findsNothing);
  });

  testWidgets('test and copied address retain the failed video and instance',
      (tester) async {
    final requests = <http.Request>[];
    service = Service(httpClient: MockClient((request) async {
      requests.add(request);
      return request.url.path.endsWith('/stats')
          ? http.Response('{"software":{"name":"invidious"}}', 200)
          : http.Response('{"videoId":"failed-video"}', 200);
    }));
    await pumpHelp(tester, videoId: 'failed-video');
    expect(requests, isEmpty);
    expect(launcher.calls, isEmpty);
    await tester.runAsync(
        () => db.useServer(const Server(url: 'https://other.example')));
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(requests.last.url.toString(),
        'https://instance.example/invidious/api/v1/videos/failed-video?local=true');
    expect(requests.every((request) => request.url.host == 'instance.example'),
        isTrue);
    expect(requests.last.headers['Authorization'], 'Basic private');
    expect(find.textContaining('video API responded'), findsOneWidget);

    await tester.tap(find.text('External link'));
    await tester.pumpAndSettle();
    const address =
        'https://instance.example/invidious/watch?v=failed-video&local=true';
    expect(find.widgetWithText(SelectableText, address), findsOneWidget);
    expect(launcher.calls, isEmpty);
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();
    final copied = platformCalls
        .where((call) => call.method == 'Clipboard.setData')
        .single;
    expect(copied.arguments, {'text': address});
    expect(copied.arguments.toString(), isNot(contains('private')));
    expect(torCalls, isEmpty);
  });

  testWidgets(
      'generic onion links show the complete watch URL without launching',
      (tester) async {
    await tester.runAsync(() => db.useServer(const Server(
        url: 'http://other.onion/invidious',
        customHeaders: {'Authorization': 'Basic private'},
        authToken: 'private-token')));
    await pumpHelp(tester, videoId: 'failed-video');
    expect(torCalls, isEmpty);
    await tester.tap(find.text('External link'));
    await tester.pumpAndSettle();
    expect(torCalls, isEmpty);
    expect(
        find.widgetWithText(SelectableText,
            'http://other.onion/invidious/watch?v=failed-video&local=true'),
        findsOneWidget);
    expect(launcher.calls, isEmpty);
    expect(
        platformCalls.where((call) => const {
              'Clipboard.getData',
              'Clipboard.setData'
            }.contains(call.method)),
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final failure in ['unavailable', 'rejected', 'missing']) {
    testWidgets('onion address copying does not depend on browser $failure',
        (tester) async {
      await tester.runAsync(() =>
          db.useServer(const Server(url: 'http://other.onion/invidious')));
      messenger.setMockMethodCallHandler(torChannel, (call) async {
        torCalls.add(call);
        if (failure == 'rejected') {
          throw PlatformException(code: 'UNAVAILABLE');
        }
        if (failure == 'missing') throw MissingPluginException();
        return false;
      });
      await pumpHelp(tester, videoId: 'failed-video');
      await tester.tap(find.text('External link'));
      await tester.pumpAndSettle();
      expect(torCalls, isEmpty);
      expect(launcher.calls, isEmpty);
      expect(
          find.widgetWithText(SelectableText,
              'http://other.onion/invidious/watch?v=failed-video&local=true'),
          findsOneWidget);
      final copy = find.widgetWithText(TextButton, 'Copy to clipboard');
      expect(copy, findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Open Tor Browser'), findsNothing);
      // SelectableText checks Clipboard.hasStrings for its editing toolbar;
      // showing guidance must not read or overwrite clipboard content.
      expect(
          platformCalls.where((call) => const {
                'Clipboard.getData',
                'Clipboard.setData'
              }.contains(call.method)),
          isEmpty);

      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(torCalls, isEmpty);
      expect(launcher.calls, isEmpty);
      expect(
          platformCalls
              .where((call) => call.method == 'Clipboard.setData')
              .single
              .arguments,
          {
            'text':
                'http://other.onion/invidious/watch?v=failed-video&local=true'
          });
      expect(platformCalls.where((call) => call.method == 'Clipboard.getData'),
          isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final tv in [false, true]) {
    testWidgets(
        '${tv ? 'TV' : 'phone'} shows a copyable safe address without launching',
        (tester) async {
      app.isTv = tv;
      launcher.succeeds = false;
      await pumpHelp(tester, videoId: 'failed-video');
      await tester.tap(find.text('External link'));
      await tester.pumpAndSettle();
      expect(
          find.widgetWithText(SelectableText,
              'https://instance.example/invidious/watch?v=failed-video&local=true'),
          findsOneWidget);
      expect(launcher.calls, isEmpty);
      expect(torCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  test('browser links preserve prefixes and reject embedded credentials', () {
    expect(AddServerScreen.instanceBrowserUrl(server)?.toString(), server.url);
    expect(
        AddServerScreen.instanceBrowserUrl(server, videoId: 'a&b')
            ?.queryParameters,
        {'v': 'a&b', 'local': 'true'});
    for (final address in [
      'https://user:secret@instance.example',
      'https://instance.example/?token=secret',
      'javascript:alert(1)'
    ]) {
      expect(AddServerScreen.instanceBrowserUrl(Server(url: address)), isNull);
    }
  });

  testWidgets('closing during a test skips further requests and UI updates',
      (tester) async {
    final response = Completer<http.Response>();
    var requests = 0;
    service = Service(httpClient: MockClient((_) {
      requests++;
      return response.future;
    }));
    await pumpHelp(tester, videoId: 'failed-video');
    await tester.tap(find.text('Test connection'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    response.complete(http.Response('{"software":{"name":"invidious"}}', 200));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
      'connection advice distinguishes rate limits, access and invalid responses',
      () {
    final locals = lookupAppLocalizations(const Locale('en'));
    expect(
        AddServerScreen.connectionAdvice(
            InvidiousServiceError('limited',
                statusCode: 429, retryAfter: const Duration(seconds: 30)),
            locals),
        contains('30 seconds'));
    expect(
        AddServerScreen.connectionAdvice(
            InvidiousServiceError('limited', statusCode: 429), locals),
        locals.instanceRateLimitedHelp);
    expect(
        AddServerScreen.connectionAdvice(
            InvidiousServiceError('private',
                statusCode: 401, responseWasHtml: true),
            locals),
        locals.instanceUnauthorizedHelp);
    expect(
        AddServerScreen.connectionAdvice(
            InvidiousServiceError('denied', statusCode: 403), locals),
        locals.instanceForbiddenHelp);
    expect(
        AddServerScreen.connectionAdvice(
            InvidiousServiceError('challenge',
                statusCode: 403, responseWasHtml: true),
            locals),
        locals.instanceBrowserChallengeHelp);
    expect(
        AddServerScreen.connectionAdvice(
            InvidiousServiceError('invalid JSON', statusCode: 200), locals),
        locals.instanceInvalidResponseHelp);
  });

  for (final body in ['', 'not-json', '[]']) {
    testWidgets('invalid video response "$body" offers retry', (tester) async {
      service = Service(
          httpClient: MockClient((request) async =>
              request.url.path.endsWith('/stats')
                  ? http.Response('{"software":{"name":"invidious"}}', 200)
                  : http.Response(body, 200)));
      await pumpHelp(tester, videoId: 'failed-video');
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('empty or invalid video data'), findsOneWidget);
      for (final label in ['Choose instance', 'Test connection']) {
        expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, label))
                .onPressed,
            isNotNull);
      }
      expect(find.text('External link'), findsOneWidget);
    });
  }

  for (final status in [401, 500, 530]) {
    testWidgets('HTTP $status offers recovery without automatic retry loops',
        (tester) async {
      var requests = 0;
      service = Service(httpClient: MockClient((request) async {
        requests++;
        return request.url.path.endsWith('/stats')
            ? http.Response('{"software":{"name":"invidious"}}', 200)
            : http.Response('Instance unavailable', status);
      }));
      await pumpHelp(tester, videoId: 'failed-video');
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      for (final label in ['Choose instance', 'Test connection']) {
        expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, label))
                .onPressed,
            isNotNull);
      }
      expect(find.text('External link'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
