import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/screens/music_automatic_collections.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void initState() {}

  @override
  void onReady() {}
}

void main() {
  testWidgets('Liked Songs removes only confirmed, selected likes',
      (tester) async {
    const first = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'firstsong01', title: 'First song');
    const second = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'secondsong2', title: 'Second song');
    const third = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'thirdsong03', title: 'Third song');
    final previousService = service;
    service = Service();
    addTearDown(() => service = previousService);
    final app = _App();
    addTearDown(app.close);
    final session = (await tester.runAsync(() async {
      db = await SembastSqfDb.createInMemory();
      addTearDown(db.close);
      final session = MusicLibrarySession(app);
      for (final song in [first, second, third]) {
        await session.library.save(song);
        await session.library.setSongLiked(song, liked: true);
      }
      return session;
    }))!;

    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MusicAutomaticCollectionsPage(session: session, showLikes: true),
      ),
    ));
    await tester.pumpAndSettle();

    Finder row(MusicLibraryEntry song) =>
        find.byKey(ValueKey('music-automatic-track-${song.id}'));
    await tester.longPress(row(first));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(row(first)).selected, isTrue);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(row(third));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(tester.widget<ListTile>(row(second)).selected, isFalse);

    Future<void> requestRemoval() async {
      await tester
          .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Liked Songs'));
      await tester.pumpAndSettle();
      expect(
          find.text('Remove these 2 songs from Liked Songs?'), findsOneWidget);
    }

    await requestRemoval();
    await tester.runAsync(() async {
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
    expect(session.library.likedSongs.length, 3);
    expect(find.text('2 selected'), findsOneWidget);

    await requestRemoval();
    final didRemove = Completer<void>();
    void onChange() => didRemove.complete();
    session.library.changes.addListener(onChange);
    try {
      await tester.runAsync(() async {
        await tester
            .tap(find.widgetWithText(TextButton, 'Remove from Liked Songs'));
        await tester.pumpAndSettle();
        await didRemove.future.timeout(const Duration(seconds: 5));
      });
    } finally {
      session.library.changes.removeListener(onChange);
    }
    await tester.pumpAndSettle();
    expect(session.library.likedSongs.map((song) => song.id), [second.id]);
    expect(session.library.entries.length, 3);
    expect(row(first), findsNothing);
    expect(row(second), findsOneWidget);
    expect(row(third), findsNothing);
    expect(find.text('2 selected'), findsNothing);
  });
}
