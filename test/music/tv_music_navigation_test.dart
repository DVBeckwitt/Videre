import 'package:clipious/app/states/app.dart';
import 'package:clipious/app/views/tv/screens/tv_home.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/content_mode.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/views/components/content_mode_selector.dart';
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
import 'package:clipious/settings/views/components/home_experience_setting.dart';
import 'package:clipious/settings/views/tv/screens/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  @override
  bool get isLoggedIn => false;

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

  @override
  Future<void> setHomeExperience(HomeExperience experience) async {
    emit(state.copyWith(settings: {
      ...state.settings,
      homeExperienceSettingName:
          SettingsValue(homeExperienceSettingName, experience.name),
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

  Finder modeLabel(String label) => find.descendant(
      of: find.byType(ContentModeSelector), matching: find.text(label));

  Future<void> select(WidgetTester tester, Finder label) async {
    Focus.of(tester.element(label)).requestFocus();
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

  testWidgets('TV mode selector and Music sidebar respond to remote keys',
      (tester) async {
    await mount(tester);
    expect(catalog.trendingCalls, 0,
        reason: 'Video browsing must not load hidden Music pages');
    expect(
        Focus.of(tester.element(find.byIcon(Icons.search))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(modeLabel('Videos'))).hasFocus, isTrue,
        reason: 'The visible switch must be reachable from the video menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(modeLabel('Music'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(settings.state.homeContentMode, HomeContentMode.music);
    expect(find.byType(MusicHomePage), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(musicSearchIcon())).hasFocus, isTrue,
        reason: 'Music search stays reachable from the top bar');
    expect(tester.getRect(modeLabel('Videos')).top, greaterThanOrEqualTo(0));
    expect(tester.getRect(modeLabel('Music')).right, lessThanOrEqualTo(960));

    final home = musicMenuIcon(Icons.home_outlined, 0);
    Focus.of(tester.element(home)).requestFocus();
    await tester.pumpAndSettle();
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('Music query and scroll survive switching modes with no refetch',
      (tester) async {
    settings.setVideoLayout([HomeDataSource.history, HomeDataSource.search]);
    await mount(tester);
    await select(tester, modeLabel('Music'));
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

    await select(tester, modeLabel('Videos'));
    expect(find.byType(MusicScreen), findsNothing);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.byIcon(Icons.subscriptions), findsNothing,
        reason: 'The customized video menu must remain unchanged');
    final hiddenSong = find.text('kept song 4', skipOffstage: false).last;
    expect(Focus.of(tester.element(hiddenSong)).canRequestFocus, isFalse);
    await select(tester, modeLabel('Music'));
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
    await select(tester, modeLabel('Music'));
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

  testWidgets('TV ignores a Home experience choice from an older session',
      (tester) async {
    await settings.setHomeExperience(HomeExperience.musicOnly);
    final router = AppRouter(hasServer: true);
    addTearDown(router.dispose);
    await mount(tester, router: router);
    await select(tester, find.byIcon(Icons.settings));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    appCubit.setSession(appCubit.state.copyWith(sessionRevision: 1));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(settings.state.homeExperience, HomeExperience.musicOnly);
    expect(tester.takeException(), isNull);
  });

  for (final experience in [
    HomeExperience.videosOnly,
    HomeExperience.musicOnly,
  ]) {
    testWidgets('TV $experience hides the selector and Settings restores it',
        (tester) async {
      await settings.setHomeContentMode(experience == HomeExperience.videosOnly
          ? HomeContentMode.music
          : HomeContentMode.videos);
      await settings.setHomeExperience(experience);
      final router = AppRouter(hasServer: true);
      addTearDown(router.dispose);
      await mount(tester, router: router);
      expect(find.byType(ContentModeSelector), findsNothing);
      if (experience == HomeExperience.musicOnly) {
        expect(find.byType(MusicHomePage), findsOneWidget);
        expect(videoService.videoRequests, 0,
            reason: 'Music-only startup must not load hidden video feeds');
        expect(find.byIcon(Icons.history), findsNothing);
      } else {
        expect(find.byIcon(Icons.history), findsOneWidget);
        expect(catalog.trendingCalls, 0);
        expect(find.byType(MusicHomePage, skipOffstage: false), findsNothing);
      }

      final locals =
          AppLocalizations.of(tester.element(find.byType(TvHomeScreen)))!;
      await select(tester, find.byIcon(Icons.settings));
      expect(find.byType(TVSettingsScreen), findsOneWidget);
      final setting = find.text(locals.homeExperience);
      expect(
          Focus.of(tester.element(
                  find.ancestor(of: setting, matching: find.byType(ListTile))))
              .hasFocus,
          isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final dualMode =
          find.text(homeExperienceLabel(HomeExperience.videosAndMusic, locals));
      expect(
          Focus.of(tester.element(
                  find.ancestor(of: dualMode, matching: find.byType(ListTile))))
              .hasFocus,
          isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(settings.state.homeExperience, HomeExperience.videosAndMusic);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ContentModeSelector), findsOneWidget);
      expect(Focus.of(tester.element(find.byIcon(Icons.settings))).hasFocus,
          isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
