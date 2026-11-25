import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/views/components/music_player.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/models/named_music_queue.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const track = Video(videoId: 'track', title: 'Track');
const snapshot = PlaybackSession(
    currentId: 'track',
    videos: [track],
    seconds: 30,
    audio: true,
    queueTitle: 'First album');
const previousQueue = NamedMusicQueue('previous', '', snapshot);
const unavailableQueue = NamedMusicQueue('missing', 'Missing source', snapshot);

class _App extends TestAppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  void showAnotherProfile() => emit(state.copyWith(
      profileId: 'another', sessionRevision: state.sessionRevision + 1));
}

class _Player extends TestPlayerCubit {
  _Player(SettingsCubit settings) : super(PlayerState.init(null), settings);

  final queues = <NamedMusicQueue>[previousQueue];
  final revision = ValueNotifier(0);
  final resumeRequests = <String>[];
  bool canSave = false;
  String? active;

  @override
  List<NamedMusicQueue> get namedMusicQueues => queues;

  @override
  ValueListenable<int> get namedMusicQueuesRevision => revision;

  @override
  String? get activeNamedMusicQueueId => active;

  @override
  bool get canSaveNamedMusicQueue => canSave;

  @override
  Future<NamedMusicQueue?> saveNamedMusicQueue(String name) async {
    if (!canSave) return null;
    final queue = NamedMusicQueue('new', name, snapshot);
    queues.add(queue);
    active = queue.id;
    revision.value++;
    return queue;
  }

  @override
  Future<NamedMusicQueueResumeResult> resumeNamedMusicQueue(String id) async {
    resumeRequests.add(id);
    return id == unavailableQueue.id
        ? NamedMusicQueueResumeResult.unavailable
        : NamedMusicQueueResumeResult.restored;
  }

  @override
  Future<bool> renameNamedMusicQueue(String id, String name) async {
    final index = queues.indexWhere((queue) => queue.id == id);
    queues[index] = NamedMusicQueue(id, name, queues[index].snapshot);
    revision.value++;
    return true;
  }

  @override
  Future<bool> deleteNamedMusicQueue(String id) async {
    queues.removeWhere((queue) => queue.id == id);
    if (active == id) active = null;
    revision.value++;
    return true;
  }
}

void main() {
  late _App app;
  late TestSettingsCubit settings;
  late _Player player;
  late bool previousTv;

  setUp(() async {
    previousTv = app_globals.isTv;
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    app = _App();
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(settings);
  });

  tearDown(() async {
    await player.close();
    player.revision.dispose();
    await settings.close();
    await app.close();
    await db.close();
    app_globals.isTv = previousTv;
  });

  Future<void> show(WidgetTester tester, Widget body,
      {double textScale = 1}) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!),
        home: Scaffold(body: body),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    expect(finder.hitTestable(), findsOneWidget);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('the active queue saves, renames and confirms deletion',
      (tester) async {
    player.canSave = true;
    await show(tester, const MusicQueue(), textScale: 1.5);
    await tap(tester, find.byKey(const ValueKey('music-queue-saved-queues')));
    expect(find.text('Previous queue'), findsOneWidget);
    await tap(tester, find.text('Save current queue'));
    final field = find.byKey(const ValueKey('music-saved-queue-name'));
    final save = find.widgetWithText(TextButton, 'Save');
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    await tester.enterText(field, '  Road trip  ');
    await tester.pumpAndSettle();
    await tap(tester, save);
    expect(player.queues.last.name, 'Road trip');
    expect(find.textContaining('Active queue'), findsOneWidget);

    final actions =
        find.byKey(const ValueKey(('music-saved-queue-actions', 'new')));
    await tap(tester, actions);
    await tap(tester, find.text('Rename queue'));
    await tester.enterText(field, 'Evening');
    await tester.pumpAndSettle();
    await tap(tester, save);
    expect(player.queues.last.name, 'Evening');

    Future<void> confirmDeletion() async {
      await tap(tester, actions);
      await tap(tester, find.text('Delete saved queue'));
      expect(find.text('Delete “Evening” from your saved queues?'),
          findsOneWidget);
    }

    await confirmDeletion();
    await tap(tester, find.widgetWithText(TextButton, 'Cancel'));
    expect(player.queues.last.name, 'Evening');
    await confirmDeletion();
    await tap(tester, find.widgetWithText(TextButton, 'Delete'));
    expect(player.queues, [previousQueue]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Library can retry after an unavailable queue with no player',
      (tester) async {
    player.queues.insert(0, unavailableQueue);
    await show(tester, const MusicLibraryPage());
    await tap(tester, find.byKey(const ValueKey('music-library-saved-queues')));
    expect(find.text('Save current queue'), findsNothing);
    await tap(tester, find.text('Missing source'));
    expect(find.textContaining('current song is unavailable'), findsOneWidget);
    expect(find.text('Previous queue'), findsOneWidget);
    await tap(tester, find.text('Previous queue'));
    expect(player.resumeRequests, ['missing', 'previous']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a profile closes its saved queues and open row menu',
      (tester) async {
    await show(tester, const MusicLibraryPage());
    await tap(tester, find.byKey(const ValueKey('music-library-saved-queues')));
    await tap(tester,
        find.byKey(const ValueKey(('music-saved-queue-actions', 'previous'))));
    expect(find.text('Rename queue'), findsOneWidget);
    app.showAnotherProfile();
    await tester.pumpAndSettle();
    expect(find.text('Previous queue'), findsNothing);
    expect(find.text('Rename queue'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
