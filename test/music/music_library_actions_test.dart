import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/playlists/models/playlist.dart';
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

class _PausedLibrary extends Service {
  final firstSaved = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> addVideoToPlaylist(String playlistId, String videoId,
      {Video? video}) async {
    await super.addVideoToPlaylist(playlistId, videoId, video: video);
    if (!firstSaved.isCompleted) {
      firstSaved.complete();
      await release.future;
    }
  }
}

class _Downloads implements DownloadManagerCubit {
  final calls = <({String id, bool audioOnly, Video? video})>[];

  @override
  Stream<DownloadManagerState> get stream => const Stream.empty();

  @override
  Future<bool> addDownload(String videoId,
      {String quality = '720p', bool audioOnly = false, Video? video}) async {
    calls.add((id: videoId, audioOnly: audioOnly, video: video));
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = Video(
      videoId: 'firstsong01',
      title: 'First song',
      musicMetadata:
          MusicMetadata(title: 'First song', artist: 'Artist', album: 'Album'));
  const second = Video(
      videoId: 'secondsong2',
      title: 'Second song',
      musicMetadata: MusicMetadata(
          title: 'Second song', artist: 'Artist', album: 'Album'));
  late Service previousService;
  late bool previousTv;
  late _App app;

  setUp(() async {
    previousService = service;
    previousTv = app_globals.isTv;
    app_globals.isTv = false;
    service = Service();
    db = await SembastSqfDb.createInMemory();
    app = _App();
  });

  tearDown(() async {
    await app.close();
    await db.close();
    service = previousService;
    app_globals.isTv = previousTv;
  });

  test('collection save preserves order, metadata and deduplicates all songs',
      () async {
    await service.addVideoToPlaylist(localWatchLaterId, first.videoId,
        video: first);
    await MusicLibrarySession(app)
        .saveToPlaylist(localWatchLaterId, [first, second, first]);
    final saved = service.getLocalPlaylists().first.videos;
    expect(
        saved.map((video) => video.videoId), [first.videoId, second.videoId]);
    expect(saved.map((video) => video.musicMetadata?.toJson()),
        [first.musicMetadata!.toJson(), second.musicMetadata!.toJson()]);
  });

  test('creating a local playlist saves the complete collection', () async {
    await MusicLibrarySession(app).createPlaylist('Album', [first, second]);
    final created = service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.title == 'Album');
    expect(created.isLocal, isTrue);
    expect(created.videos.map((video) => video.videoId),
        [first.videoId, second.videoId]);
  });

