import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/services/cached_music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

const _channel = MethodChannel('videre/proxy');
const _firstAccount =
    Server(url: 'https://example.test', id: 'first', inUse: true);
const _secondAccount =
    Server(url: 'https://example.test', id: 'second', inUse: true);

class _App extends AppCubit {
  _App() : super(AppState(0, _firstAccount, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void onReady() {}

  @override
  void initState() {}

  void select(Server server) => emit(state.copyWith(
      server: server, sessionRevision: state.sessionRevision + 1));
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final selections =
      <({List<String> renditions, int startIndex, Server owner})>[];

  @override
  Future<void> playCachedMusicSongs(List<CachedMusicSong> songs,
      {required int startIndex,
      required Server server,
      required String queueTitle,
      required bool Function() isCurrent}) async {
    expect(isCurrent(), isTrue);
    expect(queueTitle, 'Cached songs');
    selections.add((
      renditions: songs.map((song) => song.rendition).toList(),
      startIndex: startIndex,
      owner: server,
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Map<String, Object> _song(String videoId, String title, String digit) => {
      'videoId': videoId,
      'title': title,
      'artist': 'Artist',
      'lengthSeconds': 93,
      'rendition': digit * 64,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final android = TargetPlatformVariant.only(TargetPlatform.android);
  late bool wasTv;
  late _App app;
  late _Player player;
  late TestSettingsCubit settings;

  setUp(() async {
    wasTv = app_globals.isTv;
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _Player();
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_channel, null);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    app_globals.isTv = wasTv;
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: MusicLibraryPage()),
      ),
    ));
    await tester.pumpAndSettle();
    final tab = find.byKey(const ValueKey('music-library-tab-cachedSongs'));
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pump();
  }

  testWidgets('Cached songs recheck eviction and play the current cache order',
      (tester) async {
    final first = _song('aaaaaaaaaaa', 'First song', 'a');
    final second = _song('bbbbbbbbbbb', 'Second song', 'b');
    var rows = [first];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'cachedMusicSongs');
      expect(call.arguments['accountId'], _firstAccount.accountId);
      return rows;
    });

    await open(tester);
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsOneWidget);
    expect(find.text('01:33'), findsOneWidget);
    expect(find.text('Second song'), findsNothing);

    rows = [];
    await tester.tap(find.text('First song'));
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsNothing);
    expect(find.text('This song is no longer in the playback cache.'),
        findsOneWidget);
    expect(find.text('No playable songs are cached.'), findsOneWidget);
    expect(player.selections, isEmpty);

    rows = [first, second];
    await tester.tap(find.byKey(const ValueKey('music-cached-songs-refresh')));
    await tester.pumpAndSettle();
    rows = [second, first];
    await tester.tap(find.text('First song'));
    await tester.pumpAndSettle();
    final selection = player.selections.single;
    expect(selection.renditions, ['b' * 64, 'a' * 64]);
    expect(selection.startIndex, 1);
    expect(selection.owner, _firstAccount);
  }, variant: android);

  testWidgets('Cached songs discard a late list from an old account',
      (tester) async {
    final held = Completer<List<Map<String, Object>>>();
    final accounts = <String>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final account = call.arguments['accountId'] as String;
      accounts.add(account);
      return account == _firstAccount.accountId
          ? await held.future
          : [_song('bbbbbbbbbbb', 'Current account song', 'b')];
    });

    await open(tester);
    expect(accounts, [_firstAccount.accountId]);
    app.select(_secondAccount);
    await tester.pumpAndSettle();
    held.complete([_song('aaaaaaaaaaa', 'Previous account song', 'a')]);
    await tester.pumpAndSettle();
    expect(accounts, [_firstAccount.accountId, _secondAccount.accountId]);
    expect(find.text('Current account song'), findsOneWidget);
    expect(find.text('Previous account song'), findsNothing);
  }, variant: android);
}
