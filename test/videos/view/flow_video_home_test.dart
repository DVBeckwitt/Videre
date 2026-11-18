import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/home_tabs_layout.dart';
import 'package:clipious/home/views/components/flow_video_home.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/subscription_management/models/subscription.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:clipious/videos/states/video_in_list.dart';
import 'package:clipious/videos/views/tv/components/video_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

class _FeedService extends Service {
  int requests = 0;
  int historyDeletes = 0;
  List<Video> Function(String?)? discoveryResults;
  List<Subscription> follows = [];

  @override
  Future<void> deleteFromUserHistory(String videoId) async {
    historyDeletes++;
  }

  @override
  Future<List<Subscription>> getRecommendationSubscriptions({
    required Server server,
    required Future<void> Function() beforeRequest,
  }) async {
    await beforeRequest();
    return follows;
  }

  @override
  Future<List<Video>> getVideoRecommendationCandidates({
    required Server server,
    required Future<void> Function() beforeRequest,
    String? query,
    String? channelId,
  }) async {
    await beforeRequest();
    requests++;
    return discoveryResults?.call(query) ?? [];
  }

  @override
  Future<List<Video>> getPopular() async {
    requests++;
    return [];
  }

  @override
  Future<List<Video>> getTrending({String? type}) async {
    requests++;
    return [];
  }
}

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late _FeedService api;
  final calls = <MethodCall>[];
  List<String> discoveryQueries = [];
  List<Map<String, Object>> interestChips = [];
  const channel = MethodChannel('videre/recommendations');

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    service = api = _FeedService();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    calls.clear();
    discoveryQueries = [];
    interestChips = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final arguments = call.arguments as Map;
      final candidates = arguments['candidates'] as List;
      final events = arguments['events'] as List? ?? const [];
      return {
        'state': <String, Object?>{},
        'summary': {
          'discoveryQueries': discoveryQueries,
          'interestChips': interestChips,
          // The viewport tests exercise admission to the bridge. The native
          // engine can reject duplicate sightings without writing a snapshot.
          if (events
              .whereType<Map>()
              .any((event) => event['type'] == 'impression'))
            'appliedEvents': 0,
        },
        'ranked': [
          for (final candidate in candidates.reversed)
            {
              'id': (candidate as Map)['id'],
              'score': 1.0,
              'reason': 'Matches your local video interests.'
            },
        ],
      };
    });
  });

  tearDown(() async {
    RecommendationService.forProfile(db, db.profileId).dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> remember(String id, String title, double progress,
      {bool music = false}) async {
    await db.upsertHistoryVideo(HistoryVideoCache(id, title, 'Creator', '',
        lengthSeconds: 300,
        musicMetadata: music
            ? MusicMetadata(title: title, artist: 'Artist', thumbnails: [])
            : null));
    await db.saveProgress(Progress(progress, id));
  }

  Future<void> show(WidgetTester tester,
      {double scale = 1,
      bool active = true,
      bool settle = true,
      bool television = false,
      Widget? configuredFeed,
      ValueChanged<List<RecommendationInterest>>? onEdit}) async {
    tester.view.physicalSize =
        television ? const Size(1280, 800) : const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
            body: FlowVideoHome(
                active: active,
                television: television,
                configuredFeed: configuredFeed,
                onEdit: onEdit)),
      ),
    ));
    if (settle) await tester.pumpAndSettle();
  }

  test('Continue watching excludes music, completed and manually watched items',
      () async {
    await remember('resume00001', 'Resume me', 0.4);
    await remember('complete001', 'Completed', 0.95);
    await remember('manual00001', 'Marked watched', 0.3);
    await remember('song0000001', 'A song', 0.2, music: true);
    await WatchRepository.forDatabase(db)!.mark('manual00001', true);
    expect(continuingVideos(db).map((video) => video.videoId), ['resume00001']);
    expect(api.requests, 0);
  });

  test('Continue watching stays in the owning profile', () async {
    await remember('resume00001', 'First person', 0.4);
    final other = await db.createProfile('Other');
    expect(continuingVideos(db.forProfile(other.id)), isEmpty);
    expect(continuingVideos(db).single.title, 'First person');
  });

  testWidgets(
      'Continue watching removes local history for the active profile only',
      (tester) async {
    await tester.runAsync(() =>
        settings.setHomeTabsLayout(HomeTabsLayout(continueWatching: true)));
    const id = 'resume00001';
    const server =
        Server(url: 'https://invidious.example', authToken: 'test-only');
    final other = await tester.runAsync(() async {
      await db.upsertServer(server);
      await db.useServer(server);
      await remember(id, 'One recording', 0.4);
      final profile = await db.createProfile('Other');
      final owner = db.forProfile(profile.id);
      await owner.upsertHistoryVideo(
          HistoryVideoCache(id, 'Same recording', 'Creator', ''));
      await owner.saveProgress(Progress(0.6, id));
      return owner;
    });
    app.setServer(server);
    await show(tester);
    final remove = find.byTooltip('Remove from local history');
    await tester.ensureVisible(remove);
    expect(tester.getSize(remove).shortestSide, greaterThanOrEqualTo(48));

    final revision = playbackHistoryRevision.value;
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(playbackHistoryRevision.value, greaterThan(revision));
    expect(remove, findsNothing);
    expect(db.getLocalHistory(), isEmpty);
    expect(db.getVideoProgress(id), 0);
    expect(other!.getVideoProgress(id), 0.6);
    expect(other.getLocalHistory().single.videoId, id);
    expect(api.historyDeletes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Continue watching is opt-in and can be added back live',
      (tester) async {
    await tester.runAsync(() => remember('resume00001', 'Resume me', 0.4));
    await show(tester);
    expect(find.text('Continue watching'), findsNothing);
    expect(find.byTooltip('Remove from local history'), findsNothing);
    await tester.runAsync(() =>
        settings.setHomeTabsLayout(HomeTabsLayout(continueWatching: true)));
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(const HomeTabsLayout.defaults()));
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsNothing);
    expect(db.getHistoryVideoByVideoId('resume00001'), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('all Home tabs disabled is blank and does not rank or warm',
      (tester) async {
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    var edited = false;
    await show(tester,
        configuredFeed: const Text('Configured feed'),
        onEdit: (_) => edited = true);
    expect(find.text('Local video'), findsNothing);
    expect(find.text('Configured feed'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('video-home-discover')), findsNothing);
    expect(calls, isEmpty);
    expect(api.requests, 0);
    await tester.tap(find.byKey(const ValueKey('home-tabs-edit')));
    await tester.pumpAndSettle();
    expect(edited, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final configured in [false, true]) {
    testWidgets('Continue watching can stand alone: configured=$configured',
        (tester) async {
      await tester.runAsync(() => settings.setHomeTabsLayout(HomeTabsLayout(
          enabledOrder: configured ? [HomeTabsLayout.yourFeeds] : [],
          continueWatching: true)));
      await tester.runAsync(() => remember('resume00001', 'Resume me', 0.4));
      await show(tester, configuredFeed: const Text('Configured feed'));
      expect(find.text('Continue watching'), findsOneWidget);
      if (configured) expect(find.text('Configured feed'), findsOneWidget);
      expect(calls, isEmpty);
      expect(api.requests, 0);
      await tester.tap(find.byTooltip('Remove from local history'));
      await tester.pumpAndSettle();
      expect(find.text('Continue watching'), findsNothing);
      expect(db.getHistoryVideoByVideoId('resume00001'), isNull);
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Home chips follow saved order and disabled feeds stop learning',
      (tester) async {
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.discover,
              HomeTabsLayout.forYou,
            ])));
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    await show(tester, configuredFeed: const Text('Configured feed'));
    final yourFeeds = find.byKey(const ValueKey('video-home-your-feeds'));
    final discover = find.byKey(const ValueKey('video-home-discover'));
    final forYou = find.byKey(const ValueKey('video-home-for-you'));
    expect(find.text('Configured feed'), findsOneWidget);
    expect(calls, isEmpty);
    expect(tester.getTopLeft(yourFeeds).dx,
        lessThan(tester.getTopLeft(discover).dx));
    expect(
        tester.getTopLeft(discover).dx, lessThan(tester.getTopLeft(forYou).dx));
    await tester.ensureVisible(forYou);
    await tester.tap(forYou);
    await tester.pumpAndSettle();
    expect(find.text('Local video'), findsOneWidget);
    expect(calls, isNotEmpty);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await tester.pumpAndSettle();
    final ranked = calls.length;
    playbackHistoryRevision.value++;
    await tester.pumpAndSettle();
    expect(calls, hasLength(ranked));
    expect(find.text('Local video'), findsNothing);
    expect(find.text('Configured feed'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('enabling only a topic from all-off resolves it locally',
      (tester) async {
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await show(tester);
    expect(calls, isEmpty);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.topicId('science'),
            ])));
    await tester.pumpAndSettle();
    final chip = find.byKey(const ValueKey('flow-interest-science'));
    expect(chip, findsOneWidget);
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    expect(find.byKey(const ValueKey('video-home-for-you')), findsNothing);
    expect(calls, hasLength(1));
    expect(api.requests, 0, reason: 'Config reconciliation is local only');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saved topic chips resolve while Your feeds is selected',
      (tester) async {
    await tester.runAsync(() => remember('video000001', 'Local science', 0));
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.topicId('science'),
            ])));
    await show(tester, configuredFeed: const Text('Configured feed'));
    expect(find.text('Configured feed'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-interest-science')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-home-for-you')), findsNothing);
    expect((calls.single.arguments as Map)['candidates'],
        contains(predicate((dynamic value) => value['id'] == 'video000001')));
    expect(api.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'cold saved topic stays selected without an implicit remote fetch',
      (tester) async {
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(() async {
      await remember('video000001', 'Unfiltered local item', 0);
      await settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
        HomeTabsLayout.topicId('science'),
      ]));
    });
    await show(tester);
    final chip = find.byKey(const ValueKey('flow-interest-science'));
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    expect(find.text('Unfiltered local item'), findsNothing);
    expect(find.text('Discover videos'), findsOneWidget);
    expect(calls, hasLength(1));
    expect(api.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('adding a topic keeps the selected Your feeds page',
      (tester) async {
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(() => settings.setHomeTabsLayout(
        HomeTabsLayout(enabledOrder: [HomeTabsLayout.yourFeeds])));
    await show(tester, configuredFeed: const Text('Configured feed'));
    expect(calls, isEmpty);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.topicId('science'),
            ])));
    await tester.pumpAndSettle();
    expect(find.text('Configured feed'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-interest-science')), findsOneWidget);
    expect(api.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fallback in [HomeTabsLayout.forYou, HomeTabsLayout.yourFeeds]) {
    testWidgets('missing saved topic restores $fallback content',
        (tester) async {
      await tester.runAsync(() => remember('video000001', 'Local video', 0));
      await tester.runAsync(
          () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
                HomeTabsLayout.topicId('missing'),
                fallback,
              ])));
      await show(tester, configuredFeed: const Text('Configured feed'));
      expect(
          find.text(fallback == HomeTabsLayout.forYou
              ? 'Local video'
              : 'Configured feed'),
          findsOneWidget);
      expect(api.requests, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('TV skips unsupported Your feeds and preserves empty recovery',
      (tester) async {
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.forYou,
            ])));
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    await show(tester, television: true);
    expect(find.text('Local video'), findsOneWidget);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-tabs-edit')), findsOneWidget);
    expect(find.text('Local video'), findsNothing);
    expect(Focus.of(tester.element(find.byIcon(Icons.edit))).hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'opening For you ranks local metadata without loading remote feeds',
      (tester) async {
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    await show(tester);
    expect(api.requests, 0);
    expect(calls, isNotEmpty);
    expect(find.text('Local video'), findsOneWidget);
    expect(find.text('Discover videos'), findsOneWidget);
    final card = find.byKey(const ValueKey('flow-video-video000001'));
    final overflow = find.descendant(
      of: card,
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.tap(overflow);
    await tester.pumpAndSettle();
    expect(find.text('Why this?'), findsOneWidget);
    await tester.tap(find.text('Why this?'));
    await tester.pumpAndSettle();
    expect(find.text('Matches your local video interests.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only cards with active viewport dwell count as impressions',
      (tester) async {
    await tester.runAsync(() async {
      for (var index = 1; index <= 8; index++) {
        await remember('candidate0$index', 'Candidate $index', 0);
      }
    });
    final lifecycle = tester.binding.lifecycleState;
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(
        lifecycle ?? AppLifecycleState.detached));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await show(tester);
    VisibilityDetectorController.instance.notifyNow();
    final viewport = tester.getRect(find.byType(CustomScrollView).first);
    final halfVisibleIds = <String>{};
    for (var index = 1; index <= 8; index++) {
      final id = 'candidate0$index';
      final card = find.byKey(ValueKey('flow-video-$id'));
      if (card.evaluate().isEmpty) continue;
      final bounds = tester.getRect(card);
      final visible = bounds.intersect(viewport);
      if (visible.width > 0 && visible.height * 2 >= bounds.height) {
        halfVisibleIds.add(id);
      }
    }
    expect(halfVisibleIds, isNotEmpty);
    expect(halfVisibleIds.length, lessThan(8));

    Iterable<String> impressions() sync* {
      for (final call in calls) {
        final events = (call.arguments as Map)['events'] as List? ?? const [];
        for (final event in events.whereType<Map>()) {
          if (event['type'] == 'impression') {
            yield (event['candidate'] as Map)['id'] as String;
          }
        }
      }
    }

    await tester.pump(const Duration(milliseconds: 750));
    expect(impressions(), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 500));
    expect(impressions(), isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 80));
    expect(impressions().toSet(), halfVisibleIds);
    expect(impressions().length, halfVisibleIds.length);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty local history gives an explicit discovery action',
      (tester) async {
    await show(tester);
    expect(api.requests, 0);
    expect(
        find.text('Watch or save videos to shape your local recommendations.'),
        findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('video-home-discover')));
    await tester.tap(find.byKey(const ValueKey('video-home-discover')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-discovery-query')), findsOneWidget);
    expect(api.requests, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'For you uses existing follows before playback and drops unfollows',
      (tester) async {
    const server = Server(url: 'https://invidious.example');
    const channelId = 'UCaaaaaaaaaaaaaaaaaaaaaa';
    await tester.runAsync(() async {
      await db.upsertServer(server);
      await db.useServer(server);
      await db.addOfflineSubscription(const OfflineSubscription(
          channelId: channelId, channelName: 'Existing follow'));
    });
    // Make the active session visible to the same guarded source on device.
    app.setServer(server);
    api.discoveryResults = (_) => const [
          Video(
              videoId: 'followed001',
              title: 'Video from an existing follow',
              authorId: channelId),
        ];
    await show(tester);
    expect(api.requests, 1);
    expect(find.text('Video from an existing follow'), findsOneWidget);
    final warmed = calls.last.arguments as Map;
    expect(warmed['subscriptionChannels'], [
      {'id': channelId, 'name': 'Existing follow'},
    ]);
    expect(warmed['events'], isEmpty);

    await tester.runAsync(() => db.deleteOfflineSubscription(channelId));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    expect(find.text('Video from an existing follow'), findsNothing);
    expect((calls.last.arguments as Map)['subscriptionChannels'], isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing native engine shows unranked local items honestly',
      (tester) async {
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (_) async => throw MissingPluginException());
    await show(tester);
    expect(find.text('Local video'), findsOneWidget);
    expect(find.text('Why this?'), findsNothing);
    final locals =
        AppLocalizations.of(tester.element(find.byType(FlowVideoHome)))!;
    expect(find.text(locals.flowRecommendationUnavailable), findsOneWidget);
    expect(api.requests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit discovery admits subscribed videos with a full history',
      (tester) async {
    const account =
        Server(url: 'https://invidious.example', authToken: 'test-only');
    await tester.runAsync(() async {
      await db.upsertServer(account);
      await db.useServer(account);
      for (var i = 0; i < 80; i++) {
        await remember('local${i.toString().padLeft(6, '0')}', 'Local $i', 0);
      }
    });
    app.setServer(account);
    api.follows = [
      Subscription('Followed creator', 'UCaaaaaaaaaaaaaaaaaaaaaa')
    ];
    discoveryQueries = ['first interest', 'second interest'];
    api.discoveryResults = (query) {
      if (query == null) {
        return const [
          Video(
              videoId: 'followed001',
              title: 'Followed video',
              authorId: 'UCaaaaaaaaaaaaaaaaaaaaaa'),
        ];
      }
      final prefix = query == discoveryQueries.first ? 'first' : 'other';
      return [
        for (var i = 0; i < 20; i++)
          Video(
              videoId: '$prefix${i.toString().padLeft(6, '0')}',
              title: 'Discovery result $i'),
      ];
    };
    await show(tester);
    final firstRank = (calls.last.arguments as Map)['candidates'] as List;
    expect(firstRank, hasLength(81));
    expect(api.requests, 1);
    await tester
        .ensureVisible(find.byKey(const ValueKey('video-home-discover')));
    await tester.tap(find.byKey(const ValueKey('video-home-discover')));
    await tester.pumpAndSettle();
    expect(api.requests, 3);
    final ranked = (calls.last.arguments as Map)['candidates'] as List;
    expect(ranked, hasLength(100));
    expect(
        ranked
            .whereType<Map>()
            .singleWhere((row) => row['id'] == 'followed001')['isSubscribed'],
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('deactivating Home discards a pending local ranking',
      (tester) async {
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    final pending = Completer<Map<String, Object?>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    await show(tester, settle: false);
    await tester.pump();
    await show(tester, active: false);
    pending.complete({
      'state': <String, Object?>{},
      'ranked': [
        {'id': 'video000001', 'score': 1.0, 'reason': 'Old result'}
      ]
    });
    await tester.pumpAndSettle();
    expect(find.text('Local video'), findsNothing);
    expect(find.text('Why this?'), findsNothing);
    expect(api.requests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small phone with large text keeps resumed cards scrollable',
      (tester) async {
    await tester.runAsync(() =>
        settings.setHomeTabsLayout(HomeTabsLayout(continueWatching: true)));
    await tester.runAsync(
        () => remember('resume00001', 'Resume a long video title', 0.4));
    await show(tester, scale: 2);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV reranking keeps D-pad targets matched to displayed cards',
      (tester) async {
    await tester.runAsync(() async {
      await remember('video000001', 'First video', 0);
      await remember('video000002', 'Second video', 0);
    });
    var reverse = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final candidates = (call.arguments as Map)['candidates'] as List;
      return {
        'state': <String, Object?>{},
        'ranked': [
          for (final candidate in reverse ? candidates.reversed : candidates)
            {'id': (candidate as Map)['id'], 'score': 1.0, 'reason': 'Local'}
        ],
      };
    });
    await show(tester, television: true);
    final before = tester
        .widgetList<TvVideoItem>(find.byType(TvVideoItem))
        .map((card) => card.video.videoId)
        .toList();
    expect(before, hasLength(2));
    reverse = true;
    await tester.runAsync(() =>
        RecommendationService.forProfile(db, db.profileId)
            .setLearningEnabled(RecommendationDomain.video, true));
    await tester.pump();
    // Database notifications launch work in the real async zone. Let the
    // mocked platform reply return there before settling animation frames.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final cards = tester.widgetList<TvVideoItem>(find.byType(TvVideoItem));
    expect(cards.map((card) => card.video.videoId), before.reversed);
    for (final card in cards) {
      final builder = find.descendant(
          of: find.byWidget(card),
          matching:
              find.byType(BlocBuilder<VideoInListCubit, VideoInListState>));
      // TvVideoItem's D-pad handler opens this cubit's retained video.
      final target =
          tester.element(builder).read<VideoInListCubit>().state.video;
      expect(target?.videoId, card.video.videoId);
      expect(target?.title, card.video.title);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local exclusions hide a card before pending reranking completes',
      (tester) async {
    await tester.runAsync(() async {
      await remember('video000001', 'Exclude this video', 0);
      await remember('video000002', 'Keep this video', 0);
    });
    await show(tester, television: true);
    expect(find.text('Exclude this video'), findsOneWidget);
    expect(find.text('Keep this video'), findsOneWidget);
    final pending = Completer<Map<String, Object?>>();
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete({'state': <String, Object?>{}, 'ranked': <Object?>[]});
      }
    });
    var waiting = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final events = (call.arguments as Map)['events'] as List;
      if (events.isNotEmpty) {
        return {'state': <String, Object?>{}, 'ranked': <Object?>[]};
      }
      waiting = true;
      return pending.future;
    });
    await tester.runAsync(() =>
        RecommendationService.forProfile(db, db.profileId).feedback(
            const Video(videoId: 'video000001', title: 'Exclude this video'),
            RecommendationDomain.video,
            RecommendationFeedback.notInterested));
    await tester.pump();
    await tester.pump();
    expect(waiting, isTrue);
    expect(find.text('Exclude this video'), findsNothing);
    expect(find.text('Keep this video'), findsOneWidget);
    pending.complete({
      'state': <String, Object?>{},
      'ranked': [
        {'id': 'video000002', 'score': 1.0, 'reason': 'Local'}
      ],
    });
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
