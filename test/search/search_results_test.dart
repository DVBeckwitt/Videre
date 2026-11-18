import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/search/models/search_date.dart';
import 'package:clipious/search/models/search_duration.dart';
import 'package:clipious/search/models/search_results.dart';
import 'package:clipious/search/models/search_sort_by.dart';
import 'package:clipious/search/models/search_suggestion.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/search/states/search.dart';
import 'package:clipious/search/views/screens/channel_tab.dart';
import 'package:clipious/search/views/screens/playlist_tab.dart';
import 'package:clipious/search/views/screens/video_tab.dart';
import 'package:clipious/search/views/components/search_channel_hero_card.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:clipious/subscription_management/view/components/subscribe_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _SearchService extends Service {
  final requests = <({String label, Completer<SearchResults> result})>[];
  bool deferred = false;

  @override
  Future<SearchSuggestion> getSearchSuggestion(String query) async =>
      SearchSuggestion(query, []);

  @override
  Future<SearchResults> search(String query,
      {SearchType? type,
      int? page,
      SearchSortBy? sortBy,
      SearchDate date = SearchDate.any,
      SearchDuration duration = SearchDuration.any,
      Server? serverOverride,
      bool enrichResults = true}) {
    final result = Completer<SearchResults>();
    requests.add((
      label: '$query-${sortBy?.name}-${date.name}-${duration.name}',
      result: result
    ));
    if (!deferred) complete(requests.length - 1);
    return result.future;
  }

  void complete(int index) {
    final request = requests[index];
    final results = SearchResults()
      ..videos.add(Video(videoId: 'result-$index', title: request.label))
      ..channels.add(Channel(request.label, 'channel-$index', '', null, [], 0,
          null, null, false, null, '', null, null))
      ..playlists.add(Playlist(
          title: request.label,
          playlistId: 'PL-result-$index',
          author: '',
          videoCount: 0));
    request.result.complete(results);
  }
}

void main() {
  late _SearchService fakeService;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late SearchCubit search;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(const Server(url: 'https://inv.example'));
    service = fakeService = _SearchService();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    search = SearchCubit(
        SearchState.init(query: 'cats', showResults: true), settings);
  });

  tearDown(() async {
    await search.close();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> showTab(WidgetTester tester, SearchType type,
      {bool dark = false}) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SearchCubit>.value(value: search),
      ],
      child: MaterialApp(
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: switch (type) {
            SearchType.video => SearchVideoTab(),
            SearchType.channel => SearchChannelTab(),
            _ => SearchPlaylistTab(),
          },
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('switching Search layouts keeps the loaded results controller',
      (tester) async {
    await showTab(tester, SearchType.video);
    await tester.pumpAndSettle();
    final controller =
        tester.widget<GridView>(find.byType(GridView)).controller;
    expect(find.byType(CompactVideo), findsNothing);

    await tester.runAsync(search.toggleResultLayout);
    await tester.pumpAndSettle();
    expect(find.byType(CompactVideo), findsOneWidget);
    expect(find.text('cats-relevance-any-any'), findsOneWidget);
    expect(fakeService.requests, hasLength(1));
    expect(
        tester.widget<GridView>(find.byType(GridView)).controller, controller);

    final reopened = SearchCubit(SearchState.init(), settings);
    expect(reopened.compactResults.value, isTrue);
    await reopened.close();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('creator search renders an actionable card without eager follows',
      (tester) async {
    await showTab(tester, SearchType.channel);
    await tester.pumpAndSettle();
    expect(find.byType(SearchChannelHeroCard), findsOneWidget);
    expect(find.text('Go to channel'), findsOneWidget);
    expect(find.byType(SubscribeButton), findsNothing);
    expect(fakeService.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final type in [
    SearchType.video,
    SearchType.channel,
    SearchType.playlist
  ]) {
    testWidgets('${type.name} results reload only when search criteria change',
        (tester) async {
      await showTab(tester, type);
      await tester.pumpAndSettle();
      expect(fakeService.requests, hasLength(1));
      expect(find.text('cats-relevance-any-any'), findsOneWidget);

      await showTab(tester, type, dark: true);
      await tester.pumpAndSettle();
      expect(fakeService.requests, hasLength(1),
          reason: 'A theme rebuild must preserve loaded results');
      expect(find.text('cats-relevance-any-any'), findsOneWidget);

      search.onFiltersChanged(
          search.state.filters.copyWith(sortBy: SearchSortBy.views));
      await tester.pumpAndSettle();
      expect(fakeService.requests, hasLength(2));
      expect(find.text('cats-views-any-any'), findsOneWidget);
      expect(find.text('cats-relevance-any-any'), findsNothing);

      search.onFiltersChanged(
          search.state.filters.copyWith(date: SearchDate.week));
      await tester.pumpAndSettle();
      expect(fakeService.requests, hasLength(3));
      expect(find.text('cats-views-week-any'), findsOneWidget);

      search.onFiltersChanged(
          search.state.filters.copyWith(duration: SearchDuration.long));
      await tester.pumpAndSettle();
      expect(fakeService.requests, hasLength(4));
      expect(find.text('cats-views-week-long'), findsOneWidget);

      search.state.queryController.text = 'dogs';
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(fakeService.requests, hasLength(4),
          reason: 'Editing keeps the submitted results and scroll state');
      expect(find.text('cats-views-week-long'), findsOneWidget);

      await tester.runAsync(() => search.search('dogs'));
      await tester.pumpAndSettle();
      expect(fakeService.requests, hasLength(5));
      expect(find.text('dogs-views-week-long'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('${type.name} ignores results for replaced criteria',
        (tester) async {
      fakeService.deferred = true;
      await showTab(tester, type);
      expect(fakeService.requests, hasLength(1));
      search.onFiltersChanged(
          search.state.filters.copyWith(date: SearchDate.week));
      await tester.pump();
      expect(fakeService.requests, hasLength(2));
      fakeService.complete(1);
      await tester.pumpAndSettle();
      expect(find.text('cats-relevance-week-any'), findsOneWidget);

      fakeService.complete(0);
      await tester.pumpAndSettle();
      expect(find.text('cats-relevance-any-any'), findsNothing);
      expect(find.text('cats-relevance-week-any'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