  test('playlist removal rejects remote destinations and stale profiles',
      () async {
    await MusicLibrarySession(app).createPlaylist('Music', [first, second]);
    final originalProfile = db.profileId;
    final playlistId = service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.title == 'Music')
        .playlistId;
    final session = MusicLibrarySession(app);
    await expectLater(session.removeFromPlaylist('PLpublic', first.videoId),
        throwsArgumentError);
    final next = await db.createProfile('Another person');
    await db.useProfile(next.id);
    app.profileChanged(next.id);
    await expectLater(session.removeFromPlaylist(playlistId, first.videoId),
        throwsStateError);
    expect(service.getLocalPlaylists().single.videos, isEmpty);
    expect(
        service
            .getLocalPlaylists(database: db.forProfile(originalProfile))
            .singleWhere((playlist) => playlist.playlistId == playlistId)
            .videos
            .map((video) => video.videoId),
        [first.videoId, second.videoId]);
  });

  test(
      'collection downloads retain track order and metadata as unique audio jobs',
      () async {
    final downloads = _Downloads();
    final count = await MusicLibrarySession(app)
        .download(downloads, [first, second, first]);
    expect(count, 2);
    expect(downloads.calls.map((call) => call.id),
        [first.videoId, second.videoId]);
    expect(downloads.calls.every((call) => call.audioOnly), isTrue);
    expect(downloads.calls.map((call) => call.video), [first, second]);
  });

  test('profile switch stops a collection save before touching another library',
      () async {
    final originalProfile = db.profileId;
    final paused = _PausedLibrary();
    service = paused;
    final saving = MusicLibrarySession(app)
        .saveToPlaylist(localWatchLaterId, [first, second]);
    final failed = expectLater(saving, throwsStateError);
    await paused.firstSaved.future;
    final next = await db.createProfile('Another person');
    await db.useProfile(next.id);
    app.profileChanged(next.id);
    paused.release.complete();
    await failed;
    expect(service.getLocalPlaylists().first.videos, isEmpty);
    expect(
        service
            .getLocalPlaylists(database: db.forProfile(originalProfile))
            .first
            .videos
            .map((video) => video.videoId),
        [first.videoId]);
  });

  Future<void> show(WidgetTester tester,
      {bool compact = false, Widget? body}) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: body ??
              MusicLibraryActions(
                  videos: const [first, second], compact: compact),
        ),
      ),
    ));
  }

  testWidgets('mounted song actions update after another control saves it',
      (tester) async {
    final library = MusicLibraryService.forProfile(db, db.profileId);
    await show(tester,
        body: const Column(children: [
          MusicLibraryActions(videos: [first], compact: false),
          MusicLibraryActions(videos: [first], compact: false),
        ]));
    expect(find.text('Save song'), findsNWidgets(2));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save song').first);
      await Future.doWhile(() async {
        await tester.pump();
        if (library.contains(MusicLibraryKind.song, first.videoId)) {
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(find.text('Save song'), findsNothing);
    expect(find.text('Remove saved song'), findsNWidgets(2));
  });

  for (final initiallySaved in [false, true]) {
    testWidgets(
        'open song menu preserves its displayed action when saved state changes '
        '(initially saved: $initiallySaved)', (tester) async {
      final library = MusicLibraryService.forProfile(db, db.profileId);
      final entry = MusicLibraryEntry.song(first);
      if (initiallySaved) {
        await tester.runAsync(() => library.save(entry));
      }
      await show(tester, body: const MusicLibraryActions(videos: [first]));
      await tester.tap(find.byTooltip('Music actions'));
      await tester.pumpAndSettle();
      final action = initiallySaved ? 'Remove saved song' : 'Save song';
      expect(find.text(action), findsOneWidget);

      // Another screen can change the same bookmark while this menu is open.
      await tester.runAsync(() => initiallySaved
          ? library.remove(entry.kind, entry.id)
          : library.save(entry));
      await tester.pumpAndSettle();
      expect(find.text(action), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await tester.pump();
          final button = tester.widget<PopupMenuButton<dynamic>>(
              find.byWidgetPredicate((widget) => widget is PopupMenuButton));
          return !button.enabled;
        }).timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      expect(library.contains(entry.kind, entry.id), !initiallySaved);
    });
  }

  for (final action in ['Save song', 'Save to playlist', 'Download audio']) {
    testWidgets('open $action menu keeps the track it was opened for',
        (tester) async {
      final videos = ValueNotifier<List<Video>>([first]);
      addTearDown(videos.dispose);
      final downloads = _Downloads();
      final library = MusicLibraryService.forProfile(db, db.profileId);
      await show(tester,
          body: BlocProvider<DownloadManagerCubit>.value(
            value: downloads,
            child: ValueListenableBuilder<List<Video>>(
              valueListenable: videos,
              builder: (context, value, _) =>
                  MusicLibraryActions(videos: value),
            ),
          ));
      await tester.tap(find.byTooltip('Music actions'));
      await tester.pumpAndSettle();

      // A media notification or incoming link can change the player track.
      videos.value = [second];
      await tester.pumpAndSettle();
      expect(find.text(action), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        if (action == 'Save to playlist') {
          expect(find.text('Watch Later'), findsOneWidget);
          await tester.tap(find.text('Watch Later'));
        }
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await tester.pump();
          final button = tester.widget<PopupMenuButton<dynamic>>(
              find.byWidgetPredicate((widget) => widget is PopupMenuButton));
          return !button.enabled;
        }).timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();

      if (action == 'Save song') {
        expect(library.entries.map((entry) => entry.id), [first.videoId]);
      } else if (action == 'Save to playlist') {
        expect(
            service
                .getLocalPlaylists()
                .first
                .videos
                .map((video) => video.videoId),
            [first.videoId]);
      } else {
        expect(downloads.calls.map((call) => call.id), [first.videoId]);
      }
    });
  }

  testWidgets('open remove menu keeps its original local playlist and song',
      (tester) async {
    await tester.runAsync(() async {
      final session = MusicLibrarySession(app);
      await session.createPlaylist('First list', [first, second]);
      await session.createPlaylist('Second list', [first, second]);
    });
    final playlists = service.getLocalPlaylists();
    final firstId = playlists
        .singleWhere((playlist) => playlist.title == 'First list')
        .playlistId;
    final secondId = playlists
        .singleWhere((playlist) => playlist.title == 'Second list')
        .playlistId;
    final target = ValueNotifier((playlistId: firstId, video: first));
    addTearDown(target.dispose);
    await show(tester,
        body: ValueListenableBuilder<({String playlistId, Video video})>(
            valueListenable: target,
            builder: (context, value, _) => MusicLibraryActions(
                videos: [value.video], localPlaylistId: value.playlistId)));
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    target.value = (playlistId: secondId, video: second);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return service
                .getLocalPlaylists()
                .singleWhere(
                  (playlist) => playlist.playlistId == firstId,
                )
                .videos
                .length !=
            1;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    final remaining = service.getLocalPlaylists();
    expect(
        remaining
            .singleWhere((playlist) => playlist.playlistId == firstId)
            .videos
            .map((video) => video.videoId),
        [second.videoId]);
    expect(
        remaining
            .singleWhere((playlist) => playlist.playlistId == secondId)
            .videos
            .map((video) => video.videoId),
        [first.videoId, second.videoId]);
  });

  testWidgets(
      'collection destination stays enabled when only its first song is saved',
      (tester) async {
    await tester.runAsync(() => service
        .addVideoToPlaylist(localWatchLaterId, first.videoId, video: first));
    await show(tester);
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Watch Later'));
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return service.getLocalPlaylists().first.videos.length != 2;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(
        service.getLocalPlaylists().first.videos.map((video) => video.videoId),
        [first.videoId, second.videoId]);
  });

  testWidgets('profile switch dismisses owned save and create controls',
      (tester) async {
    await show(tester);
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create new playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Old profile album');
    final next =
        (await tester.runAsync(() => db.createProfile('Another person')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.getLocalPlaylists(), hasLength(1));
    expect(service.getLocalPlaylists().first.videos, isEmpty);
  });

  testWidgets(
      'TV hides audio downloads and does not require a download manager',
      (tester) async {
    app_globals.isTv = true;
    await show(tester);
    expect(find.text('Download audio'), findsNothing);
    final context = tester.element(find.byType(MusicLibraryActions));
    expect(await MusicLibraryActions.download(context, [first]), 0);
  });

  testWidgets(
      'a menu opened before a profile switch cannot save into the new profile',
      (tester) async {
    await show(tester, compact: true);
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    final next =
        (await tester.runAsync(() => db.createProfile('Another person')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(find.text('Save to playlist'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.getLocalPlaylists().first.videos, isEmpty);
  });
}
