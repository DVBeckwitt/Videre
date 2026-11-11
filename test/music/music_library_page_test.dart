import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
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
  _Player() : super(PlayerState.init(null));

  @override
  Future<void> playOfflineVideos(List<DownloadedVideo> videos) async =>
      offline.addAll(videos);

  @override
  Future<void> playVideo(List<Video> videos,
          {bool? audio, Duration? startAt, bool? playing}) async =>
      online.addAll(videos);

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
      expect(find.text('Create new playlist'), findsOneWidget);
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
    await tester.tap(find.text('Create new playlist'));
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
      'downloads show only current-profile music audio and play completed files',
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
          videoId: 'videofile01', audioOnly: false, title: 'Video'),
      complete.copyWith(
          videoId: 'spokenword1', musicMetadata: null, title: 'Speech'),
    ]));
    await show(tester, downloads: downloads);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-download-abcdefghijk')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('music-download-queuedmusic')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('music-download-foreignsong')), findsNothing);
    expect(
        find.byKey(const ValueKey('music-download-videofile01')), findsNothing);
    expect(
        find.byKey(const ValueKey('music-download-spokenword1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('music-download-queuedmusic')));
    expect(player.offline, isEmpty);
    await tester.tap(find.byKey(const ValueKey('music-download-abcdefghijk')));
    await tester.pump();
    expect(player.offline, [complete]);
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
