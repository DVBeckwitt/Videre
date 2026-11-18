import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/screens/music_library.dart';
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
  onReady() {}

  @override
  initState() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _App app;
  late MusicLibraryService library;
  late Service previousService;
  late bool previousTv;

  setUp(() async {
    previousService = service;
    previousTv = app_globals.isTv;
    service = Service();
    app_globals.isTv = true;
    db = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(db, db.profileId);
    app = _App();
  });

  tearDown(() async {
    await app.close();
    await db.close();
    service = previousService;
    app_globals.isTv = previousTv;
  });

  for (final grid in [false, true]) {
    for (final kind in [MusicLibraryKind.artist, MusicLibraryKind.playlist]) {
      testWidgets(
          '${kind.name} keeps focus when an earlier bookmark is removed (grid: $grid)',
          (tester) async {
        await tester.runAsync(() async {
          if (kind == MusicLibraryKind.playlist) {
            final local =
                await service.createPlayList('Local music list', 'local');
            await library.markLocalPlaylist(local!);
          }
          await library.save(MusicLibraryEntry(
              kind: kind, id: 'focused', title: 'Focused bookmark'));
          await library.save(MusicLibraryEntry(
              kind: kind, id: 'earlier', title: 'Earlier bookmark'));
        });
        await tester.pumpWidget(BlocProvider<AppCubit>.value(
            value: app,
            child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const Scaffold(body: MusicLibraryPage()))));
        await tester.pumpAndSettle();
        if (kind == MusicLibraryKind.artist) {
          await tester.tap(find.text('Channels'));
          await tester.pumpAndSettle();
        }
        if (grid) {
          await tester.tap(find.byKey(const ValueKey('music-library-layout')));
          await tester.pumpAndSettle();
        }

        final focusedTitle = find.text('Focused bookmark');
        final originalFocus = Focus.of(tester.element(focusedTitle));
        originalFocus.requestFocus();
        await tester.pumpAndSettle();
        expect(originalFocus.hasPrimaryFocus, isTrue);

        await tester.runAsync(() => library.remove(kind, 'earlier'));
        await tester.pumpAndSettle();

        expect(find.text('Earlier bookmark'), findsNothing);
        expect(focusedTitle, findsOneWidget);
        expect(Focus.of(tester.element(focusedTitle)).hasPrimaryFocus, isTrue,
            reason: 'Moving a surviving row must preserve its remote focus');
      });
    }
  }
}
