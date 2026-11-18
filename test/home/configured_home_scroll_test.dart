import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/home_tabs_layout.dart';
import 'package:clipious/home/views/components/home.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Feeds extends Service {
  final historyPages = <int>[];
  int syncs = 0;
  @override
  Future<List<Video>> getPopular() async => [
        const Video(
            videoId: 'popular0001', title: 'Popular today', author: 'A'),
      ];
  @override
  Future<List<Video>> getTrending({String? type}) => getPopular();
  @override
  Future<List<String>> getLocalHistoryPage(int page, int maxResults) {
    historyPages.add(page);
    return super.getLocalHistoryPage(page, maxResults);
  }

  @override
  Future<void> syncHistory() async {
    syncs++;
  }
}

class _SubscriptionFeed extends Service {
  final pages = <int>[];

  @override
  Future<bool> isLoggedIn() async => true;

  @override
  Future<UserFeed> getUserFeed({
    int? maxResults,
    int? page,
    bool saveLastSeen = true,
    Server? serverOverride,
  }) async {
    final number = page ?? 1;
    pages.add(number);
    final count = maxResults ?? 50;
    return UserFeed([], [
      for (var i = 0; i < (number == 1 ? count : 1); i++)
        Video(
            videoId:
                'sub${((number - 1) * count + i).toString().padLeft(8, '0')}',
            title: number == 1 ? 'Subscription $i' : 'Second page video',
            author: 'Creator',
            published: 10000 - (number - 1) * count - i),
    ]);
  }
}

