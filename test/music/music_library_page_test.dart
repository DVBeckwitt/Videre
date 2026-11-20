import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}

  void profileChanged(String id) => emit(state.copyWith(profileId: id));
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads(super.initialState);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  final offline = <DownloadedVideo>[];
  final online = <Video>[];
  int? start;
  _Player() : super(PlayerState.init(null));

  @override
  Future<void> playOfflineVideos(List<DownloadedVideo> videos,
      {int startIndex = 0}) async {
    start = startIndex;
    offline.addAll(videos);
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio, Duration? startAt, bool? playing, int? startIndex}) async {
    start = startIndex;
    online.addAll(videos);
  }

  @override
  Future<void> playPlaylist(List<Video> entries,
          {required PlaylistReference reference,
          int startIndex = 0,
          Duration? startAt,
          bool? audio,
          bool? playing,
          PlaylistLoadSession? playlistLoader}) async =>
      online.addAll(entries);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _DetailsCatalog extends MusicCatalogService {
  _DetailsCatalog(this.responses);

  final Map<String, MusicLibraryEntry> responses;
  final requests = <String>[];
  Completer<void>? hold;
  bool cancelled = false;

  @override
  Future<void> loadSavedSongDetails(Iterable<String> ids,
      {required bool Function() isCurrent,
      required Future<void> Function(String id, MusicLibraryEntry? details)
          onResult}) async {
    for (final id in ids) {
      requests.add(id);
      await hold?.future;
      if (!isCurrent()) {
        cancelled = true;
        return;
      }
      await onResult(id, responses[id]);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = Video(
      videoId: 'abcdefghijk',
      title: 'Saved song',
      musicMetadata: MusicMetadata(title: 'Saved song', artist: 'Artist'));
  late _App app;
  late _Player player;
  late MusicLibraryService library;
  late Service previousService;
  late bool previousTv;

  setUp(() async {
    previousService = service;
    previousTv = app_globals.isTv;
    service = Service();
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(db, db.profileId);
    app = _App();
    player = _Player();
  });

  tearDown(() async {
    await player.close();
    await app.close();
    await db.close();
    service = previousService;
    app_globals.isTv = previousTv;
  });

  Future<void> show(WidgetTester tester,
      {Widget body = const MusicLibraryPage(), _Downloads? downloads}) async {
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          if (downloads != null)
            BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: body))));
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(bool Function() ready) => Future.doWhile(() async {
        if (ready()) return false;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 5));

  testWidgets(
      'the Music Library opens the on-device setup without launching a picker',
      (tester) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final nativeCalls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await show(tester);
    expect(nativeCalls, isEmpty);
    final device = find.byKey(const ValueKey('music-library-tab-onDevice'));
    await tester.ensureVisible(device);
    await tester.tap(device);
    await tester.pumpAndSettle();
    expect(find.text('Choose music folder'), findsOneWidget);
    expect(nativeCalls, ['getFolder', 'pendingRenames']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final cancel in [false, true]) {
    testWidgets(
        cancel
            ? 'cancelling song details leaves the imported bookmark intact'
            : 'explicit song details display a proxied video thumbnail in both library layouts',
        (tester) async {
      const missing = 'abcdefghijk';
      const unavailable = 'zzzzzzzzzzz';
      const artwork = '/vi/$missing/mqdefault.jpg';
      final original = musicCatalogService;
      final catalog = _DetailsCatalog({
        missing: MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: missing,
          title: 'Recovered recording',
          subtitle: 'Recovered uploader',
          thumbnails: [ImageObject(null, artwork, 320, 180)],
          usesVideoThumbnails: true,
        ),
      });
      musicCatalogService = catalog;
      addTearDown(() => musicCatalogService = original);
      await tester.runAsync(() => library.importSongs(const [
            MusicLibraryEntry(
                kind: MusicLibraryKind.song, id: missing, title: missing),
            MusicLibraryEntry(
                kind: MusicLibraryKind.song,
                id: unavailable,
                title: unavailable),
          ]));
      await show(tester);
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();
      expect(find.text(missing), findsOneWidget);
      expect(catalog.requests, isEmpty);

      await tester.tap(find.text('Load song details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('selected Invidious server'), findsOneWidget);
      expect(catalog.requests, isEmpty);

      if (cancel) {
        catalog.hold = Completer<void>();
        await tester.tap(find.text('Load details'));
        await tester.pump();
        expect(find.text('Checked 0 of 2 songs'), findsOneWidget);
        expect(catalog.requests, [missing]);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        catalog.hold!.complete();
        await tester.pumpAndSettle();
        expect(catalog.cancelled, isTrue);
        expect(catalog.requests, [missing]);
        expect(library.entries.first.title, missing);
      } else {
        await tester.runAsync(() async {
          await tester.tap(find.text('Load details'));
          await waitFor(
              () => library.entries.first.title == 'Recovered recording');
        });
        await tester.pumpAndSettle();
        expect(find.text('Updated 1 of 2 songs.'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.text('Recovered recording'), findsOneWidget);
        expect(find.text('Recovered uploader'), findsOneWidget);
        expect(find.text(unavailable), findsOneWidget);
        final row = find.byKey(const ValueKey('music-saved-song-$missing'));
        final idOnly =
            find.byKey(const ValueKey('music-saved-song-$unavailable'));
        final frame =
            find.descendant(of: row, matching: find.byType(Thumbnail));
        void expectProxiedFrame() {
          CommunityMusicArtwork communityArtwork(Finder row) =>
              tester.widget(find.descendant(
                  of: row, matching: find.byType(CommunityMusicArtwork)));
          expect(communityArtwork(row).allowLookup, isFalse);
          expect(communityArtwork(idOnly).allowLookup, isFalse);
          final thumbnail = tester.widget<Thumbnail>(frame);
          expect(thumbnail.images!.single.url, artwork);
          expect(thumbnail.useInvidiousProxy, isTrue);
          expect(find.descendant(of: idOnly, matching: find.byType(Thumbnail)),
              findsNothing);
        }

        expectProxiedFrame();
        await tester.tap(find.byKey(const ValueKey('music-library-layout')));
        await tester.pumpAndSettle();
        expectProxiedFrame();
        expect(library.entries.first.thumbnails.single.url, artwork);
        expect(library.coversBySongId, isEmpty);
        expect(catalog.requests, [missing, unavailable]);
        expect(
            library.entries.map((entry) => entry.id), [missing, unavailable]);
      }
    });
  }

  testWidgets(
      'library shows music playlists and explicitly created empty lists',
      (tester) async {
    await tester.runAsync(() async {
      final unrelated = await service.createPlayList('Video list', 'local');
      await service.addVideoToPlaylist(unrelated!, 'videoonly01',
          video: const Video(videoId: 'videoonly01', title: 'Video only'));
      await service.createPlayList('Unmarked empty list', 'local');
      await MusicLibrarySession(app).createPlaylist('Music list', [song]);
      await MusicLibrarySession(app).createPlaylist('Empty music list', []);
    });
    await show(tester);
    expect(find.text('Music list'), findsOneWidget);
    expect(find.text('Empty music list'), findsOneWidget);
    expect(find.text('Video list'), findsNothing);
    expect(find.text('Unmarked empty list'), findsNothing);
    expect(find.text('Watch Later'), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);

    await tester.tap(find.text('Music list'));
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsOneWidget);
    await tester.tap(find.text('Play all'));
    await tester.pump();
    expect(jsonDecode(jsonEncode(player.online.single)),
        jsonDecode(jsonEncode(song.copyWith(indexId: song.videoId))));
  });

  testWidgets('local playlist grid previews reject an external song image',
      (tester) async {
    const id = 'abcdefghijk';
    const external =
        'https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=$id';
    const poster = '/vi/$id/mqdefault.jpg';
    final keys = <bool, ValueKey<String>>{};
    await tester.runAsync(() async {
      for (final hasPoster in [true, false]) {
        final name = hasPoster ? 'With stock poster' : 'Without stock poster';
        await MusicLibrarySession(app).createPlaylist(name, [
          Video(
              videoId: id,
              title: 'Legacy recording',
              musicMetadata: MusicMetadata(
                  title: 'Legacy recording',
                  artist: 'Artist',
                  thumbnails: [ImageObject(null, external, 1280, 720)]),
              videoThumbnails: [
                if (hasPoster) ImageObject(null, poster, 320, 180),
              ]),
        ]);
        final playlist =
            service.getLocalPlaylists().singleWhere((p) => p.title == name);
        expect(playlist.videos.single.musicMetadata!.thumbnails.single.url,
            external);
        keys[hasPoster] = ValueKey('music-local-${playlist.playlistId}');
      }
    });
    await show(tester);
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();

    for (final hasPoster in [true, false]) {
      final card = find.byKey(keys[hasPoster]!);
      expect(card, findsOneWidget);
      final images =
          find.descendant(of: card, matching: find.byType(Thumbnail));
      if (hasPoster) {
        final image = tester.widget<Thumbnail>(images);
        expect(image.images!.single.url, poster);
        expect(image.useInvidiousProxy, isTrue);
      } else {
        expect(images, findsNothing);
        expect(
            find.descendant(
                of: card, matching: find.byIcon(Icons.queue_music_rounded)),
            findsOneWidget);
      }
      final wrappers = tester.widgetList<CommunityMusicArtwork>(find.descendant(
          of: card, matching: find.byType(CommunityMusicArtwork)));
      expect(wrappers.any((art) => art.allowLookup), isFalse);
    }
  });

  testWidgets(
      'local playlist rows and playback use the active profile’s saved covers',
      (tester) async {
    const staleId = 'aaaaaaaaaaa';
    const emptyId = 'bbbbbbbbbbb';
    const posterId = 'ccccccccccc';
    const cover = 'https://lh3.googleusercontent.com/saved-cover';
    const staleCover = 'https://lh3.googleusercontent.com/old-cover';
    const otherCover = 'https://lh3.googleusercontent.com/other-profile-cover';
    String frame(String id) => '/vi/$id/mqdefault.jpg';
    ImageObject image(String url) => ImageObject(null, url, 320, 320);
    Video track(String id, String title, {String? oldCover}) => Video(
        videoId: id,
        title: title,
        musicMetadata: MusicMetadata(
            title: title,
            artist: 'Artist',
            thumbnails: [if (oldCover != null) image(oldCover)]),
        videoThumbnails: [image(frame(id))]);
    final songs = [
      track(staleId, 'Older cover', oldCover: staleCover),
      track(emptyId, 'Missing cover'),
      track(posterId, 'Poster only'),
    ];

    await tester.runAsync(() async {
      await MusicLibrarySession(app).createPlaylist('Local recordings', songs);
      for (final video in songs.take(2)) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: video.videoId,
            title: video.title!,
            thumbnails: [image(cover)]));
      }
      await library.save(MusicLibraryEntry.song(songs.last));
      final other = await db.createProfile('Another listener');
      await MusicLibraryService.forProfile(db, other.id).save(MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: posterId,
          title: 'Other recording',
          thumbnails: [image(otherCover)]));
    });
    await show(tester);
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local recordings'));
    await tester.pumpAndSettle();

    for (final song in songs) {
      final row = find.widgetWithText(ListTile, song.title!);
      final thumbnail = tester.widget<Thumbnail>(
          find.descendant(of: row, matching: find.byType(Thumbnail)));
      final urls = thumbnail.images!.map((image) => image.url);
      expect(urls, [if (song.videoId != posterId) cover, frame(song.videoId)]);
      expect(thumbnail.useInvidiousProxy, isTrue);
    }
    await tester.tap(find.text('Play all'));
    await tester.pump();
    expect(player.online.map((song) => song.videoId),
        [staleId, emptyId, posterId]);
    for (final song in player.online) {
      expect(song.musicMetadata!.thumbnails.map((image) => image.url),
          [if (song.videoId != posterId) cover]);
      expect(song.videoThumbnails.single.url, frame(song.videoId));
    }
  });

  testWidgets(
      'songs remain explicit saves and refresh after removal and profile switch',
      (tester) async {
    await tester.runAsync(
        () => MusicLibrarySession(app).createPlaylist('Music list', [song]));
    await show(tester);
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsNothing);
    await tester.runAsync(() => library.save(MusicLibraryEntry.song(song)));
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsOneWidget);

    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    expect(find.text('Remove saved song'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove saved song'));
      await tester.pumpAndSettle();
      await waitFor(() => library.entries.isEmpty);
    });
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsNothing);

    await tester.runAsync(() => library.save(MusicLibraryEntry.song(song)));
    await tester.pumpAndSettle();
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsNothing);
    expect(library.entries.single.id, song.videoId);
  });

  testWidgets('title sorting is local and grid actions preserve saved songs',
      (tester) async {
    const first = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'firstsong01',
        title: 'Alpha song',
        subtitle: 'First artist');
    const last = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'lastsong001',
        title: 'Zulu song',
        subtitle: 'Last artist');
    await tester.runAsync(() async {
      await library.save(first);
      await library.save(last);
    });
    await show(tester);
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Zulu song')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha song')).dy));

    await tester.tap(find.byKey(const ValueKey('music-library-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Alpha song')).dy,
        lessThan(tester.getTopLeft(find.text('Zulu song')).dy));
    expect(library.entries.map((entry) => entry.id), [last.id, first.id]);

    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.text('Zulu song'));
    await tester.pump();
    expect(player.online.map((song) => song.videoId), [first.id, last.id]);
    expect(player.start, 1);
    expect(find.byTooltip('Music actions'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('music cards adapt to a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'longtitle01',
        title: 'A long recording title that wraps across the card',
        subtitle: 'A long artist and collaborator name')));
    await show(tester,
        body: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: MusicLibraryPage()));
    await tester.ensureVisible(find.text('Songs'));
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final kind in [MusicLibraryKind.song, MusicLibraryKind.playlist]) {
    testWidgets('large $kind libraries allocate rows only near the viewport',
        (tester) async {
      const count = 1000;
      await tester.runAsync(() => db.saveSetting(SettingsValue(
          musicLibrarySettingName,
          jsonEncode({
            'version': 1,
            'entries': [
              for (var index = 0; index < count; index++)
                MusicLibraryEntry(
                        kind: kind,
                        id: 'song${index.toString().padLeft(7, '0')}',
                        title: 'Saved entry $index')
                    .toJson(),
            ],
            'playlists': [],
          }))));
      await show(tester);
      if (kind == MusicLibraryKind.song) {
        await tester.tap(find.text('Songs'));
      } else {
        await tester.tap(find.text('Playlists'));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('music-library-layout')));
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(find.byType(ListView));
      final delegate = list.childrenDelegate;
      final eagerRows =
          delegate is SliverChildListDelegate ? delegate.children.length : 0;
      // Count allocated row widgets, including offscreen children retained by
      // a list delegate. Mounted elements alone hide eager construction.
      expect(eagerRows, lessThan(30),
          reason: 'Opening a library must not allocate all $count rows');
      expect(find.text('Saved entry 0'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Saved entry 999'), 800,
          scrollable: find.descendant(
              of: find.byType(ListView), matching: find.byType(Scrollable)),
          maxScrolls: 100);
      await tester.pumpAndSettle();
      expect(find.text('Saved entry 999'), findsOneWidget);
      if (kind == MusicLibraryKind.song) {
        await tester.tap(find.text('Saved entry 999'));
        await tester.pump();
        expect(player.online, hasLength(count));
        expect(player.start, count - 1);
        expect(player.online.last.videoId, 'song0000999');
      }
      expect(library.entries, hasLength(count));
      expect(tester.takeException(), isNull);
    });
  }

  for (final tv in [false, true]) {
    testWidgets(
        'local playlist Back only consumes the active Library (TV: $tv)',
        (tester) async {
      app_globals.isTv = tv;
      await tester.runAsync(
          () => MusicLibrarySession(app).createPlaylist('Music list', [song]));
      final active = ValueNotifier(true);
      await show(tester,
          body: ValueListenableBuilder<bool>(
              valueListenable: active,
              child: const MusicLibraryPage(),
              builder: (context, value, child) =>
                  TickerMode(enabled: value, child: child!)));
      await tester.tap(find.text('Music list'));
      await tester.pumpAndSettle();
      expect(find.text('Saved song'), findsOneWidget);
      final navigator =
          Navigator.of(tester.element(find.byType(MusicLibraryPage)));

      active.value = false;
      await tester.pumpAndSettle();
      expect(await navigator.maybePop(), isFalse);
      active.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Saved song'), findsOneWidget);

      expect(await navigator.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Saved song'), findsNothing);
      expect(find.text('Music list'), findsOneWidget);
      expect(find.byTooltip('Create new playlist'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      active.dispose();
    });
  }

  testWidgets('song and channel buttons preserve hidden legacy album bookmarks',
      (tester) async {
    const album = MusicLibraryEntry(
        kind: MusicLibraryKind.album, id: 'MPREalbum', title: 'Album');
    const channel = MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: 'UCchannel', title: 'Channel');
    await tester.runAsync(() => library.save(album));
    await show(tester,
        body: Column(children: [
          const MusicLibraryActions(videos: [song], compact: false),
          const MusicBookmarkButton(entry: channel),
          const MusicBookmarkButton(entry: album),
        ]));
    expect(find.text('Save album'), findsNothing);
    expect(find.text('Remove saved album'), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('Save song'));
      await waitFor(
          () => library.contains(MusicLibraryKind.song, song.videoId));
    });
    await tester.pumpAndSettle();
    expect(find.text('Remove saved song'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Save channel'));
      await waitFor(
          () => library.contains(MusicLibraryKind.artist, channel.id));
    });
    await tester.pumpAndSettle();
    expect(find.text('Remove saved channel'), findsOneWidget);
    expect(library.entries.map((entry) => entry.kind), [
      MusicLibraryKind.artist,
      MusicLibraryKind.song,
      MusicLibraryKind.album
    ]);
    expect(library.entries.last.toJson(), album.toJson());
  });

  testWidgets('empty Music playlist creation is visible immediately',
      (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Create new playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My music');
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await waitFor(() => service.getLocalPlaylists().any((playlist) =>
          playlist.title == 'My music' && library.isMusicPlaylist(playlist)));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('My music'), findsOneWidget);
  });

  testWidgets(
      'supported bookmarks can be removed while legacy albums stay stored',
      (tester) async {
    const album = MusicLibraryEntry(
        kind: MusicLibraryKind.album, id: 'MPREalbum', title: 'Saved album');
    const artist = MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: 'UCartist', title: 'Saved artist');
    const playlist = MusicLibraryEntry(
        kind: MusicLibraryKind.playlist,
        id: 'PLpublic',
        title: 'Public playlist');
    await tester.runAsync(() async {
      for (final entry in [album, artist, playlist]) {
        await library.save(entry);
      }
    });
    await show(tester);
    expect(find.text('Albums'), findsNothing);
    expect(find.text('Artists'), findsNothing);
    expect(find.text('Saved album'), findsNothing);
    for (final item in [
      (tab: 'Playlists', label: 'Remove saved playlist', entry: playlist),
      (tab: 'Channels', label: 'Remove saved channel', entry: artist),
    ]) {
      await tester.tap(find.text(item.tab));
      await tester.pumpAndSettle();
      expect(find.text(item.entry.title), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip(item.label));
        await waitFor(() => !library.contains(item.entry.kind, item.entry.id));
      });
      await tester.pumpAndSettle();
      expect(find.text(item.entry.title), findsNothing);
    }
    expect(library.entries.single.toJson(), album.toJson());
  });

  for (final tv in [false, true]) {
    testWidgets(
        'Music removes the selected song from a mixed local playlist (TV: $tv)',
        (tester) async {
      app_globals.isTv = tv;
      const otherSong = Video(
          videoId: 'secondsong2',
          musicMetadata:
              MusicMetadata(title: 'Second song', artist: 'Other channel'));
      const nonMusic = Video(videoId: 'videoonly01', title: 'Video only');
      await tester.runAsync(() async {
        await MusicLibrarySession(app)
            .createPlaylist('Mixed music list', [nonMusic, song, otherSong]);
        await library.save(MusicLibraryEntry.song(song));
      });
      final playlistId = service
          .getLocalPlaylists()
          .singleWhere((playlist) => playlist.title == 'Mixed music list')
          .playlistId;
      await show(tester);
      expect(find.text('Albums'), findsNothing);
      expect(find.text('Channels'), findsOneWidget);
      await tester.tap(find.text('Mixed music list'));
      await tester.pumpAndSettle();
      expect(find.text('Video only'), findsNothing);
      await tester.tap(find.byTooltip('Music actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Remove saved song'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Remove from playlist'));
        await tester.pumpAndSettle();
        await waitFor(() =>
            service
                .getLocalPlaylists()
                .singleWhere(
                  (playlist) => playlist.playlistId == playlistId,
                )
                .videos
                .length ==
            2);
      });
      await tester.pumpAndSettle();
      expect(find.text('Saved song'), findsNothing);
      expect(find.text('Second song'), findsOneWidget);
      final remaining = service.getLocalPlaylists().singleWhere(
            (playlist) => playlist.playlistId == playlistId,
          );
      expect(remaining.videos.map((video) => video.videoId),
          [nonMusic.videoId, otherSong.videoId]);
      expect(remaining.videos.last.musicMetadata?.toJson(),
          otherSong.musicMetadata?.toJson());
      expect(library.contains(MusicLibraryKind.song, song.videoId), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'the Downloads shortcut shows current-profile music and plays completed files',
      (tester) async {
    const complete = DownloadedVideo(
        videoId: 'abcdefghijk',
        title: 'Downloaded song',
        musicMetadata:
            MusicMetadata(title: 'Downloaded song', artist: 'Artist'),
        audioOnly: true,
        downloadComplete: true,
        lengthSeconds: 90,
        quality: 'audio');
    final downloads = _Downloads(DownloadManagerState(videos: [
      complete,
      complete.copyWith(
          videoId: 'queuedmusic',
          title: 'Queued',
          musicMetadata: const MusicMetadata(title: 'Queued', artist: 'Artist'),
          downloadComplete: false),
      complete.copyWith(
          videoId: 'foreignsong', profileId: 'another', title: 'Other person'),
      complete.copyWith(
          videoId: 'alreadyshared',
          musicFormat: MusicDownloadFormat.mp3,
          storageUri: 'content://documents/public-track'),
      complete.copyWith(
          videoId: 'legacyshared',
          storageUri: 'content://documents/legacy-track'),
      complete.copyWith(
          videoId: 'videofile01', audioOnly: false, title: 'Video'),
      complete.copyWith(
          videoId: 'spokenword1', musicMetadata: null, title: 'Speech'),
    ]));
    await show(tester, downloads: downloads);
    await tester
        .tap(find.byKey(const ValueKey('music-library-shortcut-downloads')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-download-abcdefghijk')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('music-download-queuedmusic')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('export-music-abcdefghijk')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('export-music-queuedmusic')), findsNothing);
    expect(
        find.byKey(const ValueKey('export-music-alreadyshared')), findsNothing);
    expect(find.byKey(const ValueKey('export-music-legacyshared')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('music-download-foreignsong')), findsNothing);
    expect(
        find.byKey(const ValueKey('music-download-videofile01')), findsNothing);
    expect(
        find.byKey(const ValueKey('music-download-spokenword1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('music-download-queuedmusic')));
    expect(player.offline, isEmpty);
    await tester
        .tap(find.byKey(const ValueKey('music-download-alreadyshared')));
    await tester.pump();
    expect(player.offline.map((song) => song.videoId),
        [complete.videoId, 'alreadyshared', 'legacyshared']);
    expect(player.start, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await downloads.close();
  });

  testWidgets(
      'TV library renders without a download manager and hides Downloads',
      (tester) async {
    app_globals.isTv = true;
    await show(tester);
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Albums'), findsNothing);
  });
}
