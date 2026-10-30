import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

class _LinkApp extends AppCubit {
  _LinkApp() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}
}

class _RecordingRouter extends AppRouter {
  _RecordingRouter() : super(hasServer: true);

  PageRouteInfo? pushed;
  bool fail = false;

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) async {
    if (fail) throw StateError('navigation failed');
    pushed = route;
    return null;
  }
}

Future<void> _waitForRoute(String name, {StackRouter? router}) async {
  final active = router ?? appRouter;
  for (var attempt = 0; attempt < 100; attempt++) {
    if (active.current.name == name) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Expected $name, got ${active.current.name}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _LinkApp app;
  late bool originalTv;

  setUp(() async {
    originalTv = app_globals.isTv;
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(
        const Server(url: 'https://instance.example', inUse: true));
    app_globals.isTv = true;
    appRouter = AppRouter(hasServer: true);
    app = _LinkApp();
  });

  tearDown(() async {
    appRouter.dispose();
    await app.close();
    await db.close();
    app_globals.isTv = originalTv;
  });

  for (final link in [
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    'https://youtu.be/dQw4w9WgXcQ',
  ]) {
    test('TV cold link builds a home and video stack: $link', () async {
      await app.openAppLink(link, true);

      expect(appRouter.stack.map((page) => page.name),
          [TvHomeRoute.name, TvVideoRoute.name]);
      expect(
          appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
    });
  }

  test('TV warm link preserves the existing home stack', () async {
    await appRouter.replaceAll([const TvHomeRoute()]);
    unawaited(app.openAppLink('https://youtu.be/dQw4w9WgXcQ', false));
    await _waitForRoute(TvVideoRoute.name);

    expect(appRouter.stack.map((page) => page.name),
        [TvHomeRoute.name, TvVideoRoute.name]);
    expect(appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
  });

  test('phone cold link retains the nested phone route stack', () async {
    appRouter.dispose();
    app_globals.isTv = false;
    appRouter = AppRouter(hasServer: true);
    await app.openAppLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ', true);

    expect(appRouter.stack.map((page) => page.name), [MainRoute.name]);
    final children = appRouter.current.pendingChildren;
    expect(children.map((route) => route.name),
        [MainContentRoute.name, VideoRoute.name]);
    expect((children.last.args as VideoRouteArgs).videoId, 'dQw4w9WgXcQ');
  });

  test('phone warm link pushes inside the existing MainRoute', () async {
    appRouter.dispose();
    app_globals.isTv = false;
    appRouter = AppRouter(hasServer: true);
    await appRouter.replaceAll([const MainRoute()]);
    final parent = appRouter.current;
    // Attach the controller that MainScreen's AutoRouter creates when mounted.
    final nested = NestedStackRouter(
      parent: appRouter,
      key: parent.key,
      matchId: parent.matchId,
      routeData: parent,
      routeCollection: appRouter.routeCollection.subCollectionOf(parent.name),
    );
    appRouter.attachChildController(nested);
    try {
      await nested.replaceAll([const MainContentRoute()]);
      unawaited(app.openAppLink('https://youtu.be/dQw4w9WgXcQ', false));
      await _waitForRoute(VideoRoute.name, router: nested);

      expect(appRouter.stack.map((page) => page.name), [MainRoute.name]);
      expect(nested.stack.map((page) => page.name),
          [MainContentRoute.name, VideoRoute.name]);
      expect(nested.current.argsAs<VideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
    } finally {
      appRouter.removeChildController(nested);
      nested.dispose();
    }
  });

  for (final tv in [true, false]) {
    test('a ${tv ? 'TV' : 'phone'} link without a server opens onboarding',
        () async {
      appRouter.dispose();
      await db.close();
      db = await SembastSqfDb.createInMemory();
      app_globals.isTv = tv;
      appRouter = AppRouter(hasServer: false);
      unawaited(app.openAppLink('https://youtu.be/dQw4w9WgXcQ', true));
      final welcome = tv ? TvWelcomeWizardRoute.name : WelcomeWizardRoute.name;
      await _waitForRoute(welcome);

      expect(appRouter.stack.map((page) => page.name), [welcome]);
    });
  }

  test('navigation failures are caught after asynchronous dispatch', () async {
    appRouter.dispose();
    appRouter = _RecordingRouter()..fail = true;
    await expectLater(
        app.openAppLink('https://youtu.be/dQw4w9WgXcQ', false), completes);
  });

  test('unsupported and empty links leave navigation unchanged', () async {
    await appRouter.replaceAll([const TvHomeRoute()]);
    for (final link in [
      'https://www.youtube.com/watch?v=',
      'https://example.com/watch?v=dQw4w9WgXcQ',
      'ftp://youtube.com/watch?v=dQw4w9WgXcQ',
      'videre-auth://callback?code=private',
      'not a URL',
    ]) {
      await app.openAppLink(link, true);
      expect(appRouter.stack.map((page) => page.name), [TvHomeRoute.name]);
    }
  });

  test('Android delegates links to the sharing plugin and keeps auth isolated',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final mainActivity =
        RegExp(r'<activity\s+android:name="\.MainActivity"[\s\S]*?</activity>')
            .firstMatch(manifest)!
            .group(0)!;
    expect(
        RegExp(r'android:name="flutter_deeplinking_enabled"\s+android:value="false"')
            .hasMatch(mainActivity),
        isTrue);
    final shortLinkFilter = RegExp(r'<intent-filter[\s\S]*?</intent-filter>')
        .allMatches(mainActivity)
        .map((match) => match.group(0)!)
        .singleWhere((filter) => filter.contains('android:host="youtu.be"'));
    expect(shortLinkFilter, contains('android.intent.action.VIEW'));
    expect(shortLinkFilter, isNot(contains('android:pathPrefix')));
    expect(mainActivity, isNot(contains('videre-auth')));
    expect(
        manifest, contains('com.linusu.flutter_web_auth_2.CallbackActivity'));
    expect(manifest, contains('android:scheme="videre-auth"'));
  });
}
