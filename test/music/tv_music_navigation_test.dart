import 'package:clipious/app/states/app.dart';
import 'package:clipious/app/views/tv/screens/tv_home.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/content_mode.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/views/screens/home_tabs_editor.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/screens/music_discovery.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/tv/screens/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../podcasts/fake_podcast_player.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  @override
  bool get isLoggedIn => false;

  @override
  bool tryOpenPastedAppLink(String text) => false;

  void setSession(AppState value) => emit(value);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings() : super(SettingsState.init());

  @override
  Future<void> setHomeContentMode(HomeContentMode mode) async {
    emit(state.copyWith(settings: {
      ...state.settings,
      homeContentModeSettingName:
          SettingsValue(homeContentModeSettingName, mode.name),
    }));
  }

  void seedLegacyHomeExperience(String experience) {
    emit(state.copyWith(settings: {
      ...state.settings,
      homeExperienceSettingName:
          SettingsValue(homeExperienceSettingName, experience),
    }));
  }

  @override
  String? getLocaleDisplayName() => null;

  @override
  String getThemeLabel(AppLocalizations locals, ThemeMode theme) =>
      locals.followSystem;

  void setVideoLayout(List<HomeDataSource> pages) {
    emit(state.copyWith(settings: {
      ...state.settings,
      tvAppLayoutSettingName: SettingsValue(
          tvAppLayoutSettingName, pages.map((page) => page.name).join(',')),
    }));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service extends Service {
  int videoRequests = 0;

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<List<Video>> getTrending({String? type}) async {
    videoRequests++;
    return [];
  }

  @override
  Future<List<Video>> getPopular() async {
    videoRequests++;
    return [];
  }
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  @override
  final podcasts = FakePodcastPlayer();

  @override
  Future<void> close() async {
    podcasts.dispose();
    await super.close();
  }

  @override
  PlaybackSession? get savedSession => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Catalog extends MusicCatalogService {
  int trendingCalls = 0;
  int searchCalls = 0;

  @override
  Future<List<MusicTrack>> getTrendingSongs() async {
    trendingCalls++;
    return List.generate(
        18,
        (index) =>
            MusicTrack(videoId: 'song000000$index', title: 'Song $index'));
  }

  @override
  Future<List<MusicTrack>> searchSongs(String query) async {
    searchCalls++;
    return List.generate(
        18,
        (index) => MusicTrack(
                videoId: 'song000000$index',
                title: '$query song $index',
                artists: const [
                  'Music channel'
                ],
                artistLinks: const [
                  MusicArtist(id: 'UCmusic', name: 'Music channel')
                ]));
  }

  @override
  Future<MusicArtistPage> getArtist(String id) async => const MusicArtistPage(
      artist: MusicArtist(id: 'UCmusic', name: 'Music channel'),
      description: 'Channel detail');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service previousService;
  late MusicCatalogService previousCatalog;
  late bool previousIsTv;
  late _App appCubit;
  late _Settings settings;
  late _Catalog catalog;
  late _Service videoService;
  late _Player player;

  setUp(() async {
    previousService = service;
    previousCatalog = musicCatalogService;
    previousIsTv = app.isTv;
    service = videoService = _Service();
    musicCatalogService = catalog = _Catalog();
    app.isTv = true;
    db = await SembastSqfDb.createInMemory();
    appCubit = _App();
    settings = _Settings();
    player = _Player();
  });

  tearDown(() async {
    await settings.close();
    await player.close();
    await appCubit.close();
    await db.close();
    service = previousService;
    musicCatalogService = previousCatalog;
    app.isTv = previousIsTv;
  });

  Future<void> mount(WidgetTester tester, {AppRouter? router}) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (router != null) {
      await tester.runAsync(
          () => db.upsertServer(const Server(url: 'https://tv-music.example')));
    }
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: appCubit),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: router == null
          ? MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const TvHomeScreen(),
            )
          : MaterialApp.router(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router.config(),
            ),
    ));
    await tester.pumpAndSettle();
    if (router != null) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }
  }

  Finder modeDestination(HomeContentMode mode) =>
      find.byKey(ValueKey('tv-home-${mode.name}'));

  Finder modeIcon(HomeContentMode mode) => find.descendant(
      of: modeDestination(mode),
      matching: find.byIcon(mode == HomeContentMode.music
          ? Icons.music_note
          : Icons.ondemand_video));

  Future<void> select(WidgetTester tester, Finder control) async {
    Focus.of(tester.element(control)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
  }

  Finder musicMenuIcon(IconData icon, int index) => find.descendant(
      of: find.byKey(ValueKey('tv-music-page-$index')),
      matching: find.byIcon(icon));

  Finder musicSearchIcon() => find.descendant(
      of: find.byKey(const ValueKey('tv-music-search')),
      matching: find.byIcon(Icons.search));

  testWidgets('TV sidebar Music and Videos destinations respond to the remote',
      (tester) async {
    await mount(tester);
    expect(catalog.trendingCalls, 0,
        reason: 'Video browsing must not load hidden Music pages');
    expect(find.byType(SegmentedButton<HomeContentMode>), findsNothing);
    final videoSearch = find.descendant(
        of: find.byKey(const ValueKey('tv-home-page-search')),
        matching: find.byIcon(Icons.search));
    final music = modeIcon(HomeContentMode.music);
    expect(
        tester.getCenter(music).dy, lessThan(tester.getCenter(videoSearch).dy));
    expect(Focus.of(tester.element(videoSearch)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(music)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(settings.state.homeContentMode, HomeContentMode.music);
    expect(find.byType(MusicHomePage), findsOneWidget);
    expect(modeDestination(HomeContentMode.videos), findsOneWidget);

    final home = musicMenuIcon(Icons.home_outlined, 0);
    expect(Focus.of(tester.element(home)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(musicMenuIcon(Icons.search, 1))).hasFocus,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(MusicScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(MusicLibraryPage), findsOneWidget);
    expect(find.text('Downloads'), findsNothing);

    for (final icon in [
      Icons.account_circle_outlined,
      Icons.phonelink,
      Icons.settings,
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final item = find.byIcon(icon);
      expect(Focus.of(tester.element(item)).hasFocus, isTrue);
      expect(tester.getRect(item).bottom, lessThanOrEqualTo(540));
    }
    await select(tester, modeIcon(HomeContentMode.videos));
    expect(settings.state.homeContentMode, HomeContentMode.videos);
    expect(find.byType(MusicLibraryPage), findsNothing);
    expect(Focus.of(tester.element(music)).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Music query and scroll survive switching modes with no refetch',
      (tester) async {
    settings.setVideoLayout([HomeDataSource.history]);
    await mount(tester);
    expect(find.byKey(const ValueKey('tv-home-page-search')), findsNothing);
    await select(tester, modeIcon(HomeContentMode.music));
    await select(tester, musicMenuIcon(Icons.search, 1));
    await tester.enterText(find.byKey(const ValueKey('music-search')), 'kept');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final searchState = tester.state(find.byType(MusicScreen));
    final scroll = find.descendant(
        of: find.byType(MusicScreen), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scroll.last).position;
    position.jumpTo(300);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    final offset = position.pixels;
    final calls = catalog.searchCalls;

    await select(tester, modeIcon(HomeContentMode.videos));
    expect(find.byType(MusicScreen), findsNothing);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.byIcon(Icons.subscriptions), findsNothing,
        reason: 'The customized video menu must remain unchanged');
    final hiddenSong = find.text('kept song 4', skipOffstage: false).last;
    expect(Focus.of(tester.element(hiddenSong)).canRequestFocus, isFalse);
    await select(tester, modeIcon(HomeContentMode.music));
    expect(tester.state(find.byType(MusicScreen)), same(searchState));
    expect(position.pixels, offset);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('music-search')))
            .controller!
            .text,
        'kept');
    expect(catalog.searchCalls, calls);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV discards retained Music navigation on a profile change',
      (tester) async {
    await mount(tester);
    await select(tester, modeIcon(HomeContentMode.music));
    await select(tester, musicMenuIcon(Icons.search, 1));
    await tester.enterText(
        find.byKey(const ValueKey('music-search')), 'private');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final before = tester.state(find.byType(MusicScreen));
    final oldScroll = find.descendant(
        of: find.byType(MusicScreen), matching: find.byType(Scrollable));
    tester.state<ScrollableState>(oldScroll.last).position.jumpTo(300);
    await tester.pumpAndSettle();
    appCubit.setSession(appCubit.state
        .copyWith(profileId: 'another-person', sessionRevision: 1));
    await tester.pumpAndSettle();
    expect(before.mounted, isFalse);
    expect(find.byType(MusicScreen, skipOffstage: false), findsNothing);
    expect(find.byType(MusicHomePage), findsOneWidget);
    expect(
        Focus.of(tester.element(musicMenuIcon(Icons.home_outlined, 0)))
            .hasFocus,
        isTrue);
    await select(tester, musicMenuIcon(Icons.search, 1));
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('music-search')))
            .controller!
            .text,
        isEmpty);
    expect(find.text('private song 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV Music search opens remotely and Back restores its results',
      (tester) async {
    await settings.setHomeContentMode(HomeContentMode.music);
    final router = AppRouter(hasServer: true);
    addTearDown(router.dispose);
    await mount(tester, router: router);
    await select(tester, musicSearchIcon());
    expect(find.byType(MusicScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('music-search')), findsOneWidget);
    final before = tester.state(find.byType(MusicScreen));
    await tester.enterText(
        find.byKey(const ValueKey('music-search')), 'remote');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await select(tester, find.text('Music channel').first);
    expect(find.text('Channel detail'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Channel detail'), findsNothing);
    expect(find.text('remote song 0'), findsOneWidget);
    expect(tester.state(find.byType(MusicScreen)), same(before));
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('music-search')))
            .controller!
            .text,
        'remote');
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote opens Home tabs settings and Back restores Settings',
      (tester) async {
    const channel = MethodChannel('videre/recommendations');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        channel, (_) async => {'state': {}, 'ranked': [], 'summary': {}});
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final router = AppRouter(hasServer: true);
    addTearDown(router.dispose);
    await mount(tester, router: router);
    await select(tester, find.byIcon(Icons.settings));
    expect(find.byType(TVSettingsScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final homeTabs = find.text('Home tabs');
    expect(homeTabs, findsOneWidget);
    expect(
        Focus.of(tester.element(
                find.ancestor(of: homeTabs, matching: find.byType(ListTile))))
            .hasFocus,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
    expect(find.byType(HomeTabsEditorScreen), findsOneWidget);
    expect(find.text('Your feeds'), findsNothing);
    expect(find.text('For you'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomeTabsEditorScreen), findsNothing);
    expect(find.byType(TVSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final experience in ['videosOnly', 'musicOnly']) {
    testWidgets('TV ignores legacy $experience and keeps both destinations',
        (tester) async {
      final startMode = experience == 'videosOnly'
          ? HomeContentMode.music
          : HomeContentMode.videos;
      final otherMode = startMode == HomeContentMode.music
          ? HomeContentMode.videos
          : HomeContentMode.music;
      settings.seedLegacyHomeExperience(experience);
      await settings.setHomeContentMode(startMode);
      final router = AppRouter(hasServer: true);
      addTearDown(router.dispose);
      await mount(tester, router: router);
      expect(settings.state.homeContentMode, startMode);
      expect(modeDestination(otherMode), findsOneWidget);
      if (startMode == HomeContentMode.music) {
        expect(find.byType(MusicHomePage), findsOneWidget);
        expect(videoService.videoRequests, 0,
            reason: 'Music startup must not load hidden video feeds');
      } else {
        expect(find.byIcon(Icons.history), findsOneWidget);
        expect(catalog.trendingCalls, 0);
        expect(find.byType(MusicHomePage, skipOffstage: false), findsNothing);
      }

      final locals =
          AppLocalizations.of(tester.element(find.byType(TvHomeScreen)))!;
      await select(tester, find.byIcon(Icons.settings));
      expect(find.byType(TVSettingsScreen), findsOneWidget);
      expect(find.text('Home experience'), findsNothing);
      final navigation = find.text(locals.customizeAppLayout);
      expect(navigation, findsOneWidget);
      expect(
          Focus.of(tester.element(find.ancestor(
                  of: navigation, matching: find.byType(ListTile))))
              .hasFocus,
          isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await select(tester, modeIcon(otherMode));
      expect(settings.state.homeContentMode, otherMode);
      expect(modeDestination(startMode), findsOneWidget);
      expect(find.byType(SegmentedButton<HomeContentMode>), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
