import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_discovery.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/screens/music_discovery.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const _album = MusicAlbum(
  id: 'MPREfresh',
  title: 'Fresh album',
  artists: ['An artist'],
);
const _playlist = MusicPlaylist(id: 'PLchart', title: 'Public chart');
const _artist = MusicArtist(id: 'UCchartartist', name: 'Chart artist');
const _mood = MusicMoodCategory(
  title: 'Focus',
  params: 'focus-public',
  group: 'Moods',
);
const _countries = [
  MusicCountry(code: 'ZZ', name: 'Global'),
  MusicCountry(code: 'GB', name: 'United Kingdom'),
];

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  void change(AppState state) => emit(state);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Catalog extends MusicCatalogService {
  int releaseCalls = 0;
  int moodCalls = 0;
  final chartCalls = <String>[];
  final moodPlaylistCalls = <String>[];
  Future<List<MusicAlbum>> Function()? releases;
  Future<MusicCharts> Function(String)? charts;
  List<MusicPlaylist> moodPlaylists = [
    const MusicPlaylist(id: 'PLfocus', title: 'Focus playlist'),
  ];

  @override
  Future<List<MusicAlbum>> getNewReleases() {
    releaseCalls++;
    return releases?.call() ?? Future.value([_album]);
  }

  @override
  Future<MusicCharts> getCharts({String country = 'ZZ'}) {
    chartCalls.add(country);
    return charts?.call(country) ??
        Future.value(MusicCharts(
          country: country,
          countries: _countries,
          playlists: [_playlist],
          artists: [_artist],
        ));
  }

  @override
  Future<List<MusicMoodCategory>> getMoodCategories() async {
    moodCalls++;
    return [_mood];
  }

  @override
  Future<List<MusicPlaylist>> getMoodPlaylists(String params) async {
    moodPlaylistCalls.add(params);
    return moodPlaylists;
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

  setUp(() {
    previousCatalog = musicCatalogService;
    musicCatalogService = catalog = _Catalog();
    app = _App();
    router = _Router();
  });

  tearDown(() async {
    musicCatalogService = previousCatalog;
    await app.close();
    router.dispose();
  });

  Widget home() => MusicHomePage(onExplore: () {}, onLibrary: () {});

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

  testWidgets('Home shelves fail and retry independently', (tester) async {
    final first = Completer<List<MusicAlbum>>();
    final retry = Completer<List<MusicAlbum>>();
    catalog.releases =
        () => catalog.releaseCalls == 1 ? first.future : retry.future;
    await show(tester);
    first.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load this section.'), findsOneWidget);
    expect(find.text('Public chart'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    retry.complete([_album]);
    await tester.pumpAndSettle();
    expect(find.text('Fresh album'), findsOneWidget);
    expect(find.text('Could not load this section.'), findsNothing);
    expect(catalog.releaseCalls, 2);
    expect(catalog.chartCalls, ['ZZ']);
    expect(catalog.moodCalls, 1);
  });

  testWidgets('Home explains regional failures and retry clears the guidance',
      (tester) async {
    catalog.releases =
        () => Future.error(const MusicCatalogRegionUnavailable());
    await show(tester);
    await tester.pumpAndSettle();
    expect(
        find.textContaining('try another region or circuit'), findsOneWidget);
    expect(find.text('Public chart'), findsOneWidget);

    final retry = Completer<List<MusicAlbum>>();
    catalog.releases = () => retry.future;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.textContaining('try another region or circuit'), findsNothing);
    retry.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load this section.'), findsOneWidget);
    expect(find.textContaining('try another region or circuit'), findsNothing);
  });

  testWidgets('a new session reloads shelves after a regional failure',
      (tester) async {
    catalog.releases =
        () => Future.error(const MusicCatalogRegionUnavailable());
    await show(tester);
    await tester.pumpAndSettle();
    expect(
        find.textContaining('try another region or circuit'), findsOneWidget);
    catalog.releases = () async => [_album];
    app.change(
        app.state.copyWith(sessionRevision: app.state.sessionRevision + 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('try another region or circuit'), findsNothing);
    expect(find.text('Fresh album'), findsOneWidget);
  });

  testWidgets('Home opens the real album and playlist IDs', (tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fresh album'));
    expect((router.pushed!.args as MusicRouteArgs).albumId, _album.id);
    await tester.ensureVisible(find.text('Public chart'));
    await tester.tap(find.text('Public chart'));
    expect((router.pushed!.args as MusicRouteArgs).playlistId, _playlist.id);
    expect((router.pushed!.args as MusicRouteArgs).videoId, isNull);
  });

  testWidgets('Explore uses returned countries and keeps visited feeds',
      (tester) async {
    await show(tester, child: const MusicExplorePage());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-explore-charts')));
    await tester.pumpAndSettle();
    expect(find.text('Global'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('United Kingdom').last);
    await tester.pumpAndSettle();
    expect(catalog.chartCalls, ['ZZ', 'GB']);

    await tester.ensureVisible(find.text('Chart artist'));
    await tester.tap(find.text('Chart artist'));
    expect((router.pushed!.args as MusicRouteArgs).artistId, _artist.id);
    await tester
        .ensureVisible(find.byKey(const ValueKey('music-explore-releases')));
    await tester.tap(find.byKey(const ValueKey('music-explore-releases')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-explore-charts')));
    await tester.pumpAndSettle();
    expect(catalog.releaseCalls, 1);
    expect(catalog.chartCalls, ['ZZ', 'GB']);
    expect(find.text('United Kingdom'), findsOneWidget);
  });

  testWidgets('mood category loads its playlists and opens the playlist ID',
      (tester) async {
    await show(tester, child: const MusicExplorePage());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-explore-moods')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(catalog.moodPlaylistCalls, [_mood.params]);
    await tester.tap(find.text('Focus playlist'));
    expect((router.pushed!.args as MusicRouteArgs).playlistId, 'PLfocus');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Focus'), findsOneWidget);
    expect(catalog.moodCalls, 1);
  });

  testWidgets('country selection preserves keyboard focus', (tester) async {
    await show(tester, child: const MusicExplorePage());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-explore-charts')));
    await tester.pumpAndSettle();
    final countryFocus = Focus.of(tester.element(find.text('Global')))
        .ancestors
        .firstWhere((node) => node.canRequestFocus && node is! FocusScopeNode);
    countryFocus.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, countryFocus);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('United Kingdom').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(catalog.chartCalls, ['ZZ', 'GB']);
    expect(FocusManager.instance.primaryFocus, countryFocus);
  });

  testWidgets('visiting categories out of order retains the earlier feed',
      (tester) async {
    await show(tester, child: const MusicExplorePage());
    await tester.pumpAndSettle();
    for (final category in ['moods', 'charts', 'moods']) {
      await tester
          .ensureVisible(find.byKey(ValueKey('music-explore-$category')));
      await tester.tap(find.byKey(ValueKey('music-explore-$category')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Focus'), findsOneWidget);
    expect(catalog.moodCalls, 1);
    expect(catalog.chartCalls, ['ZZ']);
    expect(catalog.releaseCalls, 1);
  });

  testWidgets('Home mood opens at its heading and Back restores Home scroll',
      (tester) async {
    catalog.moodPlaylists = List.generate(
        30, (index) => MusicPlaylist(id: 'PLmood$index', title: 'Mood $index'));
    await show(tester);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Focus'));
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('music-home')))
        .controller!;
    final homeOffset = scroll.offset;
    expect(homeOffset, greaterThan(0));
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(find.byType(BackButton).hitTestable(), findsOneWidget);
    expect(find.text('Mood 0').hitTestable(), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(scroll.offset, homeOffset);
    expect(catalog.releaseCalls, 1);
    expect(catalog.chartCalls, ['ZZ']);
    expect(catalog.moodCalls, 1);
  });

  for (final transition in ['profile', 'server', 'revision']) {
    testWidgets('late responses are discarded after $transition changes',
        (tester) async {
      final old = Completer<List<MusicAlbum>>();
      final fresh = Completer<List<MusicAlbum>>();
      catalog.releases =
          () => catalog.releaseCalls == 1 ? old.future : fresh.future;
      await show(tester);
      app.change(switch (transition) {
        'profile' => app.state.copyWith(profileId: 'another-profile'),
        'server' => app.state
            .copyWith(server: const Server(url: 'https://other.example')),
        _ => app.state.copyWith(sessionRevision: 1),
      });
      await tester.pump();
      fresh.complete([const MusicAlbum(id: 'MPREnew', title: 'New session')]);
      await tester.pumpAndSettle();
      old.complete([_album]);
      await tester.pumpAndSettle();
      expect(find.text('New session'), findsOneWidget);
      expect(find.text('Fresh album'), findsNothing);
      expect(catalog.releaseCalls, 2);
    });
  }

  testWidgets('empty releases show an honest empty state', (tester) async {
    catalog.releases = () async => [];
    await show(tester);
    await tester.pumpAndSettle();
    expect(
        find.text('No new releases are available right now.'), findsOneWidget);
    expect(find.text('Public chart'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
      'shelf drags never flip the enclosing page, including at its edge',
      (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    catalog.releases = () async => List.generate(
        8, (index) => MusicAlbum(id: 'MPRE$index', title: 'Album $index'));
    await show(tester,
        child: PageView(
          controller: controller,
          children: [home(), const Center(child: Text('Next page'))],
        ));
    await tester.pumpAndSettle();
    final shelf = find.byKey(const ValueKey('music-home-releases'));
    await tester.drag(shelf, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    await tester.drag(shelf, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    await tester.drag(shelf, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    expect(find.text('Next page').hitTestable(), findsNothing);
  });

  testWidgets('focused album cards activate using a keyboard remote',
      (tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('Fresh album'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((router.pushed!.args as MusicRouteArgs).albumId, _album.id);
  });

  testWidgets('Home and every Explore category fit 320px with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await show(tester, child: const MusicExplorePage(), textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final category in ['charts', 'moods']) {
      await tester
          .ensureVisible(find.byKey(ValueKey('music-explore-$category')));
      await tester.tap(find.byKey(ValueKey('music-explore-$category')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
