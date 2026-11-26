import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/views/screens/subscription_tab.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/subscription_management/models/subscription.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

const _sharedId = 'UCabcdefghijklmnopqrstuv';
const _otherId = 'UCABCDEFGHIJKLMNOPQRSTUV';

class _SubscriptionService extends Service {
  final pages = <int>[];
  final subscriptions = [
    Subscription('Shared channel', _sharedId),
    Subscription('Other channel', _otherId),
  ];

  @override
  Future<bool> isLoggedIn() async => true;

  @override
  Future<List<Subscription>> getSubscriptions() async => subscriptions;

  @override
  Future<UserFeed> getUserFeed(
      {int? maxResults,
      int? page,
      bool saveLastSeen = true,
      Server? serverOverride}) async {
    final requested = page ?? 1;
    pages.add(requested);
    return UserFeed([], [
      if (requested == 2)
        const Video(
            videoId: 'first-shared',
            title: 'First shared upload',
            authorId: _sharedId),
      if (requested == 4)
        const Video(
            videoId: 'later-shared',
            title: 'Later shared upload',
            authorUrl: '/channel/$_sharedId'),
      if (requested < 4)
        for (var i = 0; i < (requested == 2 ? 49 : 50); i++)
          Video(
              videoId: 'other-$requested-$i',
              title: 'Other upload $requested/$i',
              published: 10000 - requested * 100 - i,
              authorId: _otherId),
    ]);
  }

  @override
  Future<VideosWithContinuation> getChannelVideos(
    String channelId,
    String? continuation, {
    bool saveLastSeen = true,
    Server? serverOverride,
    ChannelSortBy sortBy = ChannelSortBy.newest,
  }) async =>
      VideosWithContinuation([], null);
}

void main() {
  late Service oldService;
  late SembastSqfDb database;
  late _SubscriptionService fake;

  setUp(() async {
    oldService = service;
    fake = _SubscriptionService();
    service = fake;
    database = await createPlayerTestDatabase();
    db = database;
    await db.addOfflineSubscription(const OfflineSubscription(
        channelId: _sharedId, channelName: 'Local channel name'));
  });

  tearDown(() async {
    await database.close();
    service = oldService;
  });

  testWidgets('subscription tab creates overlapping groups and pages past gaps',
      (tester) async {
    final app = TestAppCubit(AppState(0, null, HomeLayout()))
      ..intentDataStreamSubscription =
          const Stream<void>.empty().listen((_) {});
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final player = TestPlayerCubit(PlayerState.init(null), settings);
    addTearDown(() async {
      await player.close();
      await settings.close();
      await app.close();
    });

    await tester.pumpWidget(BlocProvider<PlayerCubit>.value(
      value: player,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SubscriptionTab()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(fake.pages, [1]);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Ungrouped'), findsOneWidget);

    Finder groupMenu() => find.byTooltip('Manage channel groups');
    Finder chip(String name) =>
        find.ancestor(of: find.text(name), matching: find.byType(ChoiceChip));
    Future<void> settleAfterWrite() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }

    Future<void> createGroup(String name) async {
      await tester.tap(groupMenu());
      await tester.pumpAndSettle();
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), name);
      final member =
          find.byKey(const ValueKey('subscription-group-channel-$_sharedId'));
      expect(member, findsOneWidget);
      await tester.ensureVisible(member);
      await tester.tap(member);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settleAfterWrite();
      expect(find.byType(TextField), findsNothing);
      expect(chip(name), findsOneWidget);
    }

    Future<void> loadMore() async {
      final action = find.text('Load more');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    await createGroup('Learning');
    await createGroup('Favorites');
    await tester.tap(chip('Learning'));
    await tester.pumpAndSettle();
    expect(find.text('Other upload 1/0'), findsNothing);
    expect(find.text('First shared upload'), findsNothing);
    await loadMore();
    expect(find.text('First shared upload'), findsOneWidget);
    expect(fake.pages, [1, 2]);

    await tester.tap(chip('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('First shared upload'), findsOneWidget);
    await loadMore();
    expect(find.text('First shared upload'), findsOneWidget);
    expect(find.text('Later shared upload'), findsNothing);
    await loadMore();
    expect(find.text('Later shared upload'), findsOneWidget);
    expect(fake.pages, [1, 2, 3, 4]);

    await tester.tap(groupMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Favorites'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('confirm-delete-subscription-group')));
    await settleAfterWrite();
    expect(chip('Favorites'), findsNothing);
    expect(tester.widget<ChoiceChip>(chip('All')).selected, isTrue);
    final subscriptions = (await tester.runAsync(db.getOfflineSubscriptions))!;
    expect(subscriptions.single.channelId, _sharedId);
    expect(
        fake.subscriptions.map((sub) => sub.authorId), [_sharedId, _otherId]);

    await tester.tap(chip('Ungrouped'));
    await tester.pumpAndSettle();
    expect(find.text('Other upload 1/0'), findsOneWidget);
    expect(find.text('First shared upload'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
