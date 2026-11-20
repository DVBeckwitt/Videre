import 'dart:async';

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
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
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
  final responses = <Completer<List<MusicTrack>>>[];
  // Create this in the requesting widget's async zone, not setUp's outer zone.
  late var song = Completer<MusicTrack>();
  VideoLoadObserver? songObserver;
  final songRequests = <String>[];
  final artistRequests = <String>[];
  final releaseRequests = <String?>[];
  final releasePages = <String?, MusicArtistReleases>{};
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
  Future<List<MusicTrack>> getTrendingSongs() async => [first, second];

  @override
  Future<MusicCollection> getPlaylist(String id) {
    playlistRequests.add(id);
    return pendingPlaylist?.future ?? Future.value(collection);
  }

  @override
  Future<List<MusicArtist>> searchArtists(String query) async => [artist];

  @override
  Future<List<MusicPlaylist>> searchPlaylists(String query) async => [
        const MusicPlaylist(
            id: 'PLpublic', title: 'Public playlist', author: 'Curator'),
      ];

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
    return releasePages[continuation] ?? const MusicArtistReleases();
  }

  @override
  Future<MusicTrack> getSong(String id, {VideoLoadObserver? loadObserver}) {
    songRequests.add(id);
    songObserver = loadObserver;
    return song.future;
  }
}

class _Player extends TestPlayerCubit {
  final calls = <({
    List<Video> videos,
    bool? audio,
    Duration? startAt,
    int? startIndex
  })>[];

  _Player(super.initialState, super.settings);

  int resumes = 0;
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
  Future<void> resumeSession() async {
    resumes++;
  }

  @override
  void showBigPlayer() {
    shows++;
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio, Duration? startAt, bool? playing, int? startIndex}) async {
    _selectionRevision++;
    calls.add((
      videos: videos,
      audio: audio,
      startAt: startAt,
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
      PlaylistLoadSession? playlistLoader}) async {
    calls.add((
      videos: entries,
      audio: audio,
      startAt: startAt,
      startIndex: startIndex
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    await tester.tap(find.text('Watch Later'));
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
            queue: [first.toVideo(), second.toVideo(), first.toVideo()],
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

  testWidgets('saved tracks play without a catalog lookup', (tester) async {
    await show(tester, screen: Builder(builder: (context) {
      return TextButton(
          onPressed: () => MusicScreen.playTracks(context, [first.toVideo()]),
          child: const Text('Play saved track'));
    }));
    await tester.tap(find.text('Play saved track'));
    await tester.pumpAndSettle();
    expect(player.calls.single.videos.single.musicMetadata?.album, 'Album');
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
    var accessible = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const audioSession = MethodChannel('com.ryanheise.audio_session');
    messenger.setMockMethodCallHandler(audioSession, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return {'uri': tree, 'name': 'Music', 'selectionId': 'current'};
        case 'checkFolderAccess':
          return accessible;
        case 'listTracks':
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
    await tester.runAsync(() => tester.pump());
    await tester.pump(const Duration(milliseconds: 400));
    expect(scans, hasLength(1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.runAsync(() async {
      scans.first.complete([]);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(scans, hasLength(2));
    expect(find.text('Retry'), findsNothing);
    await tester.runAsync(() async {
      scans.last.completeError(PlatformException(code: 'FOLDER_UNAVAILABLE'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    accessible = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
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
