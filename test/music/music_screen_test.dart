import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction, SemanticsRole;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_card_origin.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_collection_order.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/music_song_row_swipe_action.dart';
import 'package:clipious/music/services/cached_music.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/services/music_offline_lyrics.dart';
import 'package:clipious/music/services/music_online_recents.dart';
import 'package:clipious/music/views/components/music_playlist_recommendation_toggle.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_collection_sort_menu.dart';
import 'package:clipious/player/models/named_music_queue.dart';
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
import 'package:clipious/settings/views/screens/browsing.dart';
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
  final playlistOverlapRequests = <({
    String playlistId,
    List<String> savedIds,
    bool Function() isCurrent,
  })>[];
  Future<List<MusicPlaylist>>? playlistOverlap;

  @override
  Future<List<MusicPlaylist>> findPlaylistsWithSongsInCommon(
      String playlistId, List<String> savedPlaylistIds,
      {required bool Function() isCurrent}) {
    playlistOverlapRequests.add((
      playlistId: playlistId,
      savedIds: List.of(savedPlaylistIds),
      isCurrent: isCurrent,
    ));
    return playlistOverlap ?? Future.value(const []);
  }

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
  final uploadRequests = <Completer<List<MusicTrack>>>[];
  final playlistRequests = <String>[];
  Completer<MusicArtistPage>? pendingArtist;
  Completer<MusicCollection>? pendingPlaylist;
  void Function(MusicCollection)? playlistProgress;
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
  Future<MusicCollection> getPlaylistProgressively(String id,
      {required void Function(MusicCollection) onProgress,
      required bool Function() isCurrent}) {
    playlistProgress = onProgress;
    return getPlaylist(id);
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
  Future<List<MusicTrack>> getArtistUploads(String id,
      {bool Function()? isCurrent}) {
    final request = Completer<List<MusicTrack>>();
    uploadRequests.add(request);
    return request.future;
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

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads(super.initialState);

  @override
  final storage = DownloadStorage();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends TestPlayerCubit {
  final calls = <({
    List<Video> videos,
    bool? audio,
    Duration? startAt,
    String? queueTitle,
    int? startIndex,
    bool songTap,
    bool collectionDetail,
  })>[];

  final offlineCalls = <({
    List<OnDeviceMusicEntry> tracks,
    int startIndex,
    bool? currentWhenCalled,
  })>[];
  _Player(super.initialState, super.settings);

  MusicCardOrigin? cardOrigin;

  @override
  Future<void> playMusicFromCard(List<Video> videos,
      {required MusicCardOrigin origin,
      Duration? startAt,
      int? startIndex,
      String? queueTitle,
      PlaylistReference? recommendationSource,
      bool songTap = false,
      bool collectionDetail = false}) {
    cardOrigin = origin;
    return playVideo(videos,
        audio: true,
        startAt: startAt,
        startIndex: startIndex,
        queueTitle: queueTitle,
        recommendationSource: recommendationSource,
        songTap: songTap,
        collectionDetail: collectionDetail,
        fromMusic: true);
  }

  int resumes = 0;
  bool? resumedFromMusic;
  int shows = 0;
  bool? sponsorFailureIsAsync;
  bool shuffledPlaylist = false;
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
      bool fromMusic = false,
      bool songTap = false,
      bool collectionDetail = false,
      PlaylistReference? recommendationSource}) async {
    _selectionRevision++;
    calls.add((
      videos: videos,
      audio: audio,
      startAt: startAt,
      queueTitle: queueTitle,
      startIndex: startIndex,
      songTap: songTap,
      collectionDetail: collectionDetail,
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
  Future<void> playMusicCollectionQueue(List<Video> tracks,
      {required String queueTitle,
      int? startIndex,
      bool shuffle = false,
      bool songTap = false,
      bool collectionDetail = false,
      List<PlaylistReference?>? recommendationSources,
      bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return;
    await playVideo(tracks,
        audio: true,
        startAt: Duration.zero,
        queueTitle: queueTitle,
        startIndex: startIndex ?? 0,
        songTap: songTap,
        collectionDetail: collectionDetail,
        fromMusic: true);
  }

  @override
  Future<void> playOnDeviceMusic(List<OnDeviceMusicEntry> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool songTap = false,
      bool collectionDetail = false,
      bool retainQueueOrder = false,
      bool Function()? isCurrent}) async {
    offlineCalls.add((
      tracks: List.of(tracks),
      startIndex: startIndex,
      currentWhenCalled: isCurrent?.call(),
    ));
  }

  @override
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      bool shuffleOnce = false,
      PlaylistLoadSession? playlistLoader,
      bool fromMusic = false,
      bool songTap = false,
      bool collectionDetail = false}) async {
    shuffledPlaylist = shuffleOnce;
    calls.add((
      videos: entries,
      audio: audio,
      startAt: startAt,
      queueTitle: reference.displayTitle,
      startIndex: startIndex,
      songTap: songTap,
      collectionDetail: collectionDetail,
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

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (_) async => throw MissingPluginException());
    isTv = false;
    previousService = service;
    service = Service();
    db = await SembastSqfDb.createInMemory();
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    try {
      // Library startup reads this profile's cover preference on the real clock.
      await LocalMusicLibrary.instance.initialize();
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
    // Run the profile's queue setup on the real database clock.
    await db.saveSetting(SettingsValue(
        namedMusicQueuesSetting, NamedMusicQueue.encodeAll(const [])));
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
      {Widget screen = const MusicScreen(), _Downloads? downloads}) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
        if (downloads != null)
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
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

  Future<void> waitForLibraryCategories(
      WidgetTester tester, String expected) async {
    const setting = 'music-library-search-categories-v1';
    final owner = db.forProfile(db.profileId);
    String? saved() => owner.getSettings(setting)?.value;
    for (var attempt = 0; attempt < 20 && saved() != expected; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(saved(), expected);
  }

  testWidgets('Music recents are opt-in, editable, removable, and clearable',
      (tester) async {
    final recents = MusicOnlineRecents.forProfile(db, db.profileId);
    final history = find.byTooltip('Recent Music searches');
    final field = find.byKey(const ValueKey('music-search'));

    Future<void> waitForWrite(bool Function() done) async {
      for (var attempt = 0; attempt < 20 && !done(); attempt++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(done(), isTrue);
      await tester.pumpAndSettle();
    }

    Future<void> toggleRecents(bool enabled) async {
      await show(tester, screen: const BrowsingSettingsScreen());
      final tile = find.text('Remember Music searches');
      final settingsList = find
          .descendant(
            of: find.byType(BrowsingSettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(tile, 200, scrollable: settingsList);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await waitForWrite(() => recents.enabled == enabled);
      await show(tester, screen: const MusicScreen(embedded: true));
    }

    await show(tester, screen: const MusicScreen(embedded: true));
    expect(history, findsNothing);
    await search(tester, 'Private query');
    catalog.responses.last.complete([]);
    await tester.pumpAndSettle();
    expect(recents.queries, isEmpty);

    await toggleRecents(true);
    expect(history, findsOneWidget);
    await tester.enterText(field, 'Unsubmitted draft');
    expect(recents.queries, isEmpty);
    await search(tester, 'First query');
    catalog.responses.last.complete([]);
    await waitForWrite(() => recents.queries.contains('First query'));
    await search(tester, 'Second query');
    catalog.responses.last.complete([]);
    await waitForWrite(() => recents.queries.length == 2);

    await tester.tap(history);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit saved search').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Edited query');
    await tester.tap(find.text('Save'));
    await waitForWrite(() => recents.queries.first == 'Edited query');
    final providerCalls = catalog.suggestionRequests.length;
    await tester.tap(find.text('Edited query'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<TextField>(field).controller!.text, 'Edited query');
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(catalog.searches, ['Private query', 'First query', 'Second query']);
    expect(catalog.suggestionRequests, hasLength(providerCalls));

    await tester.tap(history);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove saved search').last);
    await waitForWrite(() => recents.queries.length == 1);
    expect(recents.queries, ['Edited query']);
    await tester.tap(find.text('Clear search history'));
    await waitForWrite(() => recents.queries.isEmpty);
    expect(find.text('No recent Music searches'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await toggleRecents(false);
    expect(history, findsNothing);
  });

  testWidgets('leaving the profile session closes the Music recents dialog',
      (tester) async {
    final recents = MusicOnlineRecents.forProfile(db, db.profileId);
    await tester.runAsync(() async {
      await recents.setEnabled(true);
      await recents.recordSubmission('Previous profile query',
          isCurrent: () => true);
    });
    await show(tester, screen: const MusicScreen(embedded: true));
    await tester.tap(find.byTooltip('Recent Music searches'));
    await tester.pumpAndSettle();
    expect(find.text('Previous profile query'), findsOneWidget);

    app.setGlobalLoading(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Previous profile query'), findsNothing);
    expect(recents.queries, ['Previous profile query']);
  });

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

  group('Music voice search', () {
    const channel = MethodChannel('videre/music_voice_search');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final mic = find.byKey(const ValueKey('music-voice-search'));
    final field = find.byKey(const ValueKey('music-search'));

    void mockProvider(Future<String?> Function(MethodCall) recognize,
        {bool available = true}) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isAvailable') return available;
        expect(call.method, 'recognize');
        return recognize(call);
      });
    }

    Future<void> openConsent(WidgetTester tester) async {
      await tester.tap(mic);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('may send your audio'), findsOneWidget);
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.text('Use microphone'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    String draft(WidgetTester tester) =>
        tester.widget<TextField>(field).controller!.text;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    testWidgets('recognition uses the app locale and fills an editable draft',
        (tester) async {
      await tester.runAsync(() async {
        await settings.saveSetting(SettingsValue(localeSettingName, 'pt_BR'));
      });
      var launches = 0;
      mockProvider((call) async {
        launches++;
        expect(call.arguments, {'languageTag': 'pt-BR'});
        return '  João Gilberto  ';
      });
      await show(tester, screen: const MusicScreen(embedded: true));
      await tester.pumpAndSettle();
      await openConsent(tester);
      expect(launches, 0);
      await confirm(tester);
      expect(launches, 1);
      expect(draft(tester), 'João Gilberto');
      expect(catalog.searches, isEmpty);
      await tester.tap(field);
      await tester.pump(const Duration(milliseconds: 500));
      expect(catalog.suggestionRequests, isEmpty);

      await tester.enterText(field, 'João Gilberto bossa nova');
      await tester.pump(const Duration(milliseconds: 500));
      expect(catalog.suggestionRequests, isEmpty);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Playlists'));
      await tester.pumpAndSettle();
      expect(catalog.searches, isEmpty);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Songs'));
      await tester.pumpAndSettle();
      expect(catalog.searches, isEmpty);

      await search(tester, 'João Gilberto bossa nova');
      expect(catalog.searches, ['João Gilberto bossa nova']);
      expect(catalog.suggestionRequests, isEmpty);
      await tester.enterText(field, 'night jazz');
      await tester.pump(const Duration(milliseconds: 500));
      final suggestion = catalog.suggestionRequests.single;
      expect(suggestion.query, 'night jazz');
      suggestion.response.complete([]);
      await tester.pump();
    });

    testWidgets('unavailable recognition leaves typed search available',
        (tester) async {
      mockProvider((_) async => fail('Recognizer should stay closed'),
          available: false);
      await show(tester);
      await tester.pumpAndSettle();
      expect(mic, findsNothing);
      await search(tester, 'typed query');
      expect(catalog.searches, ['typed query']);
    });

    testWidgets('canceling or failing recognition preserves the typed draft',
        (tester) async {
      var launches = 0;
      mockProvider((call) async {
        expect(call.arguments, isEmpty);
        if (launches++ == 0) return null;
        throw PlatformException(code: 'VOICE_SEARCH_FAILED');
      });
      await show(tester);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'typed draft');

      await openConsent(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(launches, 0);
      expect(draft(tester), 'typed draft');

      await openConsent(tester);
      await confirm(tester);
      expect(launches, 1);
      expect(draft(tester), 'typed draft');

      await openConsent(tester);
      await confirm(tester);
      expect(launches, 2);
      expect(find.textContaining('Voice input failed'), findsOneWidget);
      expect(draft(tester), 'typed draft');
      expect(catalog.searches, isEmpty);
    });

    testWidgets('a delayed transcript cannot replace either source draft',
        (tester) async {
      final result = Completer<String?>();
      mockProvider((_) => result.future);
      await show(tester, screen: const MusicScreen(embedded: true));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'online draft');
      await openConsent(tester);
      await confirm(tester);
      expect(tester.widget<IconButton>(mic).onPressed, isNull);

      await tester
          .tap(find.byKey(const ValueKey('music-search-source-library')));
      await tester.pump();
      await tester.enterText(field, 'library draft');
      result.complete('unwanted transcript');
      await tester.pump();
      expect(draft(tester), 'library draft');

      await tester
          .tap(find.byKey(const ValueKey('music-search-source-online')));
      await tester.pumpAndSettle();
      expect(draft(tester), 'online draft');
      expect(catalog.searches, isEmpty);
    });

    testWidgets('Library voice input only fills the Library draft',
        (tester) async {
      mockProvider((_) async => 'rehearsal');
      await show(tester, screen: const MusicScreen(embedded: true));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'online draft');
      await tester
          .tap(find.byKey(const ValueKey('music-search-source-library')));
      await tester.pump();
      await openConsent(tester);
      await confirm(tester);
      expect(draft(tester), 'rehearsal');

      await tester
          .tap(find.byKey(const ValueKey('music-search-source-online')));
      await tester.pumpAndSettle();
      expect(draft(tester), 'online draft');
      expect(catalog.searches, isEmpty);
    });
  });

  testWidgets('swiping an Online song uses the song queue command',
      (tester) async {
    await tester.runAsync(() =>
        settings.setMusicSongSwipeTowardEnd(MusicSongRowSwipeAction.playNext));
    await show(tester, screen: const MusicScreen(initialQuery: 'two songs'));
    catalog.responses.single.complete([first, second]);
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('music-song-search-0-${first.videoId}'));

    await tester.drag(row, const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((song) => song.videoId),
        [first.videoId]);
    expect(player.calls.single.audio, isTrue);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(player.calls.last.videos.map((song) => song.videoId), [
      first.videoId,
      second.videoId,
    ]);
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

    final songs = find.widgetWithText(FilterChip, 'Songs');
    await tester.tap(songs);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(songs).selected, isTrue);
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
    expect(tester.widget<FilterChip>(songs).selected, isTrue);
    expect(position(libraryView).pixels, closeTo(songsOffset, 1));
    expect(catalog.artistSearches, ['artists']);
    expect(catalog.searches, isEmpty);
  });

  testWidgets('Library categories combine saved songs and local playlists',
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
    final songs = find.widgetWithText(FilterChip, 'Songs');
    final playlists = find.widgetWithText(FilterChip, 'Playlists');
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
    expect(saved, findsOneWidget);
    expect(mix, findsOneWidget);
    expect(tester.widget<FilterChip>(songs).selected, isTrue);
    expect(tester.widget<FilterChip>(playlists).selected, isTrue);
    await tester.tap(songs);
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
    expect(tester.widget<FilterChip>(playlists).selected, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'rehearsal');
    expect(mix, findsOneWidget);

    await tester.tap(online);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(channels).selected, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'artist');
    expect(find.text('Artist'), findsOneWidget);
    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(playlists).selected, isTrue);
    expect(mix, findsOneWidget);
    expect(catalog.artistSearches, ['artist']);
    expect(catalog.searches, isEmpty);
    expect(catalog.playlistSearches, isEmpty);
    expect(catalog.playlistRequests, isEmpty);

    await waitForLibraryCategories(tester, 'playlists');
    app.setGlobalLoading(true);
    await tester.pump();
    app.setGlobalLoading(false);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(all).selected, isFalse);
    expect(tester.widget<FilterChip>(playlists).selected, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets('Library category combinations persist per profile',
      (tester) async {
    const allCategories = 'songs,playlists,albums,artists,genres';
    final local = find.byKey(const ValueKey('music-search-source-library'));
    final all = find.widgetWithText(ChoiceChip, 'All');
    final albums = find.widgetWithText(FilterChip, 'Albums');
    final artists = find.widgetWithText(FilterChip, 'Artists');
    final genres = find.widgetWithText(FilterChip, 'Genres');
    final lyrics = find.widgetWithText(ChoiceChip, 'Lyrics');
    final initial = db.profileId;
    final other = (await tester.runAsync(() => db.createProfile('Other')))!;

    bool selected(Finder chip) => tester.widget<FilterChip>(chip).selected;
    Future<void> tapFilter(Finder chip) async {
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }

    Future<void> openLibrary() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await show(tester, screen: const MusicScreen(embedded: true));
      await tester.tap(local);
      await tester.pumpAndSettle();
    }

    Future<void> useProfile(String id) async {
      await tester.runAsync(() async {
        await db.useProfile(id);
        await app.initState();
      });
      await tester.pumpAndSettle();
      expect(app.state.profileId, id);
    }

    await openLibrary();
    expect(tester.widget<ChoiceChip>(all).selected, isTrue);
    await tapFilter(artists);
    await tapFilter(genres);
    await waitForLibraryCategories(tester, 'artists,genres');
    expect(selected(artists), isTrue);
    expect(selected(genres), isTrue);
    expect(selected(albums), isFalse);

    await tapFilter(lyrics);
    expect(tester.widget<ChoiceChip>(lyrics).selected, isTrue);
    expect(selected(artists), isFalse);
    expect(selected(genres), isFalse);
    await tapFilter(lyrics);
    expect(tester.widget<ChoiceChip>(lyrics).selected, isFalse);
    expect(selected(artists), isTrue);
    expect(selected(genres), isTrue);

    await openLibrary();
    expect(selected(artists), isTrue);
    expect(selected(genres), isTrue);

    await useProfile(other.id);
    expect(tester.widget<ChoiceChip>(all).selected, isTrue);
    await tapFilter(albums);
    await waitForLibraryCategories(tester, 'albums');

    await useProfile(initial);
    expect(selected(artists), isTrue);
    expect(selected(genres), isTrue);
    await tapFilter(all);
    await waitForLibraryCategories(tester, allCategories);
    await openLibrary();
    expect(tester.widget<ChoiceChip>(all).selected, isTrue);

    await useProfile(other.id);
    expect(selected(albums), isTrue);
    await tapFilter(albums);
    await waitForLibraryCategories(tester, allCategories);
    expect(tester.widget<ChoiceChip>(all).selected, isTrue);
    expect(catalog.searches, isEmpty);
    expect(catalog.suggestionRequests, isEmpty);
  });

  testWidgets('Library Search opens local album, artist, and genre details',
      (tester) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    const tree = 'content://documents/tree/MusicSearch';
    const album = 'Mélody Album';
    const artist = 'Mélody Artist';
    const genre = 'Mélody Genre';
    const title = 'Local navigation track';
    const query = 'melody';
    final library = LocalMusicLibrary.instance;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'getFolder' || 'pickFolder' => {
            'uri': tree,
            'name': 'Music Search',
            'selectionId': 'search-groups'
          },
        'checkFolderAccess' => true,
        'listTracks' => [
            {
              'uri': '$tree/document/recording',
              'title': title,
              'album': album,
              'albumKey': 'a' * 64,
              'artist': artist,
              'genre': genre,
            },
          ],
        _ => null,
      };
    });
    addTearDown(() async {
      try {
        await library.disable();
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    final chosen = await tester.runAsync(
        () => library.chooseFolder().timeout(const Duration(seconds: 3)));
    expect(chosen, isTrue);

    Future<void> waitFor(Finder finder) async {
      await tester.pump();
      for (var frame = 0; frame < 12 && finder.evaluate().isEmpty; frame++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finder, findsOneWidget);
      await tester.pumpAndSettle();
    }

    await show(tester, screen: const MusicScreen(embedded: true));
    await tester.tap(find.byKey(const ValueKey('music-search-source-library')));
    await tester.pump();
    await search(tester, query);
    await waitFor(find.widgetWithText(ListTile, album));

    final field = find.byKey(const ValueKey('music-search'));
    final track = find.widgetWithText(ListTile, title);
    for (final group in [album, artist, genre]) {
      final result = find.widgetWithText(ListTile, group);
      expect(result, findsOneWidget);
      await tester.tap(result);
      await waitFor(find.widgetWithText(AppBar, group));
      expect(track, findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, query);
    }

    await tester.tap(find.widgetWithText(ListTile, genre));
    await waitFor(find.widgetWithText(AppBar, genre));
    app.setGlobalLoading(true);
    await tester.pumpAndSettle();
    expect(track, findsNothing);
    expect(catalog.searches, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets('Library lyric search shows a line and plays the recording',
      (tester) async {
    final offline = MusicOfflineLyrics(db);
    const track = MusicMetadata(title: 'Night Train', artist: 'Ensemble');
    await tester.runAsync(() => offline.save(
          first.videoId,
          const MusicLyrics.plain('À la rivière, je chante.'),
          track: track,
          durationSeconds: 30,
        ));

    await show(tester, screen: const MusicScreen(embedded: true));
    await tester.tap(find.byKey(const ValueKey('music-search-source-library')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('music-search'));
    await tester.enterText(field, 'riviere chante');
    await tester.pump();
    final hit = find.widgetWithText(ListTile, track.title);
    expect(hit, findsNothing);

    final lyrics = find.widgetWithText(ChoiceChip, 'Lyrics');
    await tester.ensureVisible(lyrics);
    await tester.tap(lyrics);
    // The shared device catalog initializes during setup outside fake async.
    for (var frame = 0; frame < 8; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(hit, findsOneWidget);
    expect(find.textContaining('À la rivière, je chante.'), findsOneWidget);
    expect(catalog.searches, isEmpty);
    expect(catalog.suggestionRequests, isEmpty);

    await tester.tap(hit);
    await tester.pumpAndSettle();
    final selection = player.calls.single;
    expect(selection.videos.single.videoId, first.videoId);
    expect(selection.audio, isTrue);
    expect(selection.startAt, Duration.zero);

    await tester.runAsync(() => offline.remove(first.videoId));
    await tester.pumpAndSettle();
    expect(hit, findsNothing);
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
    final songs = find.widgetWithText(FilterChip, 'Songs');
    await tester.tap(songs);
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);

    await tester.tap(online);
    await tester.pump();
    await search(tester, 'newer');
    await tester.tap(local);
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);
    expect(tester.widget<FilterChip>(songs).selected, isTrue);
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

  group('Playlists with songs in common', () {
    const heading = 'Playlists with songs in common';
    const related =
        MusicPlaylist(id: 'PLrelated', title: 'Related saved playlist');

    Future<MusicLibraryService> saveCandidate(WidgetTester tester) async {
      final library = MusicLibraryService.forProfile(db, db.profileId);
      await tester.runAsync(() => library.save(MusicLibraryEntry(
          kind: MusicLibraryKind.playlist,
          id: related.id,
          title: related.title)));
      return library;
    }

    testWidgets('opens from Online and restores the source on Back',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1100);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final library = await saveCandidate(tester);
      catalog.playlistOverlap = Future.value(const [related]);
      await show(tester, screen: const MusicScreen(embedded: true));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Playlists'));
      await search(tester, 'music playlists');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public playlist'));
      await tester.pumpAndSettle();

      expect(catalog.playlistOverlapRequests.single.playlistId, 'PLpublic');
      expect(catalog.playlistOverlapRequests.single.savedIds, [related.id]);
      expect(find.text(heading), findsOneWidget);
      final card = find.text(related.title);
      await tester.ensureVisible(card);
      catalog.collection = MusicCollection(
          id: related.id,
          title: 'Opened saved playlist',
          tracks: const [first]);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text('Opened saved playlist'), findsOneWidget);
      expect(catalog.playlistRequests, ['PLpublic', related.id]);

      await tester.tap(find.byKey(const ValueKey('music-browser-up')));
      await tester.pumpAndSettle();
      expect(find.text('Public playlist'), findsOneWidget);
      expect(find.text(heading), findsOneWidget);

      await tester.runAsync(
          () => library.remove(MusicLibraryKind.playlist, related.id));
      await tester.pumpAndSettle();
      expect(find.text(heading), findsNothing);
      expect(card, findsNothing);
      expect(find.text('Public playlist'), findsOneWidget);
    });

    testWidgets('removing a bookmark invalidates a pending overlap result',
        (tester) async {
      final library = await saveCandidate(tester);
      final pending = Completer<List<MusicPlaylist>>();
      catalog.playlistOverlap = pending.future;
      await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
      await tester.pump();
      final lookup = catalog.playlistOverlapRequests.single;
      expect(lookup.savedIds, [related.id]);
      expect(lookup.isCurrent(), isTrue);

      await tester.runAsync(
          () => library.remove(MusicLibraryKind.playlist, related.id));
      await tester.pump();
      expect(lookup.isCurrent(), isFalse);
      pending.complete(const [related]);
      await tester.pumpAndSettle();
      expect(find.text(heading), findsNothing);
      expect(find.text(related.title), findsNothing);
    });

    for (final collection in const [
      MusicCollection(id: 'PLempty', title: 'Empty public playlist'),
      MusicCollection(
          id: 'IVPprivate', title: 'Private playlist', tracks: [first]),
    ]) {
      testWidgets('skips overlap lookup on ${collection.title}',
          (tester) async {
        await saveCandidate(tester);
        catalog.collection = collection;
        await show(tester, screen: MusicScreen(playlistId: collection.id));
        await tester.pumpAndSettle();
        expect(find.text(collection.title), findsOneWidget);
        expect(catalog.playlistOverlapRequests, isEmpty);
        expect(find.text(heading), findsNothing);
      });
    }
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
    expect(find.text('Browse offline music'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(catalog.searches, ['missing', 'missing']);
    catalog.responses.last.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
  });

  testWidgets('offline search opens a verified download and Back keeps Search',
      (tester) async {
    const folder = 'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic';
    const download = DownloadedVideo(
      videoId: 'downloaded1',
      title: 'Verified download',
      musicMetadata:
          MusicMetadata(title: 'Verified download', artist: 'Offline artist'),
      storageUri: '$folder/document/primary%3AMusic%2Fdownloaded1.m4a',
      folderUri: folder,
      lengthSeconds: 180,
      quality: 'audio',
      audioOnly: true,
      downloadComplete: true,
    );
    final manager = _Downloads(DownloadManagerState(videos: [
      download,
      download.copyWith(
        videoId: 'unreadable1',
        title: 'Unreadable download',
        musicMetadata:
            const MusicMetadata(title: 'Unreadable download', artist: ''),
      ),
      download.copyWith(
        videoId: 'unfinished1',
        title: 'Unfinished download',
        musicMetadata:
            const MusicMetadata(title: 'Unfinished download', artist: ''),
        downloadComplete: false,
      ),
      download.copyWith(
        videoId: 'elsewhere1',
        profileId: 'another-profile',
        title: 'Other profile download',
        musicMetadata:
            const MusicMetadata(title: 'Other profile download', artist: ''),
      ),
    ]));
    addTearDown(manager.close);
    const storage = MethodChannel('videre/download_storage');
    final identity = 'a' * 64;
    var probes = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(storage, (call) async {
      if (call.method != 'probeMusicFiles') return null;
      expect(call.arguments['profileId'], db.profileId);
      probes++;
      return {
        download.videoId: {'identity': identity, 'byteLength': 1800},
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(storage, null));

    await show(tester, downloads: manager);
    await search(tester, 'acoustic rehearsal');
    catalog.responses.single.completeError(const SocketException('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);

    final recover = find.text('Browse offline music');
    expect(recover, findsOneWidget);
    await tester.tap(recover);
    await tester.pumpAndSettle();
    expect(find.text('Offline music'), findsOneWidget);
    expect(find.text('Verified download'), findsOneWidget);
    expect(find.text('Unreadable download'), findsNothing);
    expect(find.text('Unfinished download'), findsNothing);
    expect(find.text('Other profile download'), findsNothing);

    final tile = find.widgetWithText(ListTile, 'Verified download');
    expect(tester.widget<ListTile>(tile).onTap, isNotNull);
    final probesBeforeOpen = probes;
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(probes, greaterThan(probesBeforeOpen));
    expect(player.offlineCalls, hasLength(1));
    final played = player.offlineCalls.single;
    expect(played.tracks, hasLength(1));
    final selected = played.tracks[played.startIndex];
    expect(selected.download, download);
    expect(selected.downloadFileProof, identity);
    expect(played.currentWhenCalled, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('acoustic rehearsal'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(recover, findsOneWidget);
    expect(catalog.searches, ['acoustic rehearsal']);
  });

  testWidgets('offline pagination recovery keeps Search category and scroll',
      (tester) async {
    catalog.paginate = true;
    final manager = _Downloads(const DownloadManagerState());
    addTearDown(manager.close);
    await show(tester,
        screen: const MusicScreen(embedded: true), downloads: manager);
    final playlists = find.widgetWithText(ChoiceChip, 'Playlists');
    await tester.tap(playlists);
    await search(tester, 'concerts');
    catalog.pageRequests.single.response.complete(_page([
      for (var index = 0; index < 18; index++)
        MusicCatalogPlaylistHit(
            MusicPlaylist(id: 'PLconcert$index', title: 'Concert $index')),
    ]));
    await tester.pumpAndSettle();
    final viewport = find.byKey(const ValueKey('music-search-online-viewport'));
    final scrollable =
        find.descendant(of: viewport, matching: find.byType(Scrollable));
    final loadMore = find.widgetWithText(TextButton, 'Load more');
    await tester.scrollUntilVisible(loadMore, 300, scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.tap(loadMore);
    await tester.pump();
    catalog.pageRequests.last.response
        .completeError(const SocketException('offline'));
    await tester.pumpAndSettle();

    final recover = find.text('Browse offline music');
    expect(find.text('Retry'), findsOneWidget);
    await tester.ensureVisible(recover);
    await tester.pumpAndSettle();
    final offset = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset, greaterThan(0));
    await tester.tap(recover);
    await tester.pumpAndSettle();
    expect(find.text('Offline music'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('concerts'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(playlists).selected, isTrue);
    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(offset, 1));
    expect(recover, findsOneWidget);
    expect(catalog.pageRequests.map((request) => request.page), [1, 2]);
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
    final MusicCardOrigin cardOrigin = (
      surface: MusicCardSurface.quickPicks,
      collectionId: null,
      entryId: second.videoId,
    );
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
            startIndex: 1,
            cardOrigin: cardOrigin))));
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
    expect(player.cardOrigin, cardOrigin);
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

  testWidgets('public playlist Shuffle sends all occurrences to playback',
      (tester) async {
    catalog.collection = const MusicCollection(
        id: 'PLplaylist', title: 'Playlist', tracks: [first, second, first]);
    await show(tester, screen: const MusicScreen(playlistId: 'PLplaylist'));
    final actions = find.byKey(const ValueKey('music-whole-playlist-actions'));
    await tester.ensureVisible(actions);
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shuffle'));
    await tester.pumpAndSettle();

    expect(player.shuffledPlaylist, isTrue);
    expect(player.calls.single.queueTitle, 'Playlist');
    expect(player.calls.single.videos.map((entry) => entry.videoId),
        [first.videoId, second.videoId, first.videoId]);
  });

  testWidgets('offline catalog playlist queues displayed cached occurrences',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const uncached = MusicTrack(videoId: 'uncached001', title: 'Uncached song');
    catalog.collection = const MusicCollection(
        id: 'PLpublic',
        title: 'Public playlist',
        tracks: [second, first, uncached, first]);
    await tester.runAsync(() async {
      await db.upsertServer(const Server(
          url: 'https://instance.example', id: 'catalog', inUse: true));
      await app.initState();
      final reference = PlaylistReference(
          kind: PlaylistSourceKind.public,
          playlistId: 'PLpublic',
          profileId: db.profileId);
      await settings.updateMusicCollectionOrder(
          MusicCollectionSortMenu.playlistSettingName(reference),
          field: MusicCollectionSortField.title);
    });

    const channel = MethodChannel('videre/proxy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final owner = cachedMusicOwner(app.state.server!);
    final firstRendition = 'a' * 64;
    final secondRendition = 'b' * 64;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'cachedMusicSongs') return null;
      return [
        for (final (track, rendition) in [
          (second, secondRendition),
          (first, firstRendition),
        ])
          {
            'videoId': track.videoId,
            'title': track.title,
            'artist': 'Artist',
            'lengthSeconds': 100,
            'rendition': rendition,
          },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('music-catalog-offline-toggle'));
    final playAll = find.byKey(const ValueKey('music-play-all'));
    final duplicate = find.byKey(const ValueKey('music-song-3-firstsong01'));
    expect(find.text(uncached.title), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text(uncached.title), findsNothing);
    expect(find.text(first.title), findsNWidgets(2));

    await tester.tap(playAll);
    await tester.pumpAndSettle();
    await tester.tap(duplicate);
    await tester.pumpAndSettle();
    expect(player.calls.map((call) => call.startIndex), [0, 1]);
    final canonical = assignPlaylistEntryIds(
        catalog.collection.tracks.map((track) => track.toVideo()));
    for (final call in player.calls) {
      expect(call.videos.map(playbackQueueId), [
        for (final index in [1, 3, 0]) playbackQueueId(canonical[index])
      ]);
      expect(
          call.videos.map((video) => CachedMusicPlayback.of(video)?.rendition),
          [firstRendition, firstRendition, secondRendition]);
      expect(call.videos.map((video) => CachedMusicPlayback.of(video)?.owner),
          everyElement(owner));
    }

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text(uncached.title), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

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

  testWidgets('catalog artist link actions retain the page and track offset',
      (tester) async {
    const channel =
        MusicArtist(id: 'UC_kRDKYrUlrbtrSiyu5Tflg', name: 'Catalog artist');
    const server = Server(
        id: 'selected',
        url: 'https://selected.example:8443/invidious/?private=value#profile',
        inUse: true);
    final instanceLink =
        'https://selected.example:8443/invidious/channel/${channel.id}';
    final youtubeLink = 'https://www.youtube.com/channel/${channel.id}';
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(() => db.upsertServer(server));
    app.setServer(server);
    catalog.artistResults = const [channel];
    catalog.pendingArtist = Completer<MusicArtistPage>()
      ..complete(MusicArtistPage(
          artist: channel,
          songs: List.generate(
              24,
              (index) => MusicTrack(
                  videoId: 'artistvid${index.toString().padLeft(2, '0')}',
                  title: 'Artist song $index',
                  artists: const ['Catalog artist']))));

    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final shared = <Object?>[];
    final copied = <Object?>[];
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared.add((call.arguments as Map)['text']);
      return '';
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text']);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(shareChannel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await show(tester);
    await tester.tap(find.text('Channels'));
    await search(tester, 'catalog');
    await tester.pumpAndSettle();
    await tester.tap(find.text(channel.name));
    await tester.pumpAndSettle();
    expect(catalog.artistRequests, [channel.id]);

    final page = tester.state(find.byType(MusicScreen));
    final tracks = find.descendant(
        of: find.byKey(const ValueKey('music-collection-tracks-pane')),
        matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(tracks.first).position;
    position.jumpTo(420);
    await tester.pumpAndSettle();

    final share = find.byTooltip('Share');
    for (final (choice, link) in [
      ('Share Invidious link', instanceLink),
      ('Share YouTube link', youtubeLink),
    ]) {
      await tester.tap(share);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(shared.last, link);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.state(find.byType(MusicScreen)), same(page));
      expect(
          tester.state<ScrollableState>(tracks.first).position, same(position));
      expect(position.pixels, 420);
    }
    expect(shared, [instanceLink, youtubeLink]);

    await tester.tap(find.byTooltip('Open externally'));
    await tester.pumpAndSettle();
    expect(find.text(instanceLink), findsOneWidget);
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();
    expect(copied, [instanceLink]);

    const replacement = Server(url: 'https://other.example');
    await tester.runAsync(() async {
      await db.upsertServer(replacement);
      await db.useServer(replacement);
    });
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();
    expect(copied, [instanceLink]);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(position.pixels, 420);
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
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
    expect(player.calls.map((call) => call.songTap), [true, false, false]);
    expect(player.calls.last.videos.map((v) => v.videoId),
        [first.videoId, hidden.videoId, first.videoId, second.videoId]);
    expect(player.calls.last.startIndex, 2);
    expect(catalog.searches, ['songs']);
    expect(catalog.songObserver, isNull);
  });

  testWidgets('catalog artist page edits and resets a local display alias',
      (tester) async {
    const original =
        MusicArtist(id: 'UCabcdefghijklmnopqrstuv', name: 'Original channel');
    final identity = MusicArtistIdentity.catalog(original.id);
    final library = MusicLibraryService.forProfile(db, db.profileId);
    catalog.pendingArtist = Completer<MusicArtistPage>()
      ..complete(const MusicArtistPage(artist: original, songs: []));
    await show(tester, screen: MusicScreen(artistId: original.id));
    await tester.pumpAndSettle();

    final edit = find.byKey(const ValueKey('music-edit-catalog-artist-alias'));
    final input = find.byKey(const ValueKey('music-artist-alias-input'));
    Future<void> commitAlias(String action, String? expected) async {
      await tester.runAsync(() async {
        final committed = Completer<void>();
        void onChanged() {
          if (!committed.isCompleted &&
              library.artistAlias(identity) == expected) {
            committed.complete();
          }
        }

        library.changes.addListener(onChanged);
        try {
          await tester.tap(find.text(action));
          await committed.future.timeout(const Duration(seconds: 5));
        } finally {
          library.changes.removeListener(onChanged);
        }
      });
      await tester.pumpAndSettle();
    }

    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, original.name);
    await tester.enterText(input, '  Listening Alias  ');
    await commitAlias('Save', 'Listening Alias');

    expect(library.artistAlias(identity), 'Listening Alias');
    expect(find.text('Listening Alias'), findsOneWidget);
    expect(find.text(original.name), findsOneWidget);

    await tester.tap(edit);
    await tester.pumpAndSettle();
    await commitAlias('Reset to original', null);

    expect(library.artistAlias(identity), isNull);
    expect(find.text('Listening Alias'), findsNothing);
    expect(find.text(original.name), findsOneWidget);
    expect(catalog.artistRequests, [original.id]);
  });

  testWidgets('the same song tap selects Search and album detail separately',
      (tester) async {
    await show(tester);
    await search(tester, 'first');
    catalog.responses.single.complete([first, second]);
    await tester.pumpAndSettle();
    final searchRow =
        find.byKey(ValueKey('music-song-search-0-${first.videoId}'));
    await tester.tap(searchRow);
    await tester.pumpAndSettle();

    catalog.collection = MusicCollection(
        id: first.albumId!, title: 'Album', tracks: [first, second]);
    final navigator = Navigator.of(tester.element(searchRow));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(playlistId: first.albumId))));
    await tester.pumpAndSettle();
    final albumRow = find.byKey(ValueKey('music-song-0-${first.videoId}'));
    await tester.ensureVisible(albumRow);
    await tester.tap(albumRow);
    await tester.pumpAndSettle();

    expect(player.calls.map((call) => call.songTap), [true, true]);
    expect(player.calls.map((call) => call.collectionDetail), [false, true]);
    expect(player.calls.map((call) => call.videos[call.startIndex!].videoId),
        [first.videoId, first.videoId]);
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
    final toggle = tester.widget<MusicPlaylistRecommendationToggle>(
        find.byType(MusicPlaylistRecommendationToggle));
    expect(
        toggle.reference,
        PlaylistReference(
            kind: PlaylistSourceKind.public,
            playlistId: 'PLpublic',
            profileId: db.profileId));
    await tester.tap(find.byKey(const ValueKey('music-play-all')));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((v) => v.videoId),
        [first.videoId, second.videoId]);
  });

  testWidgets('public playlist Find plays the exact duplicate in source order',
      (tester) async {
    const duplicate = MusicTrack(
        videoId: 'duplicates1',
        title: 'Café Session',
        artists: ['Zoë'],
        playlistIndex: 1,
        playlistIndexId: 'early');
    const laterDuplicate = MusicTrack(
        videoId: 'duplicates1',
        title: 'Café Session',
        artists: ['Zoë'],
        playlistIndex: 5,
        playlistIndexId: 'late');
    catalog.collection = const MusicCollection(
        id: 'PLpublic',
        title: 'Public playlist',
        tracks: [first, duplicate, second, laterDuplicate]);
    await show(tester, screen: const Scaffold(body: Text('Origin')));
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const MusicScreen(playlistId: 'PLpublic'))));
    await tester.pumpAndSettle();

    final findButton = find.byKey(const ValueKey('music-public-playlist-find'));
    final query = find.byKey(const ValueKey('music-public-playlist-query'));
    await tester.tap(findButton);
    await tester.pumpAndSettle();
    await tester.enterText(query, '  ZOE   cafe ');
    await tester.pumpAndSettle();

    expect(find.text(first.title), findsNothing);
    expect(find.text(duplicate.title), findsNWidgets(2));
    final later = find.byKey(const ValueKey('music-song-3-duplicates1'));
    expect(
        find.descendant(of: later, matching: find.text('6')), findsOneWidget);
    await tester.tap(later);
    await tester.pumpAndSettle();
    final call = player.calls.single;
    expect(call.startIndex, 3);
    expect(call.videos.map((video) => video.videoId),
        [first.videoId, duplicate.videoId, second.videoId, duplicate.videoId]);
    expect(call.videos.map((video) => video.indexId),
        [null, 'early', null, 'late']);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(find.text('Public playlist'), findsOneWidget);
    expect(catalog.playlistRequests, ['PLpublic']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Origin'), findsOneWidget);
  });

  testWidgets(
      'public playlist Find stays active through partial load and Retry',
      (tester) async {
    final request = catalog.pendingPlaylist = Completer<MusicCollection>();
    await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
    await tester.pump();
    catalog.playlistProgress!(const MusicCollection(
        id: 'PLpublic',
        title: 'Public playlist',
        tracks: [first],
        loadingComplete: false));
    await tester.pumpAndSettle();

    final query = find.byKey(const ValueKey('music-public-playlist-query'));
    await tester.tap(find.byKey(const ValueKey('music-public-playlist-find')));
    await tester.pumpAndSettle();
    await tester.enterText(query, 'second');
    await tester.pumpAndSettle();
    expect(find.text('Searching the tracks loaded so far.'), findsOneWidget);
    expect(find.text('No results found.'), findsNothing);

    request.completeError(StateError('Page failed'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Could not load the rest of this playlist. Loaded videos are still available.'),
        findsOneWidget);
    final retry = catalog.pendingPlaylist = Completer<MusicCollection>();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    catalog.playlistProgress!(const MusicCollection(
        id: 'PLpublic',
        title: 'Public playlist',
        tracks: [first, second],
        loadingComplete: false));
    await tester.pumpAndSettle();
    expect(find.text(second.title), findsOneWidget);
    expect(find.text(first.title), findsNothing);
    await tester.tap(find.text(second.title));
    await tester.pumpAndSettle();
    expect(player.calls.single.startIndex, 1);
    expect(player.calls.single.videos.map((video) => video.videoId),
        [first.videoId, second.videoId]);

    retry.complete(catalog.collection);
    await tester.pumpAndSettle();
    expect(find.text('Searching the tracks loaded so far.'), findsNothing);
    expect(tester.widget<TextField>(query).controller!.text, 'second');
    await tester.enterText(query, 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('music-browser-up')));
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(find.text('Public playlist'), findsOneWidget);
    expect(catalog.playlistRequests, ['PLpublic', 'PLpublic']);
  });

  testWidgets('artist uploads can retry independently of releases and bio',
      (tester) async {
    const release = MusicCollection(id: 'OLAK5uy_release', title: 'A release');
    final bio =
        List.generate(10, (index) => 'Biography line $index').join('\n');
    catalog.pendingArtist = Completer<MusicArtistPage>()
      ..complete(MusicArtistPage(
        artist: artist,
        description: bio,
        loadsUploadsSeparately: true,
      ));
    catalog.releasePages[null] = const MusicArtistReleases(releases: [release]);
    await show(tester, screen: const MusicScreen(artistId: 'UCartist'));
    await tester.pump();
    expect(find.text(bio), findsOneWidget);
    expect(find.text(release.title), findsOneWidget);
    expect(find.bySemanticsLabel('Popular uploads'), findsWidgets);
    expect(catalog.uploadRequests, hasLength(1));
    catalog.uploadRequests.single.completeError(StateError('Unavailable'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: find.byType(AlertDialog), matching: find.text(bio)),
        findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    final retry = find.byKey(const ValueKey('music-retry-artist-uploads'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(catalog.uploadRequests, hasLength(2));
    expect(catalog.releaseRequests, [null]);
    catalog.uploadRequests.last.complete([first]);
    await tester.pumpAndSettle();
    expect(find.text(first.title), findsOneWidget);
  });

  testWidgets('artist saved songs match catalog identity rather than names',
      (tester) async {
    const identity = 'UCabcdefghijklmnopqrstuv';
    const other = 'UCzyxwvutsrqponmlkjihgfe';
    catalog.pendingArtist = Completer<MusicArtistPage>()
      ..complete(const MusicArtistPage(
        artist: MusicArtist(id: identity, name: 'Artist'),
      ));
    final library = MusicLibraryService.forProfile(db, db.profileId);
    await library.save(const MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'matched0001',
      title: 'Matching saved song',
      artistCredits: [MusicArtistCredit(name: 'Artist', id: identity)],
    ));
    await library.save(const MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'notmatch001',
      title: 'Different saved song',
      artistCredits: [MusicArtistCredit(name: 'Artist', id: other)],
    ));
    await show(tester, screen: const MusicScreen(artistId: identity));
    await tester.pumpAndSettle();
    expect(find.text('Saved songs'), findsOneWidget);
    expect(find.text('Matching saved song'), findsOneWidget);
    expect(find.text('Different saved song'), findsNothing);
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

  testWidgets('public playlist display sort preserves duplicate queue entries',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1100);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const unrelated = MusicTrack(
        videoId: 'unrelated01', title: 'Interlude', artists: ['Artist']);
    catalog.collection = const MusicCollection(
        id: 'PLpublic',
        title: 'Public playlist',
        tracks: [first, second, first, unrelated]);
    await show(tester, screen: const MusicScreen(playlistId: 'PLpublic'));
    await tester.pumpAndSettle();

    final locals =
        AppLocalizations.of(tester.element(find.byType(MusicScreen)))!;
    final sort = find.byTooltip(locals.searchSortBy);
    final settingName =
        MusicCollectionSortMenu.playlistSettingName(PlaylistReference(
      kind: PlaylistSourceKind.public,
      playlistId: 'PLpublic',
      profileId: db.profileId,
    ));
    Future<void> choose(String label, String expected) async {
      await tester.tap(sort);
      await tester.pumpAndSettle();
      final option = find.ancestor(
          of: find.text(label),
          matching:
              find.byWidgetPredicate((widget) => widget is PopupMenuItem));
      await tester.runAsync(() async {
        final committed = settings.stream.firstWhere(
            (state) => state.settings[settingName]?.value == expected);
        await tester.tap(option);
        await tester.pumpAndSettle();
        await committed.timeout(const Duration(seconds: 3));
      });
      await tester.pumpAndSettle();
    }

    await choose(locals.musicLibraryTitleOrder, 'title:ascending');
    await choose(locals.localMusicDescending, 'title:descending');
    final firstRow = find.byKey(const ValueKey('music-song-0-firstsong01'));
    final secondRow = find.byKey(const ValueKey('music-song-1-secondsong2'));
    final duplicateRow = find.byKey(const ValueKey('music-song-2-firstsong01'));
    double top(Finder row) => tester.getTopLeft(row).dy;
    expect(top(secondRow), lessThan(top(firstRow)));
    expect(top(firstRow), lessThan(top(duplicateRow)));
    expect(player.calls, isEmpty);

    await tester.runAsync(
        () => MusicListeningHistory.forProfile(db, db.profileId).merge([
              MusicListeningEvent(
                id: 'first-recorded-play',
                entry: HistoryVideoCache(first.videoId, first.title, null, ''),
                source: MusicListeningSource.catalog,
                elapsed: const Duration(seconds: 10),
              ),
            ]));
    await choose(locals.musicListeningTimeOrder, 'listeningTime:descending');
    expect(top(firstRow), lessThan(top(duplicateRow)));
    expect(top(duplicateRow), lessThan(top(secondRow)));

    await choose(locals.musicLibraryTitleOrder, 'title:descending');
    await tester.tap(find.byKey(const ValueKey('music-public-playlist-find')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('music-public-playlist-query')), 'song');
    await tester.pumpAndSettle();
    expect(find.text(unrelated.title), findsNothing);
    expect(top(secondRow), lessThan(top(firstRow)));
    expect(top(firstRow), lessThan(top(duplicateRow)));

    await tester.tap(duplicateRow);
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.map((video) => video.videoId),
        [first.videoId, second.videoId, first.videoId, unrelated.videoId]);
    expect(player.calls.single.startIndex, 2);
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
    final catalogSearch = find.descendant(
        of: find.byKey(const ValueKey('music-search')),
        matching: find.byIcon(Icons.search));
    expect(Focus.of(tester.element(catalogSearch)).hasPrimaryFocus, isTrue);
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
