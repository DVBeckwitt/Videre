import 'dart:async';
import 'dart:ui' show SemanticsAction, SemanticsRole;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/service.dart' show Service, VideoLoadObserver;
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';
import 'support/community_filter_fixture.dart';

const artist = MusicArtist(id: 'UCartist', name: 'Artist');

const first = MusicTrack(
    videoId: 'firstsong01',
    title: 'First song',
    artists: ['Artist'],
    artistLinks: [artist],
    albumId: 'MPREalbum',
    albumTitle: 'Album');
const second = MusicTrack(
    videoId: 'secondsong2',
    title: 'Second song',
    artists: ['Artist'],
    albumId: 'MPREalbum',
    albumTitle: 'Album');

class _Catalog extends MusicCatalogService {
  final searches = <String>[];
  final artistSearches = <String>[];
  final playlistSearches = <String>[];
  final suggestionRequests = <({
    String query,
    bool Function()? isCurrent,
    Completer<List<String>> response,
  })>[];
  final pageRequests = <({
    String query,
    MusicCatalogSearchType type,
    int page,
    bool Function()? isCurrent,
    Completer<MusicCatalogSearchPage> response,
  })>[];
  bool paginate = false;
  final responses = <Completer<List<MusicTrack>>>[];
  List<MusicArtist> artistResults = const [artist];
  // Create this in the requesting widget's async zone, not setUp's outer zone.
  late var song = Completer<MusicTrack>();
  VideoLoadObserver? songObserver;
  final songRequests = <String>[];
  final artistRequests = <String>[];
  final releaseRequests = <String?>[];
  final releasePages = <String?, MusicArtistReleases>{};
  Object? releaseFailure;
  final playlistRequests = <String>[];
  Completer<MusicArtistPage>? pendingArtist;
  Completer<MusicCollection>? pendingPlaylist;
  MusicCollection collection = const MusicCollection(
      id: 'PLpublic',
      title: 'Public playlist',
      artists: ['Artist'],
      tracks: [first, second]);

  @override
  Future<List<MusicTrack>> searchSongs(String query) {
    searches.add(query);
    final response = Completer<List<MusicTrack>>();
    responses.add(response);
    return response.future;
  }

  @override
  Future<List<String>> searchSuggestions(String query,
      {bool Function()? isCurrent}) {
    final response = Completer<List<String>>();
    suggestionRequests
        .add((query: query, isCurrent: isCurrent, response: response));
    return response.future;
  }

  @override
  Future<MusicCatalogSearchPage> searchPage(
      String query, MusicCatalogSearchType type, int page,
      {bool Function()? isCurrent}) {
    if (!paginate) {
      return super.searchPage(query, type, page, isCurrent: isCurrent);
    }
    final response = Completer<MusicCatalogSearchPage>();
    pageRequests.add((
      query: query,
      type: type,
      page: page,
      isCurrent: isCurrent,
      response: response,
    ));
    return response.future;
  }

  @override
  Future<List<MusicTrack>> getTrendingSongs() async => [first, second];

  @override
  Future<MusicCollection> getPlaylist(String id) {
    playlistRequests.add(id);
    return pendingPlaylist?.future ?? Future.value(collection);
  }

  @override
  Future<List<MusicArtist>> searchArtists(String query) async {
    artistSearches.add(query);
    return artistResults;
  }

  @override
  Future<List<MusicPlaylist>> searchPlaylists(String query) async {
    playlistSearches.add(query);
    return const [
      MusicPlaylist(
          id: 'PLpublic', title: 'Public playlist', author: 'Curator'),
    ];
  }

  @override
  Future<MusicArtistPage> getArtist(String id) {
    artistRequests.add(id);
    return pendingArtist?.future ??
        Future.value(const MusicArtistPage(
          artist: artist,
          description: 'Artist description',
          songs: [first, second],
        ));
  }

  @override
  Future<MusicArtistReleases> getArtistReleases(String id,
      {String? continuation, bool Function()? isCurrent}) async {
    releaseRequests.add(continuation);
    if (releaseFailure case final error?) throw error;
    return releasePages[continuation] ?? const MusicArtistReleases();
  }

  @override
  Future<MusicTrack> getSong(String id, {VideoLoadObserver? loadObserver}) {
    songRequests.add(id);
    songObserver = loadObserver;
    return song.future;
  }
}

MusicCatalogSearchPage _page(List<MusicCatalogSearchHit> hits,
        {List<String>? rawKeys}) =>
    MusicCatalogSearchPage(
        hits: hits, rawKeys: rawKeys ?? [for (final hit in hits) hit.key]);

class _Player extends TestPlayerCubit {
  final calls = <({
    List<Video> videos,
    bool? audio,
    Duration? startAt,
    String? queueTitle,
    int? startIndex
  })>[];

  _Player(super.initialState, super.settings);

  int resumes = 0;
  bool? resumedFromMusic;
  int shows = 0;
  bool? sponsorFailureIsAsync;
  Completer<void>? playbackStartup;
  bool holdSelections = false;
  final pendingSelections = <Completer<void>>[];
  int _selectionRevision = 0;
  // A committed selection persists the playback session in the fixture DB.
  // Keep those writes on the same real clock as setUp and tearDown.
  final _databaseZone = Zone.current;

  @override
  int get musicSelectionRequestRevision => _selectionRevision;

  void commitSelection(List<Video> videos, int index, {bool mini = false}) {
    final queue = assignPlaybackQueueIds(videos);
    _databaseZone.run(() => emit(state.copyWith(
        videos: queue,
        currentlyPlaying: queue[index],
        isAudio: true,
        isHidden: false,
        isMini: mini,
        isPlaying: true)));
  }

  @override
  Future<List<SponsorSegment>> prepareSponsorSegments(String videoId) {
    final error = StateError('SponsorBlock unavailable');
    return switch (sponsorFailureIsAsync) {
      true => Future.error(error),
      false => throw error,
      null => Future.value([]),
    };
  }

  @override
  Future<void> resumeSession({bool? fromMusic}) async {
    resumes++;
    resumedFromMusic = fromMusic;
  }

