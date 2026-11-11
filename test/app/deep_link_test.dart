import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/models/timestamp_linkifier.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/text_linkified.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

class _LinkApp extends AppCubit {
  _LinkApp() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}

  void requireSessionRecovery() {
    emit(state.copyWith(sessionRecoveryRequired: true));
  }
}

class _LinkPlayer implements PlayerCubit {
  @override
  final PlayerState state;
  Duration? sought;

  _LinkPlayer(this.state);

  @override
  void seek(Duration duration) => sought = duration;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
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

void _expectMusicArgs(MusicRouteArgs args, String kind, String id) {
  expect(args.videoId, kind == 'song' ? id : isNull);
  expect(args.playlistId, kind == 'playlist' ? id : isNull);
  expect(args.artistId, kind == 'artist' ? id : isNull);
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

  for (final (kind, link, id) in [
    (
      'artist',
      'https://music.youtube.com/browse/UCuAXFkgsw1L7xaCfnd5JJOw',
      'UCuAXFkgsw1L7xaCfnd5JJOw'
    ),
    (
      'artist',
      'https://music.youtube.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg',
      'UC_kRDKYrUlrbtrSiyu5Tflg'
    ),
    (
      'song',
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVMdQw4w9WgXcQ',
      'dQw4w9WgXcQ'
    ),
    (
      'playlist',
      'https://music.youtube.com/playlist?list=OLAK5uy_music-collection',
      'OLAK5uy_music-collection'
    ),
  ]) {
    for (final tv in [true, false]) {
      final platform = tv ? 'TV' : 'phone/tablet';
      final linkKind = kind == 'artist'
          ? '$kind (${Uri.parse(link).pathSegments.first})'
          : kind;
      test('$platform cold music $linkKind link retains the home stack',
          () async {
        appRouter.dispose();
        app_globals.isTv = tv;
        appRouter = AppRouter(hasServer: true);
        await app.openAppLink(link, true);

        if (tv) {
          expect(appRouter.stack.map((page) => page.name),
              [TvHomeRoute.name, MusicRoute.name]);
          _expectMusicArgs(
              appRouter.current.argsAs<MusicRouteArgs>(), kind, id);
        } else {
          expect(appRouter.stack.map((page) => page.name), [MainRoute.name]);
          final children = appRouter.current.pendingChildren;
          expect(children.map((route) => route.name),
              [MainContentRoute.name, MusicRoute.name]);
          _expectMusicArgs(children.last.args as MusicRouteArgs, kind, id);
        }
      });

      test('$platform warm music $linkKind link preserves existing navigation',
          () async {
        appRouter.dispose();
        app_globals.isTv = tv;
        appRouter = AppRouter(hasServer: true);
        NestedStackRouter? nested;
        if (tv) {
          await appRouter.replaceAll([const TvHomeRoute()]);
        } else {
          await appRouter.replaceAll([const MainRoute()]);
          final parent = appRouter.current;
          nested = NestedStackRouter(
            parent: appRouter,
            key: parent.key,
            matchId: parent.matchId,
            routeData: parent,
            routeCollection:
                appRouter.routeCollection.subCollectionOf(parent.name),
          );
          appRouter.attachChildController(nested);
          await nested.replaceAll([const MainContentRoute()]);
        }
        try {
          final active = nested ?? appRouter;
          unawaited(app.openAppLink(link, false));
          await _waitForRoute(MusicRoute.name, router: active);

          expect(active.stack.map((page) => page.name),
              [tv ? TvHomeRoute.name : MainContentRoute.name, MusicRoute.name]);
          _expectMusicArgs(active.current.argsAs<MusicRouteArgs>(), kind, id);
        } finally {
          if (nested != null) {
            appRouter.removeChildController(nested);
            nested.dispose();
          }
        }
      });
    }
  }

  for (final tv in [true, false]) {
    for (final link in [
      'https://youtu.be/dQw4w9WgXcQ',
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
    ]) {
      test(
          'a ${tv ? 'TV' : 'phone'} link without a server opens onboarding: $link',
          () async {
        appRouter.dispose();
        await db.close();
        db = await SembastSqfDb.createInMemory();
        app_globals.isTv = tv;
        appRouter = AppRouter(hasServer: false);
        unawaited(app.openAppLink(link, true));
        final welcome =
            tv ? TvWelcomeWizardRoute.name : WelcomeWizardRoute.name;
        await _waitForRoute(welcome);

        expect(appRouter.stack.map((page) => page.name), [welcome]);
      });
    }
  }

  test('navigation failures are caught after asynchronous dispatch', () async {
    appRouter.dispose();
    appRouter = _RecordingRouter()..fail = true;
    await expectLater(
        app.openAppLink('https://youtu.be/dQw4w9WgXcQ', false), completes);
    await expectLater(
        app.openAppLink('https://music.youtube.com/watch?v=dQw4w9WgXcQ', false),
        completes);
  });

  test('unsupported and empty links leave navigation unchanged', () async {
    await appRouter.replaceAll([const TvHomeRoute()]);
    for (final link in [
      'https://www.youtube.com/watch?v=',
      'https://www.youtube.com/watch?v=..%2Flogin%3Ftoken%3Dprivate',
      'https://youtu.be/too-short',
      'https://music.youtube.com/watch?v=',
      'https://music.youtube.com/watch?v=too-short',
      'https://music.youtube.com/browse/UCartist',
      'https://music.youtube.com/channel/UCartist',
      'https://music.youtube.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg/extra',
      'https://music.youtube.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg%2Fprivate',
      'https://music.youtube.com/channel/MPREb_K8qWMWVqXGi',
      'https://music.youtube.com/browse/MPREb_K8qWMWVqXGi',
      'https://music.youtube.com.example.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg',
      'https://music.youtube.com/browse/MPREalbum%2Fprivate',
      'https://music.youtube.com/playlist?list=',
      'https://music.youtube.com/playlist?list=PL..%2Fprivate',
      'https://music.youtube.com/playlist?list=${'PL' * 101}',
      'ftp://music.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://music.youtube.com.example.com/watch?v=dQw4w9WgXcQ',
      'https://example.com/watch?v=dQw4w9WgXcQ',
      'ftp://youtube.com/watch?v=dQw4w9WgXcQ',
      'videre-auth://callback?code=private',
      'not a URL',
    ]) {
      await app.openAppLink(link, true);
      expect(appRouter.stack.map((page) => page.name), [TvHomeRoute.name]);
    }
  });

  test('music links respect profile switching and session recovery gates',
      () async {
    await appRouter.replaceAll([const TvHomeRoute()]);
    app.setGlobalLoading(true);
    await app.openAppLink(
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ', true);
    expect(appRouter.stack.map((page) => page.name), [TvHomeRoute.name]);

    app.setGlobalLoading(false);
    app.requireSessionRecovery();
    await app.openAppLink(
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ', true);
    expect(appRouter.stack.map((page) => page.name), [TvHomeRoute.name]);
  });

  testWidgets('description music links use Music and timestamps still seek',
      (tester) async {
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    final video = Video(videoId: 'dQw4w9WgXcQ', title: 'Song');
    final player = _LinkPlayer(PlayerState.init([video])
        .copyWith(isPlaying: true, currentlyPlaying: video));
    final linkified = TextLinkified(text: '', player: player, video: video);
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<AppCubit>.value(value: app, child: linkified),
    ));
    final context = tester.element(find.byType(TextLinkified));

    linkified.openLink(
        context,
        UrlElement(
            'https://music.youtube.com/playlist?list=PLsupported_music'));
    await tester.pump();
    expect(router.pushed?.routeName, MusicRoute.name);
    _expectMusicArgs(
        router.pushed!.args as MusicRouteArgs, 'playlist', 'PLsupported_music');

    linkified.openLink(context, TimestampElement('1:23'));
    expect(player.sought, const Duration(minutes: 1, seconds: 23));
  });

  test('shared link query data and malformed input stay out of logs', () async {
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    final previous = Logger.root.level;
    Logger.root.level = Level.FINE;
    addTearDown(() => Logger.root.level = previous);
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    await app.openAppLink(
        'https://youtu.be/dQw4w9WgXcQ?token=private-query-value', false);
    expect(router.pushed?.routeName, TvVideoRoute.name);
    await app.openAppLink('https://[private-invalid-value', false);
    await app.openAppLink(
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ&token=private-music-value',
        false);
    expect(router.pushed?.routeName, MusicRoute.name);
    final messages = records.map((e) => '${e.message} ${e.error}').join();
    expect(messages, isNot(contains('private-query-value')));
    expect(messages, isNot(contains('private-invalid-value')));
    expect(messages, isNot(contains('private-music-value')));
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
    final musicFilter = RegExp(r'<intent-filter[\s\S]*?</intent-filter>')
        .allMatches(mainActivity)
        .map((match) => match.group(0)!)
        .singleWhere(
            (filter) => filter.contains('android:host="music.youtube.com"'));
    expect(musicFilter, contains('android.intent.action.VIEW'));
    expect(musicFilter, contains('android:pathPrefix="/watch"'));
    expect(musicFilter, contains('android:pathPrefix="/browse/"'));
    expect(musicFilter, contains('android:pathPrefix="/channel/"'));
    expect(musicFilter, contains('android:pathPrefix="/playlist"'));
    expect(musicFilter, isNot(contains('android:host="youtube.com"')));
    expect(mainActivity, isNot(contains('videre-auth')));
    expect(
        manifest, contains('com.linusu.flutter_web_auth_2.CallbackActivity'));
    expect(manifest, contains('android:scheme="videre-auth"'));
  });
}
