import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_card_origin.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_charts.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/music_artwork_cache.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_starter_artists.dart';
import 'package:clipious/music/services/music_visibility.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/music/views/components/music_song_selection_bar.dart';
import 'package:clipious/music/views/screens/music_discovery.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/screens/music_settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';
import 'support/community_filter_fixture.dart';

const _saved = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'savedmusic1',
    title: 'Saved recording',
    subtitle: 'Saved artist');

const _discovered = MusicTrack(
    videoId: 'discover001', title: 'Discovered recording', artists: ['Artist']);

const _genres = ['pop', 'jazz', 'classical', 'electronic'];
const _genreLabels = ['Pop', 'Jazz', 'Classical', 'Electronic'];

List<MusicTrack> _genreTracks(String genre) => [
      for (var i = 1; i <= 2; i++)
        MusicTrack(
            videoId: 'genre${_genres.indexOf(genre)}song$i',
            title: '$genre recording $i'),
    ];

class _App extends Cubit<AppState> implements AppCubit {
  _App()
      : super(AppState(
            0, const Server(url: 'https://music.example'), HomeLayout(),
            profileId: db.profileId));

  void change(AppState state) => emit(state);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Catalog extends MusicCatalogService {
  int trendingCalls = 0;
  int searchCalls = 0;
  int discoveryCalls = 0;
  bool holdDiscovery = false;
  final discoveries = <Completer<List<MusicTrack>>>[];
  final discoveryFailures = <void Function(InvidiousServiceError)?>[];
  final discoveryGuards = <bool Function()?>[];
  final discoveryArtists = <String?>[];
  final relatedSeeds = <List<String>>[];
  final relatedGuards = <bool Function()?>[];
  final relatedResponses = <Completer<List<MusicTrack>>>[];
  bool holdGenres = false;
  bool useGenreTracks = false;
  final genres = <String>[];
  final genreGuards = <bool Function()?>[];
  final genreFailures = <void Function(InvidiousServiceError)?>[];
  final genreResponses = <Completer<List<MusicTrack>>>[];
  final chartRequests = <String>[];
  Completer<List<MusicTrack>>? chartResponse;
  List<MusicTrack> chartTracks = const [];
  Object? chartFailure;
  final artistReleaseRequests = <String>[];
  final artistReleases = <String, MusicArtistReleases>{};
  final artistQueries = <String>[];
  final artistResults = <String, List<MusicArtist>>{};
  final pendingArtistSearches = <String, Completer<List<MusicArtist>>>{};

  @override
  Future<List<MusicTrack>> getChartSongs(String playlistId,
      {bool Function()? isCurrent}) async {
    chartRequests.add(playlistId);
    if (chartFailure case final error?) throw error;
    if (chartResponse case final pending?) return pending.future;
    return chartTracks;
  }

  @override
  Future<MusicArtistReleases> getArtistReleases(String id,
      {String? continuation,
      Server? expectedServer,
      bool Function()? isCurrent}) async {
    artistReleaseRequests.add(id);
    return artistReleases[id] ?? const MusicArtistReleases();
  }

  @override
  Future<List<MusicTrack>> getGenreSongs(String genre,
      {bool Function()? isCurrent,
      void Function(InvidiousServiceError)? onInstanceFailure}) {
    genres.add(genre);
    genreGuards.add(isCurrent);
    genreFailures.add(onInstanceFailure);
    if (!holdGenres) {
      return Future.value(useGenreTracks ? _genreTracks(genre) : []);
    }
    final response = Completer<List<MusicTrack>>();
    genreResponses.add(response);
    return response.future;
  }

  @override
  Future<List<MusicTrack>> getRelatedSongs(Iterable<String> seedIds,
      {bool Function()? isCurrent}) {
    relatedSeeds.add(seedIds.toList());
    relatedGuards.add(isCurrent);
    final response = Completer<List<MusicTrack>>();
    relatedResponses.add(response);
    return response.future;
  }

  @override
  Future<List<MusicTrack>> getDiscoverySongs(
      {String? artist,
      bool Function()? isCurrent,
      void Function(InvidiousServiceError)? onInstanceFailure}) {
    discoveryCalls++;
    discoveryFailures.add(onInstanceFailure);
    discoveryGuards.add(isCurrent);
    discoveryArtists.add(artist);
    if (!holdDiscovery) return Future.value([]);
    final response = Completer<List<MusicTrack>>();
    discoveries.add(response);
    return response.future;
  }

  @override
  Future<List<MusicTrack>> getTrendingSongs() async {
    trendingCalls++;
    throw StateError('Home must not request the unsupported music feed.');
  }

  @override
  Future<List<MusicTrack>> searchSongs(String query) async {
    searchCalls++;
    return [];
  }

  @override
  Future<List<MusicArtist>> searchArtists(String query) async {
    artistQueries.add(query);
    if (pendingArtistSearches[query] case final pending?) return pending.future;
    return artistResults[query] ?? const [];
  }
}

class _StarterArtistArtworkCache extends Fake
    implements MusicArtworkCache, cache.BaseCacheManager {
  _StarterArtistArtworkCache(this.image);

  final fs.File image;
  final requests = <String>[];

  @override
  cache.BaseCacheManager catalogManager(String profileId) => this;

  @override
  Stream<cache.FileResponse> getFileStream(String url,
      {String? key, Map<String, String>? headers, bool withProgress = false}) {
    requests.add(url);
    return Stream.value(
        cache.FileInfo(image, cache.FileSource.Cache, DateTime.utc(2100), url));
  }
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  @override
  int get playlistGeneration => 0;

  @override
  bool canAddMusicRequest(IdedVideo entry) => false;

  final plays =
      <({List<String> ids, int? startIndex, bool? audio, bool fromMusic})>[];

  final offlinePlays = <List<OnDeviceMusicEntry>>[];

  @override
  final musicSelectionFailureRevision = ValueNotifier(0);

  MusicCardOrigin? cardOrigin;
  int cardToggles = 0;

  void setCardPlaying(MusicCardOrigin origin) {
    cardOrigin = origin;
    emit(state.copyWith(isPlaying: true));
  }

  @override
  bool? musicCardPlaying(MusicCardOrigin origin) =>
      cardOrigin == origin ? state.isPlaying : null;

  @override
  bool toggleMusicCard(MusicCardOrigin origin) {
    if (cardOrigin != origin) return false;
    cardToggles++;
    emit(state.copyWith(isPlaying: !state.isPlaying));
    return true;
  }

  @override
  Future<void> playMusicFromCard(List<Video> videos,
          {required MusicCardOrigin origin,
          Duration? startAt,
          int? startIndex,
          String? queueTitle,
          PlaylistReference? recommendationSource,
          bool songTap = false,
          bool collectionDetail = false}) =>
      playVideo(videos,
          audio: true,
          startAt: startAt,
          startIndex: startIndex,
          queueTitle: queueTitle,
          recommendationSource: recommendationSource,
          songTap: songTap,
          collectionDetail: collectionDetail,
          fromMusic: true);

  void setAudioPlayer({required bool minimized}) =>
      emit(state.copyWith(isAudio: true, isHidden: false, isMini: minimized));

  @override
  Future<void> playOnDeviceMusic(List<OnDeviceMusicEntry> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool songTap = false,
      bool collectionDetail = false,
      bool retainQueueOrder = false,
      bool Function()? isCurrent}) async {
    if (isCurrent?.call() != false) offlinePlays.add(tracks);
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      PlaylistReference? recommendationSource,
      bool fromMusic = false,
      bool songTap = false,
      bool collectionDetail = false}) async {
    plays.add((
      ids: videos.map((video) => video.videoId).toList(),
      startIndex: startIndex,
      audio: audio,
      fromMusic: fromMusic,
    ));
  }

  @override
  Future<void> close() async {
    musicSelectionFailureRevision.dispose();
    await super.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads() : super(const DownloadManagerState());

  final _changes = ValueNotifier(0);

  @override
  Listenable get discoveryOfflineChanges => _changes;

  final selections = <String, List<String>>{};
  final requests = <({String profileId, List<String> ids})>[];
  List<MusicFileProbe> readable = [];

  @override
  List<String> offlineDiscoveryIds(String profileId) =>
      selections[profileId] ?? const [];

  @override
  Future<bool> setOfflineDiscovery(
      String profileId, Iterable<Video> songs) async {
    final ids = songs.map((song) => song.videoId).toList();
    requests.add((profileId: profileId, ids: ids));
    selections[profileId] = ids;
    _changes.value++;
    return true;
  }

  @override
  Future<List<MusicFileProbe>> probeOfflineDiscovery(String profileId) async =>
      readable.where((file) => file.download.profileId == profileId).toList();

  void report(List<DownloadedVideo> rows, {required bool waitingForWifi}) {
    emit(state.copyWith(
        videos: rows,
        wifiOnly: waitingForWifi,
        waitingForWifi: waitingForWifi));
  }

  @override
  Future<void> close() async {
    _changes.dispose();
    await super.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Router extends AppRouter {
  PageRouteInfo? pushed;
  Future<void> Function()? openPlayer;

  _Router() : super(hasServer: true);

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) async {
    pushed = route;
    await openPlayer?.call();
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MusicCatalogService previousCatalog;
  late _Catalog catalog;
  late MusicLibraryService library;
  late _App app;
  late _Player player;
  late _Router router;
  late int searches;
  late int libraryVisits;

  setUp(() async {
    // Widget tests have no native recommendation plugin. Model its explicit
    // unavailable response instead of leaving an unanswered platform message.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (_) async => throw MissingPluginException());
    db = await SembastSqfDb.createInMemory();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    library = MusicLibraryService.forProfile(db, db.profileId);
    previousCatalog = musicCatalogService;
    musicCatalogService = catalog = _Catalog();
    app = _App();
    player = _Player();
    router = _Router();
    searches = 0;
    libraryVisits = 0;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('videre/recommendations'), null);
    musicCatalogService = previousCatalog;
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await app.close();
    await player.close();
    await db.close();
    router.dispose();
  });

  Future<void> show(WidgetTester tester,
      {double textScale = 1,
      bool active = true,
      bool settle = true,
      SettingsCubit? settings,
      DownloadManagerCubit? downloads,
      MusicArtworkCache? artworkCache}) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
        if (settings != null)
          BlocProvider<SettingsCubit>.value(value: settings),
        if (downloads != null)
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
        if (artworkCache != null)
          RepositoryProvider<MusicArtworkCache>.value(value: artworkCache),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: StackRouterScope(
          controller: router,
          stateHash: 0,
          child: Scaffold(
            body: TickerMode(
              enabled: active,
              child: MusicHomePage(
                onSearch: () => searches++,
                onLibrary: () => libraryVisits++,
              ),
            ),
          ),
        ),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  void expectSongQueue(List<String> ids, int selected) {
    final args = router.pushed!.args as MusicRouteArgs;
    expect(args.videoId, ids[selected]);
    expect(args.queue.map((video) => video.videoId), ids);
    expect(args.startIndex, selected);
  }

  Finder starterControl(String name) => find.byKey(ValueKey(name));

  Finder artistResult(String id) =>
      starterControl('music-starter-artist-result-$id');

  final starterInput = starterControl('music-starter-artist-input');
  final starterSave = starterControl('music-starter-artists-save');

  Future<void> openStarterArtists(WidgetTester tester,
      {String entry = 'music-starter-artists-edit'}) async {
    final edit = starterControl(entry);
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(starterControl('music-starter-artists-dialog'), findsOneWidget);
  }

  Future<void> typeStarterQuery(WidgetTester tester, String query) async {
    await tester.enterText(starterInput, query);
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('Same-name starter artists retain their exact ID and artwork',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 560);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final artwork = (await tester.runAsync(() async {
      await db.upsertServer(app.state.server!);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xff14865e), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 8);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return _StarterArtistArtworkCache(
          MemoryFileSystem.test().file('starter-artist.png')
            ..writeAsBytesSync(bytes!.buffer.asUint8List()));
    }))!;

    const artist = 'Björk';
    const noArtworkId = 'UCabcdefghijklmnopqrstuv';
    const artworkId = 'UCABCDEFGHIJKLMNOPQRSTUV';
    const artworkUrl = 'https://yt3.ggpht.com/starter-avatar=s88';
    const routedUrl = 'https://music.example/ggpht/starter-avatar=s88';
    final withArtwork = MusicArtist(
        id: artworkId,
        name: artist,
        thumbnails: [ImageObject(null, artworkUrl, 88, 88)]);
    catalog.artistResults[artist] = [
      const MusicArtist(id: noArtworkId, name: artist),
      withArtwork,
      withArtwork,
    ];

    await show(tester, textScale: 1.5, artworkCache: artwork);
    expect(find.text('Choose artists'), findsOneWidget);
    await openStarterArtists(tester);
    expect(tester.widget<FilledButton>(starterSave).onPressed, isNull);

    await typeStarterQuery(tester, '  $artist  ');
    await tester.pumpAndSettle();
    final pictured = artistResult(artworkId);
    final noPicture = artistResult(noArtworkId);
    expect(pictured, findsOneWidget);
    expect(noPicture, findsOneWidget);

    Finder avatarIn(Finder row) =>
        find.descendant(of: row, matching: find.byType(ChannelAvatar));
    final noPictureAvatar = avatarIn(noPicture);
    expect(find.descendant(of: noPictureAvatar, matching: find.text('B')),
        findsOneWidget);
    final displayedArtwork = find.descendant(
        of: avatarIn(pictured), matching: find.byType(CachedNetworkImage));
    expect(tester.widget<CachedNetworkImage>(displayedArtwork).imageUrl,
        routedUrl);
    expect(artwork.requests, contains(routedUrl));

    await tester.ensureVisible(pictured);
    await tester.tap(pictured);
    await tester.pumpAndSettle();
    final draft = find.widgetWithText(InputChip, artist);
    expect(avatarIn(draft), findsOneWidget);

    await typeStarterQuery(tester, artist);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(pictured).onTap, isNull);
    expect(tester.widget<ListTile>(noPicture).onTap, isNotNull);
    await tester.tap(starterSave);
    await tester.pumpAndSettle();
    expect(starterControl('music-starter-artists-dialog'), findsNothing);
    final saved = MusicStarterArtists(db, db.profileId).picks!.single;
    expect(saved.catalogId, artworkId);
    expect(saved.thumbnails.single.url, artworkUrl);

    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester, textScale: 1.5, artworkCache: artwork);
    final pick = find.widgetWithText(ActionChip, artist);
    expect(avatarIn(pick), findsOneWidget);
    expect(find.text('Choose artists'), findsNothing);
    expect(router.pushed, isNull);
    expect(catalog.searchCalls, 0);
    expect(catalog.discoveryArtists.whereType<String>(), isEmpty);
    expect(catalog.artistReleaseRequests, isEmpty);

    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(router.pushed, isA<MusicRoute>());
    expect((router.pushed!.args as MusicRouteArgs).artistId, artworkId);

    await openStarterArtists(tester);
    final label = find.descendant(of: draft, matching: find.text(artist));
    await tester.ensureVisible(label);
    Focus.of(tester.element(label)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(draft, findsNothing);

    await tester.tap(starterSave);
    await tester.pumpAndSettle();
    expect(MusicStarterArtists(db, db.profileId).picks, isEmpty);
    expect(pick, findsNothing);
    expect(find.text('Edit starter artists'), findsOneWidget);
  });

  testWidgets('Starter artist searches debounce and ignore outdated results',
      (tester) async {
    final delayed = catalog.pendingArtistSearches['Old'] = Completer();
    final latest = catalog.pendingArtistSearches['Current'] = Completer();
    const old = MusicArtist(id: 'UCabcdefghijklmnopqrstuv', name: 'Old row');
    const current =
        MusicArtist(id: 'UCABCDEFGHIJKLMNOPQRSTUV', name: 'Current row');
    await show(tester);
    await openStarterArtists(tester);

    await tester.enterText(starterInput, 'O');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.enterText(starterInput, 'Old');
    await tester.pump(const Duration(milliseconds: 150));
    expect(catalog.artistQueries, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(catalog.artistQueries, ['Old']);
    await typeStarterQuery(tester, 'Current');
    expect(catalog.artistQueries, ['Old', 'Current']);

    latest.complete([current]);
    await tester.pumpAndSettle();
    expect(artistResult(current.id), findsOneWidget);
    delayed.complete([old]);
    await tester.pumpAndSettle();
    expect(artistResult(current.id), findsOneWidget);
    expect(artistResult(old.id), findsNothing);

    await typeStarterQuery(tester, 'No match');
    await tester.pumpAndSettle();
    expect(artistResult(current.id), findsNothing);
    expect(find.text('No results found.'), findsOneWidget);
    expect(tester.widget<FilledButton>(starterSave).onPressed, isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    expect(MusicStarterArtists(db, db.profileId).picks, isNull);
  });

  for (final switchProfile in [false, true]) {
    testWidgets(
        'Pending starter artist responses are discarded after a '
        '${switchProfile ? 'profile' : 'server'} change', (tester) async {
      final original = db.profileId;
      final pending = catalog.pendingArtistSearches['Delayed'] = Completer();
      const stale =
          MusicArtist(id: 'UCabcdefghijklmnopqrstuv', name: 'Stale row');
      await show(tester);
      await openStarterArtists(tester);
      await typeStarterQuery(tester, 'Delayed');
      expect(catalog.artistQueries, ['Delayed']);

      if (switchProfile) {
        final other = (await tester.runAsync(() async {
          final profile = await db.createProfile('Second starter profile');
          await db.useProfile(profile.id);
          return profile;
        }))!;
        app.change(app.state.copyWith(
            profileId: other.id,
            server: Server(url: 'https://other.example', profileId: other.id)));
      } else {
        app.change(app.state
            .copyWith(server: const Server(url: 'https://other.example')));
      }
      await tester.pump();
      pending.complete([stale]);
      await tester.pumpAndSettle();

      expect(artistResult(stale.id), findsNothing);
      expect(starterInput, findsNothing);
      expect(
          find.textContaining('profile or connection changed'), findsOneWidget);
      expect(MusicStarterArtists(db, original).picks, isNull);
      expect(MusicStarterArtists(db, db.profileId).picks, isNull);
    });
  }

  testWidgets('Skipping starter artists persists only in the current profile',
      (tester) async {
    final original = db.profileId;
    final server = app.state.server!;
    await show(tester);
    await openStarterArtists(tester);
    await tester.enterText(starterInput, 'Discarded artist');
    await tester.tap(starterControl('music-starter-artists-skip'));
    await tester.pumpAndSettle();
    expect(find.text('Choose artists'), findsNothing);
    expect(find.text('Edit starter artists'), findsOneWidget);
    expect(find.text('Discarded artist'), findsNothing);
    expect(catalog.artistQueries, isEmpty);

    final other = (await tester
        .runAsync(() => db.createProfile('Other starter profile')))!;
    await tester.runAsync(() => db.useProfile(other.id));
    app.change(app.state.copyWith(
        profileId: other.id, server: server.copyWith(profileId: other.id)));
    await tester.pumpAndSettle();

    const otherArtist = MusicArtist(
        id: 'UCABCDEFGHIJKLMNOPQRSTUV', name: 'Other profile artist');
    catalog.artistResults['Other'] = [otherArtist];
    expect(find.text('Choose artists'), findsOneWidget);
    await openStarterArtists(tester);
    await typeStarterQuery(tester, 'Other');
    await tester.pumpAndSettle();
    await tester.tap(artistResult(otherArtist.id));
    await tester.pumpAndSettle();
    await tester.tap(starterSave);
    await tester.pumpAndSettle();
    final otherPick = find.widgetWithText(ActionChip, otherArtist.name);
    expect(otherPick, findsOneWidget);

    await tester.runAsync(() => db.useProfile(original));
    app.change(app.state.copyWith(profileId: original, server: server));
    await tester.pumpAndSettle();
    expect(otherPick, findsNothing);
    expect(find.text('Choose artists'), findsNothing);
    expect(find.text('Edit starter artists'), findsOneWidget);
  });

  testWidgets('Music Settings opens the same editor and keeps legacy picks',
      (tester) async {
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(musicStarterArtistsSettingName, '["Legacy"]')));
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final focus = FocusNode();
    addTearDown(settings.close);
    addTearDown(focus.dispose);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MusicSettingsScreen(
          television: false,
          focusedSetting: 'music-starter-artists-setting',
          settingFocusNode: focus,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    const artist =
        MusicArtist(id: 'UCABCDEFGHIJKLMNOPQRSTUV', name: 'Nina Simone');
    catalog.artistResults['Nina'] = [artist];
    await openStarterArtists(tester, entry: 'music-starter-artists-setting');
    expect(find.widgetWithText(InputChip, 'Legacy'), findsOneWidget);
    await typeStarterQuery(tester, 'Nina');
    await tester.pumpAndSettle();
    await tester.tap(artistResult(artist.id));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, artist.name), findsOneWidget);
    await tester.tap(starterSave);
    await tester.pumpAndSettle();

    final saved = MusicStarterArtists(db, db.profileId).picks!;
    expect(saved.map((pick) => pick.name), ['Legacy', artist.name]);
    expect(saved.map((pick) => pick.catalogId), [null, artist.id]);
    await openStarterArtists(tester, entry: 'music-starter-artists-setting');
    expect(find.widgetWithText(InputChip, 'Legacy'), findsOneWidget);
    expect(find.widgetWithText(InputChip, artist.name), findsOneWidget);
  });

  testWidgets('Starter artists use local songs and reorder generic discovery',
      (tester) async {
    await tester.runAsync(() async {
      for (final (id, artist) in [
        ('starterhist', 'Artist'),
        ('otherhist01', 'An artist tribute'),
      ]) {
        await db.recordPlaybackHistory(
            PlaybackHistoryOrigin.music,
            HistoryVideoCache(id, id, artist, '',
                musicMetadata: MusicMetadata(title: id, artist: artist)));
      }
    });
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(musicStarterArtistsSettingName, '["ARTÍST"]')));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([
      const MusicTrack(videoId: 'priorSong01', title: 'First result'),
      _discovered,
    ]);
    await tester.pumpAndSettle();
    final shelf = starterControl('music-starter-artist-matches');
    expect(shelf, findsOneWidget);
    expect(starterControl('music-starter-artist-matches-starterhist'),
        findsOneWidget);
    expect(starterControl('music-starter-artist-matches-otherhist01'),
        findsNothing);
    expect(catalog.discoveryArtists, [null]);

    final discover = starterControl('music-discovery-${_discovered.videoId}');
    await tester.ensureVisible(discover);
    await tester.pumpAndSettle();
    await tester.tap(discover);
    expectSongQueue([_discovered.videoId, 'priorSong01'], 0);

    await tester.runAsync(() => MusicStarterArtists(db, db.profileId).save([]));
    await tester.pumpAndSettle();
    expect(shelf, findsNothing);
    expect(catalog.discoveryArtists, [null]);
  });

  testWidgets('Home loads the regional stock chart and rotates its tracks',
      (tester) async {
    catalog.chartTracks = List.generate(
        12,
        (index) => MusicTrack(
            videoId: 'chartSong${index.toString().padLeft(2, '0')}',
            title: 'Chart track $index'));
    await show(tester);
    expect(catalog.chartRequests, [
      musicCharts.singleWhere((chart) => chart.countryCode == 'US').playlistId
    ]);
    expect(find.text('From your regional chart'), findsOneWidget);
    expect(find.text('Chart track 0'), findsOneWidget);

    final refresh = find.byKey(const ValueKey('music-home-fresh-refresh'));
    Future<void> reload() async {
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
    }

    await reload();
    expect(find.text('Chart track 0'), findsNothing);
    expect(find.text('Chart track 6'), findsOneWidget);
    await reload();
    expect(find.text('Chart track 0'), findsOneWidget);
    expect(find.text('Chart track 6'), findsNothing);
    catalog.chartFailure = StateError('Chart temporarily unavailable');
    await reload();
    expect(find.text('Chart track 0'), findsOneWidget);
    expect(catalog.chartRequests.toSet(), hasLength(1));
  });

  testWidgets('changing the proxy replaces Home chart and release selections',
      (tester) async {
    final artistId = 'UC${'a' * 22}';
    const oldRelease = MusicCollection(id: 'PLold', title: 'Old release');
    const newRelease = MusicCollection(id: 'PLnew', title: 'New release');
    await tester.runAsync(() => library.save(MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: artistId, title: 'Saved channel')));
    catalog.artistReleases[artistId] =
        const MusicArtistReleases(releases: [oldRelease]);
    catalog.chartTracks = [_discovered];
    await show(tester);
    expect(find.text(oldRelease.title), findsOneWidget);
    expect(find.text(_discovered.title), findsOneWidget);

    catalog.artistReleases[artistId] =
        const MusicArtistReleases(releases: [newRelease]);
    catalog.chartTracks = const [
      MusicTrack(videoId: 'newchart001', title: 'New chart song')
    ];
    await tester.runAsync(
        () => NetworkProxy.instance.apply(SocksProxyConfig(enabled: true)));
    await tester.pumpAndSettle();
    expect(find.text(oldRelease.title), findsNothing);
    expect(find.text(_discovered.title), findsNothing);
    expect(find.text(newRelease.title), findsOneWidget);
    expect(find.text('New chart song'), findsOneWidget);
    expect(catalog.chartRequests, hasLength(2));
    expect(catalog.artistReleaseRequests, [artistId, artistId]);
  });

  testWidgets('Home replaces chart rows hidden by a changed community rule',
      (tester) async {
    await tester.runAsync(() async {
      await installCommunityMusicFilters();
      await communityFilters.setAction(
          CommunityRule.music, CommunityAction.label);
    });
    catalog.chartTracks = [
      for (var i = 0; i < 6; i++)
        MusicTrack(
            videoId: 'hiddenSong$i',
            title: 'Listed chart song $i',
            uploaderChannelId: musicListedUploader),
      _discovered,
    ];
    await show(tester);
    expect(find.text('Listed chart song 0'), findsOneWidget);
    expect(find.text(_discovered.title), findsNothing);

    await tester.runAsync(() =>
        communityFilters.setAction(CommunityRule.music, CommunityAction.hide));
    await tester.pumpAndSettle();
    expect(find.text('Listed chart song 0'), findsNothing);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(
        find.byKey(const ValueKey('music-home-fresh-refresh')), findsOneWidget);
    expect(catalog.chartRequests, hasLength(1));
  });

  testWidgets(
      'Home can reveal chart rows fetched while the uploader was hidden',
      (tester) async {
    await tester.runAsync(installCommunityMusicFilters);
    const hiddenTrack = MusicTrack(
        videoId: 'hiddenSong1',
        title: 'Listed chart song',
        uploaderChannelId: musicListedUploader);
    catalog.chartTracks = [hiddenTrack];
    await show(tester);
    expect(find.text(hiddenTrack.title), findsNothing);

    await tester.runAsync(() =>
        communityFilters.setAction(CommunityRule.music, CommunityAction.label));
    await tester.pumpAndSettle();
    expect(find.text(hiddenTrack.title), findsOneWidget);
    expect(catalog.chartRequests, hasLength(1));
  });

  testWidgets('initial chart failure allows retry after instance cooldown',
      (tester) async {
    catalog.chartFailure = InvidiousServiceError('Too many requests',
        statusCode: 429, retryAfter: const Duration(minutes: 1));
    await show(tester);
    final retry = find.byKey(const ValueKey('music-home-fresh-retry'));
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    expect(find.byKey(const ValueKey('music-home-fresh-browse-offline')),
        findsNothing);
    expect(catalog.chartRequests, hasLength(1));
    await tester.pump(const Duration(minutes: 1));
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    expect(catalog.chartRequests, hasLength(1));

    catalog.chartFailure = null;
    catalog.chartTracks = [_discovered];
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(retry, findsNothing);
    expect(find.byKey(const ValueKey('music-home-chart')), findsOneWidget);
    expect(catalog.chartRequests, hasLength(2));
  });

  testWidgets('a chart connection failure offers offline browsing by Retry',
      (tester) async {
    catalog.chartFailure = TimeoutException('Connection timed out');
    await show(tester);

    expect(
        find.byKey(const ValueKey('music-home-fresh-retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-home-fresh-browse-offline')),
        findsOneWidget);
  });

  testWidgets('changing chart region respects the active instance cooldown',
      (tester) async {
    catalog.chartFailure = InvidiousServiceError('Too many requests',
        statusCode: 429, retryAfter: const Duration(minutes: 1));
    await show(tester);
    expect(catalog.chartRequests, hasLength(1));
    await show(tester, active: false);
    await tester
        .runAsync(() => db.saveSetting(SettingsValue(browsingCountry, 'JP')));
    catalog.chartFailure = null;
    catalog.chartTracks = [_discovered];
    await show(tester);
    expect(catalog.chartRequests, hasLength(1));
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(catalog.chartRequests, hasLength(2));
    expect(
        catalog.chartRequests.last,
        musicCharts
            .firstWhere((chart) => chart.countryCode == 'JP')
            .playlistId);
    expect(find.text(_discovered.title), findsOneWidget);
  });

  testWidgets('Home requests releases for only three saved artist channels',
      (tester) async {
    const release =
        MusicCollection(id: 'OLAK5uy_homeRelease', title: 'Artist release');
    final ids = List.generate(4, (index) => 'UC${'a' * 21}$index');
    await tester.runAsync(() async {
      for (final id in ids) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.artist, id: id, title: 'Saved channel $id'));
        catalog.artistReleases[id] =
            const MusicArtistReleases(releases: [release]);
      }
    });
    catalog.artistReleases[ids.last] = MusicArtistReleases(releases: [
      ...List.generate(
          6,
          (i) => MusicCollection(
              id: 'OLAK5uy_home$i', title: 'Latest saved artist release $i')),
      release,
    ]);
    await show(tester);

    expect(catalog.artistReleaseRequests, ids.reversed.take(3));
    expect(find.text('Releases from saved artists'), findsOneWidget);
    final card = find.text(release.title);
    expect(card, findsOneWidget);
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    final args = router.pushed!.args as MusicRouteArgs;
    expect(args.playlistId, release.id);
  });

  Future<void> playFromMenu(WidgetTester tester, Finder row) async {
    router.pushed = null;
    await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-song-play')));
    await tester.pumpAndSettle();
  }

  Future<void> tapAndWaitForEligibility(WidgetTester tester, Finder button,
      MusicTrack track, bool eligible) async {
    await tester.runAsync(() async {
      final recommendations =
          RecommendationService.forProfile(db, db.profileId);
      final completed = Completer<void>();
      void changed() {
        if (!completed.isCompleted &&
            recommendations.eligibleMusic([track]).isNotEmpty == eligible) {
          completed.complete();
        }
      }

      recommendations.changes.addListener(changed);
      try {
        await tester.tap(button);
        await tester.pumpAndSettle();
        await completed.future.timeout(const Duration(seconds: 5));
      } finally {
        recommendations.changes.removeListener(changed);
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('Quick Picks use native ranking and explain the displayed song',
      (tester) async {
    final requests = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (call) async {
      final args = call.arguments as Map;
      requests.add(args);
      return {
        'state': <String, Object?>{},
        'ranked': [
          for (final item in (args['candidates'] as List).reversed)
            {
              'id': (item as Map)['id'],
              'score': 1.0,
              'reason': 'From your local listening preferences'
            },
        ],
        'summary': <String, Object?>{},
      };
    });
    await tester.runAsync(() async {
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'quickpick01',
          title: 'First pick',
          subtitle: 'Artist'));
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'quickpick02',
          title: 'Second pick',
          subtitle: 'Artist'));
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'quickpick03',
          title: 'Third pick',
          subtitle: 'Artist'));
    });
    await show(tester);
    expect(find.text('Quick picks'), findsOneWidget);
    final first = find.byKey(const ValueKey('music-quick-pick-quickpick01'));
    final second = find.byKey(const ValueKey('music-quick-pick-quickpick02'));
    expect(tester.getRect(first).top, lessThan(tester.getRect(second).top));
    expect(requests.first['domain'], 'music');
    expect(requests.first['surface'], 'quick_picks');
    const rankedIds = ['quickpick01', 'quickpick02', 'quickpick03'];
    await tester.tap(second);
    expectSongQueue(rankedIds, 1);
    await playFromMenu(tester, second);
    expectSongQueue(rankedIds, 1);
    final actions =
        find.descendant(of: first, matching: find.byTooltip('Music actions'));
    await tester.tap(actions);
    await tester.pumpAndSettle();
    final enqueue = find.byKey(const ValueKey('music-song-add-to-queue'));
    expect(tester.getRect(enqueue).right,
        lessThan(tester.getRect(find.text('Why this?')).left));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('From your local listening preferences'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(player.plays, isEmpty);
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(enqueue);
    await tester.pumpAndSettle();
    expect(player.plays.single.ids, ['quickpick01']);
    final originalSlot = tester.getTopLeft(second);
    await tester.tap(
        find.descendant(of: second, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    const secondTrack =
        MusicTrack(videoId: 'quickpick02', title: 'Second pick');
    await tapAndWaitForEligibility(
        tester, find.text('Not interested'), secondTrack, false);
    expect(second, findsNothing);
    final undo = find.widgetWithText(SnackBarAction, 'Undo');
    expect(undo, findsOneWidget);
    await tester.runAsync(() =>
        RecommendationService.forProfile(db, db.profileId).feedback(
            const MusicTrack(videoId: 'quickpick01', title: 'First pick')
                .toVideo(),
            RecommendationDomain.music,
            RecommendationFeedback.like));
    await tester.pumpAndSettle();
    expect(second, findsNothing);
    await tapAndWaitForEligibility(tester, undo, secondTrack, true);
    expect(tester.getTopLeft(second), originalSlot);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 560);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await show(tester, textScale: 1.8);
    await tester.ensureVisible(first);
    await tester.tap(
        find.descendant(of: first, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    expect(tester.getRect(enqueue).bottom,
        lessThan(tester.getRect(find.text('Why this?')).top));
    await tester.ensureVisible(find.text('Why this?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Why this?'));
    await tester.pumpAndSettle();
    expect(find.text('From your local listening preferences'), findsOneWidget);
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    await tester.pumpAndSettle();
    expect(find.text('From your local listening preferences'), findsNothing);
    expect(catalog.searchCalls, 0);
    expect(catalog.discoveryArtists, [null, 'Artist', null]);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('Keep Listening uses music history and retires across profiles',
      (tester) async {
    await tester.runAsync(() async {
      await db.recordPlaybackHistory(
          PlaybackHistoryOrigin.music,
          HistoryVideoCache('listenagain', 'Listened song', 'Artist', '',
              musicMetadata:
                  const MusicMetadata(title: 'Listened song', artist: 'Artist'))
            ..created = DateTime.utc(2026, 1, 2));
      await db.recordPlaybackHistory(
          PlaybackHistoryOrigin.music,
          HistoryVideoCache('olderlisten', 'Earlier song', 'Artist', '',
              musicMetadata:
                  const MusicMetadata(title: 'Earlier song', artist: 'Artist'))
            ..created = DateTime.utc(2026, 1, 1));
      await db.recordPlaybackHistory(
          PlaybackHistoryOrigin.music,
          HistoryVideoCache('newerlisten', 'Later song', 'Artist', '',
              musicMetadata:
                  const MusicMetadata(title: 'Later song', artist: 'Artist'))
            ..created = DateTime.utc(2026, 1, 3));
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.video,
          HistoryVideoCache('videohist01', 'Video history', 'Creator', ''));
    });
    await show(tester);
    expect(find.text('Keep listening'), findsOneWidget);
    expect(find.text('Video history'), findsNothing);
    final card = find.byKey(const ValueKey('music-keep-listening-listenagain'));
    expect(find.descendant(of: card, matching: find.text('Listened song')),
        findsOneWidget);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    const historyIds = ['newerlisten', 'listenagain', 'olderlisten'];
    expectSongQueue(historyIds, 1);
    await playFromMenu(tester, card);
    expectSongQueue(historyIds, 1);
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    await tester.pumpAndSettle();
    expect(find.text('Listened song'), findsNothing);
    expect(find.text('Keep listening'), findsNothing);
    expect(catalog.searchCalls, 0);
    expect(catalog.discoveryCalls, 2);
  });

  Future<void> saveLearnedTracks(WidgetTester tester) =>
      tester.runAsync(() async {
        for (var i = 1; i <= 7; i++) {
          await library.save(MusicLibraryEntry(
              kind: MusicLibraryKind.song,
              id: 'learnmusic$i',
              title: 'Learned track $i',
              subtitle: 'Artist $i'));
        }
      });

  for (final rtl in [false, true]) {
    testWidgets(
        'Quick Picks snap one column per swipe (${rtl ? 'RTL' : 'LTR'})',
        (tester) async {
      if (rtl) {
        tester.platformDispatcher.localesTestValue = [const Locale('ar')];
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      }
      final forward = rtl ? 1.0 : -1.0;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final ids = List.generate(10, (i) => 'snappick00$i');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('videre/recommendations'),
              (_) async => {
                    'ranked': [
                      for (final id in ids)
                        {'id': id, 'score': 1.0, 'reason': 'Saved song'},
                    ],
                  });
      await tester.runAsync(() async {
        for (final id in ids) {
          await library.save(MusicLibraryEntry(
              kind: MusicLibraryKind.song, id: id, title: id));
        }
      });
      await show(tester);
      final shelf = find.byKey(const ValueKey('music-quick-picks'));
      Finder pick(int index) =>
          find.byKey(ValueKey('music-quick-pick-${ids[index]}'));
      final leading = tester.getTopLeft(pick(0)).dx;
      Future<void> swipe(double distance) async {
        await tester.fling(shelf, Offset(distance, 0), 2400);
        await tester.pumpAndSettle();
      }

      // A short, slow drag returns to the original column.
      await tester.timedDrag(
          shelf, Offset(40 * forward, 0), const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(pick(0)).dx, closeTo(leading, 1));

      // A fast swipe advances a single column even with a third available.
      await swipe(100 * forward);
      expect(tester.getTopLeft(pick(4)).dx, closeTo(leading, 1));
      await swipe(100 * forward);
      final lastColumn = tester.getRect(pick(8));
      expect(lastColumn.left, closeTo(leading, 1));
      expect(pick(9).hitTestable(), findsOneWidget);
      await swipe(100 * forward);
      expect(tester.getRect(pick(8)).left, closeTo(lastColumn.left, 1));

      await swipe(-100 * forward);
      expect(tester.getTopLeft(pick(4)).dx, closeTo(leading, 1));
      await tester.timedDrag(
          shelf, Offset(-210 * forward, 0), const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(pick(0)).dx, closeTo(leading, 1));
      await swipe(-100 * forward);
      expect(tester.getTopLeft(pick(0)).dx, closeTo(leading, 1));

      // A wide gesture can travel past a whole column, but still advances one.
      tester.view.physicalSize = const Size(830, 800);
      await tester.pumpAndSettle();
      final tabletStart = tester.getTopLeft(pick(0)).dx;
      final shelfBounds = tester.getRect(shelf);
      await tester.flingFrom(
          Offset(rtl ? shelfBounds.left + 8 : shelfBounds.right - 8,
              shelfBounds.center.dy),
          Offset((shelfBounds.width - 16) * forward, 0),
          3000);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(pick(4)).dx, closeTo(tabletStart, 1));

      // When all three columns fit, a swipe cannot page into empty space.
      tester.view.physicalSize = const Size(1440, 800);
      await tester.pumpAndSettle();
      final wideStart = tester.getTopLeft(pick(0)).dx;
      expect(pick(9).hitTestable(), findsOneWidget);
      await swipe(100 * forward);
      expect(tester.getTopLeft(pick(0)).dx, closeTo(wideStart, 1));
    });
  }

  for (final retainsSong in [true, false]) {
    testWidgets(
        'TV Back restores the Quick Pick ${retainsSong ? 'across lanes' : 'at the nearest remaining slot'}',
        (tester) async {
      final previousTv = isTv;
      isTv = true;
      addTearDown(() => isTv = previousTv);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var ranking = [1, 2, 3, 4, 5, 6, 7];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('videre/recommendations'),
              (_) async => {
                    'summary': <String, Object?>{},
                    'ranked': [
                      for (final number in ranking)
                        {
                          'id': 'learnmusic$number',
                          'score': 1.0,
                          'reason': 'Saved song'
                        },
                    ],
                  });
      await saveLearnedTracks(tester);
      await show(tester);
      Finder pickTitle(int number) => find.descendant(
          of: find.byKey(ValueKey('music-quick-pick-learnmusic$number')),
          matching: find.text('Learned track $number'));
      final played = pickTitle(6);
      final navigator = Navigator.of(tester.element(played));
      router.openPlayer = () => navigator.push<void>(MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Playing Quick Pick'))));
      await tester.ensureVisible(played);
      Focus.of(tester.element(played)).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Playing Quick Pick'), findsOneWidget);
      expect((router.pushed!.args as MusicRouteArgs).videoId, 'learnmusic6');

      ranking = retainsSong ? [6, 1, 2, 3, 4, 5, 7] : [1, 2];
      await tester.runAsync(() => db.recordPlaybackHistory(
          PlaybackHistoryOrigin.music,
          HistoryVideoCache('learnmusic6', 'Learned track 6', 'Artist', '',
              musicMetadata: const MusicMetadata(
                  title: 'Learned track 6', artist: 'Artist'))));
      playbackHistoryRevision.value++;
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      if (retainsSong) {
        expect(tester.getRect(played).top,
            lessThan(tester.getRect(pickTitle(1)).top));
      } else {
        expect(played, findsNothing);
      }
      expect(
          Focus.of(tester.element(pickTitle(retainsSong ? 6 : 2)))
              .hasPrimaryFocus,
          isTrue);
    });
  }

  testWidgets('Flow local shelves respect rank, thresholds and queue position',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('videre/recommendations'),
        (_) async => {
              'ranked': <Object?>[],
              'summary': {
                'onRepeat': ['learnmusic2', 'learnmusic1', 'unknown0001'],
                'rediscover': ['learnmusic1', 'learnmusic3', 'learnmusic4'],
                'timeBucket': 'WeekendEvening',
                'timeOfDay': [
                  'learnmusic2',
                  'learnmusic5',
                  'learnmusic6',
                  'learnmusic7'
                ],
              },
            });
    await saveLearnedTracks(tester);
    await show(tester);
    expect(find.text('On repeat'), findsOneWidget);
    expect(find.text('Rediscover'), findsNothing);
    expect(find.text('Your evening rotation'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('music-rotation-learnmusic2')), findsNothing);
    final first = find.byKey(const ValueKey('music-on-repeat-learnmusic2'));
    final second = find.byKey(const ValueKey('music-on-repeat-learnmusic1'));
    expect(tester.getTopLeft(first).dx, lessThan(tester.getTopLeft(second).dx));
    await tester.ensureVisible(second);
    await tester.pumpAndSettle();
    await tester.tap(second);
    expect(player.plays.single.ids, ['learnmusic2', 'learnmusic1']);
    expect(player.plays.single.startIndex, 1);
    expect(player.plays.single.audio, isTrue);
    expect(player.plays.single.fromMusic, isTrue);
    expect(catalog.relatedSeeds, isEmpty);
    expect(
        catalog.discoveryArtists, [null, 'Artist 7', 'Artist 6', 'Artist 5']);
  });

  List<String> stubMixRanking() {
    final requests = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('videre/recommendations'), (call) async {
      final args = call.arguments as Map;
      final surface = args['surface'] as String;
      if ((args['candidates'] as List).isNotEmpty) requests.add(surface);
      return {
        'ranked': [
          if (surface == 'discover')
            for (final track in (args['candidates'] as List).reversed)
              {'id': (track as Map)['id'], 'score': 1, 'reason': 'Learned'},
        ],
        'summary': {
          'dailyMixes': [
            {
              'label': 'Artist',
              'seedTrackIds': [
                'learnmusic1',
                'learnmusic2',
                'learnmusic3',
                'learnmusic4',
              ]
            },
          ],
        },
      };
    });
    return requests;
  }

  final mixTracks = [
    for (var index = 1; index <= 4; index++)
      MusicTrack(videoId: 'related000$index', title: 'Related song $index'),
  ];
  final mix = find.byKey(const ValueKey('music-daily-mix-0'));

  for (final tablet in [false, true]) {
    testWidgets(
        'daily mix opens immediately with its prepared ranked songs on ${tablet ? 'tablet' : 'phone'}',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize =
          tablet ? const Size(960, 640) : const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final readyTracks = tablet
          ? [
              for (var index = 1; index <= 14; index++)
                MusicTrack(
                    videoId: 'related${index.toString().padLeft(4, '0')}',
                    title: 'Related song $index'),
            ]
          : mixTracks;
      final requests = stubMixRanking();
      await saveLearnedTracks(tester);
      await show(tester);
      expect(catalog.relatedSeeds, [
        ['learnmusic1', 'learnmusic2', 'learnmusic3']
      ]);
      expect(mix, findsNothing);
      final previousRanks =
          requests.where((surface) => surface == 'quick_picks').length;
      await tester.runAsync(() => db.recordPlaybackHistory(
          PlaybackHistoryOrigin.music,
          HistoryVideoCache('learnmusic1', 'Learned track 1', 'Artist 1', '',
              musicMetadata: const MusicMetadata(
                  title: 'Learned track 1', artist: 'Artist 1'))));
      playbackHistoryRevision.value++;
      await tester.pumpAndSettle();
      expect(requests.where((surface) => surface == 'quick_picks').length,
          greaterThan(previousRanks));
      catalog.relatedResponses.single.complete(readyTracks);
      await tester.pumpAndSettle();
      expect(mix, findsOneWidget);
      expect(requests.where((surface) => surface == 'discover'), hasLength(1));
      await tester.runAsync(() => db.recordPlaybackHistory(
          PlaybackHistoryOrigin.music,
          HistoryVideoCache('learnmusic2', 'Learned track 2', 'Artist 2', '',
              musicMetadata: const MusicMetadata(
                  title: 'Learned track 2', artist: 'Artist 2'))));
      playbackHistoryRevision.value++;
      await tester.pumpAndSettle();
      await tester.ensureVisible(mix);
      await tester.tap(mix);
      await tester.pumpAndSettle();
      expect(find.text('Artist Mix'), findsOneWidget);
      expect(find.byKey(const ValueKey('music-collection-load')), findsNothing);
      final song = find.text(readyTracks.last.title);
      final play = find.byKey(const ValueKey('music-collection-play'));
      final details =
          find.byKey(const ValueKey('music-collection-details-pane'));
      expect(song, findsOneWidget);
      if (tablet) {
        expect(details, findsOneWidget);
        expect(tester.getCenter(play).dx, lessThan(tester.getCenter(song).dx));
      } else {
        expect(details, findsNothing);
        expect(tester.getCenter(play).dy, lessThan(tester.getCenter(song).dy));
      }
      expect(catalog.relatedResponses, hasLength(1));
      expect(requests.where((surface) => surface == 'discover'), hasLength(1));
      await tester.tap(play);
      expect(player.plays.single.ids,
          readyTracks.reversed.map((track) => track.videoId));
      if (tablet) {
        final scroller = find.descendant(
            of: find.byKey(const ValueKey('music-collection-tracks-pane')),
            matching: find.byType(Scrollable));
        final state = tester.state<ScrollableState>(scroller);
        await tester.drag(scroller, const Offset(0, -180));
        await tester.pumpAndSettle();
        final offset = state.position.pixels;
        expect(offset, greaterThan(0));

        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(details, findsNothing);
        expect(tester.state<ScrollableState>(scroller), same(state));
        expect(state.position.pixels, closeTo(offset, 1));
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(play, findsNothing);
      expect(mix, findsOneWidget);
    });
  }

  for (final fails in [true, false]) {
    testWidgets(
        'daily mix stays hidden after ${fails ? 'failed recall' : 'insufficient tracks'}',
        (tester) async {
      stubMixRanking();
      await saveLearnedTracks(tester);
      await show(tester);
      final response = catalog.relatedResponses.single;
      if (fails) {
        response.completeError(StateError('Related songs unavailable'));
      } else {
        response.complete(mixTracks.take(3).toList());
      }
      await tester.pumpAndSettle();
      expect(mix, findsNothing);
      expect(find.byKey(const ValueKey('music-daily-mixes')), findsNothing);
      expect(tester.takeException(), isNull);
      await show(tester, active: false);
      await show(tester);
      expect(mix, findsNothing);
      if (fails) {
        expect(catalog.relatedResponses, hasLength(2));
        catalog.relatedResponses.last.complete(mixTracks);
        await tester.pumpAndSettle();
        expect(mix, findsOneWidget);
      } else {
        expect(catalog.relatedResponses, hasLength(1));
      }
    });
  }

  testWidgets('daily mix waits for visible Music and drops hidden results',
      (tester) async {
    stubMixRanking();
    await saveLearnedTracks(tester);
    await show(tester, active: false);
    expect(catalog.relatedSeeds, isEmpty);
    await show(tester);
    final current = catalog.relatedGuards.single!;
    expect(current(), isTrue);
    await show(tester, active: false);
    expect(current(), isFalse);
    catalog.relatedResponses.single.complete(mixTracks);
    await tester.pumpAndSettle();
    await show(tester);
    expect(catalog.relatedResponses, hasLength(2));
    expect(mix, findsNothing);
    catalog.relatedResponses.last.complete(mixTracks);
    await tester.pumpAndSettle();
    expect(mix, findsOneWidget);
  });

  for (final scope in ['profile', 'server', 'proxy']) {
    testWidgets('daily mix drops a late response after a $scope change',
        (tester) async {
      stubMixRanking();
      await saveLearnedTracks(tester);
      await show(tester);
      final current = catalog.relatedGuards.single!;
      final original = catalog.relatedResponses.single;
      switch (scope) {
        case 'profile':
          final next =
              (await tester.runAsync(() => db.createProfile('Second')))!;
          await tester.runAsync(() => db.useProfile(next.id));
          app.change(app.state.copyWith(profileId: next.id));
        case 'server':
          app.change(app.state
              .copyWith(server: const Server(url: 'https://second.example')));
        case 'proxy':
          await tester.runAsync(() =>
              NetworkProxy.instance.apply(SocksProxyConfig(enabled: true)));
      }
      expect(current(), isFalse);
      original.complete(mixTracks);
      await tester.pumpAndSettle();
      expect(mix, findsNothing);
      if (scope == 'profile') {
        expect(catalog.relatedResponses, hasLength(1));
      } else {
        expect(catalog.relatedResponses, hasLength(2));
        catalog.relatedResponses.last.complete(mixTracks);
        await tester.pumpAndSettle();
        expect(mix, findsOneWidget);
      }
    });
  }

  testWidgets('daily mix ignores background results and resumes on return',
      (tester) async {
    final binding = tester.binding;
    final previous = binding.lifecycleState;
    addTearDown(() => binding
        .handleAppLifecycleStateChanged(previous ?? AppLifecycleState.resumed));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    stubMixRanking();
    await saveLearnedTracks(tester);
    await show(tester);
    final current = catalog.relatedGuards.single!;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(current(), isFalse);
    catalog.relatedResponses.single.complete(mixTracks);
    await tester.pump();
    expect(catalog.relatedResponses, hasLength(1));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(mix, findsNothing);
    expect(catalog.relatedResponses, hasLength(2));
    catalog.relatedResponses.last.complete(mixTracks);
    await tester.pumpAndSettle();
    expect(mix, findsOneWidget);
  });

  testWidgets('retained Keep Listening updates while learning is paused',
      (tester) async {
    final settings = TestSettingsCubit(SettingsState.init(), app);
    addTearDown(settings.close);
    await tester.runAsync(() =>
        RecommendationService.forProfile(db, db.profileId)
            .setLearningEnabled(RecommendationDomain.music, false));
    await show(tester, settings: settings);
    expect(find.text('Keep listening'), findsNothing);
    await tester.runAsync(() => db.recordPlaybackHistory(
        PlaybackHistoryOrigin.music,
        HistoryVideoCache('listenagain', 'Newly listened song', 'Artist', '',
            musicMetadata: const MusicMetadata(
                title: 'Newly listened song', artist: 'Artist'))));
    playbackHistoryRevision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Keep listening'), findsOneWidget);
    final historyCard =
        find.byKey(const ValueKey('music-keep-listening-listenagain'));
    expect(
        find.descendant(
            of: historyCard, matching: find.text('Newly listened song')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('music-speed-dial-listenagain')),
        findsOneWidget);
    final shortcuts = find.byKey(const ValueKey('music-home-shortcuts'));
    final original = settings.state.musicLayout;
    await tester.runAsync(() =>
        settings.setMusicLayout(original.copyWith(showRecentActivity: false)));
    await tester.pumpAndSettle();
    expect(historyCard, findsNothing);
    expect(find.byKey(const ValueKey('music-speed-dial-listenagain')),
        findsOneWidget);
    expect(shortcuts, findsOneWidget);
    await tester.runAsync(() =>
        settings.setMusicLayout(original.copyWith(showHomeShortcuts: false)));
    await tester.pumpAndSettle();
    expect(shortcuts, findsNothing);
    expect(find.text('Saved songs'), findsOneWidget);
    expect(historyCard, findsOneWidget);
    expect(catalog.discoveryCalls, 1);
    expect(catalog.searchCalls, 0);
  });

  testWidgets('Home uses local music without loading a trending feed',
      (tester) async {
    await show(tester);
    expect(find.byKey(const ValueKey('music-home-shortcuts')), findsOneWidget);
    expect(find.text('Saved songs'), findsOneWidget);
    expect(find.text('Search suggestions'), findsNothing);
    expect(find.text('Save songs to build your music home.'), findsOneWidget);
    expect(find.text('Trending music'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(catalog.trendingCalls, 0);
    expect(catalog.searchCalls, 0);
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets('slow initial sections use their shelf layouts and one status', (
    tester,
  ) async {
    const artistId = 'UCaaaaaaaaaaaaaaaaaaaaaa';
    const release = MusicCollection(id: 'OLAK5uy_loading', title: 'New album');
    await tester.runAsync(
      () => library.save(
        const MusicLibraryEntry(
          kind: MusicLibraryKind.artist,
          id: artistId,
          title: 'Saved artist',
        ),
      ),
    );
    catalog.artistReleases[artistId] = const MusicArtistReleases(
      releases: [release],
    );
    final chart = catalog.chartResponse = Completer<List<MusicTrack>>();
    catalog.holdGenres = catalog.holdDiscovery = true;
    await show(tester, settle: false);

    final discovery = find.byKey(const ValueKey('music-discovery-loading'));
    final releases = find.byKey(const ValueKey('music-home-releases-loading'));
    final charts = find.byKey(const ValueKey('music-home-chart-loading'));
    final explore = find.byKey(const ValueKey('music-explore-loading'));
    final grid = find.descendant(of: explore, matching: find.byType(Wrap));
    final shelf = find.descendant(
      of: charts,
      matching: find.byType(MusicCatalogShelf),
    );
    final status = find.bySemanticsLabel('Finding music…');
    expect(discovery, findsOneWidget);
    expect(releases, findsOneWidget);
    expect(shelf, findsOneWidget);
    expect(tester.widget<Wrap>(grid).children, hasLength(4));
    expect(find.bySemanticsLabel('Explore music'), findsNothing);
    expect(find.bySemanticsLabel('Releases from saved artists'), findsNothing);
    expect(status, findsOneWidget);
    final liveStatus = tester.getSemantics(status);
    expect(liveStatus, containsSemantics(isLiveRegion: true));
    final statusId = liveStatus.id;
    final shelfSize = tester.getSize(shelf);

    chart.complete([
      const MusicTrack(videoId: 'chartTrack1', title: 'Regional recording'),
    ]);
    await tester.pumpAndSettle();
    expect(releases, findsNothing);
    expect(charts, findsNothing);
    expect(find.text(release.title), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('music-home-chart'))),
      shelfSize,
    );
    expect(discovery, findsOneWidget);
    expect(tester.getSemantics(status).id, statusId);

    catalog.discoveries.first.complete([_discovered]);
    await tester.pumpAndSettle();
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    expect(discovery, findsNothing);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(explore, findsOneWidget);
    expect(tester.getSemantics(status).id, statusId);

    for (final _ in _genres) {
      catalog.genreResponses.last.complete([]);
      await tester.pumpAndSettle();
    }
    expect(explore, findsNothing);
    expect(status, findsNothing);
  });

  testWidgets('initial placeholders stay static while reduced motion is set', (
    tester,
  ) async {
    catalog.holdDiscovery = true;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await show(tester);
    final placeholder = find.byKey(const ValueKey('music-discovery-loading'));
    expect(placeholder, findsOneWidget);
    expect(
      find.descendant(
          of: placeholder,
          matching: find.byType(TweenAnimationBuilder<double>)),
      findsNothing,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);

    catalog.discoveries.single.complete([]);
    await tester.pumpAndSettle();
    expect(placeholder, findsNothing);
    expect(find.byKey(const ValueKey('music-discovery-empty')), findsOneWidget);
  });

  testWidgets('visible Home discovers songs once and opens verified results',
      (tester) async {
    await tester.runAsync(installCommunityMusicFilters);
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    expect(catalog.discoveryCalls, 1);
    expect(
        find.byKey(const ValueKey('music-discovery-loading')), findsOneWidget);
    catalog.discoveries.single.complete([
      const MusicTrack(videoId: 'priorSong01', title: 'First result'),
      const MusicTrack(
          videoId: 'hiddenSong1',
          title: 'Hidden song',
          uploaderChannelId: musicListedUploader),
      _discovered,
      const MusicTrack(videoId: 'laterSong01', title: 'Last result')
    ]);
    await tester.pumpAndSettle();
    await show(tester);
    expect(catalog.discoveryCalls, 1);
    final card = find.byKey(const ValueKey('music-discovery-discover001'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    expectSongQueue(['priorSong01', _discovered.videoId, 'laterSong01'], 1);
    final toggle = find.textContaining('Show hidden results');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(card);
    await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    router.pushed = null;
    await tester.tap(find.byKey(const ValueKey('music-song-play')));
    await tester.pumpAndSettle();
    expectSongQueue(
        ['priorSong01', 'hiddenSong1', _discovered.videoId, 'laterSong01'], 2);
    expect(catalog.discoveryCalls, 1);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('holding Discovery cards selects in displayed order before Back',
      (tester) async {
    const firstSong = MusicTrack(videoId: 'priorSong01', title: 'First result');
    const lastSong = MusicTrack(videoId: 'laterSong01', title: 'Last result');
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([firstSong, _discovered, lastSong]);
    await tester.pumpAndSettle();
    Finder card(MusicTrack song) =>
        find.byKey(ValueKey('music-discovery-${song.videoId}'));
    final first = card(firstSong);
    final last = card(lastSong);
    await tester.ensureVisible(last);
    final mouse = await tester.startGesture(tester.getCenter(last),
        kind: PointerDeviceKind.mouse);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.ensureVisible(first);
    await tester.tap(first);
    await tester.pumpAndSettle();
    final bar = find.byType(MusicSongSelectionBar);
    expect(find.text('2 selected'), findsOneWidget);
    expect(
        tester
            .widget<MusicSongSelectionBar>(bar)
            .selected
            .map((v) => v.videoId),
        [firstSong.videoId, lastSong.videoId]);
    expect(router.pushed, isNull);

    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Select all'));
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    await tester.ensureVisible(first);
    await tester.tap(
        find.descendant(of: first, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select song'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Close'));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    await tester.ensureVisible(first);
    await tester.tap(first);
    expectSongQueue(
        [firstSong.videoId, _discovered.videoId, lastSong.videoId], 0);
  });

  testWidgets('Discovery snooze removes the recording and can be ended in Home',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('music-discovery-discover001'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snooze in Discovery'));
    await tester.pumpAndSettle();

    final visibility = MusicVisibility.forProfile(db, db.profileId);
    Future<void> change(Finder target) async {
      await tester.runAsync(() async {
        final saved = Completer<void>();
        void changed() {
          if (!saved.isCompleted) saved.complete();
        }

        visibility.addListener(changed);
        try {
          await tester.tap(target);
          await tester.pumpAndSettle();
          await saved.future.timeout(const Duration(seconds: 5));
        } finally {
          visibility.removeListener(changed);
        }
      });
      await tester.pumpAndSettle();
    }

    await change(find.text('7 days'));
    expect(card, findsNothing);
    final manager = find.text('Snoozed songs');
    await tester.ensureVisible(manager);
    await tester.tap(manager);
    await tester.pumpAndSettle();
    expect(find.textContaining('Until '), findsWidgets);
    await change(find.byTooltip('End snooze'));
    expect(visibility.activeSnoozes, isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets('offline discovery saves visible picks and plays readable files',
      (tester) async {
    final downloads = _Downloads();
    addTearDown(downloads.close);
    await tester.runAsync(installCommunityMusicFilters);
    catalog.holdDiscovery = true;
    await show(tester, downloads: downloads, settle: false);
    const unreadable = MusicTrack(videoId: 'unreadable1', title: 'Unreadable');
    const pending = MusicTrack(videoId: 'queuedSong1', title: 'Will download');
    catalog.discoveries.single.complete([
      _discovered,
      const MusicTrack(
          videoId: 'hiddenSong1',
          title: 'Hidden song',
          uploaderChannelId: musicListedUploader),
      unreadable,
      pending,
    ]);
    await tester.pumpAndSettle();
    expect(downloads.requests, isEmpty);

    final profileId = app.state.profileId;
    final keep = find.byKey(const ValueKey('music-discovery-keep-offline'));
    await tester.ensureVisible(keep);
    await tester.tap(keep);
    await tester.pumpAndSettle();
    expect(downloads.requests.single.profileId, profileId);
    expect(downloads.requests.single.ids,
        [_discovered.videoId, unreadable.videoId, pending.videoId]);

    DownloadedVideo row(MusicTrack track, {bool complete = true}) =>
        DownloadedVideo(
            videoId: track.videoId,
            title: track.title,
            profileId: profileId,
            musicMetadata: track.musicMetadata,
            lengthSeconds: 63,
            quality: highestAudioDownloadQuality,
            audioOnly: true,
            downloadComplete: complete);
    final available = row(_discovered);
    final verified = DownloadedVideo.fromJson(available.toJson());
    final proof = 'a' * 64;
    downloads.readable = [
      (
        download: verified,
        uri: 'file:///offline-song',
        identity: proof,
        byteLength: 42
      ),
    ];
    downloads.report(
        [available, row(unreadable), row(pending, complete: false)],
        waitingForWifi: true);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3 songs available offline'), findsOneWidget);
    expect(find.text('Waiting for Wi-Fi'), findsOneWidget);

    // The profile can listen and opt out even when the catalog is unavailable.
    app.change(app.state.copyWith(server: null));
    await tester.pumpAndSettle();
    expect(keep, findsNothing);
    final play = find.byKey(const ValueKey('music-discovery-play-offline'));
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pumpAndSettle();
    final entry = player.offlinePlays.single.single;
    expect(entry.download, verified);
    expect(entry.downloadFileProof, proof);

    final stop = find.byKey(const ValueKey('music-discovery-stop-offline'));
    await tester.ensureVisible(stop);
    await tester.tap(stop);
    await tester.pumpAndSettle();
    expect(downloads.requests.last.profileId, profileId);
    expect(downloads.requests.last.ids, isEmpty);
    expect(play, findsNothing);
    expect(stop, findsNothing);
  });

  testWidgets('offline discovery actions expire when the profile changes',
      (tester) async {
    final downloads = _Downloads();
    addTearDown(downloads.close);
    catalog.holdDiscovery = true;
    final first = app.state.profileId;
    downloads.selections[first] = [_discovered.videoId];
    await show(tester, downloads: downloads, settle: false);
    catalog.discoveries.single.complete([]);
    await tester.pumpAndSettle();
    final stop = find.byKey(const ValueKey('music-discovery-stop-offline'));
    final stale = tester.widget<TextButton>(stop).onPressed!;

    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    stale();
    await tester.pump();
    await tester.pump();
    expect(downloads.requests, isEmpty);
    expect(downloads.selections[first], [_discovered.videoId]);
    expect(stop, findsNothing);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
  });

  void rankDiscovery({bool Function()? available}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (call) async {
      if (available?.call() == false) throw MissingPluginException();
      final args = call.arguments as Map;
      return {
        'ranked': [
          for (final item in args['candidates'] as List)
            {'id': (item as Map)['id'], 'score': 1.0, 'reason': 'Local choice'},
        ],
        'state': <String, Object?>{},
        'summary': <String, Object?>{},
      };
    });
  }

  testWidgets('ranked discovery can queue a displayed song while refreshing',
      (tester) async {
    rankDiscovery();
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('music-discovery-refresh'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pump();
    expect(catalog.discoveryCalls, 2);
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
    final card = find.byKey(const ValueKey('music-discovery-discover001'));
    final actions =
        find.descendant(of: card, matching: find.byTooltip('Music actions'));
    await tester.ensureVisible(actions);
    await tester.pump();
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-song-add-to-queue')));
    await tester.pumpAndSettle();
    expect(player.plays.map((play) => play.ids), [
      [_discovered.videoId]
    ]);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
  });

  testWidgets('discovery undo restores the same slot without native ranking',
      (tester) async {
    var nativeAvailable = true;
    rankDiscovery(available: () => nativeAvailable);
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    const before = MusicTrack(videoId: 'discover002', title: 'First song');
    const after = MusicTrack(videoId: 'discover003', title: 'Last song');
    catalog.discoveries.single.complete([before, _discovered, after]);
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('music-discovery-discover001'));
    final first = find.byKey(const ValueKey('music-discovery-discover002'));
    final last = find.byKey(const ValueKey('music-discovery-discover003'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final oldLocation = tester.getTopLeft(card);
    await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('music-song-add-to-queue')), findsOneWidget);
    nativeAvailable = false;
    await tapAndWaitForEligibility(
        tester, find.text('Not interested'), _discovered, false);
    expect(card, findsNothing);
    expect(
        RecommendationService.forProfile(db, db.profileId)
            .eligibleMusic([_discovered]),
        isEmpty);
    final undo = find.widgetWithText(SnackBarAction, 'Undo');
    expect(undo, findsOneWidget);
    await tapAndWaitForEligibility(tester, undo, _discovered, true);
    expect(tester.getTopLeft(card), oldLocation);
    expect(tester.getTopLeft(first).dx, lessThan(tester.getTopLeft(card).dx));
    expect(tester.getTopLeft(last).dx, greaterThan(tester.getTopLeft(card).dx));
    expect(catalog.discoveryCalls, 1);
    expect(catalog.searchCalls, 0);
  });

  testWidgets('external exclusions update retained discovery and stale cards',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('music-discovery-discover001'));
    final stale = tester.widget<MusicCatalogCard>(card);
    await tester.runAsync(() =>
        RecommendationService.forProfile(db, db.profileId).feedback(
            _discovered.toVideo(),
            RecommendationDomain.music,
            RecommendationFeedback.notInterested));
    stale.onOpen();
    expect(router.pushed, isNull);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(find.byKey(const ValueKey('music-home-discover')), findsNothing);
    expect(catalog.discoveryCalls, 1);
  });

  Future<void> finishDiscovery(
      WidgetTester tester, List<MusicTrack> songs) async {
    catalog.discoveries.last.complete(songs);
    await tester.pump();
    await tester.pump();
  }

  final discoverShortcut = find.byKey(const ValueKey('music-home-discover'));
  Finder artistChip(String artist) => find.widgetWithText(ChoiceChip, artist);
  const artistSong =
      MusicTrack(videoId: 'artist00001', title: 'Prepared artist recording');

  final homeScroll = find.byKey(const PageStorageKey('music-home'));

  ScrollPosition homePosition(WidgetTester tester) =>
      tester.widget<SingleChildScrollView>(homeScroll).controller!.position;

  Future<void> pullHome(WidgetTester tester) async {
    final home = tester.getRect(homeScroll);
    await tester.dragFrom(
        home.topCenter + const Offset(0, 16), const Offset(0, 340));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
  }

  testWidgets('Home pull refreshes a short page and its remote shelves',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, []);
    await tester.pumpAndSettle();
    expect(homePosition(tester).maxScrollExtent, 0);
    final chartId = catalog.chartRequests.single;
    final genres = List.of(catalog.genres);

    await pullHome(tester);
    expect(catalog.discoveryArtists, [null, null]);
    expect(catalog.chartRequests, [chartId]);
    catalog.chartTracks = const [
      MusicTrack(videoId: 'newchart001', title: 'New chart song')
    ];
    await finishDiscovery(tester, [_discovered]);
    await tester.pumpAndSettle();

    expect(find.text(_discovered.title), findsOneWidget);
    expect(find.text('New chart song'), findsOneWidget);
    expect(catalog.chartRequests, [chartId, chartId]);
    expect(catalog.genres, genres);
    expect(catalog.relatedSeeds, isEmpty);
    expect(catalog.artistReleaseRequests, isEmpty);
    expect(catalog.searchCalls, 0);
    expect(catalog.trendingCalls, 0);
    expect(searches, 0);
    expect(libraryVisits, 0);
  });

  testWidgets('Home pull waits for a different seed then refreshes its own',
      (tester) async {
    const refreshed = MusicTrack(
        videoId: 'discover002', title: 'Refreshed general recording');
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, [_discovered]);
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
    final chartId = catalog.chartRequests.single;

    await pullHome(tester);
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(catalog.chartRequests, [chartId]);

    await finishDiscovery(tester, [artistSong]);
    expect(catalog.discoveryArtists, [null, 'Saved artist', null]);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(catalog.chartRequests, [chartId]);

    await finishDiscovery(tester, [refreshed]);
    await tester.pumpAndSettle();
    final allMusic = artistChip('All music');
    expect(tester.widget<ChoiceChip>(allMusic).selected, isTrue);
    expect(find.text(refreshed.title), findsOneWidget);
    expect(find.text(_discovered.title), findsNothing);
    expect(catalog.chartRequests, [chartId, chartId]);
  });

  testWidgets('Home pull joins active work and keeps the selected artist',
      (tester) async {
    const refreshed =
        MusicTrack(videoId: 'artist00002', title: 'Refreshed artist recording');
    const oldRelease = MusicCollection(id: 'PLold', title: 'Old release');
    const newRelease = MusicCollection(id: 'PLnew', title: 'New release');
    final artistId = 'UC${'a' * 22}';
    await tester.runAsync(() async {
      await library.save(_saved);
      await library.save(MusicLibraryEntry(
          kind: MusicLibraryKind.artist, id: artistId, title: 'Saved artist'));
    });
    catalog.holdDiscovery = true;
    catalog.chartTracks = List.generate(
        10,
        (index) =>
            MusicTrack(videoId: 'chart00000$index', title: 'Chart $index'));
    catalog.artistReleases[artistId] =
        const MusicArtistReleases(releases: [oldRelease]);
    await show(tester, settle: false);
    await finishDiscovery(tester, [_discovered]);
    await finishDiscovery(tester, [artistSong]);
    await tester.pumpAndSettle();
    final choice = artistChip('Saved artist');
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(choice).selected, isTrue);
    expect(find.text(artistSong.title), findsOneWidget);
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
    final chartId = catalog.chartRequests.single;

    final chart = find.byKey(const ValueKey('music-home-chart'));
    await tester.ensureVisible(chart);
    await tester.drag(chart, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(catalog.chartRequests, [chartId]);
    expect(catalog.discoveryCalls, 2);

    final chartRefresh = find.byKey(const ValueKey('music-home-fresh-refresh'));
    final discoveryRefresh =
        find.byKey(const ValueKey('music-discovery-refresh'));
    final pendingChart = Completer<List<MusicTrack>>();
    catalog.chartResponse = pendingChart;
    await tester.ensureVisible(chartRefresh);
    await tester.tap(chartRefresh);
    await tester.pump();
    await tester.ensureVisible(discoveryRefresh);
    await tester.tap(discoveryRefresh);
    await tester.pump();
    homePosition(tester).jumpTo(0);
    await tester.pump();
    await pullHome(tester);
    expect(catalog.discoveryArtists, [null, 'Saved artist', 'Saved artist']);
    expect(catalog.chartRequests, [chartId, chartId]);
    expect(find.text(artistSong.title), findsOneWidget);
    expect(find.text(oldRelease.title), findsOneWidget);

    // The chart can finish first. It still satisfies the Home refresh.
    catalog.artistReleases[artistId] =
        const MusicArtistReleases(releases: [newRelease]);
    catalog.chartResponse = null;
    pendingChart.complete(
        const [MusicTrack(videoId: 'newchart001', title: 'New chart song')]);
    await tester.pump();
    await tester.pump();
    expect(find.text(newRelease.title), findsOneWidget);
    expect(find.text(artistSong.title), findsOneWidget);
    await finishDiscovery(tester, [refreshed]);
    await tester.pumpAndSettle();
    expect(catalog.chartRequests, [chartId, chartId]);
    expect(catalog.artistReleaseRequests, [artistId, artistId]);
    expect(tester.widget<ChoiceChip>(choice).selected, isTrue);
    expect(find.text(refreshed.title), findsOneWidget);
    expect(find.text(artistSong.title), findsNothing);

    await pullHome(tester);
    expect(catalog.discoveryArtists,
        [null, 'Saved artist', 'Saved artist', 'Saved artist']);
    expect(find.text(refreshed.title), findsOneWidget);
    catalog.discoveries.last.completeError(InvidiousServiceError(
        'Too many requests',
        statusCode: 429,
        retryAfter: const Duration(minutes: 1)));
    await tester.pumpAndSettle();
    expect(find.text(refreshed.title), findsOneWidget);
    expect(tester.widget<ChoiceChip>(choice).selected, isTrue);
    expect(find.text('New chart song'), findsOneWidget);
    expect(find.text(newRelease.title), findsOneWidget);
    await pullHome(tester);
    await tester.pumpAndSettle();
    expect(catalog.discoveryCalls, 4);
    expect(catalog.chartRequests, [chartId, chartId]);
    expect(catalog.artistReleaseRequests, [artistId, artistId]);

    final allMusic = artistChip('All music');
    await tester.ensureVisible(allMusic);
    await tester.tap(allMusic);
    await tester.pumpAndSettle();
    expect(find.text(_discovered.title), findsOneWidget);
    expect(catalog.discoveryCalls, 4);
  });

  testWidgets('Home prepares at most three distinct saved artists in sequence',
      (tester) async {
    await tester.runAsync(() async {
      for (final artist in ['First', 'Second', 'Third', 'Fourth']) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: artist,
            title: '$artist recording',
            subtitle: artist));
      }
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.artist,
          id: 'UCsavedchannel',
          title: 'FOURTH'));
    });
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    expect(catalog.discoveryArtists, [null]);
    expect(discoverShortcut, findsNothing);
    expect(artistChip('FOURTH'), findsNothing);

    await finishDiscovery(tester, [_discovered]);
    expect(catalog.discoveryArtists, [null, 'FOURTH']);
    expect(discoverShortcut, findsOneWidget);
    expect(artistChip('FOURTH'), findsNothing);
    await finishDiscovery(tester, [artistSong]);
    expect(catalog.discoveryArtists, [null, 'FOURTH', 'Third']);
    expect(artistChip('FOURTH'), findsOneWidget);
    expect(artistChip('Third'), findsNothing);

    await tester.ensureVisible(artistChip('FOURTH'));
    await tester.tap(artistChip('FOURTH'));
    await tester.pump();
    expect(find.text(artistSong.title), findsOneWidget);
    expect(find.text(_discovered.title), findsNothing);
    expect(catalog.discoveryArtists, [null, 'FOURTH', 'Third']);
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
    await tester.tap(artistChip('All music'));
    await tester.pump();
    expect(find.text(_discovered.title), findsOneWidget);

    await finishDiscovery(tester, []);
    expect(catalog.discoveryArtists, [null, 'FOURTH', 'Third', 'Second']);
    expect(artistChip('Third'), findsNothing);
    expect(artistChip('Second'), findsNothing);
    await finishDiscovery(tester, [
      const MusicTrack(videoId: 'second00001', title: 'Second artist song')
    ]);
    expect(artistChip('Second'), findsOneWidget);
    expect(artistChip('First'), findsNothing);
    await tester.ensureVisible(artistChip('Second'));
    await tester.tap(artistChip('Second'));
    await tester.pumpAndSettle();
    expect(find.text('Second artist song'), findsOneWidget);
    expect(catalog.discoveryArtists, [null, 'FOURTH', 'Third', 'Second']);
    expect(router.pushed, isNull);
  });

  testWidgets('Discover opens a ready artist when general discovery is empty',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, []);
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
    expect(discoverShortcut, findsNothing);
    expect(artistChip('Saved artist'), findsNothing);
    await finishDiscovery(tester, [artistSong]);
    expect(discoverShortcut, findsOneWidget);
    await tester.ensureVisible(discoverShortcut);
    await tester.tap(discoverShortcut);
    await tester.pumpAndSettle();
    expect(find.text(artistSong.title), findsOneWidget);
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
  });

  testWidgets('returning Home resumes artist preparation from the ready cache',
      (tester) async {
    await tester.runAsync(() async {
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.artist, id: 'UColderartist', title: 'Older'));
      await library.save(_saved);
    });
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, [_discovered]);
    await finishDiscovery(tester, [artistSong]);
    expect(catalog.discoveryArtists, [null, 'Saved artist', 'Older']);
    final pending = catalog.discoveries.last;
    final current = catalog.discoveryGuards.last!;

    await show(tester, active: false);
    expect(current(), isFalse);
    pending.complete([
      const MusicTrack(videoId: 'stale000001', title: 'Covered recommendation')
    ]);
    await tester.pumpAndSettle();
    expect(catalog.discoveryArtists, [null, 'Saved artist', 'Older']);
    await show(tester, settle: false);
    expect(catalog.discoveryArtists, [null, 'Saved artist', 'Older', 'Older']);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(artistChip('Saved artist'), findsOneWidget);
    expect(artistChip('Older'), findsNothing);
    await finishDiscovery(tester, []);
    expect(find.text('Covered recommendation'), findsNothing);
  });

  testWidgets(
      'instance cooldown stops automatic artist batches until a permitted retry',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.completeError(InvidiousServiceError(
        'Too many requests',
        statusCode: 429,
        retryAfter: const Duration(minutes: 1)));
    await tester.pumpAndSettle();
    final retry = find.byKey(const ValueKey('music-discovery-retry'));
    expect(tester.widget<FilledButton>(retry).onPressed, isNull);
    expect(discoverShortcut, findsNothing);
    expect(catalog.discoveryArtists, [null]);
    await show(tester, active: false);
    await show(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(tester.widget<FilledButton>(retry).onPressed, isNull);
    expect(catalog.discoveryArtists, [null]);
    await tester.pump(const Duration(seconds: 31));
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
    expect(catalog.discoveryArtists, [null]);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(catalog.discoveryArtists, [null, null]);
    await finishDiscovery(tester, [_discovered]);
    expect(catalog.discoveryArtists, [null, null, 'Saved artist']);
    await finishDiscovery(tester, [artistSong]);
    expect(artistChip('Saved artist'), findsOneWidget);
  });

  testWidgets(
      'a partial response preserves verified songs during an instance cooldown',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveryFailures.single!(InvidiousServiceError('Too many requests',
        statusCode: 429, retryAfter: const Duration(minutes: 1)));
    await finishDiscovery(tester, [_discovered]);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(discoverShortcut, findsOneWidget);
    expect(catalog.discoveryArtists, [null]);
    await show(tester, active: false);
    await show(tester);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(artistChip('Saved artist'), findsNothing);
    expect(catalog.discoveryArtists, [null]);
    await tester.pump(const Duration(minutes: 1));
    expect(catalog.discoveryArtists, [null]);
  });

  testWidgets('a failed artist stays hidden and can be prepared on retry',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, []);
    catalog.discoveries.last.completeError(StateError('Unavailable'));
    await tester.pumpAndSettle();
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
    expect(discoverShortcut, findsNothing);
    expect(artistChip('Saved artist'), findsNothing);
    final retry = find.byKey(const ValueKey('music-discovery-retry'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(catalog.discoveryArtists, [null, 'Saved artist', 'Saved artist']);
    await finishDiscovery(tester, [artistSong]);
    expect(discoverShortcut, findsOneWidget);
    expect(artistChip('Saved artist'), findsOneWidget);
    final shelf = find.byKey(const ValueKey('music-discovery-songs'));
    await tester.ensureVisible(shelf);
    await tester.pumpAndSettle();
    expect(find.descendant(of: shelf, matching: find.text(artistSong.title)),
        findsOneWidget);
  });

  testWidgets('hidden discovery has a reveal and keeps its loaded selection',
      (tester) async {
    await tester.runAsync(installCommunityMusicFilters);
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([
      const MusicTrack(
          videoId: 'discover001',
          title: 'Discovered recording',
          uploaderChannelId: musicListedUploader),
    ]);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('music-discovery-discover001')),
        findsNothing);
    expect(discoverShortcut, findsNothing);
    expect(find.byKey(const ValueKey('music-discovery-empty')), findsNothing);
    final toggle = find.textContaining('Show hidden results');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-discovery-discover001')),
        findsOneWidget);
    final badge = find.text('AI');
    expect(badge, findsOneWidget);
    await tester.ensureVisible(badge);
    await tester.pumpAndSettle();
    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(find.text('Listed by Flow AI music'), findsOneWidget);
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets('discovery waits for Home visibility and retains its selection',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, active: false);
    expect(catalog.discoveryCalls, 0);
    await show(tester, settle: false);
    expect(catalog.discoveryCalls, 1);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    await show(tester, active: false);
    await show(tester);
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets(
      'backgrounded discovery cancels pending work and retains ready songs',
      (tester) async {
    final binding = tester.binding;
    final initialLifecycle = binding.lifecycleState;
    addTearDown(() => binding.handleAppLifecycleStateChanged(
        initialLifecycle ?? AppLifecycleState.resumed));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    catalog.holdDiscovery = true;
    await show(tester);
    expect(find.byType(MusicHomePage), findsOneWidget);
    expect(catalog.discoveryCalls, 0);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(catalog.discoveryCalls, 1);
    final current = catalog.discoveryGuards.single!;
    expect(current(), isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(current(), isFalse);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(current(), isFalse);
    await tester.pump();
    await tester.pump();
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.first.complete([
      const MusicTrack(videoId: 'stale000001', title: 'Stale recommendation')
    ]);
    catalog.discoveries.last.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Stale recommendation'), findsNothing);
    expect(find.text('Discovered recording'), findsOneWidget);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(catalog.discoveryCalls, 2);
    expect(find.text('Discovered recording'), findsOneWidget);
  });

  testWidgets('full audio player suspends discovery until Home is uncovered',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    final firstRequest = catalog.discoveries.single;
    final current = catalog.discoveryGuards.single!;
    expect(current(), isTrue);

    player.setAudioPlayer(minimized: false);
    await tester.pump();
    expect(current(), isFalse);
    firstRequest.complete([
      const MusicTrack(videoId: 'stale000001', title: 'Covered recommendation')
    ]);
    await tester.pumpAndSettle();
    expect(catalog.discoveryCalls, 1);
    expect(find.text('Covered recommendation'), findsNothing);

    player.setAudioPlayer(minimized: true);
    await tester.pump();
    await tester.pump();
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);

    player.setAudioPlayer(minimized: false);
    await tester.pumpAndSettle();
    player.setAudioPlayer(minimized: true);
    await tester.pumpAndSettle();
    expect(catalog.discoveryCalls, 2);
    expect(find.text('Discovered recording'), findsOneWidget);
  });

  testWidgets('discovery starts once a usable server session is available',
      (tester) async {
    final server = app.state.server;
    app.change(app.state.copyWith(server: null));
    catalog.holdDiscovery = true;
    await show(tester);
    expect(catalog.discoveryCalls, 0);

    app.change(
        app.state.copyWith(server: server, sessionRecoveryRequired: true));
    await tester.pumpAndSettle();
    expect(catalog.discoveryCalls, 0);

    app.change(app.state.copyWith(sessionRecoveryRequired: false));
    await tester.pump();
    await tester.pump();
    expect(catalog.discoveryCalls, 1);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);
  });

  testWidgets('hiding Home cancels an initial batch before more lookups',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    final original = catalog.discoveries.single;
    final current = catalog.discoveryGuards.single!;
    await show(tester, active: false);
    expect(current(), isFalse);
    original.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 1);
    await show(tester, settle: false);
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);
  });

  testWidgets('hiding Home during refresh preserves its earlier selection',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('music-discovery-refresh'));
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pump();
    final current = catalog.discoveryGuards.last!;
    await show(tester, active: false);
    expect(current(), isFalse);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    await show(tester);
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(catalog.discoveryCalls, 2);
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
  });

  for (final connection in ['HTTPS', 'onion', 'SOCKS']) {
    testWidgets('$connection discovery starts on entering Home',
        (tester) async {
      if (connection == 'onion') {
        app.change(app.state
            .copyWith(server: const Server(url: 'http://musicexample.onion')));
      } else if (connection == 'SOCKS') {
        await NetworkProxy.instance.initialize(
            saved: '{"enabled":true,"host":"127.0.0.1","port":9050}',
            configureNative: false);
      }
      catalog.holdDiscovery = true;
      await show(tester, settle: false);
      expect(catalog.discoveryCalls, 1);
      expect(find.byKey(const ValueKey('music-discovery-load')), findsNothing);
      expect(find.byKey(const ValueKey('music-discovery-loading')),
          findsOneWidget);
      catalog.discoveries.single.complete([_discovered]);
      await tester.pumpAndSettle();
      expect(find.text('Discovered recording'), findsOneWidget);
    });
  }

  testWidgets('failed refresh retains only the current selection with a notice',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('music-discovery-refresh'));
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pump();
    expect(tester.widget<IconButton>(refresh).onPressed, isNull);
    expect(find.text('Discovered recording'), findsOneWidget);
    catalog.discoveries.last
        .completeError(const MusicCatalogException('Unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(
        find.text(
            'Could not refresh. Showing the previously loaded selection.'),
        findsOneWidget);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
    expect(catalog.discoveryCalls, 2);
  });

  testWidgets('failed initial discovery has an explicit retry without looping',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single
        .completeError(const MusicCatalogException('Unavailable'));
    await tester.pumpAndSettle();
    await show(tester);
    expect(catalog.discoveryCalls, 1);
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
    expect(
        find.byKey(const ValueKey('music-discovery-failure')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-discovery-browse-offline')),
        findsNothing);
    final retry = find.byKey(const ValueKey('music-discovery-retry'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pump();
    catalog.discoveries.last.complete([_discovered]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-discovery-failure')), findsNothing);
    expect(catalog.discoveryCalls, 2);
  });

  testWidgets(
      'offline browsing returns to the failed Discovery scroll position',
      (tester) async {
    catalog.holdDiscovery = true;
    catalog.useGenreTracks = true;
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, settle: false);
    catalog.discoveries.single
        .completeError(const SocketException('Network is unreachable'));
    await tester.pumpAndSettle();

    final home = find.byType(MusicHomePage);
    final homeState = tester.state(home);
    final scroll = tester
        .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('music-home')))
        .controller!;
    final retry = find.byKey(const ValueKey('music-discovery-retry'));
    final browse = find.byKey(const ValueKey('music-discovery-browse-offline'));
    expect(retry, findsOneWidget);
    expect(browse, findsOneWidget);
    await tester.ensureVisible(browse);
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    await tester.tap(browse);
    await tester.pumpAndSettle();
    expect(find.text('Offline music'), findsOneWidget);
    expect(home, findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state(home), same(homeState));
    expect(scroll.offset, offset);
    expect(retry, findsOneWidget);
    expect(browse, findsOneWidget);
    expect(catalog.discoveryCalls, 1);
  });

  testWidgets('offline browsing retains the selected Discovery artist',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, [_discovered]);
    await finishDiscovery(tester, [artistSong]);
    await tester.pumpAndSettle();

    final artist = artistChip('Saved artist');
    await tester.ensureVisible(artist);
    await tester.tap(artist);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('music-discovery-refresh'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pump();
    catalog.discoveries.last.completeError(TimeoutException('Connection lost'));
    await tester.pumpAndSettle();

    final browse = find.byKey(const ValueKey('music-discovery-browse-offline'));
    await tester.ensureVisible(browse);
    await tester.tap(browse);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(artist).selected, isTrue);
    expect(find.text(artistSong.title), findsOneWidget);
    expect(catalog.discoveryArtists, [null, 'Saved artist', 'Saved artist']);
  });

  for (final transition in [
    'server',
    'account',
    'backend',
    'revision',
    'loading'
  ]) {
    testWidgets('discovery rejects late results after a $transition change',
        (tester) async {
      catalog.holdDiscovery = true;
      await show(tester, settle: false);
      final original = catalog.discoveries.single;
      final current = catalog.discoveryGuards.single!;
      app.change(switch (transition) {
        'server' => app.state
            .copyWith(server: const Server(url: 'https://other.example')),
        'account' => app.state.copyWith(
            server: app.state.server!.copyWith(id: 'another-account')),
        'backend' => app.state.copyWith(
            server: app.state.server!
                .copyWith(customHeaders: {'Cookie': 'backend=second'})),
        'loading' => app.state.copyWith(globalLoading: true),
        _ => app.state.copyWith(sessionRevision: 1),
      });
      expect(current(), isFalse);
      await tester.pump();
      original.complete([_discovered]);
      await tester.pump();
      expect(find.text('Discovered recording'), findsNothing);
      expect(catalog.discoveryCalls, transition == 'loading' ? 1 : 2);
      if (transition != 'loading') {
        expect(catalog.discoveryGuards.last!(), isTrue);
        catalog.discoveries.last.complete([]);
      }
      await tester.pumpAndSettle();
      expect(catalog.trendingCalls, 0);
    });
  }

  testWidgets('country changes discard stale songs and load the new region',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    final original = catalog.discoveries.single;
    await tester
        .runAsync(() => db.saveSetting(SettingsValue(browsingCountry, 'DE')));
    expect(catalog.discoveryGuards.single!(), isFalse);
    original.complete([_discovered]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
  });

  testWidgets('a proxy change clears discovery and refetches automatically',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    final original = catalog.discoveries.single;
    await tester.runAsync(
        () => NetworkProxy.instance.apply(SocksProxyConfig(enabled: true)));
    expect(catalog.discoveryGuards.single!(), isFalse);
    original.complete([_discovered]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-discovery-loading')), findsNothing);
  });

  testWidgets('returning after filter edits discards the previous selection',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final stale = tester.widget<MusicCatalogCard>(
        find.byKey(const ValueKey('music-discovery-discover001')));
    await show(tester, active: false);
    await tester.runAsync(() =>
        db.saveFilter(VideoFilter(value: 'Discovered')..hideFromFeed = true));
    stale.onOpen();
    expect(router.pushed, isNull);
    await show(tester, settle: false);
    expect(find.text('Discovered recording'), findsNothing);
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Discovered recording'), findsNothing);
  });

  testWidgets('profile changes clear cached discovery and stale card actions',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('music-discovery-discover001'));
    final stale = tester.widget<MusicCatalogCard>(card);
    await tester.ensureVisible(card);
    await tester.longPress(card);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    stale.onOpen();
    expect(router.pushed, isNull);
    await tester.pump();
    await tester.pump();
    expect(find.text('Discovered recording'), findsNothing);
    expect(find.byType(MusicSongSelectionBar), findsNothing);
    expect(catalog.discoveryCalls, 2);
    catalog.discoveries.last.complete([]);
    await tester.pumpAndSettle();
  });

  testWidgets('disposing Home revokes discovery before its response arrives',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    final current = catalog.discoveryGuards.single!;
    expect(current(), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(current(), isFalse);
    catalog.discoveries.single.complete([_discovered]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty Home keeps Search and Library available', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-home-search')));
    await tester.tap(find.byKey(const ValueKey('music-home-library')));
    expect(searches, 1);
    expect(libraryVisits, 1);
    await tester.tap(find.byKey(const ValueKey('music-home-saved-library')));
    expect(libraryVisits, 2);
  });

  testWidgets('Liked Songs opens only the active profile’s local collection',
      (tester) async {
    await tester.runAsync(() => library.setSongLiked(_saved, liked: true));
    await show(tester);
    final shortcut = find.byKey(const ValueKey('music-home-likedSongs'));
    final song =
        find.byKey(const ValueKey('music-automatic-track-savedmusic1'));
    final homeRequests = (catalog.discoveryCalls, catalog.chartRequests.length);

    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Liked songs'), findsOneWidget);
    expect(song, findsOneWidget);
    expect(libraryVisits, 0);
    expect(
        (catalog.discoveryCalls, catalog.chartRequests.length), homeRequests);
    expect(catalog.searchCalls, 0);

    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    await tester.pumpAndSettle();
    expect(song, findsNothing);
    expect(find.text('This source is no longer available.'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Liked songs'), findsOneWidget);
    expect(song, findsNothing);
    expect(find.text('No playable songs in this collection.'), findsOneWidget);
  });

  testWidgets(
      'saving the last prepared artist song removes its discovery choice',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, [_discovered]);
    await finishDiscovery(tester, [artistSong]);
    final choice = artistChip('Saved artist');
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('music-discovery-${artistSong.videoId}'));
    final previousCard = tester.widget<MusicCatalogCard>(card);

    await tester.runAsync(() => library.save(MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: artistSong.videoId,
        title: artistSong.title,
        subtitle: _saved.subtitle)));
    previousCard.onOpen();
    expect(router.pushed, isNull);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(choice, findsNothing);
    expect(find.byKey(ValueKey('music-discovery-${_discovered.videoId}')),
        findsOneWidget);
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
  });

  testWidgets('removing a saved artist retires its pending and prepared songs',
      (tester) async {
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, [_discovered]);
    await tester.runAsync(() => library.save(_saved));
    await tester.pump();
    await tester.pump();
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
    final pending = catalog.discoveries.last;
    final current = catalog.discoveryGuards.last!;
    await tester.runAsync(() => library.remove(_saved.kind, _saved.id));
    await tester.pump();
    expect(current(), isFalse);
    pending.complete([artistSong]);
    await tester.pumpAndSettle();
    expect(artistChip('Saved artist'), findsNothing);
    expect(find.text(artistSong.title), findsNothing);

    await tester.runAsync(() => library.save(_saved));
    await tester.pump();
    await tester.pump();
    expect(catalog.discoveryArtists, [null, 'Saved artist', 'Saved artist']);
    await finishDiscovery(tester, [artistSong]);
    await tester.ensureVisible(artistChip('Saved artist'));
    await tester.tap(artistChip('Saved artist'));
    await tester.pump();
    expect(find.text(artistSong.title), findsOneWidget);
    await tester.runAsync(() => library.remove(_saved.kind, _saved.id));
    await tester.pumpAndSettle();
    expect(artistChip('Saved artist'), findsNothing);
    expect(find.text(artistSong.title), findsNothing);
    expect(find.text(_discovered.title), findsOneWidget);
    expect(catalog.discoveryCalls, 3);
  });

  testWidgets('prepared artist songs and chip actions stay in their profile',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    catalog.holdDiscovery = true;
    await show(tester, settle: false);
    await finishDiscovery(tester, [_discovered]);
    await finishDiscovery(tester, [artistSong]);
    final stale = tester.widget<ChoiceChip>(artistChip('Saved artist'));
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    stale.onSelected!(true);
    await tester.pump();
    await tester.pump();
    expect(artistChip('Saved artist'), findsNothing);
    expect(find.text(artistSong.title), findsNothing);
    expect(discoverShortcut, findsNothing);
    expect(catalog.discoveryArtists, [null, 'Saved artist', null]);
    await finishDiscovery(tester, []);
    expect(discoverShortcut, findsNothing);
  });

  testWidgets('genre tiles appear in order after their songs are prepared',
      (tester) async {
    catalog.holdGenres = true;
    await show(tester);
    for (var index = 0; index < _genres.length; index++) {
      expect(catalog.genres, _genres.take(index + 1).toList());
      expect(find.byKey(ValueKey('music-explore-$index')), findsNothing);
      catalog.genreResponses.last.complete(_genreTracks(_genres[index]));
      await tester.pumpAndSettle();
      expect(find.text(_genreLabels[index]), findsOneWidget);
    }
    for (var index = 0; index < _genres.length; index++) {
      final genre = _genres[index];
      final tile = find.byKey(ValueKey('music-explore-$index'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text(_genreLabels[index]), findsOneWidget);
      expect(find.text('$genre recording 1'), findsOneWidget);
      expect(find.text('$genre recording 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('music-collection-load')), findsNothing);
      expect(catalog.genres, _genres);
      if (index == 0) {
        await tester.tap(find.byKey(const ValueKey('music-collection-play')));
        expect(player.plays.single.ids,
            _genreTracks(genre).map((s) => s.videoId).toList());
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tile, findsOneWidget);
    }
    expect(catalog.genres, _genres);
    expect(catalog.trendingCalls, 0);
    expect(catalog.searchCalls, 0);
  });

  testWidgets('failed and empty genres do not advertise unavailable songs',
      (tester) async {
    catalog.holdGenres = true;
    await show(tester);
    catalog.genreResponses.single.completeError(Exception('Unavailable'));
    await tester.pumpAndSettle();
    expect(catalog.genres, ['pop', 'jazz']);
    catalog.genreResponses.last.complete([]);
    await tester.pumpAndSettle();
    expect(catalog.genres, ['pop', 'jazz', 'classical']);
    catalog.genreResponses.last.complete([_genreTracks('classical').first]);
    await tester.pumpAndSettle();
    expect(find.text('Pop'), findsNothing);
    expect(find.text('Jazz'), findsNothing);
    expect(find.text('Classical'), findsOneWidget);
    expect(find.text('Electronic'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden Music cancels genre preparation and resumes on return',
      (tester) async {
    catalog.holdGenres = true;
    await show(tester, active: false);
    expect(catalog.genres, isEmpty);
    await show(tester);
    final current = catalog.genreGuards.single!;
    expect(current(), isTrue);
    await show(tester, active: false);
    expect(current(), isFalse);
    catalog.genreResponses.single.complete(_genreTracks('pop'));
    await tester.pumpAndSettle();
    expect(catalog.genres, ['pop']);
    await show(tester);
    expect(find.text('Pop'), findsNothing);
    expect(catalog.genres, ['pop', 'pop']);
    catalog.genreResponses.last.complete(_genreTracks('pop'));
    await tester.pumpAndSettle();
    expect(find.text('Pop'), findsOneWidget);
  });

  testWidgets('genre keeps verified tracks and stops fetching on rate limit',
      (tester) async {
    catalog.holdGenres = true;
    await show(tester);
    catalog.genreFailures.single!(InvidiousServiceError('Try later',
        statusCode: 429, retryAfter: const Duration(minutes: 2)));
    catalog.genreResponses.single.complete(_genreTracks('pop'));
    await tester.pumpAndSettle();
    expect(catalog.genres, ['pop']);
    expect(find.text('Jazz'), findsNothing);
    final pop = find.byKey(const ValueKey('music-explore-0'));
    await tester.ensureVisible(pop);
    await tester.tap(pop);
    await tester.pumpAndSettle();
    expect(find.text('pop recording 1'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(catalog.genres, ['pop']);
    expect(pop, findsOneWidget);
  });

  testWidgets('changing servers drops genre results from the old instance',
      (tester) async {
    catalog.holdGenres = true;
    await show(tester);
    final original = catalog.genreResponses.single;
    final current = catalog.genreGuards.single!;
    app.change(app.state
        .copyWith(server: const Server(url: 'https://second.example')));
    expect(current(), isFalse);
    original.complete(_genreTracks('pop'));
    await tester.pumpAndSettle();
    expect(catalog.genres, ['pop', 'pop']);
    expect(find.text('Pop'), findsNothing);
    const fresh =
        MusicTrack(videoId: 'newpopsong1', title: 'New instance recording');
    catalog.genreResponses.last.complete([fresh]);
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('music-explore-0'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text(fresh.title), findsOneWidget);
    expect(find.text('pop recording 1'), findsNothing);
  });

  testWidgets('saved songs refresh locally and open their identifiers',
      (tester) async {
    await show(tester);
    await tester.runAsync(() => library.save(_saved));
    await tester.pumpAndSettle();
    final savedRow = find.byKey(ValueKey('music-home-saved-${_saved.id}'));
    expect(savedRow, findsOneWidget);
    expect(find.byKey(const ValueKey('music-home-saved-empty')), findsNothing);
    await tester.ensureVisible(savedRow);
    await tester.tap(savedRow);
    expect((router.pushed!.args as MusicRouteArgs).videoId, _saved.id);
    await tester.runAsync(() => library.remove(_saved.kind, _saved.id));
    await tester.pumpAndSettle();
    expect(find.text('Saved recording'), findsNothing);
    expect(
        find.byKey(const ValueKey('music-home-saved-empty')), findsOneWidget);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('Speed dial opens the selected song and Random pick opens one',
      (tester) async {
    const second = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'secondmusic',
        title: 'Second recording');
    final shelf = find.byKey(const ValueKey('music-speed-dial'));
    final random = find.byKey(const ValueKey('music-random-pick'));
    final empty = find.text('No songs to pick from yet.');
    await show(tester);
    expect(shelf, findsNothing);
    expect(random, findsNothing);
    expect(empty, findsOneWidget);

    await tester.runAsync(() async {
      await library.save(_saved);
      await library.save(second);
    });
    await tester.pumpAndSettle();
    expect(empty, findsNothing);
    final card = find.byKey(ValueKey('music-speed-dial-${_saved.id}'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    expectSongQueue([second.id, _saved.id], 1);
    final launched = router.pushed!;
    final args = launched.args as MusicRouteArgs;
    expect(args.queueTitle, 'Speed dial');
    expect(args.cardOrigin, (
      surface: MusicCardSurface.speedDial,
      collectionId: null,
      entryId: _saved.id,
    ));

    Finder pauseIcon(Finder target) =>
        find.descendant(of: target, matching: find.byIcon(Icons.pause_rounded));
    final savedRow = find.byKey(ValueKey('music-home-saved-${_saved.id}'));
    player.setCardPlaying(args.cardOrigin!);
    await tester.pumpAndSettle();
    expect(pauseIcon(card), findsOneWidget);
    expect(pauseIcon(savedRow), findsNothing);

    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(pauseIcon(card), findsNothing);
    expect(player.cardToggles, 1);
    expect(router.pushed, same(launched));

    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(pauseIcon(card), findsOneWidget);
    expect(player.cardToggles, 2);
    expect(router.pushed, same(launched));

    await tester.ensureVisible(savedRow);
    await tester.tap(savedRow);
    expect((router.pushed!.args as MusicRouteArgs).cardOrigin, (
      surface: MusicCardSurface.savedSongs,
      collectionId: null,
      entryId: _saved.id,
    ));
    expect(player.cardToggles, 2);

    // Apply the filter before the button rebuilds to exercise tap admission.
    await tester.runAsync(
        () => db.saveFilter(VideoFilter(value: 'Second')..hideFromFeed = true));
    await tester.ensureVisible(random);
    await tester.tap(random);
    expectSongQueue([_saved.id], 0);
    final randomArgs = router.pushed!.args as MusicRouteArgs;
    expect(randomArgs.queueTitle, 'Random pick');
    expect(randomArgs.cardOrigin, isNull);
  });

  testWidgets('stale Home picks are ignored after a profile switch',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    final speedDial = tester.widget<MusicCatalogCard>(
        find.byKey(ValueKey('music-speed-dial-${_saved.id}')));
    final random = tester
        .widget<TextButton>(find.byKey(const ValueKey('music-random-pick')));

    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    speedDial.onOpen();
    random.onPressed!();
    expect(router.pushed, isNull);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-speed-dial')), findsNothing);
    expect(find.byKey(const ValueKey('music-random-pick')), findsNothing);
    expect(find.text('No songs to pick from yet.'), findsOneWidget);
  });

  testWidgets('saved song rows retain their existing library actions',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    final actions = find.descendant(
        of: find.byKey(ValueKey('music-home-saved-${_saved.id}')),
        matching: find.byTooltip('Music actions'));
    await tester.ensureVisible(actions);
    await tester.pumpAndSettle();
    await tester.tap(actions);
    await tester.pumpAndSettle();
    expect(find.text('Remove saved song'), findsOneWidget);
    expect(find.text('Save to playlist'), findsOneWidget);
    await tester.runAsync(() async {
      final removed = Completer<void>();
      void onChanged() {
        if (library.entries.isEmpty && !removed.isCompleted) removed.complete();
      }

      library.changes.addListener(onChanged);
      try {
        await tester.tap(find.text('Remove saved song'));
        await tester.pumpAndSettle();
        await removed.future.timeout(const Duration(seconds: 5));
      } finally {
        library.changes.removeListener(onChanged);
      }
    });
    await tester.pumpAndSettle();
    expect(library.entries, isEmpty);
    expect(find.text('Saved recording'), findsNothing);
    expect(
        find.byKey(const ValueKey('music-home-saved-empty')), findsOneWidget);
    expect(catalog.discoveryArtists, [null, 'Saved artist']);
  });

  testWidgets('Home removes only confirmed selected Saved Songs',
      (tester) async {
    await tester.runAsync(() async {
      for (var index = 1; index <= 3; index++) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'savedmusic$index',
            title: 'Saved track $index'));
      }
    });
    await show(tester);
    final first = find.byKey(const ValueKey('music-home-saved-savedmusic3'));
    final last = find.byKey(const ValueKey('music-home-saved-savedmusic1'));
    await tester.ensureVisible(first);
    await tester.longPress(first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(last);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    Future<void> openRemoval() async {
      final actions = find.byTooltip('Actions for selected songs');
      await tester.ensureVisible(actions);
      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Saved Songs'));
      await tester.pumpAndSettle();
      expect(
          find.text('Remove these 2 songs from Saved Songs?'), findsOneWidget);
    }

    await openRemoval();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(library.entries, hasLength(3));
    expect(find.text('2 selected'), findsOneWidget);
    await openRemoval();
    await tester.runAsync(() async {
      final removed = Completer<void>();
      void onChanged() {
        if (library.entries.length == 1 && !removed.isCompleted) {
          removed.complete();
        }
      }

      library.changes.addListener(onChanged);
      try {
        await tester
            .tap(find.widgetWithText(FilledButton, 'Remove from Saved Songs'));
        await tester.pumpAndSettle();
        await removed.future.timeout(const Duration(seconds: 5));
      } finally {
        library.changes.removeListener(onChanged);
      }
    });
    await tester.pumpAndSettle();
    expect(library.entries.map((entry) => entry.id), ['savedmusic2']);
    expect(find.byType(MusicSongSelectionBar), findsNothing);
    expect(router.pushed, isNull);
  });

  testWidgets('Home limits its preview while keeping the full library',
      (tester) async {
    await tester.runAsync(() async {
      for (var index = 0; index < 14; index++) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'saved$index',
            title: 'Song $index'));
      }
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.album, id: 'MPREold', title: 'Legacy album'));
    });
    await show(tester);
    final shelf = find.byKey(const ValueKey('music-home-saved'));
    await tester.ensureVisible(shelf);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song 12'));
    final preview = [for (var i = 13; i >= 2; i--) 'saved$i'];
    expectSongQueue(preview, 1);
    await playFromMenu(
        tester, find.byKey(const ValueKey('music-home-saved-saved12')));
    expectSongQueue(preview, 1);
    await tester.drag(shelf, const Offset(-1500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Song 2'), findsOneWidget);
    expect(find.text('Song 1'), findsNothing);
    expect(find.text('Song 0'), findsNothing);
    expect(library.entries.length, 15);
    expect(find.text('Legacy album'), findsNothing);
    await tester
        .ensureVisible(find.byKey(const ValueKey('music-home-saved-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-home-saved-library')));
    expect(libraryVisits, 1);
  });

  testWidgets('saved music and stale actions cannot cross profiles',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    final stale = tester.widget<InkWell>(find
        .descendant(
            of: find.byKey(ValueKey('music-home-saved-${_saved.id}')),
            matching: find.byType(InkWell))
        .first);
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.change(app.state.copyWith(profileId: next.id));
    stale.onTap!();
    expect(router.pushed, isNull);
    await tester.pumpAndSettle();
    expect(find.text('Saved recording'), findsNothing);
    expect(library.entries.single.id, _saved.id);
    final nextLibrary = MusicLibraryService.forProfile(db, next.id);
    await tester.runAsync(() => nextLibrary.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'second',
        title: 'Second profile song')));
    await tester.pumpAndSettle();
    expect(find.text('Second profile song'), findsOneWidget);
    expect(find.text('Saved recording'), findsNothing);
  });

  for (final transition in ['server', 'revision', 'loading', 'recovery']) {
    testWidgets('stale genre actions are ignored after $transition changes',
        (tester) async {
      catalog.useGenreTracks = true;
      await show(tester);
      final stale =
          tester.widget<InkWell>(find.byKey(const ValueKey('music-explore-0')));
      app.change(switch (transition) {
        'server' => app.state
            .copyWith(server: const Server(url: 'https://other.example')),
        'loading' => app.state.copyWith(globalLoading: true),
        'recovery' => app.state.copyWith(sessionRecoveryRequired: true),
        _ => app.state.copyWith(sessionRevision: 1),
      });
      stale.onTap!();
      expect(router.pushed, isNull);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('music-collection-play')), findsNothing);
    });
  }

  testWidgets('Home keeps its scroll position across rebuilds', (tester) async {
    catalog.useGenreTracks = true;
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester);
    final homeState = tester.state(find.byType(MusicHomePage));
    final scroll = tester
        .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('music-home')))
        .controller!;
    scroll.jumpTo(200);
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    await show(tester);
    expect(tester.state(find.byType(MusicHomePage)), same(homeState));
    expect(scroll.offset, offset);
    expect(catalog.trendingCalls, 0);
  });

  testWidgets('saved songs can be activated by keyboard remote',
      (tester) async {
    await tester.runAsync(() => library.save(_saved));
    await show(tester);
    final title = find.descendant(
        of: find.byKey(ValueKey('music-home-saved-${_saved.id}')),
        matching: find.text('Saved recording'));
    Focus.of(tester.element(title)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((router.pushed!.args as MusicRouteArgs).videoId, _saved.id);
  });

  testWidgets('Home fits 320px with large text and long saved titles',
      (tester) async {
    catalog.useGenreTracks = true;
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'longsong001',
        title: 'A recording with a very long title that needs multiple lines',
        subtitle: 'A channel with a similarly long display name')));
    await show(tester, textScale: 2.5);
    expect(find.byKey(const ValueKey('music-random-pick')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('music-explore-3')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('focusing a lower genre scrolls that tile fully into view',
      (tester) async {
    catalog.useGenreTracks = true;
    tester.view.physicalSize = const Size(320, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, textScale: 1.6);
    Focus.of(tester.element(find.text('Electronic'))).requestFocus();
    await tester.pumpAndSettle();
    final tile = tester.getRect(find.byKey(const ValueKey('music-explore-3')));
    expect(tile.top, greaterThanOrEqualTo(0));
    expect(tile.bottom, lessThanOrEqualTo(350));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Electronic'), findsOneWidget);
    expect(find.text('electronic recording 1').hitTestable(), findsOneWidget);
    expect(catalog.genres, _genres);
  });
}
