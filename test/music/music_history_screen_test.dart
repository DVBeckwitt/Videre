import 'dart:async';
import 'dart:convert';

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
  final chronologicalQueues = <({List<String> ids, int? startIndex})>[];

  @override
  Future<void> playMusicCollectionQueue(List<Video> tracks,
      {required String queueTitle,
      bool shuffle = false,
      bool songTap = false,
      bool collectionDetail = false,
      List<PlaylistReference?>? recommendationSources,
      bool Function()? isCurrent,
      int? startIndex}) async {
    expect(queueTitle, 'Music history');
    expect(shuffle, isFalse);
    chronologicalQueues.add((
      ids: tracks.map((track) => track.videoId).toList(),
      startIndex: startIndex,
    ));
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
      {String artist = 'Artist',
      String? album,
      int order = 0,
      DateTime? playedAt}) {
    final history = HistoryVideoCache(id, title, artist, '',
        musicMetadata:
            MusicMetadata(title: title, artist: artist, album: album))
      ..created = (playedAt ?? DateTime.utc(2025, 1, 1, 0, order)).toUtc();
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

  testWidgets(
      'Spotify import previews, adds only new matches and hides stale rows',
      (tester) async {
    const files = MethodChannel('videre/files');
    const device = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final rows = jsonEncode([
      for (final title in ['Known song', 'Two releases', 'Missing song'])
        {
          'ts': '2025-01-01T01:15:00-06:00',
          'master_metadata_track_name': title,
          'master_metadata_album_artist_name': 'Artist',
          'ms_played': 24000,
        },
    ]);
    messenger.setMockMethodCallHandler(files, (call) async {
      expect(call.method, 'open');
      return rows;
    });
    messenger.setMockMethodCallHandler(device, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(files, null);
      messenger.setMockMethodCallHandler(device, null);
    });

    final original = MusicListeningHistory.forProfile(db, db.profileId);
    await tester.runAsync(() async {
      await seed(db, 'knownSong01', 'Known song');
      await seed(db, 'release0001', 'Two releases', album: 'One');
      await seed(db, 'release0002', 'Two releases', album: 'Two');
    });
    final other = (await tester.runAsync(() => db.createProfile('Other')))!;
    await show(tester);

    Future<void> pumpUntil(Finder finder) async {
      final timer = Stopwatch()..start();
      while (finder.evaluate().isEmpty &&
          timer.elapsed < const Duration(seconds: 8)) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      expect(finder, findsWidgets);
    }

    Future<void> openSpotifyPreview() async {
      await tester.tap(find.byKey(const ValueKey('music-history-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import or export history'));
      await tester.pumpAndSettle();
      await tester
          .runAsync(() => tester.tap(find.text('Import Spotify history')));
      await pumpUntil(find.text('All rows (3)'));
      await tester.pumpAndSettle();
    }

    await openSpotifyPreview();
    expect(find.text('Import 1 match'), findsOneWidget);
    expect(find.text('2025-01-01 07:15:00.000Z'), findsWidgets);
    expect(original.events(), hasLength(3));

    final filter = find.byWidgetPredicate((widget) => widget is DropdownButton);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ambiguous (1)').last);
    await tester.pumpAndSettle();
    expect(find.text('2 Videre tracks'), findsOneWidget);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unmatched (1)').last);
    await tester.pumpAndSettle();
    expect(find.text('Missing song'), findsOneWidget);

    await tester.runAsync(() => tester.tap(find.text('Import 1 match')));
    await pumpUntil(find.text('1 listening record added.'));
    await tester.pumpAndSettle();
    expect(original.events(trackId: 'knownSong01').first.playedAt,
        DateTime.utc(2025, 1, 1, 7, 15));
    expect(original.events(), hasLength(4));
    await openSpotifyPreview();
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Import 1 match'), findsNothing);

    await tester.runAsync(() => db.useProfile(other.id));
    app.showProfile(other.id);
    await tester.pumpAndSettle();
    expect(find.text('This source is no longer available.'), findsOneWidget);
    expect(find.text('2025-01-01 07:15:00.000Z'), findsNothing);
    expect(original.events(), hasLength(4));
    expect(db.getMusicListeningEvents(), isEmpty);
  });

  testWidgets('offers play counts for the active profile and handles cancel',
      (tester) async {
    const files = MethodChannel('videre/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final picker = Completer<MethodCall>();
    final result = Completer<bool?>();
    messenger.setMockMethodCallHandler(files, (call) {
      picker.complete(call);
      return result.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(files, null));

    await tester.runAsync(() async {
      await seed(db, 'outside', 'Other profile song');
      final profile = await db.createProfile('Listener');
      await db.useProfile(profile.id);
      app.showProfile(profile.id);
      await seed(db, 'inside', 'Active profile song');
      await seed(db, 'inside', 'Active profile song', order: 1);
    });
    await show(tester);

    await tester.tap(find.byKey(const ValueKey('music-history-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import or export history'));
    await tester.pumpAndSettle();
    expect(find.text('Export listening history'), findsOneWidget);
    expect(picker.isCompleted, isFalse);
    await tester.tap(find.text('Export play counts (CSV)'));

    // Let the encoder finish in its isolate and pump the result back to the UI.
    final wait = Stopwatch()..start();
    while (!picker.isCompleted && wait.elapsed < const Duration(seconds: 5)) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(picker.isCompleted, isTrue);
    final call = await picker.future;
    expect(call.method, 'save');
    expect(call.arguments, {
      'name': matches(r'^videre-music-play-counts-\d{4}-\d{2}-\d{2}\.csv$'),
      'text': 'trackId,title,artist,playCount\r\n'
          'inside,Active profile song,Artist,2\r\n',
      'mimeType': 'text/csv',
    });

    result.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Active profile song'), findsOneWidget);
  });

  Future<void> settleHistoryWrite(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
  }

  testWidgets('Every listen groups repeats by local day and replays either A',
      (tester) async {
    final beforeMidnight = DateTime(2025, 6, 1, 23, 59);
    final midnight = DateTime(2025, 6, 2);
    await tester.runAsync(() async {
      await seed(db, 'a', 'Song Alpha', playedAt: beforeMidnight);
      await seed(db, 'b', 'Song B', playedAt: midnight);
      await seed(db, 'a', 'Song Alpha',
          playedAt: midnight.add(const Duration(minutes: 1)));
    });
    final events = MusicListeningHistory.forProfile(db, db.profileId).events();
    expect(events.map((event) => event.trackId), ['a', 'b', 'a']);

    await show(tester);
    expect(find.text('Song Alpha'), findsOneWidget);
    await tester.tap(find.text('Every listen'));
    await tester.pumpAndSettle();

    final newerA = find.byKey(ValueKey(events[0].id));
    final songB = find.byKey(ValueKey(events[1].id));
    final olderA = find.byKey(ValueKey(events[2].id));
    expect(find.text('Song Alpha'), findsNWidgets(2));
    for (final row in [newerA, songB, olderA]) {
      expect(row, findsOneWidget);
    }
    final material = MaterialLocalizations.of(
        tester.element(find.byType(MusicHistoryScreen)));
    final newerDay = find.text(material.formatFullDate(midnight));
    final olderDay = find.text(material.formatFullDate(beforeMidnight));
    expect(newerDay, findsOneWidget);
    expect(olderDay, findsOneWidget);
    Finder tile(Finder row) =>
        find.descendant(of: row, matching: find.byType(ListTile));
    double top(Finder finder) => tester.getTopLeft(finder).dy;
    expect(top(newerDay), lessThan(top(tile(newerA))));
    expect(top(tile(newerA)), lessThan(top(tile(songB))));
    expect(top(tile(songB)), lessThan(top(olderDay)));
    expect(top(olderDay), lessThan(top(tile(olderA))));

    await tester.tap(tile(newerA));
    await tester.pumpAndSettle();
    await tester.tap(tile(olderA));
    await tester.pumpAndSettle();

    expect(player.chronologicalQueues.map((queue) => queue.ids),
        everyElement(['a', 'b', 'a']));
    expect(player.chronologicalQueues.map((queue) => queue.startIndex), [0, 2]);

    await tester.tap(findButton);
    await tester.pumpAndSettle();
    await tester.enterText(query, 'alpha');
    await tester.pumpAndSettle();
    expect(songB, findsNothing);
    await tester.tap(tile(olderA));
    await tester.pumpAndSettle();
    expect(player.chronologicalQueues.last.ids, ['a', 'a']);
    expect(player.chronologicalQueues.last.startIndex, 1);
  });

  testWidgets('Every listen removes only confirmed occurrences of a song',
      (tester) async {
    await tester.runAsync(() async {
      await seed(db, 'a', 'Repeated song');
      await seed(db, 'b', 'Untouched song', order: 1);
      await seed(db, 'a', 'Repeated song', order: 2);
    });
    final history = MusicListeningHistory.forProfile(db, db.profileId);
    final events = history.events();
    Finder tile(int index) => find.descendant(
          of: find.byKey(ValueKey(events[index].id)),
          matching: find.byType(ListTile),
        );

    await show(tester);
    await tester.tap(find.text('Every listen'));
    await tester.pumpAndSettle();
    await tester.longPress(tile(0));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(tile(0)).selected, isTrue);
    expect(tester.widget<ListTile>(tile(2)).selected, isFalse);
    await tester.tap(tile(2));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(player.chronologicalQueues, isEmpty);

    await tester.tap(tile(2));
    await tester.pumpAndSettle();
    await openSelectionAction(tester, 'Remove listens from Music history');
    expect(find.text('Remove this listen from Music history?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(history.events().map((event) => event.id),
        events.map((event) => event.id));
    expect(find.text('1 selected'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(find.text('Music history'), findsOneWidget);

    await tester.longPress(tile(0));
    await tester.pumpAndSettle();
    await openSelectionAction(tester, 'Remove listens from Music history');
    await tester.tap(delete);
    await settleHistoryWrite(tester);
    expect(history.events().map((event) => event.id),
        [events[1].id, events[2].id]);
    expect(find.text('Repeated song'), findsOneWidget);
    expect(find.text('Untouched song'), findsOneWidget);
  });

  testWidgets('clearing Every listen retains other profiles and Video history',
      (tester) async {
    final current = db.forProfile(db.profileId);
    final other = (await tester.runAsync(() async {
      await seed(current, 'sharedSong', 'Current profile song');
      await seed(current, 'sharedSong', 'Current profile song', order: 1);
      final profile = await db.createProfile('Other');
      final other = db.forProfile(profile.id);
      await seed(other, 'sharedSong', 'Other profile song');
      await current.recordPlaybackHistory(PlaybackHistoryOrigin.video,
          HistoryVideoCache('sharedSong', 'Same ID in Video', 'Uploader', ''));
      return other;
    }))!;
    final history = MusicListeningHistory.forProfile(db, current.profileId);
    final otherHistory = MusicListeningHistory.forProfile(db, other.profileId);
    final otherEvent = otherHistory.events().single;

    await show(tester);
    await tester.tap(find.text('Every listen'));
    await tester.pumpAndSettle();
    expect(find.text('Current profile song'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('music-history-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history ?'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await settleHistoryWrite(tester);

    expect(find.text('Current profile song'), findsNothing);
    expect(
        find.text('Songs played from Music will appear here.'), findsOneWidget);
    expect(history.events(), isEmpty);
    expect(otherHistory.events().single.id, otherEvent.id);
    expect(current.getPlaybackHistory(PlaybackHistoryOrigin.video).single.title,
        'Same ID in Video');
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
    await settleHistoryWrite(tester);
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
