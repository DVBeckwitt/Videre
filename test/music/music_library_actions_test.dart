import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
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

  Future<void> show(WidgetTester tester, {bool compact = false}) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MusicLibraryActions(
              videos: const [first, second], compact: compact),
        ),
      ),
    ));
  }

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
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.getLocalPlaylists().first.videos, isEmpty);
  });
}
