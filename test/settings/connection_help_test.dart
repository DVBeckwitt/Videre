import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
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
  const server = Server(
      url: 'https://instance.example/invidious',
      customHeaders: {'Authorization': 'Basic private'},
      authToken: 'private-token');
  late _Launcher launcher;
  late UrlLauncherPlatform originalLauncher;

  setUp(() async {
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

  testWidgets('test and browser retain the failed video and instance',
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
        'https://instance.example/invidious/api/v1/videos/failed-video');
    expect(requests.every((request) => request.url.host == 'instance.example'),
        isTrue);
    expect(requests.last.headers['Authorization'], 'Basic private');
    expect(find.textContaining('video API responded'), findsOneWidget);

    await tester.tap(find.text('Open in browser'));
    await tester.pumpAndSettle();
    final opened = launcher.calls.single;
    expect(
        opened.url, 'https://instance.example/invidious/watch?v=failed-video');
    expect(opened.options.mode, PreferredLaunchMode.externalApplication);
    expect(opened.options.webViewConfiguration.headers, isEmpty);
    expect(opened.url, isNot(contains('private')));
  });

  for (final tv in [false, true]) {
    testWidgets(
        '${tv ? 'TV' : 'missing browser'} shows a copyable safe address',
        (tester) async {
      app.isTv = tv;
      launcher.succeeds = false;
      await pumpHelp(tester, videoId: 'failed-video');
      await tester.tap(find.text('Open in browser'));
      await tester.pumpAndSettle();
      expect(
          find.widgetWithText(SelectableText,
              'https://instance.example/invidious/watch?v=failed-video'),
          findsOneWidget);
      expect(launcher.calls, hasLength(tv ? 0 : 1));
      expect(tester.takeException(), isNull);
    });
  }

  test('browser links preserve prefixes and reject embedded credentials', () {
    expect(AddServerScreen.instanceBrowserUrl(server)?.toString(), server.url);
    expect(
        AddServerScreen.instanceBrowserUrl(server, videoId: 'a&b')
            ?.queryParameters,
        {'v': 'a&b'});
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
      expect(find.text('Open in browser'), findsOneWidget);
    });
  }
}