void main() {
  testWidgets(
      'subscription page and position survive Continue watching updates',
      (tester) async {
    final feeds = _SubscriptionFeed();
    final layout = HomeLayout()
      ..showBigSource = true
      ..bigSource = HomeDataSource.subscription
      ..smallSources = [];
    late TestAppCubit app;
    late TestSettingsCubit settings;
    late TestPlayerCubit player;
    await tester.runAsync(() async {
      db = await SembastSqfDb.createInMemory();
      service = feeds;
      await db.upsertHomeLayout(layout);
      app = TestAppCubit(AppState(0, null, layout));
      app.intentDataStreamSubscription =
          const Stream<void>.empty().listen((_) {});
      await app.initState();
      settings = TestSettingsCubit(SettingsState.init(), app);
      await settings.setHomeTabsLayout(HomeTabsLayout(
          enabledOrder: [HomeTabsLayout.yourFeeds], continueWatching: true));
      player = TestPlayerCubit(PlayerState.init(null), settings);
    });
    addTearDown(() async {
      RecommendationService.forProfile(db, db.profileId).dispose();
      await player.close();
      await settings.close();
      await app.close();
      await db.close();
    });
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HomeView()),
      ),
    ));
    await tester.pumpAndSettle();
    ScrollPosition feedPosition() => tester
        .state<ScrollableState>(find
            .descendant(
                of: find.byType(GridView), matching: find.byType(Scrollable))
            .first)
        .position;
    expect(feeds.pages, [1]);
    final position = feedPosition();
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(feeds.pages, [1, 2]);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final secondPage = find.text('Second page video').hitTestable();
    expect(secondPage, findsOneWidget);
    final offset = position.pixels;
    final rowTop = tester.getTopLeft(secondPage).dy;
    final shelf = find.byKey(PageStorageKey('flow-resume-${db.profileId}'));
    expect(shelf, findsNothing);
    expect(offset, greaterThan(0));
    const id = 'resume00001';
    for (final showShelf in [true, false]) {
      await tester.runAsync(() async {
        if (showShelf) {
          await db.upsertHistoryVideo(HistoryVideoCache(
              id, 'Resume me', 'Creator', '',
              lengthSeconds: 200));
          await db.saveProgress(Progress(0.5, id));
        } else {
          await db.deleteLocalHistory(id);
        }
      });
      playbackHistoryRevision.value++;
      await tester.pumpAndSettle();
      expect(feeds.pages, [1, 2], reason: 'shelf visible: $showShelf');
      expect(shelf, showShelf ? findsOneWidget : findsNothing);
      expect(feedPosition(), same(position));
      expect(feedPosition().pixels, closeTo(offset, 1));
      expect(secondPage, findsOneWidget);
      expect(tester.getTopLeft(secondPage).dy, closeTo(rowTop, 1));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mainFeed in [true, false]) {
    testWidgets(
        'Your feeds scrolls the full resume shelf away and back '
        'with a ${mainFeed ? "paged" : "compact-only"} layout', (tester) async {
      final feeds = _Feeds();
      final layout = HomeLayout()
        ..showBigSource = mainFeed
        ..bigSource = HomeDataSource.history
        ..smallSources = mainFeed
            ? []
            : [
                HomeDataSource.popular,
                HomeDataSource.trending,
                HomeDataSource.history
              ];
      late TestAppCubit app;
      late TestSettingsCubit settings;
      late TestPlayerCubit player;
      await tester.runAsync(() async {
        db = await SembastSqfDb.createInMemory();
        service = feeds;
        await db.upsertHomeLayout(layout);
        for (var i = 0; i < 22; i++) {
          final id = 'video${i.toString().padLeft(6, "0")}';
          await db.upsertHistoryVideo(HistoryVideoCache(
              id, 'History item $i', 'Creator', '',
              lengthSeconds: 200));
          if (i < 2) await db.saveProgress(Progress(0.5, id));
        }
        app = TestAppCubit(AppState(0, null, layout));
        app.intentDataStreamSubscription =
            const Stream<void>.empty().listen((_) {});
        await app.initState();
        settings = TestSettingsCubit(SettingsState.init(), app);
        await settings.setHomeTabsLayout(HomeTabsLayout(
            enabledOrder: [HomeTabsLayout.yourFeeds], continueWatching: true));
        player = TestPlayerCubit(PlayerState.init(null), settings);
      });
      addTearDown(() async {
        RecommendationService.forProfile(db, db.profileId).dispose();
        await player.close();
        await settings.close();
        await app.close();
        await db.close();
      });
      tester.view.physicalSize = const Size(360, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<PlayerCubit>.value(value: player),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HomeView()),
        ),
      ));
      await tester.pumpAndSettle();
      final heading = find.text('Continue watching').hitTestable();
      final removal = find.byTooltip('Remove from local history').hitTestable();
      final tabs = find.byKey(const ValueKey('video-home-your-feeds'));
      expect(heading, findsOneWidget);
      final carousel =
          find.byKey(PageStorageKey('flow-resume-${db.profileId}'));
      final position = tester
          .state<ScrollableState>(
              find.descendant(of: carousel, matching: find.byType(Scrollable)))
          .position;
      await tester.drag(carousel, const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(heading, findsOneWidget);

      await tester.dragFrom(const Offset(140, 453), const Offset(0, -410));
      await tester.pumpAndSettle();
      expect(heading, findsNothing);
      expect(removal, findsNothing);
      expect(tabs.hitTestable(), findsOneWidget);
      if (mainFeed) {
        // Hit the end of the first real history page via touch.
        for (var i = 0; i < 6 && !feeds.historyPages.contains(2); i++) {
          await tester.dragFrom(const Offset(140, 453), const Offset(0, -410));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 550));
        }
        expect(feeds.historyPages, contains(2));
      }

      for (var i = 0; i < 10 && heading.evaluate().isEmpty; i++) {
        await tester.dragFrom(const Offset(140, 95), const Offset(0, 440));
        await tester.pumpAndSettle();
      }
      expect(heading, findsOneWidget);
      if (mainFeed) {
        // Pull from the list, where the existing refresh control is attached.
        final previousSyncs = feeds.syncs;
        await tester.dragFrom(const Offset(140, 454), const Offset(0, 420));
        await tester.pumpAndSettle();
        expect(feeds.syncs, previousSyncs + 1);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
