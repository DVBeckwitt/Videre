import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/music/views/screens/music_discovery.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = MusicTrack(
    videoId: 'musicvideo1', title: 'Trending recording', artists: ['Channel']);

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  void change(AppState state) => emit(state);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Catalog extends MusicCatalogService {
  int trendingCalls = 0;
  Future<List<MusicTrack>> Function()? trending;

  @override
  Future<List<MusicTrack>> getTrendingSongs() {
    trendingCalls++;
    return trending?.call() ?? Future.value([_song]);
  }
}

class _Router extends AppRouter {
  PageRouteInfo? pushed;

  _Router() : super(hasServer: true);

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) async {
    pushed = route;
    return null;
  }
}

void main() {
  late MusicCatalogService previousCatalog;
  late _Catalog catalog;
  late _App app;
  late _Router router;
  late int searches;
  late int libraryVisits;

  setUp(() {
    previousCatalog = musicCatalogService;
    musicCatalogService = catalog = _Catalog();
    app = _App();
    router = _Router();
    searches = 0;
    libraryVisits = 0;
  });

  tearDown(() async {
    musicCatalogService = previousCatalog;
    await app.close();
    router.dispose();
  });

  Widget home() => MusicHomePage(
      onSearch: () => searches++, onLibrary: () => libraryVisits++);

  Future<void> show(WidgetTester tester,
      {Widget? child, double textScale = 1}) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: StackRouterScope(
          controller: router,
          stateHash: 0,
          child: Scaffold(body: child ?? home()),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('Home opens the selected instance music feed and song IDs',
      (tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Trending music'), findsOneWidget);
    expect(find.text('Trending recording'), findsOneWidget);
    for (final title in [
      'New releases',
      'Charts',
      'Moods & genres',
      'Albums'
    ]) {
      expect(find.text(title), findsNothing);
    }
    expect(
        find.textContaining('not available through Invidious'), findsNothing);
    expect(catalog.trendingCalls, 1);
    await tester.tap(find.text('Trending recording'));
    expect((router.pushed!.args as MusicRouteArgs).videoId, 'musicvideo1');
  });

  testWidgets('Search and Library remain usable while trending fails',
      (tester) async {
    final pending = Completer<List<MusicTrack>>();
    catalog.trending = () => pending.future;
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-home-search')));
    await tester.tap(find.byKey(const ValueKey('music-home-library')));
    expect(searches, 1);
    expect(libraryVisits, 1);
    pending.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load this section.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('music-home-search')));
    await tester.tap(find.byKey(const ValueKey('music-home-library')));
    expect(searches, 2);
    expect(libraryVisits, 2);
  });

  testWidgets('Home retries its feed without exposing upstream errors',
      (tester) async {
    catalog.trending = () async => throw StateError('private diagnostic');
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Could not load this section.'), findsOneWidget);
    expect(find.textContaining('private diagnostic'), findsNothing);
    catalog.trending = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Trending recording'), findsOneWidget);
    expect(find.text('Could not load this section.'), findsNothing);
    expect(catalog.trendingCalls, 2);
  });

  for (final transition in ['profile', 'server', 'revision']) {
    testWidgets('late feed responses are discarded after $transition changes',
        (tester) async {
      final old = Completer<List<MusicTrack>>();
      final fresh = Completer<List<MusicTrack>>();
      catalog.trending =
          () => catalog.trendingCalls == 1 ? old.future : fresh.future;
      await show(tester);
      app.change(switch (transition) {
        'profile' => app.state.copyWith(profileId: 'another-profile'),
        'server' => app.state
            .copyWith(server: const Server(url: 'https://other.example')),
        _ => app.state.copyWith(sessionRevision: 1),
      });
      await tester.pump();
      fresh.complete([
        const MusicTrack(videoId: 'freshvideo1', title: 'New session'),
      ]);
      await tester.pumpAndSettle();
      old.complete([_song]);
      await tester.pumpAndSettle();
      expect(find.text('New session'), findsOneWidget);
      expect(find.text('Trending recording'), findsNothing);
      expect(catalog.trendingCalls, 2);
    });
  }

  for (final blocked in ['loading', 'recovery']) {
    testWidgets('Home waits while the account is $blocked', (tester) async {
      app.change(blocked == 'loading'
          ? app.state.copyWith(globalLoading: true)
          : app.state.copyWith(sessionRecoveryRequired: true));
      await show(tester);
      expect(catalog.trendingCalls, 0);
      app.change(app.state
          .copyWith(globalLoading: false, sessionRecoveryRequired: false));
      await tester.pumpAndSettle();
      expect(catalog.trendingCalls, 1);
      expect(find.text('Trending recording'), findsOneWidget);
    });
  }

  testWidgets('a stale song action cannot open content for a new account',
      (tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    final card = tester.widget<MusicCatalogCard>(find.byType(MusicCatalogCard));
    app.change(app.state.copyWith(sessionRevision: 1));
    card.onOpen();
    expect(router.pushed, isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('empty trending leaves Search and Library available',
      (tester) async {
    catalog.trending = () async => [];
    await show(tester);
    await tester.pumpAndSettle();
    expect(
        find.text('No trending music is available from this server right now.'),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('music-home-search')));
    await tester.tap(find.byKey(const ValueKey('music-home-library')));
    expect(searches, 1);
    expect(libraryVisits, 1);
  });

  testWidgets('Home shows the full feed and retains scroll without refetch',
      (tester) async {
    catalog.trending = () async => List.generate(
        18, (index) => MusicTrack(videoId: 'song$index', title: 'Song $index'));
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Song 17'), findsOneWidget);
    final homeState = tester.state(find.byType(MusicHomePage));
    final scroll = tester
        .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('music-home')))
        .controller!;
    scroll.jumpTo(300);
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    await show(tester);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(MusicHomePage)), same(homeState));
    expect(scroll.offset, offset);
    expect(catalog.trendingCalls, 1);
  });

  testWidgets('focused songs activate using a keyboard remote', (tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('Trending recording'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((router.pushed!.args as MusicRouteArgs).videoId, 'musicvideo1');
  });

  testWidgets('late completion after leaving Home does not update its state',
      (tester) async {
    final pending = Completer<List<MusicTrack>>();
    catalog.trending = () => pending.future;
    await show(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete([_song]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home and its shortcuts fit 320px with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Trending recording'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