  @override
  void showBigPlayer() {
    shows++;
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      bool fromMusic = false}) async {
    _selectionRevision++;
    calls.add((
      videos: videos,
      audio: audio,
      startAt: startAt,
      queueTitle: queueTitle,
      startIndex: startIndex
    ));
    if (holdSelections) {
      final pending = Completer<void>();
      pendingSelections.add(pending);
      await pending.future;
    } else if (playbackStartup case final startup?) {
      commitSelection(videos, startIndex ?? 0);
      await startup.future;
    }
  }

  @override
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      PlaylistLoadSession? playlistLoader,
      bool fromMusic = false}) async {
    calls.add((
      videos: entries,
      audio: audio,
      startAt: startAt,
      queueTitle: reference.displayTitle,
      startIndex: startIndex
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service previousService;
  late MusicCatalogService previousCatalog;
  late _Catalog catalog;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;

  setUpAll(() async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    try {
      // The permission-free search fixtures share the app's library singleton.
      // Complete its one-time startup on the same clock as fixture setup.
      await LocalMusicLibrary.instance.initialize();
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (_) async => throw MissingPluginException());
    isTv = false;
    previousService = service;
    service = Service();
    db = await SembastSqfDb.createInMemory();
    previousCatalog = musicCatalogService;
    musicCatalogService = catalog = _Catalog();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(PlayerState.init(null), settings);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('videre/recommendations'), null);
    musicCatalogService = previousCatalog;
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
  });

  Future<void> show(WidgetTester tester,
      {Widget screen = const MusicScreen()}) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: screen,
      ),
    ));
    await tester.pump();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const ValueKey('music-search')), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
  }

  group('online search suggestions', () {
    const debounce = Duration(milliseconds: 500);
    final field = find.byKey(const ValueKey('music-search'));
    const screen = MusicScreen(embedded: true);

    testWidgets(
        'debounces typing and submits a suggestion to the active filter',
        (tester) async {
      catalog.paginate = true;
      await show(tester, screen: screen);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Channels'));
      await tester.pump();
      await tester.enterText(field, 'night');
      await tester.pump(const Duration(milliseconds: 499));
      expect(catalog.suggestionRequests, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      final request = catalog.suggestionRequests.single;
      expect(request.query, 'night');
      expect(catalog.pageRequests, isEmpty);
      request.response.complete(['night jazz radio']);
      await tester.pump();

      await tester.tap(find.text('night jazz radio'));
      await tester.pump();
      final results = catalog.pageRequests.single;
      expect(results.query, 'night jazz radio');
      expect(results.type, MusicCatalogSearchType.channels);
      expect(results.page, 1);
      results.response.complete(_page(const [MusicCatalogChannelHit(artist)]));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, results.query);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(find.text(artist.name), findsOneWidget);
      await tester.pump(debounce);
      expect(catalog.suggestionRequests, hasLength(1));
    });

    testWidgets('fill puts the suggestion in the field without submitting',
        (tester) async {
      await show(tester, screen: screen);
      await tester.enterText(field, 'brass');
      await tester.pump(debounce);
      catalog.suggestionRequests.single.response.complete(['brass ensemble']);
      await tester.pump();

      await tester.tap(find.byTooltip('Fill search field'));
      await tester.pump();
      final input = tester.widget<TextField>(field);
      expect(input.controller!.text, 'brass ensemble');
      expect(input.controller!.selection,
          TextSelection.collapsed(offset: 'brass ensemble'.length));
      expect(input.focusNode!.hasFocus, isTrue);
      expect(catalog.searches, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('keeps newer suggestions and skips blank or pasted addresses',
        (tester) async {
      await show(tester, screen: screen);
      await tester.enterText(field, 'night');
      await tester.pump(debounce);
      final older = catalog.suggestionRequests.single;
      await tester.enterText(field, 'night jazz');
      await tester.pump(debounce);
      final newer = catalog.suggestionRequests.last;
      expect(newer.query, 'night jazz');
      expect(older.isCurrent!(), isFalse);
      newer.response.complete(['night jazz live']);
      await tester.pump();
      older.response.complete(['night rock']);
      await tester.pump();
      expect(find.text('night jazz live'), findsOneWidget);
      expect(find.text('night rock'), findsNothing);

      await tester.enterText(field, ' ');
      await tester.pump(debounce);
      expect(find.text('night jazz live'), findsNothing);
      await tester.enterText(
          field, 'https://music-instance.test/watch?v=firstsong01');
      await tester.pump(debounce);
      expect(catalog.suggestionRequests.map((request) => request.query),
          ['night', 'night jazz']);
    });

    testWidgets('waits for the IME to commit composing text', (tester) async {
      await show(tester, screen: screen);
      await tester.showKeyboard(field);
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: 'cafe',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4)));
      await tester.pump();
      await tester.pump(debounce);
      expect(catalog.suggestionRequests, isEmpty);

      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: 'cafe', selection: TextSelection.collapsed(offset: 4)));
      await tester.pump();
      await tester.pump(debounce);
      final request = catalog.suggestionRequests.single;
      expect(request.query, 'cafe');
      request.response.complete(['Café live']);
      await tester.pumpAndSettle();
      expect(find.text('Café live'), findsOneWidget);
    });

    testWidgets('dismissing suggestions restores the same Online viewport',
        (tester) async {
      addTearDown(tester.view.resetViewInsets);
      await show(tester, screen: screen);
      await search(tester, 'existing results');
      catalog.responses.single.complete([
        for (var i = 0; i < 30; i++)
          MusicTrack(
              videoId: 'song${i.toString().padLeft(7, '0')}',
              title: 'Existing song $i'),
      ]);
      await tester.pumpAndSettle();
      final viewport =
          find.byKey(const ValueKey('music-search-online-viewport'));
      final scrollable =
          find.descendant(of: viewport, matching: find.byType(Scrollable));
      await tester.drag(viewport, const Offset(0, -420));
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(scrollable);
      final offset = scroll.position.pixels;
      expect(offset, greaterThan(180));

      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pump();
      await tester.enterText(field, 'music offer');
      await tester.pump(debounce);
      catalog.suggestionRequests.single.response
          .complete(['Music offer result']);
      await tester.pumpAndSettle();
      expect(find.text('Music offer result'), findsOneWidget);
      expect(viewport, findsNothing);

      await tester.enterText(field, 'outdated keyboard');
      await tester.pump(debounce);
      final pending = catalog.suggestionRequests.last;
      tester.testTextInput.hide();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(pending.isCurrent!(), isFalse);
      pending.response.complete(['Hidden keyboard result']);
      await tester.pumpAndSettle();
      expect(find.text('Hidden keyboard result'), findsNothing);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(tester.state<ScrollableState>(scrollable), same(scroll));
      expect(scroll.position.pixels, closeTo(offset, 1));

      await tester.enterText(field, 'hardware editing');
      await tester.pump(debounce);
      catalog.suggestionRequests.last.response.complete(['Hardware result']);
      await tester.pumpAndSettle();
      expect(find.text('Hardware result'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Hardware result'), findsNothing);
      expect(scroll.position.pixels, closeTo(offset, 1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets(
        'retires in-flight suggestions across source and session changes',
        (tester) async {
      await show(tester, screen: screen);
      final online = find.byKey(const ValueKey('music-search-source-online'));
      final library = find.byKey(const ValueKey('music-search-source-library'));
      await tester.enterText(field, 'provider draft');
      await tester.pump(debounce);
      final oldSource = catalog.suggestionRequests.single;
      await tester.tap(library);
      await tester.pump();
      await tester.enterText(field, 'private library draft');
      await tester.pump(debounce);
      expect(oldSource.isCurrent!(), isFalse);
      expect(catalog.suggestionRequests, hasLength(1));
      oldSource.response.complete(['old source suggestion']);
      await tester.pump();
      expect(find.text('old source suggestion'), findsNothing);

      await tester.tap(online);
      await tester.pump();
      expect(
          tester.widget<TextField>(field).controller!.text, 'provider draft');
      expect(find.text('old source suggestion'), findsNothing);
      await tester.enterText(field, 'another draft');
      await tester.pump(debounce);
      expect(catalog.suggestionRequests, hasLength(2));
      final oldSession = catalog.suggestionRequests.last;
      app.setGlobalLoading(true);
      await tester.pump();
      expect(oldSession.isCurrent!(), isFalse);
      oldSession.response.complete(['old session suggestion']);
      await tester.pump();
      expect(find.text('old session suggestion'), findsNothing);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    });

    testWidgets('a suggestion error leaves manual search usable',
        (tester) async {
      await show(tester, screen: screen);
      await tester.enterText(field, 'manual jazz');
      await tester.pump(debounce);
      catalog.suggestionRequests.single.response.completeError(
          const MusicCatalogException('Suggestions unavailable'));
      await tester.pump();

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(catalog.searches, ['manual jazz']);
      catalog.responses.single.complete([first]);
      await tester.pumpAndSettle();
      expect(find.text(first.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('only explicit music search submissions produce learning signals',
      (tester) async {
    final events = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (call) async {
      final args = call.arguments as Map;
      events.addAll((args['events'] as List).cast<Map>());
      return {
        'state': <String, Object?>{},
        'ranked': <Object?>[],
        'summary': <String, Object?>{}
      };
    });
    await show(tester, screen: const MusicScreen(initialQuery: 'jazz music'));
    catalog.responses.single.complete([]);
    await tester.pumpAndSettle();
    expect(events, isEmpty);
    await search(tester, 'explicit jazz');
    catalog.responses.last.complete([]);
    await tester.pumpAndSettle();
    expect(
        events
            .where((event) => event['type'] == 'search')
            .map((event) => event['query']),
        ['explicit jazz']);
  });

  testWidgets(
      'Music search hides listed uploaders, labels warnings and can reveal the same results',
      (tester) async {
    await tester.runAsync(installCommunityMusicFilters);
    await show(tester);
    await search(tester, 'music');
    catalog.responses.single.complete([
      const MusicTrack(
          videoId: 'hiddenmusic',
          title: 'Listed song',
          uploaderChannelId: musicListedUploader),
      const MusicTrack(
          videoId: 'warnedmusic',
          title: 'Warned song',
          uploaderChannelId: youtubeWarnedUploader),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Listed song'), findsNothing);
    expect(find.text('Warned song'), findsOneWidget);
    expect(find.byType(CommunityMatchLabels), findsOneWidget);
    await tester.tap(find.textContaining('Show hidden results'));
    await tester.pumpAndSettle();
    expect(find.text('Listed song'), findsOneWidget);
    expect(find.byType(CommunityMatchLabels), findsNWidgets(2));

    await tester.tap(find.text('Listed by Flow AI music'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow this channel'));
    // Sembast completes writes on the real event loop while the dialog and
    // result-list updates are scheduled on the widget test's fake clock.
    for (var attempt = 0; attempt < 8; attempt++) {
      if (communityFilters
          .exceptions(CommunityList.aimusic)
          .contains(musicListedUploader)) {
        break;
      }
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(communityFilters.exceptions(CommunityList.aimusic),
        {musicListedUploader});
    await tester.pumpAndSettle();
    expect(find.text('Listed song'), findsOneWidget);
    expect(find.text('Listed by Flow AI music'), findsNothing);
    expect(find.text('Hide hidden results'), findsNothing);
    expect(catalog.searches, ['music']);
  });

  testWidgets('a genre shortcut searches the selected Invidious catalog once',
      (tester) async {
    await show(tester, screen: const MusicScreen(initialQuery: 'jazz music'));
    expect(catalog.searches, ['jazz music']);
    expect(find.text('jazz music'), findsOneWidget);
    catalog.responses.single.complete([first]);
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsOneWidget);
    await show(tester, screen: const MusicScreen(initialQuery: 'jazz music'));
    expect(catalog.searches, ['jazz music']);
    await tester.tap(find.text('First song'));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.single.videoId, first.videoId);
    expect(player.calls.single.audio, isTrue);
  });

  testWidgets('a replacement genre drops late results from its predecessor',
      (tester) async {
    await show(tester, screen: const MusicScreen(initialQuery: 'pop music'));
    await show(tester,
        screen: const MusicScreen(initialQuery: 'electronic music'));
    expect(catalog.searches, ['pop music', 'electronic music']);
    catalog.responses[1].complete([second]);
    await tester.pumpAndSettle();
    catalog.responses[0].complete([first]);
    await tester.pumpAndSettle();
    expect(find.text('Second song'), findsOneWidget);
    expect(find.text('First song'), findsNothing);
  });

  testWidgets('blank search arguments do not make catalog requests',
      (tester) async {
    await show(tester, screen: const MusicScreen(initialQuery: '   '));
    await tester.pumpAndSettle();
    expect(catalog.searches, isEmpty);
    expect(find.text('Search for a song, artist channel, or public playlist.'),
        findsOneWidget);
  });

  testWidgets('Invidious search exposes supported categories and plays songs',
      (tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Search songs, channels, or playlists'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Albums'), findsNothing);
    expect(find.textContaining('selected Invidious instance'), findsOneWidget);
    await search(tester, 'song');
    final frame = '/vi/${first.videoId}/mqdefault.jpg';
    catalog.responses.single.complete([
      MusicTrack(
          videoId: first.videoId,
          title: first.title,
          artists: first.artists,
          videoThumbnails: [ImageObject(null, frame, 320, 180)])
    ]);
    await tester.pumpAndSettle();
    final result = find.byKey(ValueKey('music-song-search-0-${first.videoId}'));
    final community = tester.widget<CommunityMusicArtwork>(find.descendant(
        of: result, matching: find.byType(CommunityMusicArtwork)));
    expect(community.allowLookup, isFalse);
    final artwork = tester.widget<Thumbnail>(
        find.descendant(of: result, matching: find.byType(Thumbnail)));
    expect(artwork.images!.single.url, frame);
    expect(artwork.useInvidiousProxy, isTrue);
    await tester.tap(find.text('First song'));
    await tester.pumpAndSettle();
    final played = player.calls.single.videos.single;
    expect(played.videoId, first.videoId);
    expect(played.musicMetadata!.thumbnails, isEmpty);
    expect(player.calls.single.audio, isTrue);
    expect(player.calls.single.queueTitle,
        AppLocalizations.of(tester.element(result))!.search);
  });

  testWidgets('historical song album labels do not offer album navigation',
      (tester) async {
    await show(tester);
    await search(tester, 'first');
    catalog.responses.single.complete([first]);
    await tester.pumpAndSettle();
    expect(find.text('Album'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Album'), findsNothing);
    expect(find.text('Albums'), findsNothing);
    expect(catalog.playlistRequests, isEmpty);
    expect(player.calls, isEmpty);
  });

  testWidgets('new searches discard late results from older requests',
      (tester) async {
    await show(tester);
    await search(tester, 'first');
    await search(tester, 'second');
    expect(catalog.searches, ['first', 'second']);
    catalog.responses[1].complete([second]);
    await tester.pumpAndSettle();
    expect(find.text('Second song'), findsOneWidget);
    catalog.responses[0].complete([first]);
    await tester.pumpAndSettle();
    expect(find.text('Second song'), findsOneWidget);
    expect(find.text('First song'), findsNothing);
  });

  testWidgets('unified search restores each source draft and results viewport',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final library = MusicLibraryService.forProfile(db, db.profileId);
    await tester.runAsync(() => library.importSongs([
          for (var i = 0; i < 35; i++)
            MusicLibraryEntry(
              kind: MusicLibraryKind.song,
              id: 'saved${i.toString().padLeft(6, '0')}',
              title: 'Démo recording $i',
            ),
        ]));
    catalog.artistResults = [
      for (var i = 0; i < 35; i++)
        MusicArtist(
            id: 'UC${i.toString().padLeft(22, 'A')}', name: 'Artist $i'),
    ];
    await show(tester, screen: const MusicScreen(embedded: true));
    await tester.pumpAndSettle();
    const channels = 'Channels';
    final channelFilter = find.widgetWithText(ChoiceChip, channels);
    final field = find.byKey(const ValueKey('music-search'));
    final online = find.byKey(const ValueKey('music-search-source-online'));
    final local = find.byKey(const ValueKey('music-search-source-library'));
    final onlineView =
        find.byKey(const ValueKey('music-search-online-viewport'));
    final libraryView =
        find.byKey(const ValueKey('music-search-library-viewport'));
    ScrollPosition position(Finder view) => tester
        .state<ScrollableState>(
            find.descendant(of: view, matching: find.byType(Scrollable)).first)
        .position;

    await tester.tap(channelFilter);
    await search(tester, 'artists');
    await tester.pumpAndSettle();
    expect(find.text('Artist 0'), findsOneWidget);
    await tester.drag(onlineView, const Offset(0, -380));
    await tester.pumpAndSettle();
    final onlineOffset = position(onlineView).pixels;
    expect(onlineOffset, greaterThan(180));

    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(channelFilter, findsNothing);
    expect(onlineView, findsNothing);
    await search(tester, 'demo');
    await tester.pumpAndSettle();
    expect(find.textContaining('Démo recording'), findsWidgets);
    await tester.drag(libraryView, const Offset(0, -260));
    await tester.pumpAndSettle();
    final libraryOffset = position(libraryView).pixels;
    expect(libraryOffset, greaterThan(125));

    await tester.tap(online);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'artists');
    expect(tester.widget<ChoiceChip>(channelFilter).selected, isTrue);
    expect(position(onlineView).pixels, closeTo(onlineOffset, 1));
    expect(libraryView, findsNothing);
    final retainedLibrary = find.byKey(
        const ValueKey('music-search-library-viewport'),
        skipOffstage: false);
    expect(retainedLibrary, findsOneWidget);
    expect(
        find.descendant(
            of: retainedLibrary,
            matching: find.byType(Scrollable, skipOffstage: false),
            skipOffstage: false),
        findsNothing);
    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'demo');
    expect(position(libraryView).pixels, closeTo(libraryOffset, 1));
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);

    final songs = find.widgetWithText(ChoiceChip, 'Songs');
    await tester.tap(songs);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(songs).selected, isTrue);
    expect(position(libraryView).pixels, 0);
    await tester.drag(libraryView, const Offset(0, -210));
    await tester.pumpAndSettle();
    final songsOffset = position(libraryView).pixels;
    expect(songsOffset, greaterThan(100));
    await tester.tap(online);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(channelFilter).selected, isTrue);
    expect(position(onlineView).pixels, closeTo(onlineOffset, 1));
    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(songs).selected, isTrue);
    expect(position(libraryView).pixels, closeTo(songsOffset, 1));
    expect(catalog.artistSearches, ['artists']);
    expect(catalog.searches, isEmpty);
  });

  testWidgets(
      'Library type filters keep saved songs and local playlists distinct',
      (tester) async {
    final playlistId = await tester.runAsync(() async {
      final library = MusicLibraryService.forProfile(db, db.profileId);
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'firstsong01',
          title: 'Saved rehearsal'));
      final id = (await service.createPlayList('Rehearsal mix', 'local'))!;
      await library.markLocalPlaylist(id);
      return id;
    });
    await show(tester, screen: const MusicScreen(embedded: true));
    final online = find.byKey(const ValueKey('music-search-source-online'));
    final local = find.byKey(const ValueKey('music-search-source-library'));
    final field = find.byKey(const ValueKey('music-search'));
    final all = find.widgetWithText(ChoiceChip, 'All');
    final songs = find.widgetWithText(ChoiceChip, 'Songs');
    final playlists = find.widgetWithText(ChoiceChip, 'Playlists');
    final channels = find.widgetWithText(ChoiceChip, 'Channels');
    final saved = find.widgetWithText(ListTile, 'Saved rehearsal');
    final mix = find.widgetWithText(ListTile, 'Rehearsal mix');

    await tester.tap(channels);
    await search(tester, 'artist');
    await tester.pumpAndSettle();
    expect(find.text('Artist'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(all).selected, isFalse);
    expect(tester.widget<ChoiceChip>(channels).selected, isTrue);
    await tester.tap(local);
    await tester.pump();
    await search(tester, 'rehearsal');
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(all).selected, isTrue);
    expect(saved, findsOneWidget);
    expect(mix, findsOneWidget);
    expect(channels, findsNothing);

    // An old row can still be in the render tree before the filter rebuilds.
    // It must not launch, even if that song belongs to the selected type too.
    final oldSongTap = tester.widget<ListTile>(saved).onTap!;
    await tester.tap(songs);
    oldSongTap();
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
    expect(saved, findsOneWidget);
    expect(mix, findsNothing);
    await tester.tap(saved);
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.single.videoId, 'firstsong01');

    await tester.tap(playlists);
    await tester.pumpAndSettle();
    expect(saved, findsNothing);
    expect(mix, findsOneWidget);
    await tester.tap(mix);
    await tester.pumpAndSettle();
    final page = tester.widget<MusicLibraryPage>(find.byType(MusicLibraryPage));
    expect(page.source?.playlistId, playlistId);
    expect(find.text('Rehearsal mix'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(playlists).selected, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'rehearsal');
    expect(mix, findsOneWidget);

    await tester.tap(online);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(channels).selected, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'artist');
    expect(find.text('Artist'), findsOneWidget);
    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(playlists).selected, isTrue);
    expect(mix, findsOneWidget);
    expect(catalog.artistSearches, ['artist']);
    expect(catalog.searches, isEmpty);
    expect(catalog.playlistSearches, isEmpty);
    expect(catalog.playlistRequests, isEmpty);

    app.setGlobalLoading(true);
    await tester.pump();
    app.setGlobalLoading(false);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(all).selected, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets(
      'playing a Library result clears search focus with the IME hidden',
      (tester) async {
    await tester.runAsync(() => MusicLibraryService.forProfile(db, db.profileId)
        .save(const MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'firstsong01',
            title: 'Saved rehearsal')));
    await show(tester, screen: const MusicScreen(embedded: true));
    await tester.tap(find.byKey(const ValueKey('music-search-source-library')));
    await tester.pump();
    final field = find.byKey(const ValueKey('music-search'));
    await tester.enterText(field, 'rehearsal');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final search = tester.widget<TextField>(field);
    expect(search.focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(MediaQuery.viewInsetsOf(tester.element(field)).bottom, isZero);

    final hit = find.widgetWithText(ListTile, 'Saved rehearsal');
    await tester.tap(hit);
    await tester.pumpAndSettle();

    expect(search.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(search.controller!.text, 'rehearsal');
    expect(hit, findsOneWidget);
    expect(player.calls.single.videos.single.videoId, 'firstsong01');
    expect(player.calls.single.audio, isTrue);
  });

  testWidgets('only the newest Online response survives a Library source visit',
      (tester) async {
    await tester.runAsync(() => MusicLibraryService.forProfile(db, db.profileId)
        .save(const MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'offlinelane',
            title: 'Offline library marker')));
    await show(tester, screen: const MusicScreen(embedded: true));
    final online = find.byKey(const ValueKey('music-search-source-online'));
    final local = find.byKey(const ValueKey('music-search-source-library'));
    final marker = find.text('Offline library marker');
    await search(tester, 'older');
    await tester.tap(local);
    await tester.pump();
    await search(tester, 'library marker');
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);
    final songs = find.widgetWithText(ChoiceChip, 'Songs');
    await tester.tap(songs);
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);

    await tester.tap(online);
    await tester.pump();
    await search(tester, 'newer');
    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);
    expect(tester.widget<ChoiceChip>(songs).selected, isTrue);
    catalog.responses[1].complete([second]);
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);
    expect(find.text('Second song'), findsNothing);
    catalog.responses[0].complete([first]);
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);
    expect(find.text('First song'), findsNothing);

    await tester.tap(online);
    await tester.pumpAndSettle();
    expect(find.text('newer'), findsOneWidget);
    expect(find.text('Second song'), findsOneWidget);
    expect(find.text('First song'), findsNothing);
    expect(marker, findsNothing);
    expect(catalog.searches, ['older', 'newer']);
  });

  testWidgets('Online All keeps provider order and skips a hidden Top result',
      (tester) async {
    await tester.runAsync(installCommunityMusicFilters);
    catalog.paginate = true;
    await show(tester, screen: const MusicScreen(embedded: true));
    final songs = find.widgetWithText(ChoiceChip, 'Songs');
    final all = find.widgetWithText(ChoiceChip, 'All');
    expect(tester.widget<ChoiceChip>(songs).selected, isTrue);
    await tester.tap(all);
    await search(tester, 'provider order');
    expect(catalog.pageRequests.single.type, MusicCatalogSearchType.all);
    catalog.pageRequests.single.response.complete(_page(const [
      MusicCatalogSongHit(MusicTrack(
          videoId: 'hiddenmusic',
          title: 'Listed song',
          uploaderChannelId: musicListedUploader)),
      MusicCatalogPlaylistHit(
          MusicPlaylist(id: 'PLpublic', title: 'Provider playlist')),
      MusicCatalogSongHit(first),
      MusicCatalogChannelHit(
          MusicArtist(id: 'UCartist', name: 'Ranked channel')),
      MusicCatalogSongHit(second),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Listed song'), findsNothing);
    expect(find.text('Top result'), findsOneWidget);
    final positions = [
      for (final title in [
        'Top result',
        'Provider playlist',
        'First song',
        'Ranked channel',
        'Second song',
      ])
        tester.getTopLeft(find.text(title)).dy,
    ];
    expect(positions, orderedEquals([...positions]..sort()));
    expect(positions.toSet(), hasLength(positions.length));
    expect(find.text('Provider playlist'), findsOneWidget);
    await tester.tap(find.text('First song'));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((video) => video.videoId),
        [first.videoId, second.videoId]);
    expect(player.calls.single.startIndex, 0);
  });

  testWidgets('Online pagination retries in place and ends on a repeated page',
      (tester) async {
    catalog.paginate = true;
    await show(tester, screen: const MusicScreen(embedded: true));
    await search(tester, 'pages');
    catalog.pageRequests.single.response
        .complete(_page(const [MusicCatalogSongHit(first)]));
    await tester.pumpAndSettle();
    final view = find.byKey(const ValueKey('music-search-online-viewport'));
    final scrollable =
        find.descendant(of: view, matching: find.byType(Scrollable));
    final before = tester.state<ScrollableState>(scrollable);
    final loadMore = find.widgetWithText(TextButton, 'Load more');
    final retry = find.widgetWithText(TextButton, 'Retry');
    final firstSong = find.text('First song');
    await tester.tap(loadMore);
    await tester.pump();
    expect(firstSong, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(catalog.pageRequests.last.page, 2);
    catalog.pageRequests.last.response.completeError(StateError('try again'));
    await tester.pumpAndSettle();
    expect(firstSong, findsOneWidget);
    expect(retry, findsOneWidget);
    expect(tester.state<ScrollableState>(scrollable), same(before));

    await tester.tap(retry);
    await tester.pump();
    expect(catalog.pageRequests.map((request) => request.page), [1, 2, 2]);
    catalog.pageRequests.last.response.complete(
        _page(const [MusicCatalogSongHit(first), MusicCatalogSongHit(second)]));
    await tester.pumpAndSettle();
    expect(firstSong, findsOneWidget);
    expect(find.text('Second song'), findsOneWidget);
    expect(tester.state<ScrollableState>(scrollable), same(before));
    expect(tester.getTopLeft(firstSong).dy,
        lessThan(tester.getTopLeft(find.text('Second song')).dy));

    await tester.tap(loadMore);
    await tester.pump();
    expect(catalog.pageRequests.last.page, 3);
    const unpainted = 'songs:unpainted01';
    catalog.pageRequests.last.response
        .complete(_page([], rawKeys: [unpainted]));
    await tester.pumpAndSettle();
    expect(loadMore, findsOneWidget);
    await tester.tap(loadMore);
    await tester.pump();
    expect(catalog.pageRequests.last.page, 4);
    catalog.pageRequests.last.response
        .complete(_page([], rawKeys: [unpainted]));
    await tester.pumpAndSettle();
    expect(loadMore, findsNothing);
    expect(find.text('Second song'), findsOneWidget);
    expect(
        catalog.pageRequests.every((request) =>
            request.query == 'pages' &&
            request.type == MusicCatalogSearchType.songs),
        isTrue);
  });

  testWidgets('changing Online type or query retires pending pagination',
      (tester) async {
    catalog.paginate = true;
    await show(tester, screen: const MusicScreen(embedded: true));
    await search(tester, 'old query');
    catalog.pageRequests.single.response
        .complete(_page(const [MusicCatalogSongHit(first)]));
    await tester.pumpAndSettle();
    final loadMore = find.widgetWithText(TextButton, 'Load more');
    await tester.tap(loadMore);
    await tester.pump();
    final outdatedSongAppend = catalog.pageRequests.last;

    await tester.tap(find.widgetWithText(ChoiceChip, 'Channels'));
    await tester.pump();
    expect(outdatedSongAppend.isCurrent!(), isFalse);
    expect(catalog.pageRequests.last.type, MusicCatalogSearchType.channels);
    expect(catalog.pageRequests.last.page, 1);
    catalog.pageRequests.last.response.complete(_page(const [
      MusicCatalogChannelHit(
          MusicArtist(id: 'UCold', name: 'Previous channel')),
    ]));
    outdatedSongAppend.response
        .complete(_page(const [MusicCatalogSongHit(second)]));
    await tester.pumpAndSettle();
    expect(find.text('Previous channel'), findsOneWidget);
    expect(find.text('Second song'), findsNothing);
    await tester.tap(loadMore);
    await tester.pump();
    final outdatedChannelAppend = catalog.pageRequests.last;
    expect(outdatedChannelAppend.page, 2);

    await search(tester, 'new query');
    expect(outdatedChannelAppend.isCurrent!(), isFalse);
    expect(catalog.pageRequests.last.query, 'new query');
    expect(catalog.pageRequests.last.page, 1);
    catalog.pageRequests.last.response.complete(_page(const [
      MusicCatalogChannelHit(MusicArtist(id: 'UCfresh', name: 'Fresh channel')),
    ]));
    outdatedChannelAppend.response.complete(_page(const [
      MusicCatalogChannelHit(MusicArtist(id: 'UCstale', name: 'Stale channel')),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Previous channel'), findsNothing);
    expect(find.text('Stale channel'), findsNothing);
    expect(find.text('Fresh channel'), findsOneWidget);
    expect(loadMore, findsOneWidget);
  });

  testWidgets('Online collection Back restores the pending page action',
      (tester) async {
    catalog.paginate = true;
    await show(tester, screen: const MusicScreen(embedded: true));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Playlists'));
    await search(tester, 'playlists');
    catalog.pageRequests.single.response.complete(_page(const [
      MusicCatalogPlaylistHit(
          MusicPlaylist(id: 'PLpublic', title: 'Search collection')),
    ]));
    await tester.pumpAndSettle();
    final loadMore = find.widgetWithText(TextButton, 'Load more');
    await tester.tap(loadMore);
    await tester.pump();
    final abandoned = catalog.pageRequests.last;
    await tester.tap(find.text('Search collection'));
    await tester.pumpAndSettle();
    expect(abandoned.isCurrent!(), isFalse);
    expect(find.text('Public playlist'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('music-browser-up')));
    await tester.pumpAndSettle();
    expect(find.text('Search collection'), findsOneWidget);
    await tester.tap(loadMore);
    await tester.pump();
    expect(catalog.pageRequests.map((request) => request.page), [1, 2, 2]);
    abandoned.response.complete(_page(const [
      MusicCatalogPlaylistHit(
          MusicPlaylist(id: 'PLabandoned', title: 'Abandoned result')),
    ]));
    catalog.pageRequests.last.response.complete(_page(const []));
    await tester.pumpAndSettle();
    expect(find.text('Abandoned result'), findsNothing);
    expect(loadMore, findsNothing);
    expect(find.text('Search collection'), findsOneWidget);
  });

  testWidgets('failed catalog search can retry and show an empty result',
      (tester) async {
    await show(tester);
    await search(tester, 'missing');
    catalog.responses.single.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(
        find.text('Could not load music. Check your connection and try again.'),
        findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(catalog.searches, ['missing', 'missing']);
    catalog.responses.last.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
  });

  testWidgets('search error clears before retry and stays clear after success',
      (tester) async {
    const errorMessage =
        'Could not load music. Check your connection and try again.';
    await show(tester);
    await search(tester, 'song');
    catalog.responses.single
        .completeError(const MusicCatalogException('Offline'));
    await tester.pumpAndSettle();
    expect(find.text(errorMessage), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text(errorMessage), findsNothing);
    catalog.responses.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(
        find.text('Could not load music. Check your connection and try again.'),
        findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    catalog.responses.last.complete([first]);
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsOneWidget);
  });

  testWidgets('profile changes clear a catalog error', (tester) async {
    await show(tester);
    await search(tester, 'song');
    catalog.responses.single
        .completeError(const MusicCatalogException('Offline'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check your connection and try again'),
        findsOneWidget);
    app.setGlobalLoading(true);
    await tester.pumpAndSettle();
    expect(find.textContaining('Check your connection and try again'),
        findsNothing);
  });

  testWidgets(
      'playlist search preserves track order and starts an audio queue at zero',
      (tester) async {
    await show(tester);
    await tester.tap(find.text('Playlists'));
    await search(tester, 'public');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Public playlist'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Second song'), 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    final firstPosition = tester.getTopLeft(find.text('First song'));
    final secondPosition = tester.getTopLeft(find.text('Second song'));
    expect(firstPosition.dy, lessThan(secondPosition.dy));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('music-play-all')), -150,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.byKey(const ValueKey('music-play-all')));
    await tester.pumpAndSettle();
    expect(player.calls, hasLength(1));
    final call = player.calls.single;
    expect(call.videos.map((video) => video.videoId),
        ['firstsong01', 'secondsong2']);
    expect(call.audio, isTrue);
    expect(call.startAt, Duration.zero);
    expect(call.videos.first.musicMetadata?.album, 'Album');
    expect(call.videos.first.musicMetadata?.artist, 'Artist');
  });

  testWidgets('song save uses the local library and keeps music metadata',
      (tester) async {
    await show(tester);
    await search(tester, 'first');
    catalog.responses.single.complete([first]);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Watch Later'));
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return !service.getLocalPlaylists().any((playlist) =>
            playlist.playlistId == localWatchLaterId &&
            playlist.videos.any((video) => video.videoId == first.videoId));
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    final playlist = service
        .getLocalPlaylists()
        .singleWhere((p) => p.playlistId == localWatchLaterId);
    expect(playlist.videos.single.videoId, first.videoId);
    expect(playlist.videos.single.musicMetadata?.album, 'Album');
    expect(playlist.videos.single.musicMetadata?.artist, 'Artist');
  });

  testWidgets('profile switching cancels a pending deep-link autoplay',
      (tester) async {
    await show(tester, screen: const MusicScreen(videoId: 'firstsong01'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final observer = catalog.songObserver!;
    expect(observer.isCurrent(), isTrue);
    app.setGlobalLoading(true);
    await tester.pump();
    expect(observer.isCurrent(), isFalse);
    observer.onRetry();
    catalog.song.complete(first);
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
    expect(find.text('First song'), findsNothing);
    expect(find.text('Retrying video details…'), findsNothing);
  });

  for (final isAsync in [false, true]) {
    testWidgets(
        'song details load if optional SponsorBlock fails (async: $isAsync)',
        (tester) async {
      player.sponsorFailureIsAsync = isAsync;
      await show(tester, screen: MusicScreen(videoId: first.videoId));
      catalog.song.complete(first);
      await tester.pumpAndSettle();
      expect(player.calls.single.videos.single.videoId, first.videoId);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (label, image, expectedCovers) in [
    ('catalog cover', 'https://lh3.googleusercontent.com/album-cover', 1),
    (
      'video thumbnail',
      'https://instance.example/vi/firstsong01/mqdefault.jpg',
      0
    ),
  ]) {
    testWidgets('a saved song link handles a cached $label', (tester) async {
      const selected = Server(url: 'https://instance.example', inUse: true);
      const channel = 'UC0123456789012345678901';
      const credits = [MusicArtistCredit(name: 'Saved artist', id: channel)];
      final audio = AdaptiveFormat(
          null,
          '128000',
          null,
          'https://instance.example/audio?itag=251',
          '251',
          'audio/webm; codecs="opus"',
          '12345',
          '1700000000000',
          'RECTANGULAR',
          'webm',
          'opus',
          null,
          null);
      await tester.runAsync(() async {
        await db.upsertServer(selected);
        final server = await db.getCurrentlySelectedServer();
        await app.initState();
        await MusicLibraryService.forProfile(db, db.profileId)
            .save(MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: first.videoId,
          title: 'Bookmarked song',
          subtitle: 'Bookmarked artist',
          artistCredits: const [
            MusicArtistCredit(
                name: 'Bookmarked artist', id: 'UCabcdefghijklmnopqrstuv'),
          ],
          thumbnails: [ImageObject(null, image, 320, 320)],
        ));
        if (label == 'video thumbnail') {
          await db.upsertHistoryVideo(HistoryVideoCache(
              first.videoId, 'Saved song', 'Saved artist', '',
              musicMetadata: const MusicMetadata(
                  title: 'Saved song',
                  artist: 'Saved artist',
                  artistCredits: credits)));
        }
        final provenance = DownloadPlaybackProvenance.create(
            video: Video(videoId: first.videoId, adaptiveFormats: [audio]),
            server: server,
            audioOnly: true,
            container: DownloadContainer.webm,
            audio: audio,
            videoFormat: null,
            byteLength: 10000,
            sha256: 'a' * 64)!;
        await db.upsertDownload(DownloadedVideo(
            videoId: first.videoId,
            title: 'Saved song',
            author: 'Saved artist',
            accountId: server.accountId,
            storageUri: 'content://music/saved-song',
            lengthSeconds: 180,
            quality: 'audio',
            container: DownloadContainer.webm,
            audioOnly: true,
            downloadComplete: true,
            playbackProvenance: provenance,
            musicMetadata: const MusicMetadata(
                title: 'Saved song',
                artist: 'Saved artist',
                album: 'Saved album')));
      });
      player.sponsorFailureIsAsync = true;
      await show(tester,
          screen: MusicScreen(
              videoId: first.videoId,
              artistCredits: label == 'catalog cover' ? credits : const []));
      // The remote cover can keep its loading indicator animated in this test.
      // The song and its artwork metadata are published before image decoding.
      await tester.pump();
      expect(catalog.songObserver, isNull);
      final played = player.calls.single.videos.single;
      expect(played.downloadPlaybackOnly, isTrue);
      expect(played.musicMetadata?.artist, 'Saved artist');
      expect(played.musicMetadata!.artistCredits.single.id, channel);
      expect(played.musicMetadata?.album, 'Saved album');
      final covers = played.musicMetadata!.thumbnails;
      expect(covers, hasLength(expectedCovers));
      if (expectedCovers > 0) expect(covers.single.url, image);
      expect(find.text('Saved song'), findsOneWidget);
    });
  }

  testWidgets('admitting a routed song restores its caller before startup ends',
      (tester) async {
    final startup = Completer<void>();
    player.playbackStartup = startup;
    addTearDown(() {
      if (!startup.isCompleted) startup.complete();
    });
    await show(tester, screen: const MusicScreen(initialQuery: 'jazz music'));
    catalog.responses.single.complete([first, second]);
    await tester.pumpAndSettle();
    final origin = tester.state(find.byType(MusicScreen));
    final navigator = Navigator.of(origin.context);
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(
            videoId: second.videoId,
            queue: [
              first.toVideo(),
              Video(videoId: second.videoId, title: 'Cached title'),
              first.toVideo()
            ],
            startIndex: 1))));
    await tester.pump();
    final songRoute = find.byWidgetPredicate(
        (widget) => widget is MusicScreen && widget.videoId == second.videoId,
        skipOffstage: false);
    Finder inSongRoute(Finder matching) =>
        find.descendant(of: songRoute, matching: matching, skipOffstage: false);
    expect(inSongRoute(find.text('Now playing', skipOffstage: false)),
        findsOneWidget);
    expect(
        inSongRoute(find.byType(TextField, skipOffstage: false)), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('music-search')), findsNothing);
    expect(find.byKey(const ValueKey('music-search-filters')), findsNothing);
    catalog.song.complete(second);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final played = player.calls.single;
    expect(played.videos.map((video) => video.videoId),
        [first.videoId, second.videoId, first.videoId]);
    expect(played.startIndex, 1);
    expect(played.videos[1].title, second.title);
    expect(catalog.songRequests, [second.videoId]);
    expect(player.playbackStartup!.isCompleted, isFalse);
    expect(player.state.isMini, isFalse);
    expect(tester.state(find.byType(MusicScreen)), same(origin));
    expect(find.text('jazz music'), findsOneWidget);
    expect(find.text('First song'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
    player.playbackStartup!.complete();
    await tester.pumpAndSettle();
    expect(catalog.searches, ['jazz music']);
  });

  testWidgets(
      'a routed replacement waits for its queue and selected occurrence',
      (tester) async {
    player.holdSelections = true;
    player.commitSelection([second.toVideo()], 0, mini: true);
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    final queue = assignPlaybackQueueIds(
        [first.toVideo(), second.toVideo(), first.toVideo()]);
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) =>
            MusicScreen(videoId: first.videoId, queue: queue, startIndex: 2))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    catalog.song.complete(first);
    await tester.pump();
    expect(player.calls.single.startIndex, 2);
    expect(player.state.currentQueueId, second.videoId);
    expect(find.text('Origin'), findsNothing);

    // Both end rows have the same upload ID. Only the tapped occurrence
    // in its original queue may dismiss this launcher.
    Future<void> commit(List<Video> videos, int index) async {
      await tester.runAsync(() async {
        player.commitSelection(videos, index);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await commit(queue, 0);
    expect(find.text('Origin'), findsNothing);
    await commit([queue.last, queue.first], 0);
    expect(find.text('Origin'), findsNothing);
    await commit(queue, 2);
    expect(find.text('Origin'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
    expect(player.pendingSelections.single.isCompleted, isFalse);
    player.pendingSelections.single.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a failed routed replacement preserves playback and offers Retry',
      (tester) async {
    player.holdSelections = true;
    player.commitSelection([first.toVideo()], 0, mini: true);
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(videoId: second.videoId))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    catalog.song.complete(second);
    await tester.pump();
    player.musicSelectionFailureRevision.value++;
    player.pendingSelections.single.complete();
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Origin'), findsNothing);
    expect(player.state.currentlyPlaying?.videoId, first.videoId);
    expect(player.state.isPlaying, isTrue);
    expect(player.state.isMini, isTrue);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(player.calls, hasLength(2));
    player.commitSelection(player.calls.last.videos, 0);
    player.pendingSelections.last.complete();
    await tester.pumpAndSettle();
    expect(find.text('Origin'), findsOneWidget);
  });

  testWidgets('a covered song launcher cannot take over a newer route',
      (tester) async {
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(videoId: first.videoId))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final observer = catalog.songObserver!;
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('New page')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(observer.isCurrent(), isFalse);
    catalog.song.complete(first);
    await tester.pumpAndSettle();
    expect(find.text('New page'), findsOneWidget);
    expect(player.calls, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Origin'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
    expect(player.calls, isEmpty);
  });

  testWidgets(
      'leaving a covering page before song details arrive restores the source',
      (tester) async {
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(videoId: first.videoId))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('New page')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The pending catalog lookup sends no retry or progress events while the
    // other page is open. Back should still return directly to the source.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    catalog.song.complete(first);
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
    expect(find.text('Origin'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('replaying a song after a rejected launch returns to its caller',
      (tester) async {
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(videoId: first.videoId))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    catalog.song.complete(first);
    await tester.pumpAndSettle();
    expect(player.calls, hasLength(1));
    expect(player.state.videos, isEmpty);
    expect(find.text('First song'), findsOneWidget);

    player.playbackStartup = Completer<void>()..complete();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.calls, hasLength(2));
    expect(player.state.videos.single.videoId, first.videoId);
    expect(find.text('Origin'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('one TV Back from a routed song returns to its original page',
      (tester) async {
    isTv = true;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const audioSession = MethodChannel('com.ryanheise.audio_session');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final audioConfiguration = Completer<void>();
    messenger.setMockMethodCallHandler(
        audioSession, (_) => audioConfiguration.future);
    addTearDown(() {
      audioConfiguration.complete();
      messenger.setMockMethodCallHandler(audioSession, null);
      isTv = false;
    });
    await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
    await tester.pumpAndSettle();
    final origin = tester.state(find.byType(MusicScreen));
    unawaited(Navigator.of(origin.context).push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(
            videoId: second.videoId,
            queue: [
              Video(videoId: first.videoId),
              second.toVideo(),
              first.toVideo()
            ],
            startIndex: 1))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-search')), findsNothing);
    catalog.song.complete(second);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final tvPlayer =
        tester.element(find.byType(Scaffold).last).read<PlayerCubit>();
    expect(tvPlayer, isNot(same(player)));
    expect(tvPlayer.state.videos.map((video) => video.videoId),
        [first.videoId, second.videoId, first.videoId]);
    expect(tvPlayer.state.videos.first.musicMetadata?.title, first.videoId);
    expect(tvPlayer.state.videos.last.musicMetadata?.title, first.title);
    expect(catalog.songRequests, [second.videoId]);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(MusicScreen)), same(origin));
    expect(find.text('Public playlist'), findsOneWidget);
    expect(catalog.playlistRequests, ['PLpublic']);
  });

  testWidgets('song links show retry feedback and clear it before playback',
      (tester) async {
    await show(tester,
        screen: const MusicScreen(
            videoId: 'firstsong01', startAt: Duration(seconds: 42)));
    catalog.songObserver!.onRetry();
    await tester.pump();
    expect(find.text('Retrying video details…'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-search')), findsNothing);

    final route =
        BackendPlayback(const Server(url: 'https://instance.example'));
    final loaded = Video(
        videoId: first.videoId,
        formatStreams: [],
        adaptiveFormats: [],
        backendPlayback: route);
    catalog.song.complete(MusicTrack(
        videoId: first.videoId,
        title: first.title,
        artists: first.artists,
        playbackVideo: loaded));
    await tester.pumpAndSettle();
    expect(find.text('Retrying video details…'), findsNothing);
    expect(find.text('First song'), findsOneWidget);
    expect(player.calls.single.videos.single.videoId, first.videoId);
    expect(player.calls.single.videos.single.backendPlayback, same(route));
    expect(player.calls.single.videos.single.adaptiveFormats, isNotNull);
    expect(player.calls.single.videos.single.musicMetadata?.title, first.title);
    expect(player.calls.single.startAt, const Duration(seconds: 42));
  });

  testWidgets(
      'a new timestamp on the same Music link starts at the new position',
      (tester) async {
    await show(tester,
        screen: const MusicScreen(
            videoId: 'firstsong01', startAt: Duration(seconds: 42)));
    catalog.song.complete(first);
    await tester.pumpAndSettle();
    expect(player.calls.single.startAt, const Duration(seconds: 42));
    await show(tester,
        screen:
            const MusicScreen(videoId: 'firstsong01', startAt: Duration.zero));
    await tester.pumpAndSettle();
    expect(player.calls, hasLength(2));
    expect(player.calls.last.startAt, Duration.zero);
  });

  for (final tv in [false, true]) {
    testWidgets(
        'clearing a mounted song route cancels its request and retry feedback (TV: $tv)',
        (tester) async {
      isTv = tv;
      await show(tester, screen: const MusicScreen(videoId: 'firstsong01'));
      final state = tester.state(find.byType(MusicScreen));
      final observer = catalog.songObserver!;
      observer.onRetry();
      await tester.pump();
      expect(find.text('Retrying video details…'), findsOneWidget);

      await show(tester);
      expect(tester.state(find.byType(MusicScreen)), same(state));
      expect(observer.isCurrent(), isFalse);
      expect(find.text('Retrying video details…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      observer.onRetry();
      catalog.song.complete(first);
      await tester.pumpAndSettle();
      expect(player.calls, isEmpty);
      expect(find.text('First song'), findsNothing);
      expect(find.text('Retrying video details…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('song retry failure keeps a manual retry action', (tester) async {
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(videoId: first.videoId))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    catalog.songObserver!.onRetry();
    await tester.pump();
    expect(find.text('Retrying video details…'), findsOneWidget);

    catalog.song.completeError(const MusicCatalogException('Unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Retrying video details…'), findsNothing);
    final retry = find.ancestor(
        of: find.text('Retry'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(retry, findsOneWidget);
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
    expect(player.calls, isEmpty);
    catalog.song = Completer<MusicTrack>();
    player.playbackStartup = Completer<void>()..complete();
    await tester.tap(retry);
    await tester.pump();
    catalog.song.complete(first);
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.single.videoId, first.videoId);
    expect(find.text('Origin'), findsOneWidget);
  });

  testWidgets('a playlist may contain the same song more than once',
      (tester) async {
    catalog.collection = const MusicCollection(
        id: 'PLplaylist', title: 'Playlist', tracks: [first, first]);
    await show(tester, screen: const MusicScreen(playlistId: 'PLplaylist'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('music-song-1-firstsong01')), 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('First song'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile switching closes open save and create dialogs',
      (tester) async {
    await show(tester);
    await search(tester, 'first');
    catalog.responses.single.complete([first]);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create new playlist'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    app.setGlobalLoading(true);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Select playlist'), findsNothing);
    expect(service.getLocalPlaylists().single.videos, isEmpty);
  });

  testWidgets('Music marks unlabeled queue entries and keeps catalog metadata',
      (tester) async {
    const unlabeled = Video(
        videoId: 'unlabeled01',
        title: 'Local playlist title',
        author: 'Uploader',
        queueEntryId: 'second occurrence');
    await show(tester, screen: Builder(builder: (context) {
      return TextButton(
          onPressed: () =>
              MusicScreen.playTracks(context, [first.toVideo(), unlabeled]),
          child: const Text('Play saved track'));
    }));
    await tester.tap(find.text('Play saved track'));
    await tester.pumpAndSettle();
    final songs = player.calls.single.videos;
    expect(songs.first.musicMetadata?.album, 'Album');
    expect(songs.last.musicMetadata?.title, unlabeled.title);
    expect(songs.last.musicMetadata?.artist, unlabeled.author);
    expect(songs.last.queueEntryId, unlabeled.queueEntryId);
    expect(player.calls.single.audio, isTrue);
    expect(player.calls.single.startAt, Duration.zero);
    expect(catalog.searches, isEmpty);
    expect(catalog.song.isCompleted, isFalse);
  });

  testWidgets('leaving a pending song link cannot start playback later',
      (tester) async {
    await show(tester, screen: const MusicScreen(videoId: 'firstsong01'));
    final observer = catalog.songObserver!;
    await tester.pumpWidget(const SizedBox());
    expect(observer.isCurrent(), isFalse);
    observer.onRetry();
    catalog.song.complete(first);
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final detail in [
    (name: 'artist', screen: const MusicScreen(artistId: 'UCartist')),
    (name: 'playlist', screen: const MusicScreen(playlistId: 'PLpublic')),
  ]) {
    testWidgets('direct ${detail.name} returns to its caller on the first Back',
        (tester) async {
      await show(tester, screen: const Scaffold(body: Text('Origin')));
      final navigator = Navigator.of(tester.element(find.text('Origin')));
      for (final systemBack in [false, true]) {
        unawaited(navigator
            .push<void>(MaterialPageRoute(builder: (_) => detail.screen)));
        await tester.pumpAndSettle();
        expect(find.byType(MusicScreen), findsOneWidget);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('Back'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(MusicScreen), findsNothing);
        expect(find.text('Origin'), findsOneWidget);
      }
    });
  }

  testWidgets('direct playlist returns through channel history before leaving',
      (tester) async {
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const MusicScreen(playlistId: 'PLpublic'))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('First song'), 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.widgetWithText(TextButton, 'Artist').first);
    await tester.pumpAndSettle();
    expect(find.text('Artist description'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-play-all')), findsOneWidget);
    expect(find.byType(MusicScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Origin'), findsOneWidget);
    expect(find.byType(MusicScreen), findsNothing);
  });

  testWidgets(
      'tablet artist panes scroll independently and restore the browse origin',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final tracks = List.generate(
        40,
        (index) => MusicTrack(
            videoId: 'tablet${index.toString().padLeft(5, '0')}',
            title: 'Tablet song $index',
            artists: const ['Artist']));
    final releases = List.generate(
        24,
        (index) => MusicCollection(
            id: 'OLAK5uy_tablet_release_$index', title: 'Release $index'));
    catalog.pendingArtist = Completer<MusicArtistPage>()
      ..complete(MusicArtistPage(
          artist: artist, description: 'Tablet artist summary', songs: tracks));
    catalog.releasePages[null] = MusicArtistReleases(releases: releases);
    catalog.collection = const MusicCollection(
        id: 'OLAK5uy_tablet_release_12',
        title: 'Nested tablet release',
        tracks: [first, second]);
    player.commitSelection([first.toVideo(), second.toVideo()], 1, mini: true);
    final listening = player.state;

    await show(tester, screen: const Scaffold(body: Text('Browse origin')));
    final navigator = Navigator.of(tester.element(find.text('Browse origin')));
    unawaited(navigator.push<void>(
        MaterialPageRoute(builder: (_) => MusicScreen(artistId: artist.id))));
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('music-collection-details-pane'));
    final list = find.byKey(const ValueKey('music-collection-tracks-pane'));
    double position(Finder pane) => tester
        .state<ScrollableState>(
            find.descendant(of: pane, matching: find.byType(Scrollable)).first)
        .position
        .pixels;
    expect(tester.getRect(details).right, lessThan(tester.getRect(list).left));
    for (final (pane, label) in [
      (details, 'Collection details'),
      (list, 'Collection tracks'),
    ]) {
      final semantics = tester.getSemantics(pane).getSemanticsData();
      expect(semantics.label, label);
      expect(semantics.role, SemanticsRole.region);
    }
    expect(
        find.descendant(
            of: details, matching: find.text('Tablet artist summary')),
        findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('Tablet song 0')),
        findsOneWidget);

    await tester.drag(list, const Offset(0, -480));
    await tester.pumpAndSettle();
    final trackOffset = position(list);
    expect(trackOffset, greaterThan(200));
    expect(position(details), 0);
    final release =
        find.byKey(const ValueKey('music-release-OLAK5uy_tablet_release_12'));
    await tester.ensureVisible(release);
    await tester.pumpAndSettle();
    final detailsOffset = position(details);
    expect(detailsOffset, greaterThan(200));
    expect(position(list), trackOffset);

    await tester.tap(release);
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: details, matching: find.text('Nested tablet release')),
        findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('First song')),
        findsOneWidget);
    final up = find.byKey(const ValueKey('music-browser-up'));
    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(position(details), closeTo(detailsOffset, 1));
    expect(position(list), closeTo(trackOffset, 1));
    await tester.longPress(up);
    await tester.pumpAndSettle();
    expect(find.text('Browse origin'), findsOneWidget);
    expect(find.byType(MusicScreen), findsNothing);
    expect(catalog.artistRequests, [artist.id]);
    expect(catalog.playlistRequests, [releases[12].id]);
    expect(player.state, same(listening));
    expect(player.calls, isEmpty);
  });

  testWidgets('catalog panes fit large text and follow RTL reading order',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 740);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    catalog.collection = MusicCollection(
      id: 'PLpublic',
      title: 'Public playlist',
      tracks: [
        first,
        for (var index = 0; index < 30; index++)
          MusicTrack(
              videoId: 'fit${index.toString().padLeft(8, '0')}',
              title: 'Catalog track $index'),
      ],
    );
    await show(tester, screen: Builder(builder: (context) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
        child: const Directionality(
          textDirection: TextDirection.rtl,
          child: MusicScreen(playlistId: 'PLpublic'),
        ),
      );
    }));
    await tester.pumpAndSettle();
    final details = find.byKey(const ValueKey('music-collection-details-pane'));
    final tracks = find.byKey(const ValueKey('music-collection-tracks-pane'));
    final scroll =
        find.descendant(of: tracks, matching: find.byType(Scrollable)).first;
    final viewport = tester.state<ScrollableState>(scroll);
    final playAll = find.byKey(const ValueKey('music-play-all'));
    expect(tester.getRect(details).left,
        greaterThan(tester.getRect(tracks).right));
    expect(find.descendant(of: details, matching: playAll), findsOneWidget);
    expect(find.descendant(of: tracks, matching: find.text('First song')),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(tracks, const Offset(0, -260));
    await tester.pumpAndSettle();
    final offset = viewport.position.pixels;
    expect(offset, greaterThan(100));

    tester.view.physicalSize = const Size(570, 900);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(tester.state<ScrollableState>(scroll), same(viewport));
    expect(viewport.position.pixels, closeTo(offset, 1));
    viewport.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.descendant(of: tracks, matching: playAll), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(catalog.playlistRequests, ['PLpublic']);
  });

  testWidgets(
      'holding catalog Up skips to retained Search and drops a late album',
      (tester) async {
    const query = 'retained artist query';
    const release = MusicCollection(
      id: 'OLAK5uy_browse_release',
      title: 'Artist release',
      tracks: [first, second],
    );
    catalog.releasePages[null] = const MusicArtistReleases(releases: [release]);
    catalog.collection = release;
    player.commitSelection([first.toVideo(), second.toVideo()], 1, mini: true);
    final listening = player.state;
    await show(tester, screen: const Scaffold(body: Text('Search origin')));
    final navigator = Navigator.of(tester.element(find.text('Search origin')));
    unawaited(navigator.push<void>(
        MaterialPageRoute(builder: (_) => const MusicScreen(embedded: true))));
    await tester.pumpAndSettle();
    final channels = find.widgetWithText(ChoiceChip, 'Channels');
    await tester.tap(channels);
    await search(tester, query);
    await tester.pumpAndSettle();
    expect(catalog.artistSearches, [query]);
    await tester.tap(find.text(artist.name));
    await tester.pumpAndSettle();
    expect(find.text('Artist description'), findsOneWidget);
    final entry =
        find.byKey(const ValueKey('music-release-OLAK5uy_browse_release'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final up = find.byKey(const ValueKey('music-browser-up'));
    expect(find.byKey(const ValueKey('music-play-all')), findsOneWidget);
    final data = tester.getSemantics(up).getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(
        data.customSemanticsActionIds!
            .map((id) => CustomSemanticsAction.getAction(id)?.label),
        contains('Return to Music search results'));
    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(find.text('Artist description'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-play-all')), findsNothing);
    expect(find.text('Search origin'), findsNothing);

    final lateAlbum = catalog.pendingPlaylist = Completer<MusicCollection>();
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(up.hitTestable(), findsOneWidget);
    await tester.longPress(up);
    await tester.pumpAndSettle();
    final field =
        tester.widget<TextField>(find.byKey(const ValueKey('music-search')));
    expect(field.controller!.text, query);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.widget<ChoiceChip>(channels).selected, isTrue);
    expect(find.widgetWithText(ListTile, artist.name), findsOneWidget);
    expect(find.text('Artist description'), findsNothing);
    expect(find.text('Search origin'), findsNothing);
    expect(up, findsNothing);
    expect(catalog.artistSearches, [query]);
    expect(catalog.artistRequests, [artist.id]);
    expect(catalog.releaseRequests, [null]);
    expect(catalog.playlistRequests, [release.id, release.id]);
    expect(player.state, same(listening));

    lateAlbum.complete(const MusicCollection(
        id: 'OLAK5uy_browse_release', title: 'Discarded late album'));
    await tester.pumpAndSettle();
    expect(find.text('Discarded late album'), findsNothing);
    expect(find.widgetWithText(ListTile, artist.name), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Search origin'), findsOneWidget);
    expect(player.state, same(listening));
    expect(player.calls, isEmpty);
  });

  testWidgets(
      'holding Up from directly opened details returns one route to playback',
      (tester) async {
    const release = MusicCollection(
        id: 'OLAK5uy_direct_release', title: 'Direct release', tracks: [first]);
    catalog.releasePages[null] = const MusicArtistReleases(releases: [release]);
    catalog.collection = release;
    player.commitSelection([first.toVideo(), second.toVideo()], 1);
    final listening = player.state;
    await show(tester, screen: const Scaffold(body: Text('Outside playback')));
    final navigator =
        Navigator.of(tester.element(find.text('Outside playback')));
    unawaited(navigator.push<void>(MaterialPageRoute(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => unawaited(MusicScreen.openPlayingSource(
              context, const MusicScreen(artistId: 'UCartist'),
              television: false)),
          child: const Text('Open currently playing source'),
        ),
      ),
    )));
    await tester.pumpAndSettle();
    final origin = find.text('Open currently playing source');
    final releaseRow =
        find.byKey(const ValueKey('music-release-OLAK5uy_direct_release'));
    final up = find.byKey(const ValueKey('music-browser-up'));
    for (final useAccessibilityAction in [false, true]) {
      await tester.tap(origin);
      await tester.pumpAndSettle();
      expect(find.text('Artist description'), findsOneWidget);
      await tester.ensureVisible(releaseRow);
      await tester.tap(releaseRow);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('music-play-all')), findsOneWidget);
      final node = tester.getSemantics(up);
      final data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      final returnAction = data.customSemanticsActionIds!.singleWhere((id) =>
          CustomSemanticsAction.getAction(id)?.label ==
          'Return to previous screen');
      if (useAccessibilityAction) {
        node.owner!
            .performAction(node.id, SemanticsAction.customAction, returnAction);
      } else {
        await tester.longPress(up);
      }
      await tester.pumpAndSettle();
      expect(find.byType(MusicScreen), findsNothing);
      expect(origin, findsOneWidget);
      expect(find.text('Outside playback'), findsNothing);
      expect(navigator.canPop(), isTrue);
      expect(player.state, same(listening));
      expect(player.calls, isEmpty);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Outside playback'), findsOneWidget);
  });

  testWidgets('searching from a direct detail keeps Back to search behavior',
      (tester) async {
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const MusicScreen(playlistId: 'PLpublic'))));
    await tester.pumpAndSettle();
    await search(tester, 'song');
    catalog.responses.single.complete([first]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artist'));
    await tester.pumpAndSettle();
    expect(find.text('Artist description'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MusicScreen), findsOneWidget);
    expect(find.text('First song'), findsOneWidget);
    expect(find.text('Artist description'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Origin'), findsOneWidget);
  });

  testWidgets('channel search opens uploads and returns to its search results',
      (tester) async {
    await show(tester);
    await tester.tap(find.text('Channels'));
    await search(tester, 'artist');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artist'));
    await tester.pumpAndSettle();
    expect(catalog.artistRequests, ['UCartist']);
    expect(find.text('Popular uploads'), findsOneWidget);
    expect(find.text('Albums'), findsNothing);
    expect(find.text('Singles and EPs'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('music-play-artist-songs')));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((v) => v.videoId),
        [first.videoId, second.videoId]);
    await tester.ensureVisible(find.text('Second song'));
    await tester.tap(find.text('Second song'));
    await tester.pumpAndSettle();
    expect(player.calls.last.videos.map((v) => v.videoId),
        [first.videoId, second.videoId]);
    expect(player.calls.last.startIndex, 1);
    expect(player.calls.map((call) => call.queueTitle),
        [artist.name, artist.name]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Artist description'), findsNothing);
    expect(find.text('Artist'), findsOneWidget);
  });

  testWidgets('a later search row supersedes an unfinished playback selection',
      (tester) async {
    player.holdSelections = true;
    await show(tester, screen: const MusicScreen(initialQuery: 'songs'));
    catalog.responses.single.complete([first, second]);
    await tester.pumpAndSettle();
    await tester.tap(find.text(first.title));
    await tester.pump();
    expect(player.calls.single.startIndex, 0);
    await tester.tap(find.text(second.title));
    await tester.pump();
    expect(player.calls.map((call) => call.startIndex), [0, 1]);
    expect(player.pendingSelections.first.isCompleted, isFalse);
    player.commitSelection(player.calls.last.videos, 1);
    player.pendingSelections.last.complete();
    await tester.pump();
    player.pendingSelections.first
        .completeError(StateError('Obsolete selection'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    expect(player.state.currentQueueId, second.videoId);
    expect(catalog.searches, ['songs']);
  });

  testWidgets('search rows and both Play menus keep the visible song queue',
      (tester) async {
    await tester.runAsync(installCommunityMusicFilters);
    await show(tester);
    await search(tester, 'songs');
    const hidden = MusicTrack(
        videoId: 'hiddenmusic',
        title: 'Listed song',
        uploaderChannelId: musicListedUploader);
    catalog.responses.single.complete([first, hidden, first, second]);
    await tester.pumpAndSettle();

    final selected =
        find.byKey(ValueKey('music-song-search-1-${first.videoId}'));
    await tester.ensureVisible(selected);
    await tester.tap(selected);
    await tester.pumpAndSettle();
    await tester.longPress(selected);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-song-play')));
    await tester.pumpAndSettle();
    expect(player.calls, hasLength(2));
    for (final call in player.calls) {
      expect(call.videos.map((v) => v.videoId),
          [first.videoId, first.videoId, second.videoId]);
      expect(call.startIndex, 1);
    }

    final reveal = find.textContaining('Show hidden results');
    await tester.ensureVisible(reveal);
    await tester.tap(reveal);
    await tester.pumpAndSettle();
    final actions = find.descendant(
        of: find.byKey(ValueKey('music-song-search-2-${first.videoId}')),
        matching: find.byTooltip('Music actions'));
    await tester.ensureVisible(actions);
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-song-play')));
    await tester.pumpAndSettle();
    expect(player.calls, hasLength(3));
    expect(player.calls.last.videos.map((v) => v.videoId),
        [first.videoId, hidden.videoId, first.videoId, second.videoId]);
    expect(player.calls.last.startIndex, 2);
    expect(catalog.searches, ['songs']);
    expect(catalog.songObserver, isNull);
  });

  testWidgets('song artist links open the matching artist', (tester) async {
    await show(tester);
    await search(tester, 'first');
    catalog.responses.single.complete([first]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artist'));
    await tester.pumpAndSettle();
    expect(catalog.artistRequests, ['UCartist']);
    expect(find.text('Artist description'), findsOneWidget);
    expect(player.calls, isEmpty);
  });

  testWidgets('public playlist search opens ordered songs', (tester) async {
    await show(tester);
    await tester.tap(find.text('Playlists'));
    await search(tester, 'public');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Public playlist'));
    await tester.pumpAndSettle();
    expect(catalog.playlistRequests, ['PLpublic']);
    await tester.tap(find.byKey(const ValueKey('music-play-all')));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((v) => v.videoId),
        [first.videoId, second.videoId]);
  });

  testWidgets('artist releases page into the existing playlist flow',
      (tester) async {
    const album =
        MusicCollection(id: 'OLAK5uy_release', title: 'First release');
    const single = MusicCollection(id: 'OLAK5uy_single', title: 'Next release');
    catalog.releasePages[null] =
        const MusicArtistReleases(releases: [album], continuation: 'next');
    catalog.releasePages['next'] =
        const MusicArtistReleases(releases: [album, single]);
    await show(tester, screen: const MusicScreen(artistId: 'UCartist'));
    await tester.pumpAndSettle();

    expect(find.text('Releases'), findsOneWidget);
    expect(find.text(album.title), findsOneWidget);
    await tester.ensureVisible(find.text('Load more'));
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(catalog.releaseRequests, [null, 'next']);
    expect(find.text(album.title), findsOneWidget);
    expect(find.text(single.title), findsOneWidget);

    await tester.ensureVisible(find.text(single.title));
    await tester.tap(find.text(single.title));
    await tester.pumpAndSettle();
    expect(catalog.playlistRequests, [single.id]);
    expect(find.byKey(const ValueKey('music-play-all')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(single.title), findsOneWidget);
    expect(catalog.releaseRequests, [null, 'next']);
  });

  for (final failed in [false, true]) {
    testWidgets(
        'Back from a ${failed ? 'failed' : 'pending'} release returns to its artist',
        (tester) async {
      const album = MusicCollection(id: 'OLAK5uy_release', title: 'Release');
      catalog.releasePages[null] = const MusicArtistReleases(releases: [album]);
      await show(tester, screen: const Scaffold(body: Text('Origin')));
      final navigator = Navigator.of(tester.element(find.text('Origin')));
      unawaited(navigator.push<void>(MaterialPageRoute(
          builder: (_) => const MusicScreen(artistId: 'UCartist'))));
      await tester.pumpAndSettle();
      final request = catalog.pendingPlaylist = Completer<MusicCollection>();
      await tester.tap(find.text(album.title));
      await tester.pump();
      expect(catalog.playlistRequests, [album.id]);
      if (failed) {
        request.completeError(StateError('Playlist unavailable'));
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsOneWidget);
        await tester.tap(find.byTooltip('Back'));
      } else {
        await tester.binding.handlePopRoute();
        request.complete(catalog.collection);
      }
      await tester.pumpAndSettle();
      expect(find.text(album.title), findsOneWidget);
      expect(find.text('Artist description'), findsOneWidget);
      expect(catalog.artistRequests, [artist.id]);
      expect(catalog.releaseRequests, [null]);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Origin'), findsOneWidget);
    });
  }

  testWidgets('artist release pagination waits for the instance cooldown',
      (tester) async {
    const firstRelease =
        MusicCollection(id: 'OLAK5uy_release', title: 'First release');
    const nextRelease =
        MusicCollection(id: 'OLAK5uy_next', title: 'Next release');
    catalog.releasePages[null] = const MusicArtistReleases(
        releases: [firstRelease], continuation: 'next');
    catalog.releasePages['next'] =
        const MusicArtistReleases(releases: [nextRelease]);
    await show(tester, screen: const MusicScreen(artistId: 'UCartist'));
    await tester.pumpAndSettle();
    catalog.releaseFailure = InvidiousServiceError('Too many requests',
        statusCode: 429, retryAfter: const Duration(minutes: 1));
    await tester.ensureVisible(find.text('Load more'));
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    final retry = find.widgetWithText(TextButton, 'Retry');
    expect(find.text(firstRelease.title), findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    expect(catalog.releaseRequests, [null, 'next']);

    catalog.releaseFailure = null;
    await tester.pump(const Duration(minutes: 1));
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.text(nextRelease.title), findsOneWidget);
    expect(catalog.releaseRequests, [null, 'next', 'next']);
  });

  testWidgets('starting a later playlist song retains its complete queue',
      (tester) async {
    await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Second song'), 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Second song'));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((video) => video.videoId),
        [first.videoId, second.videoId]);
    expect(player.calls.single.startIndex, 1);
    expect(player.calls.single.audio, isTrue);
  });

  testWidgets('late artist detail cannot replace a newer search',
      (tester) async {
    catalog.pendingArtist = Completer<MusicArtistPage>();
    await show(tester, screen: const MusicScreen(artistId: 'UCartist'));
    await search(tester, 'second');
    catalog.responses.single.complete([second]);
    await tester.pumpAndSettle();
    catalog.pendingArtist!.complete(const MusicArtistPage(artist: artist));
    await tester.pumpAndSettle();
    expect(find.text('Second song'), findsOneWidget);
    final locals =
        AppLocalizations.of(tester.element(find.byType(MusicScreen)))!;
    expect(find.text(locals.musicArtistEmpty), findsNothing);
  });

  testWidgets(
      'narrow large-text search filters stay reachable without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await show(tester);
    await tester.drag(find.byKey(const ValueKey('music-search-filters')),
        const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Playlists'))
            .selected,
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV directional and Select keys change search kind',
      (tester) async {
    isTv = true;
    await show(tester);
    Focus.of(tester.element(find.text('Songs'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Channels'))
            .selected,
        isTrue);
    isTv = false;
  });

  testWidgets('TV cold playlist route starts with focus on the search action',
      (tester) async {
    isTv = true;
    addTearDown(() => isTv = false);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.byIcon(Icons.search))).hasPrimaryFocus,
        isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('TV Up from playlist Play all reaches Resume listening',
      (tester) async {
    isTv = true;
    addTearDown(() => isTv = false);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => db.saveSetting(SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
                videos: [first.toVideo()],
                currentId: first.videoId,
                seconds: 42,
                audio: true)
            .encode())));
    await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('Play all'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
        Focus.of(tester.element(find.text('Resume listening'))).hasPrimaryFocus,
        isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
      'TV local resume shows progress, then retries a failed folder scan',
      (tester) async {
    isTv = true;
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    const tree = 'content://documents/tree/Music';
    const song =
        LocalMusicTrack(uri: '$tree/document/recording', title: 'Recording');
    final scans = <Completer<List<Object?>>>[];
    final platformCalls = <String>[];
    var accessible = true;
    var rejectedAccessChecks = 0;
    var selectingFolder = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const audioSession = MethodChannel('com.ryanheise.audio_session');
    messenger.setMockMethodCallHandler(audioSession, (call) async {
      platformCalls.add('audio session ${call.method}');
      return null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      platformCalls.add('local library ${call.method}');
      switch (call.method) {
        case 'getFolder':
        case 'pickFolder':
          return {'uri': tree, 'name': 'Music', 'selectionId': 'current'};
        case 'checkFolderAccess':
          if (!accessible) rejectedAccessChecks++;
          return accessible;
        case 'listTracks':
          if (selectingFolder) {
            throw PlatformException(code: 'SCAN_INTERRUPTED');
          }
          final scan = Completer<List<Object?>>();
          scans.add(scan);
          return scan.future;
        case 'forgetFolder':
          return null;
        default:
          throw UnsupportedError(call.method);
      }
    });
    addTearDown(() async {
      await LocalMusicLibrary.instance.disable();
      messenger.setMockMethodCallHandler(audioSession, null);
      messenger.setMockMethodCallHandler(channel, null);
      isTv = false;
    });
    // Choose the grant explicitly because an earlier Library search can have
    // initialized the singleton before this fixture installs its native mock.
    // An interrupted first scan leaves the grant usable for the lazy Resume.
    final chosen = await tester.runAsync(() => LocalMusicLibrary.instance
        .chooseFolder()
        .timeout(const Duration(seconds: 3)));
    expect(chosen, isTrue);
    selectingFolder = false;
    expect(LocalMusicLibrary.instance.loaded, isFalse);
    expect(scans, isEmpty);

    Future<void> pumpUntil(bool Function() observed) async {
      await tester.pump();
      for (var attempt = 0; attempt < 10 && !observed(); attempt++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(observed(), isTrue, reason: 'Platform calls $platformCalls');
    }

    await tester.runAsync(() => db.saveSetting(SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
                offlineIds: [song.playbackId],
                currentId: song.playbackId,
                seconds: 17,
                audio: true,
                localSelectionId: 'current')
            .encode())));
    await show(tester);
    await tester.pump();
    await tester.tap(find.text('Resume listening'));
    await pumpUntil(() => scans.length == 1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.runAsync(() async {
      scans.first.complete([]);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await pumpUntil(() => scans.length == 2);
    expect(find.text('Retry'), findsNothing);
    await tester.runAsync(() async {
      scans.last.completeError(PlatformException(code: 'FOLDER_UNAVAILABLE'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    accessible = false;
    await tester.tap(find.text('Retry'));
    await pumpUntil(() =>
        rejectedAccessChecks == 1 && find.text('Retry').evaluate().isNotEmpty);
    expect(scans, hasLength(2));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'dormant music resumes its session instead of starting a new queue',
      (tester) async {
    await tester.runAsync(() => db.saveSetting(SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
                videos: [first.toVideo()],
                currentId: first.videoId,
                seconds: 42,
                audio: true)
            .encode())));
    await show(tester);
    expect(find.text('Resume listening'), findsOneWidget);
    await tester.tap(find.text('Resume listening'));
    await tester.pumpAndSettle();
    expect(player.resumes, 1);
    expect(player.resumedFromMusic, isTrue);
    expect(player.calls, isEmpty);
  });

  testWidgets('active music opens now playing without resetting position',
      (tester) async {
    await tester.runAsync(() async {
      await player.close();
      player = _Player(
          PlayerState.init([first.toVideo()]).copyWith(
              currentlyPlaying: first.toVideo(),
              isAudio: true,
              isHidden: false,
              position: const Duration(seconds: 42)),
          settings);
    });
    await show(tester);
    expect(find.text('Resume listening'), findsNothing);
    await tester.tap(find.text('Now playing'));
    await tester.pumpAndSettle();
    expect(player.shows, 1);
    expect(player.resumes, 0);
    expect(player.calls, isEmpty);
    expect(player.state.position, const Duration(seconds: 42));
  });

  testWidgets('music resume recognizes the repeated final queue entry',
      (tester) async {
    final repeated = first.toVideo().copyWith(queueEntryId: 'entry-second');
    await tester.runAsync(() => db.saveSetting(SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
            videos: [first.toVideo(), second.toVideo(), repeated],
            currentId: 'entry-second',
            seconds: 42,
            audio: true,
            played: [first.videoId, second.videoId]).encode())));
    await show(tester);
    expect(find.text('Resume listening'), findsOneWidget);
    await tester.tap(find.text('Resume listening'));
    await tester.pumpAndSettle();
    expect(player.resumes, 1);
    expect(player.calls, isEmpty);
    expect(player.savedSession?.currentId, 'entry-second');
  });

  testWidgets(
      'music resume recognizes a repeated saved download by its source ID',
      (tester) async {
    final repeated = '${first.videoId}#1';
    await tester.runAsync(() async {
      await db.upsertDownload(DownloadedVideo(
          videoId: first.videoId,
          title: first.title,
          musicMetadata: first.toVideo().musicMetadata,
          downloadComplete: true,
          audioOnly: true,
          lengthSeconds: 180,
          quality: 'Audio'));
      await db.saveSetting(SettingsValue(
          playbackSessionSetting,
          PlaybackSession(
                  offlineIds: [first.videoId, repeated],
                  currentId: repeated,
                  played: [first.videoId],
                  seconds: 42,
                  audio: true)
              .encode()));
    });
    await show(tester);
    await tester.tap(find.text('Resume listening'));
    await tester.pumpAndSettle();
    expect(player.resumes, 1);
    expect(player.savedSession?.currentId, repeated);
    expect(player.savedSession?.seconds, 42);
    expect(player.calls, isEmpty);
  });

  testWidgets(
      'a deliberately saved video session is not offered as music resume',
      (tester) async {
    await tester.runAsync(() => db.saveSetting(SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
                videos: [first.toVideo()],
                currentId: first.videoId,
                seconds: 42,
                audio: false)
            .encode())));
    await show(tester);
    expect(find.text('Resume listening'), findsNothing);
  });

  for (final complete in [false, true]) {
    testWidgets(
        'offline resume availability requires complete download ($complete)',
        (tester) async {
      await tester.runAsync(() async {
        await db.upsertDownload(DownloadedVideo(
            videoId: first.videoId,
            title: first.title,
            musicMetadata: first.toVideo().musicMetadata,
            downloadComplete: complete,
            audioOnly: true,
            lengthSeconds: 180,
            quality: 'Audio'));
        await db.saveSetting(SettingsValue(
            playbackSessionSetting,
            PlaybackSession(
                    offlineIds: [first.videoId],
                    currentId: first.videoId,
                    seconds: 42,
                    audio: true)
                .encode()));
      });
      await show(tester);
      expect(find.text('Resume listening'),
          complete ? findsOneWidget : findsNothing);
    });
  }
}
