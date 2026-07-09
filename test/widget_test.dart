import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'test_app_cubit.dart';
import 'test_player_cubit.dart';
import 'test_settings_cubit.dart';

class _EmptyService extends Service {
  @override
  void syncHistory() {}

  @override
  Future<bool> isLoggedIn() async => true;

  @override
  Future<List<Video>> getTrending({String? type}) async => [];

  @override
  Future<List<Video>> getPopular() async => [];

  @override
  Future<UserFeed> getUserFeed(
          {int? maxResults, int? page, bool saveLastSeen = true}) async =>
      UserFeed([], []);

  @override
  Future<List<Playlist>> getUserPlaylists({bool postProcessing = true}) async =>
      [];

  @override
  Future<List<String>> getUserHistory(int page, int maxResults) async => [];

  @override
  Future<VideosWithContinuation> getChannelVideos(
          String channelId, String? continuation,
          {bool saveLastSeen = true,
          ChannelSortBy sortBy = ChannelSortBy.newest}) async =>
      VideosWithContinuation([], null);
}

Future<void> _pumpHomepage(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final appCubit = TestAppCubit(AppState(0, null, HomeLayout()));
  final settingsCubit = TestSettingsCubit(SettingsState.init(), appCubit);

  await tester.pumpWidget(MultiBlocProvider(
    providers: [
      BlocProvider<AppCubit>.value(value: appCubit),
      BlocProvider<SettingsCubit>.value(value: settingsCubit),
      BlocProvider<PlayerCubit>(
        create: (context) =>
            TestPlayerCubit(PlayerState.init(null), settingsCubit),
      ),
      BlocProvider<DownloadManagerCubit>(
        create: (context) => DownloadManagerCubit(
            const DownloadManagerState(), context.read<PlayerCubit>()),
      ),
    ],
    child: MaterialApp.router(
      routerConfig: appRouter.config(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  ));

  await tester.pumpAndSettle();
}

ScrollPosition _tabPosition(WidgetTester tester) {
  return tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .map((state) => state.position)
      .singleWhere((position) =>
          position.axis == Axis.horizontal &&
          (position.maxScrollExtent - position.viewportDimension * 3).abs() <
              0.01);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    app_main.isTv = false;
    globals.service = _EmptyService();
    globals.packageInfo = PackageInfo(
        appName: 'Videre',
        packageName: 'com.github.lamarios.clipious',
        version: '1.0.0',
        buildNumber: '1');
    globals.db = await SembastSqfDb.createInMemory();

    final server = Server(url: 'https://example.com', sidCookie: 'SID=test');
    await globals.db.upsertServer(server);
    await globals.db.useServer(server);
    appRouter = AppRouter(hasServer: true);
  });

  tearDown(() async {
    await globals.db.close();
  });

  testWidgets('phone homepage tabs swipe fluidly and bounce at both edges',
      (tester) async {
    await _pumpHomepage(tester, const Size(390, 844));
    final tabPosition = _tabPosition(tester);

    void expectSelectedTab(int index) {
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        index,
      );
    }

    Future<void> swipeLeft() async {
      await tester.dragFrom(const Offset(350, 400), const Offset(-320, 0));
      await tester.pumpAndSettle();
    }

    Future<void> swipeRight() async {
      await tester.dragFrom(const Offset(40, 400), const Offset(320, 0));
      await tester.pumpAndSettle();
    }

    expectSelectedTab(0);

    final leadingEdgeDrag = await tester.startGesture(const Offset(40, 400));
    await leadingEdgeDrag.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(tabPosition.pixels, lessThan(0));
    await leadingEdgeDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(0);

    final pageDrag = await tester.startGesture(const Offset(350, 400));
    await pageDrag.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(
        tabPosition.pixels, inExclusiveRange(0, tabPosition.viewportDimension));
    await pageDrag.moveBy(const Offset(-200, 0));
    await pageDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(1);
    await swipeLeft();
    expectSelectedTab(2);
    await swipeLeft();
    expectSelectedTab(3);

    final trailingEdgeDrag = await tester.startGesture(const Offset(350, 400));
    await trailingEdgeDrag.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(tabPosition.pixels, greaterThan(tabPosition.maxScrollExtent));
    await trailingEdgeDrag.up();
    await tester.pumpAndSettle();
    expectSelectedTab(3);

    await swipeRight();
    expectSelectedTab(2);
    await swipeRight();
    expectSelectedTab(1);
    await swipeRight();
    expectSelectedTab(0);
  });

  testWidgets('tablet homepage tabs ignore horizontal swipes', (tester) async {
    await _pumpHomepage(tester, const Size(1024, 768));
    final tabPosition = _tabPosition(tester);

    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        0);
    await tester.dragFrom(const Offset(900, 400), const Offset(-800, 0));
    await tester.pumpAndSettle();

    expect(tabPosition.pixels, 0);
    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        0);
  });
}
