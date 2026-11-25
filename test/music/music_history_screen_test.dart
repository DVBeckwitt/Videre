import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/views/screens/music_history.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
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
  void onReady() {}

  @override
  void initState() {}

  void showProfile(String id) => emit(state.copyWith(
      profileId: id, sessionRevision: state.sessionRevision + 1));
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final queues = <List<String>>[];

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      PlaylistReference? recommendationSource,
      bool fromMusic = false,
      bool songTap = false}) async {
    expect(audio, isTrue);
    expect(fromMusic, isTrue);
    expect(queueTitle, 'Music history');
    queues.add(videos.map((video) => video.videoId).toList());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final query = find.byKey(const ValueKey('music-history-query'));
  final findButton = find.byKey(const ValueKey('music-history-find'));
  final selectButton = find.widgetWithIcon(IconButton, Icons.checklist_rounded);
  final delete = find.widgetWithText(TextButton, 'Delete');
  late _App app;
  late _Player player;
  late bool previousTv;

  setUp(() async {
    previousTv = app_globals.isTv;
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _Player();
  });

  tearDown(() async {
    app_globals.isTv = previousTv;
    await player.close();
    await app.close();
    await db.close();
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MusicHistoryScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> seed(IDbClient owner, String id, String title,
      {String artist = 'Artist', String? album, int order = 0}) {
    final history = HistoryVideoCache(id, title, artist, '',
        musicMetadata:
            MusicMetadata(title: title, artist: artist, album: album))
      ..created = DateTime.utc(2025, 1, 1, 0, order);
    return owner.beginMusicListening(id)!.record(history);
  }

  Iterable<String> trackIds(IDbClient owner) => owner
      .getPlaybackHistory(PlaybackHistoryOrigin.music)
      .map((entry) => entry.videoId);

  Future<void> openSelectionAction(WidgetTester tester, String action) async {
    await tester.tap(find.byTooltip('Actions for selected songs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  testWidgets('an import picker stays bound to its original profile',
      (tester) async {
    const files = MethodChannel('videre/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final selection = Completer<String?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(files, (call) {
      calls.add(call.method);
      return selection.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(files, null));

    final original = MusicListeningHistory.forProfile(db, db.profileId);
    final other = await tester.runAsync(() => db.createProfile('Other'));
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-history-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import or export history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import listening history'));
    await tester.pumpAndSettle();
    expect(calls, ['open']);

    await tester.runAsync(() => db.useProfile(other!.id));
    app.showProfile(other!.id);
    selection.complete('invalid file from the old profile');
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(original.events(), isEmpty);
    expect(
        MusicListeningHistory.forProfile(db, db.profileId).events(), isEmpty);
  });

  testWidgets('Find scopes ordered play, shuffle and removal to all matches',
      (tester) async {
    await tester.runAsync(() async {
      await seed(db, 'matchedOld', 'Café nocturne',
          artist: 'Lumière Quartet', album: 'Été');
      await seed(db, 'matchedOld', 'Café nocturne',
          artist: 'Lumière Quartet', album: 'Été', order: 1);
      await seed(db, 'matchedNew', 'Café nocturne',
          artist: 'Lumière Trio', album: 'Été', order: 2);
      await seed(db, 'otherAlbum', 'Café nocturne',
          artist: 'Lumière Trio', album: 'Hiver', order: 3);
      for (var i = 0; i < 22; i++) {
        await seed(db, 'filler$i', 'A newer song $i', order: 4 + i);
      }
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.video,
          HistoryVideoCache('matchedNew', 'Same ID in Video', 'Uploader', ''));
    });
    final history = MusicListeningHistory.forProfile(db, db.profileId);
    expect(history.events(trackId: 'matchedOld'), hasLength(2));
    await show(tester);
    expect(find.text('Café nocturne'), findsNothing);

    await tester.tap(findButton);
    await tester.pumpAndSettle();
    await tester.enterText(query, '  cafe LUMIERE ete  ');
    await tester.pumpAndSettle();
    expect(find.text('Café nocturne'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('otherAlbum')), findsNothing);

    await tester.tap(find.byTooltip('Play all'));
    await tester.pumpAndSettle();
    await tester.tap(selectButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await openSelectionAction(tester, 'Play');
    await openSelectionAction(tester, 'Shuffle');
    expect(player.queues, hasLength(3));
    expect(player.queues[0], ['matchedNew', 'matchedOld']);
    expect(player.queues[1], ['matchedNew', 'matchedOld']);
    expect(player.queues[2], unorderedEquals(['matchedNew', 'matchedOld']));

    await openSelectionAction(tester, 'Remove from Music history');
    expect(find.text('Remove all plays of these 2 songs from Music history?'),
        findsOneWidget);
    await tester.tap(delete);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(find.text('No results found.'), findsOneWidget);
    expect(history.events(trackId: 'matchedOld'), isEmpty);
    expect(history.events(trackId: 'matchedNew'), isEmpty);
    expect(
        trackIds(db),
        unorderedEquals([
          'otherAlbum',
          for (var i = 0; i < 22; i++) 'filler$i',
        ]));
    expect(db.getPlaybackHistory(PlaybackHistoryOrigin.video).single.title,
        'Same ID in Video');
  });

  testWidgets('confirming after a profile switch leaves both histories intact',
      (tester) async {
    final original = db.forProfile(db.profileId);
    final other = (await tester.runAsync(() async {
      await seed(original, 'sharedSong', 'Original profile song');
      final profile = await db.createProfile('Other');
      await seed(db.forProfile(profile.id), 'sharedSong', 'Other profile song');
      return profile;
    }))!;
    await show(tester);
    await tester.longPress(find.text('Original profile song'));
    await tester.pumpAndSettle();
    await openSelectionAction(tester, 'Remove from Music history');
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.runAsync(() => db.useProfile(other.id));
    app.showProfile(other.id);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();

    expect(trackIds(original), ['sharedSong']);
    expect(trackIds(db), ['sharedSong']);
    expect(find.text('Original profile song'), findsNothing);
    expect(find.text('Other profile song'), findsNothing);
  });

  testWidgets('TV Select opens Find and Back returns focus after selection',
      (tester) async {
    app_globals.isTv = true;
    await tester.runAsync(() => seed(db, 'tvSong', 'TV song'));
    await show(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).focusNode!.hasFocus, isTrue);
    await tester.enterText(query, 'song');
    await tester.pumpAndSettle();
    tester.widget<IconButton>(selectButton).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, 'song');
    expect(tester.widget<IconButton>(selectButton).focusNode!.hasFocus, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(tester.widget<IconButton>(findButton).focusNode!.hasFocus, isTrue);
  });
}
