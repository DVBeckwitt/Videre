import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/music/views/screens/music_discovery.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/community_filter_fixture.dart';

const _saved = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'savedmusic1',
    title: 'Saved recording',
    subtitle: 'Saved artist');

const _discovered = MusicTrack(
    videoId: 'discover001', title: 'Discovered recording', artists: ['Artist']);

class _App extends Cubit<AppState> implements AppCubit {
  _App()
      : super(AppState(
            0, const Server(url: 'https://music.example'), HomeLayout(),
            profileId: db.profileId));

  void change(AppState state) => emit(state);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Catalog extends MusicCatalogService {
  int trendingCalls = 0;
  int searchCalls = 0;
  int discoveryCalls = 0;
  bool holdDiscovery = false;
  final discoveries = <Completer<List<MusicTrack>>>[];
  final discoveryGuards = <bool Function()?>[];

  @override
  Future<List<MusicTrack>> getDiscoverySongs({bool Function()? isCurrent}) {
    discoveryCalls++;
    discoveryGuards.add(isCurrent);
    if (!holdDiscovery) return Future.value([]);
    final response = Completer<List<MusicTrack>>();
    discoveries.add(response);
    return response.future;
  }

  @override
  Future<List<MusicTrack>> getTrendingSongs() async {
    trendingCalls++;
    throw StateError('Home must not request the unsupported music feed.');
  }

  @override
  Future<List<MusicTrack>> searchSongs(String query) async {
    searchCalls++;
    return [];
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late MusicCatalogService previousCatalog;
  late _Catalog catalog;
  late MusicLibraryService library;
  late _App app;
  late _Router router;
  late int searches;
  late int libraryVisits;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    library = MusicLibraryService.forProfile(db, db.profileId);
    previousCatalog = musicCatalogService;
    musicCatalogService = catalog = _Catalog();
    app = _App();
    router = _Router();
    searches = 0;
    libraryVisits = 0;
  });

  tearDown(() async {
    musicCatalogService = previousCatalog;
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await app.close();
    await db.close();
    router.dispose();
  });

  Future<void> show(WidgetTester tester,
      {double textScale = 1, bool active = true, bool settle = true}) async {
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
          child: Scaffold(
            body: TickerMode(
              enabled: active,
              child: MusicHomePage(
                onSearch: () => searches++,
                onLibrary: () => libraryVisits++,
              ),
            ),
          ),
        ),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> loadDiscovery(WidgetTester tester) async {
    final load = find.byKey(const ValueKey('music-discovery-load'));
    await tester.ensureVisible(load);
    await tester.pumpAndSettle();
    await tester.tap(load);
    await tester.pump();
  }

