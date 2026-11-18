import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/channels/views/components/info.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

class _ChannelService extends Service {
  int infoRequests = 0;
  final videoRequests = <(String?, ChannelSortBy)>[];

  @override
  Future<Channel> getChannel(String channelId,
      {bool saveLastSeen = true, Server? serverOverride}) async {
    infoRequests++;
    return Channel(
        'Flow test channel',
        channelId,
        '/@flowtest',
        [],
        [],
        1200,
        null,
        null,
        false,
        null,
        'Private channel description.',
        null,
        [
          const Video(
              videoId: 'featured001',
              title: 'Featured video',
              author: 'Creator'),
        ]);
  }

  @override
  Future<VideosWithContinuation> getChannelVideos(
      String channelId, String? continuation,
      {bool saveLastSeen = true,
      Server? serverOverride,
      ChannelSortBy sortBy = ChannelSortBy.newest}) async {
    videoRequests.add((continuation, sortBy));
    return VideosWithContinuation(
      List.generate(
        14,
        (i) => Video(
            videoId: 'entry-$continuation-$i',
            title: 'Channel upload $i',
            author: 'Creator'),
      ),
      continuation == null ? 'next' : null,
    );
  }

  @override
  Future<bool> isLoggedIn() async => false;
}

void main() {
  testWidgets('channel tabs share a collapsing header and keep pagination',
      (tester) async {
    tester.view.physicalSize = const Size(400, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _ChannelService();
    final database = await tester.runAsync(SembastSqfDb.createInMemory);
    db = database!;
    service = api;
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final player = TestPlayerCubit(PlayerState.init(null), settings);
    final router = RootStackRouter.build(routes: [
      AutoRoute(
          page: ChannelRoute.page,
          path: '/channel/:channelId',
          children: [
            AutoRoute(page: ChannelInfoRoute.page),
            AutoRoute(page: ChannelVideoRoute.page),
            AutoRoute(page: ChannelShortsRoute.page),
            AutoRoute(page: ChannelStreamRoute.page),
            AutoRoute(page: ChannelPlaylistsRoute.page),
          ]),
    ]);
    addTearDown(() async {
      router.dispose();
      await player.close();
      await settings.close();
      await app.close();
      await database.close();
    });
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp.router(
        routerConfig: router.config(
          deepLinkBuilder: (_) =>
              DeepLink([ChannelRoute(channelId: 'fixture-channel')]),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();
    final header = find.byType(ChannelHeader);
    final tabs = find.byType(TabBar);
    expect(find.text('Featured video'), findsOneWidget);
    expect(header, findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(api.videoRequests, isEmpty);

    await tester.tap(find.text('Videos'));
    await tester.pumpAndSettle();
    expect(find.text('Channel upload 0'), findsOneWidget);
    expect(api.infoRequests, 1);
    expect(api.videoRequests, [(null, ChannelSortBy.newest)]);
    final headerTitle =
        find.descendant(of: header, matching: find.text('Flow test channel'));
    expect(headerTitle.hitTestable(), findsOneWidget);
    final grid = find.byType(GridView);
    await tester.drag(grid, const Offset(0, -450));
    await tester.pumpAndSettle();
    // A collapsed header can be outside the lazy viewport altogether.
    expect(headerTitle.hitTestable(), findsNothing);
    expect(tabs.hitTestable(), findsOneWidget);

    for (var i = 0; i < 9 && api.videoRequests.length == 1; i++) {
      await tester.drag(grid, const Offset(0, -520));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
    }
    expect(api.videoRequests.last, ('next', ChannelSortBy.newest));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
