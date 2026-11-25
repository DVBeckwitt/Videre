import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_rule_playlist_store.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void onReady() {}

  @override
  void initState() {}
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final requests = <({List<String> ids, int? startIndex, String? title})>[];

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      bool fromMusic = false}) async {
    expect(audio, isTrue);
    expect(fromMusic, isTrue);
    requests.add((
      ids: videos.map((video) => video.videoId).toList(),
      startIndex: startIndex,
      title: queueTitle,
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alpha = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'firstsong01',
    title: 'First song',
    subtitle: 'Chorus',
  );
  const beta = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'secondsong2',
    title: 'Second song',
    subtitle: 'The CHORUS',
  );
  const gamma = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'thirdsong03',
    title: 'Third song',
    subtitle: 'Chorus',
  );
  const unrelated = MusicLibraryEntry(
    kind: MusicLibraryKind.song,
    id: 'othertrack4',
    title: 'Another song',
    subtitle: 'Orchestra',
  );

  late _App app;
  late _Player player;
  late TestSettingsCubit settings;
  late MusicLibraryService library;
  late MusicRulePlaylistStore rules;
  late Service previousService;
  late bool previousTv;

  setUp(() async {
    previousService = service;
    previousTv = app_globals.isTv;
    service = Service();
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(db, db.profileId);
    rules = MusicRulePlaylistStore.forProfile(db, db.profileId);
    app = _App();
    player = _Player();
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
    app_globals.isTv = previousTv;
  });

  Finder control(String suffix) =>
      find.byKey(ValueKey('music-rule-playlist-$suffix'));
  Finder track(MusicLibraryEntry entry) => control('track-${entry.id}');

  testWidgets('a saved rule playlist plays the current limited membership',
      (tester) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MusicLibraryPage()),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-rule-playlists')));
    await tester.pumpAndSettle();
    await tester.tap(control('create'));
    await tester.pumpAndSettle();

    await tester.enterText(control('name'), 'Chorus picks');
    await tester.ensureVisible(control('artist'));
    await tester.enterText(control('artist'), 'chorus');
    await tester.ensureVisible(control('limit'));
    await tester.enterText(control('limit'), '2');
    await tester.ensureVisible(control('save'));
    await tester.runAsync(() async {
      final saved = Completer<void>();
      void onSaved() {
        if (!saved.isCompleted) saved.complete();
      }

      rules.changes.addListener(onSaved);
      try {
        await tester.tap(control('save'));
        await tester.pumpAndSettle();
        expect(control('save'), findsNothing);
        await saved.future.timeout(const Duration(seconds: 5));
      } finally {
        rules.changes.removeListener(onSaved);
      }
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('Chorus picks'));
    await tester.pumpAndSettle();
    expect(find.text('No saved songs match these rules.'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(control('play')).onPressed, isNull);
    expect(player.requests, isEmpty);

    await tester.runAsync(() async {
      for (final song in [alpha, beta, gamma, unrelated]) {
        await library.save(song);
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('No saved songs match these rules.'), findsNothing);
    expect(track(gamma), findsOneWidget);
    expect(track(beta), findsOneWidget);
    expect(track(alpha), findsNothing);
    expect(track(unrelated), findsNothing);

    final removedSongTap = tester.widget<ListTile>(track(gamma)).onTap!;
    await tester
        .runAsync(() => library.remove(MusicLibraryKind.song, gamma.id));
    removedSongTap();
    expect(player.requests, isEmpty);
    await tester.pumpAndSettle();
    expect(track(gamma), findsNothing);
    expect(track(alpha), findsOneWidget);
    await tester.tap(track(alpha));
    await tester.pumpAndSettle();
    final playback = player.requests.single;
    expect(playback.ids, [beta.id, alpha.id]);
    expect(playback.startIndex, 1);
    expect(playback.title, 'Chorus picks');
  });
}