  testWidgets('Home uses local music without loading a trending feed',
      (tester) async {
    await show(tester);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Saved songs'), findsOneWidget);
    expect(find.text('Search suggestions'), findsOneWidget);
    expect(find.text('Save songs to build your music home.'), findsOneWidget);
    expect(find.text('Trending music'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(catalog.trendingCalls, 0);
    expect(catalog.searchCalls, 0);
    expect(catalog.discoveryCalls, 0);
  });

  testWidgets('explicit discovery loads once and opens verified results',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    expect(catalog.discoveryCalls, 1);
    expect(
        find.byKey(const ValueKey('music-discovery-loading')), findsOneWidget);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    await show(tester);
    expect(catalog.discoveryCalls, 1);
    final card = find.byKey(const ValueKey('music-discovery-discover001'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    expect(
        (router.pushed!.args as MusicRouteArgs).videoId, _discovered.videoId);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('hidden discovery has a reveal and keeps its loaded selection',
      (tester) async {
    await tester.runAsync(installCommunityMusicFilters);
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    catalog.discoveries.single.complete([
      const MusicTrack(
          videoId: 'discover001',
          title: 'Discovered recording',
          uploaderChannelId: musicListedUploader),
    ]);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('music-discovery-discover001')),
        findsNothing);
    expect(find.byKey(const ValueKey('music-discovery-empty')), findsNothing);
    final toggle = find.textContaining('Show hidden results');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-discovery-discover001')),
        findsOneWidget);
    expect(find.byType(CommunityMatchLabels), findsOneWidget);
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets('discovery waits for Home visibility and retains its selection',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, active: false);
    expect(catalog.discoveryCalls, 0);
    await show(tester, settle: false);
    await loadDiscovery(tester);
    expect(catalog.discoveryCalls, 1);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    await show(tester, active: false);
    await show(tester);
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets('hiding Home cancels an initial batch before more lookups',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    final original = catalog.discoveries.single;
    final current = catalog.discoveryGuards.single!;
    await show(tester, active: false);
    expect(current(), isFalse);
    original.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 1);
    await show(tester, settle: false);
    await loadDiscovery(tester);
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);
  });

  testWidgets('hiding Home during refresh preserves its earlier selection',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('music-discovery-refresh'));
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pump();
    final current = catalog.discoveryGuards.last!;
    await show(tester, active: false);
    expect(current(), isFalse);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    await show(tester);
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(catalog.discoveryCalls, 2);
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
  });

  for (final connection in ['HTTPS', 'onion', 'SOCKS']) {
    testWidgets('$connection discovery requires an explicit Load music action',
        (tester) async {
      if (connection == 'onion') {
        app.change(app.state
            .copyWith(server: const Server(url: 'http://musicexample.onion')));
      } else if (connection == 'SOCKS') {
        await NetworkProxy.instance.initialize(
            saved: '{"enabled":true,"host":"127.0.0.1","port":9050}',
            configureNative: false);
      }
      catalog.holdDiscovery = true;
      await show(tester);
      expect(catalog.discoveryCalls, 0);
      final load = find.byKey(const ValueKey('music-discovery-load'));
      await tester.ensureVisible(load);
      await tester.pumpAndSettle();
      await tester.tap(load);
      await tester.pump();
      expect(catalog.discoveryCalls, 1);
      expect(find.byKey(const ValueKey('music-discovery-loading')),
          findsOneWidget);
      catalog.discoveries.single.complete([_discovered]);
      await tester.pumpAndSettle();
      expect(find.text('Discovered recording'), findsOneWidget);
    });
  }

  testWidgets('failed refresh retains only the current selection with a notice',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('music-discovery-refresh'));
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pump();
    expect(tester.widget<IconButton>(refresh).onPressed, isNull);
    expect(find.text('Discovered recording'), findsOneWidget);
    catalog.discoveries.last
        .completeError(const MusicCatalogException('Unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(
        find.text(
            'Could not refresh. Showing the previously loaded selection.'),
        findsOneWidget);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
    expect(catalog.discoveryCalls, 2);
  });

  testWidgets('failed initial discovery has an explicit retry without looping',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    catalog.discoveries.single
        .completeError(const MusicCatalogException('Unavailable'));
    await tester.pumpAndSettle();
    await show(tester);
    expect(catalog.discoveryCalls, 1);
    expect(
        find.byKey(const ValueKey('music-discovery-failure')), findsOneWidget);
    final retry = find.byKey(const ValueKey('music-discovery-load'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pump();
    catalog.discoveries.last.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-discovery-failure')), findsNothing);
    expect(catalog.discoveryCalls, 2);
  });

  for (final transition in [
    'server',
    'account',
    'backend',
    'revision',
    'loading'
  ]) {
    testWidgets('discovery rejects late results after a $transition change',
        (tester) async {
      catalog.holdDiscovery = true;
      await show(tester, settle: false);
      await loadDiscovery(tester);
      final original = catalog.discoveries.single;
      final current = catalog.discoveryGuards.single!;
      app.change(switch (transition) {
        'server' => app.state
            .copyWith(server: const Server(url: 'https://other.example')),
        'account' => app.state.copyWith(
            server: app.state.server!.copyWith(id: 'another-account')),
        'backend' => app.state.copyWith(
            server: app.state.server!
                .copyWith(customHeaders: {'Cookie': 'backend=second'})),
        'loading' => app.state.copyWith(globalLoading: true),
        _ => app.state.copyWith(sessionRevision: 1),
      });
      expect(current(), isFalse);
      await tester.pump();
      original.complete([_discovered]);
      await tester.pump();
      expect(find.text('Discovered recording'), findsNothing);
      await tester.pumpAndSettle();
      expect(catalog.discoveryCalls, 1);
      expect(catalog.trendingCalls, 0);
    });
  }

  testWidgets('country changes invalidate discovery and cannot keep a spinner',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    final original = catalog.discoveries.single;
    await tester
        .runAsync(() => db.saveSetting(SettingsValue(browsingCountry, 'DE')));
    expect(catalog.discoveryGuards.single!(), isFalse);
    original.complete([_discovered]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
  });

  testWidgets('a proxy change clears discovery and waits for manual reloading',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    final original = catalog.discoveries.single;
    await tester.runAsync(
        () => NetworkProxy.instance.apply(SocksProxyConfig(enabled: true)));
    expect(catalog.discoveryGuards.single!(), isFalse);
    original.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 1);
    expect(find.byKey(const ValueKey('music-discovery-load')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
  });

  testWidgets('returning after filter edits discards the previous selection',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final stale = tester.widget<MusicCatalogCard>(
        find.byKey(const ValueKey('music-discovery-discover001')));
    await show(tester, active: false);
    await tester.runAsync(() =>
        db.saveFilter(VideoFilter(value: 'Discovered')..hideFromFeed = true));
    stale.onOpen();
    expect(router.pushed, isNull);
    await show(tester, settle: false);
    await loadDiscovery(tester);
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsNothing);
  });

  testWidgets('profile changes clear cached discovery and stale card actions',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final stale = tester.widget<MusicCatalogCard>(
        find.byKey(const ValueKey('music-discovery-discover001')));
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    stale.onOpen();
    expect(router.pushed, isNull);
    await tester.pump();
    await tester.pump();
    expect(find.text('Discovered recording'), findsNothing);
    await tester.pumpAndSettle();
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets('disposing Home revokes discovery before its response arrives',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await loadDiscovery(tester);
    final current = catalog.discoveryGuards.single!;
    expect(current(), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(current(), isFalse);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty Home keeps Search and Library available', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-home-search')));
    await tester.tap(find.byKey(const ValueKey('music-home-library')));
    expect(searches, 1);
    expect(libraryVisits, 1);
    await tester.tap(find.byKey(const ValueKey('music-home-saved-library')));
    expect(libraryVisits, 2);
  });

  testWidgets('saved music supplies three distinct local search suggestions',
      (tester) async {
    await tester.runAsync(() async {
      for (final artist in ['First', 'Second', 'Third', 'Fourth']) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: artist,
            title: '$artist recording',
            subtitle: artist));
      }
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.artist,
          id: 'UCsavedchannel',
          title: 'FOURTH'));
    });
    await show(tester);
    final suggestions = find.byType(ActionChip);
    expect(suggestions, findsNWidgets(3));
    expect(find.widgetWithText(ActionChip, 'FOURTH'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Third'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Second'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'First'), findsNothing);
    final selected = find.widgetWithText(ActionChip, 'FOURTH');
    await tester.ensureVisible(selected);
    await tester.pumpAndSettle();
    await tester.tap(selected);
    expect(
        (router.pushed!.args as MusicRouteArgs).initialQuery, 'FOURTH music');
    expect(catalog.searchCalls, 0);
    expect(catalog.discoveryCalls, 0);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('search suggestions refresh when saved music changes',
      (tester) async {
    await show(tester);
    expect(find.byType(ActionChip), findsNothing);
    await tester.runAsync(() => library.save(_saved));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ActionChip, 'Saved artist'), findsOneWidget);
    await tester.runAsync(() => library.remove(_saved.kind, _saved.id));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNothing);
    expect(catalog.discoveryCalls, 0);
  });

  testWidgets('suggestions and their actions stay in their saved music profile',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    final stale = tester
        .widget<ActionChip>(find.widgetWithText(ActionChip, 'Saved artist'));
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    final nextLibrary = MusicLibraryService.forProfile(db, next.id);
    await tester.runAsync(() => nextLibrary.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.artist,
        id: 'UCsecondchannel',
        title: 'Second profile artist')));
    app.change(app.state.copyWith(profileId: next.id));
    stale.onPressed!();
    expect(router.pushed, isNull);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ActionChip, 'Saved artist'), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Second profile artist'),
        findsOneWidget);
    expect(catalog.discoveryCalls, 0);
  });

  testWidgets('genre tiles open explicit Invidious song searches',
      (tester) async {
    await show(tester);
    const queries = [
      'pop music',
      'jazz music',
      'classical music',
      'electronic music'
    ];
    for (var index = 0; index < queries.length; index++) {
      final tile = find.byKey(ValueKey('music-explore-$index'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      expect(
          (router.pushed!.args as MusicRouteArgs).initialQuery, queries[index]);
    }
    expect(catalog.trendingCalls, 0);
    expect(catalog.searchCalls, 0);
  });

  testWidgets('saved songs refresh locally and open their identifiers',
      (tester) async {
    await show(tester);
    await tester.runAsync(() => library.save(_saved));
    await tester.pumpAndSettle();
    expect(find.text('Saved recording'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-home-saved-empty')), findsNothing);
    await tester.tap(find.text('Saved recording'));
    expect((router.pushed!.args as MusicRouteArgs).videoId, _saved.id);
    await tester.runAsync(() => library.remove(_saved.kind, _saved.id));
    await tester.pumpAndSettle();
    expect(find.text('Saved recording'), findsNothing);
    expect(
        find.byKey(const ValueKey('music-home-saved-empty')), findsOneWidget);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('saved song rows retain their existing library actions',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    expect(find.text('Remove saved song'), findsOneWidget);
    expect(find.text('Save to playlist'), findsOneWidget);
    await tester.runAsync(() async {
      final removed = Completer<void>();
      void onChanged() {
        if (library.entries.isEmpty && !removed.isCompleted) removed.complete();
      }

      library.changes.addListener(onChanged);
      try {
        await tester.tap(find.text('Remove saved song'));
        await tester.pumpAndSettle();
        await removed.future.timeout(const Duration(seconds: 5));
      } finally {
        library.changes.removeListener(onChanged);
      }
    });
    await tester.pumpAndSettle();
    expect(library.entries, isEmpty);
    expect(find.text('Saved recording'), findsNothing);
    expect(
        find.byKey(const ValueKey('music-home-saved-empty')), findsOneWidget);
    expect(catalog.discoveryCalls, 0);
  });

  testWidgets('Home limits its preview while keeping the full library',
      (tester) async {
    await tester.runAsync(() async {
      for (var index = 0; index < 14; index++) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'saved$index',
            title: 'Song $index'));
      }
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.album, id: 'MPREold', title: 'Legacy album'));
    });
    await show(tester);
    final shelf = find.byKey(const ValueKey('music-home-saved'));
    await tester.ensureVisible(shelf);
    await tester.pumpAndSettle();
    await tester.drag(shelf, const Offset(-1500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Song 2'), findsOneWidget);
    expect(find.text('Song 1'), findsNothing);
    expect(find.text('Song 0'), findsNothing);
    expect(library.entries.length, 15);
    expect(find.text('Legacy album'), findsNothing);
    await tester
        .ensureVisible(find.byKey(const ValueKey('music-home-saved-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-home-saved-library')));
    expect(libraryVisits, 1);
  });

  testWidgets('saved music and stale actions cannot cross profiles',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    final stale = tester.widget<InkWell>(find
        .descendant(
            of: find.byKey(ValueKey('music-home-saved-${_saved.id}')),
            matching: find.byType(InkWell))
        .first);
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    stale.onTap!();
    expect(router.pushed, isNull);
    await tester.pumpAndSettle();
    expect(find.text('Saved recording'), findsNothing);
    expect(library.entries.single.id, _saved.id);
    final nextLibrary = MusicLibraryService.forProfile(db, next.id);
    await tester.runAsync(() => nextLibrary.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'second',
        title: 'Second profile song')));
    await tester.pumpAndSettle();
    expect(find.text('Second profile song'), findsOneWidget);
    expect(find.text('Saved recording'), findsNothing);
  });

  for (final transition in ['server', 'revision', 'loading', 'recovery']) {
    testWidgets('stale genre actions are ignored after $transition changes',
        (tester) async {
      await show(tester);
      final stale =
          tester.widget<InkWell>(find.byKey(const ValueKey('music-explore-0')));
      app.change(switch (transition) {
        'server' => app.state
            .copyWith(server: const Server(url: 'https://other.example')),
        'loading' => app.state.copyWith(globalLoading: true),
        'recovery' => app.state.copyWith(sessionRecoveryRequired: true),
        _ => app.state.copyWith(sessionRevision: 1),
      });
      stale.onTap!();
      expect(router.pushed, isNull);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('Home keeps its scroll position across rebuilds', (tester) async {
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester);
    final homeState = tester.state(find.byType(MusicHomePage));
    final scroll = tester
        .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('music-home')))
        .controller!;
    scroll.jumpTo(200);
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    await show(tester);
    expect(tester.state(find.byType(MusicHomePage)), same(homeState));
    expect(scroll.offset, offset);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('saved songs can be activated by keyboard remote',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    Focus.of(tester.element(find.text('Saved recording'))).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((router.pushed!.args as MusicRouteArgs).videoId, _saved.id);
  });

  testWidgets('Home fits 320px with large text and long saved titles',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'longsong',
        title: 'A recording with a very long title that needs multiple lines',
        subtitle: 'A channel with a similarly long display name')));
    await show(tester, textScale: 2.5);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('music-explore-3')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('focusing a lower genre scrolls that tile fully into view',
      (tester) async {
    tester.view.physicalSize = const Size(320, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, textScale: 1.6);
    Focus.of(tester.element(find.text('Electronic'))).requestFocus();
    await tester.pumpAndSettle();
    final tile = tester.getRect(find.byKey(const ValueKey('music-explore-3')));
    expect(tile.top, greaterThanOrEqualTo(0));
    expect(tile.bottom, lessThanOrEqualTo(350));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((router.pushed!.args as MusicRouteArgs).initialQuery,
        'electronic music');
  });
}
