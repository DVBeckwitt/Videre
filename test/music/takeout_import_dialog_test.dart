import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/takeout_import_dialog.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}

  void changed() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));
}

class _NoNetwork extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Local import attempted a network connection');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _App app;
  late MusicLibraryService library;
  late Service previousService;
  late HttpOverrides? previousHttp;
  late _NoNetwork network;
  late List<String> methods;
  late Future<List<Map<String, String>>?> Function() choose;
  late int serviceRequests;

  const file = {
    'name': 'music-library-songs.csv',
    'text': 'Video ID,Song Title,Artist Name,Album Title\r\n'
        'abcdefghijk,Replacement title,Artist,Album\r\n'
        'lmnopqrstuv,"New, song",New artist,New album\r\n'
        'lmnopqrstuv,Duplicate,Artist,Album\r\n'
        'invalid,Invalid song,Artist,Album\r\n',
  };

  setUp(() async {
    previousHttp = HttpOverrides.current;
    previousService = service;
    network = _NoNetwork();
    HttpOverrides.global = network;
    expect(() => HttpClient(), throwsStateError);
    network.attempts = 0;
    serviceRequests = 0;
    service = Service(httpClient: MockClient((_) async {
      serviceRequests++;
      throw StateError('Local import called the instance');
    }));
    db = await SembastSqfDb.createInMemory();
    app = _App();
    library = MusicLibraryService.forProfile(db, db.profileId);
    methods = [];
    choose = () async => [file];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      expect(call.method, 'openTakeout');
      return choose();
    });
  });

  tearDown(() async {
    expect(network.attempts, 0);
    expect(serviceRequests, 0);
    messenger.setMockMethodCallHandler(channel, null);
    await app.close();
    await db.close();
    service = previousService;
    HttpOverrides.global = previousHttp;
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => showTakeoutImport(context),
                    child: const Text('Open import'),
                  )),
        ),
      ),
    ));
    await tester.tap(find.text('Open import'));
    await tester.pump();
  }

  Future<void> finishReading(WidgetTester tester) async {
    for (var attempt = 0; attempt < 200; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (find.text('Reading local file…').evaluate().isEmpty) break;
    }
    expect(find.text('Reading local file…'), findsNothing);
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.runAsync(() async => tester.tap(find.text('Import songs')));
    for (var attempt = 0; attempt < 200; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('preview and merge read only the file and keep existing songs',
      (tester) async {
    await tester.runAsync(() => library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'abcdefghijk',
        title: 'Keep my title')));
    await open(tester);
    await finishReading(tester);
    expect(library.entries, hasLength(1));
    expect(find.text('2 songs ready. Existing songs will be kept.'),
        findsOneWidget);
    expect(find.text('1 invalid row and 1 duplicate row skipped.'),
        findsOneWidget);
    expect(find.textContaining('may include songs you haven’t liked'),
        findsOneWidget);
    await confirm(tester);
    expect(
        find.text('1 song added. 1 already in your library.'), findsOneWidget);
    expect(library.entries.map((entry) => entry.title),
        ['Keep my title', 'New, song']);
    expect(library.entries.last.subtitle, 'New artist');
    expect(library.entries.last.thumbnails, isEmpty);
    expect(methods, ['openTakeout']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('canceling the preview writes nothing', (tester) async {
    await open(tester);
    await finishReading(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(library.entries, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('canceling the native picker writes nothing', (tester) async {
    choose = () async => null;
    await open(tester);
    await finishReading(tester);
    expect(library.entries, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a covered import keeps the completed file preview',
      (tester) async {
    final picked = Completer<List<Map<String, String>>?>();
    choose = () => picked.future;
    await open(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Shared link')))));
    await tester.pumpAndSettle();
    picked.complete([file]);
    for (var attempt = 0; attempt < 200; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (find
          .text('Reading local file…', skipOffstage: false)
          .evaluate()
          .isEmpty) {
        break;
      }
    }
    expect(find.text('Shared link'), findsOneWidget);
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reading local file…'), findsNothing);
    expect(find.text('2 songs ready. Existing songs will be kept.'),
        findsOneWidget);
    expect(library.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker cancellation closes only its covered import dialog',
      (tester) async {
    final picked = Completer<List<Map<String, String>>?>();
    choose = () => picked.future;
    await open(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Shared link')))));
    await tester.pumpAndSettle();
    picked.complete(null);
    await tester.pump();
    expect(find.text('Shared link'), findsOneWidget);
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Open import'), findsOneWidget);
    expect(library.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a covered import finishes saving and can be closed',
      (tester) async {
    await open(tester);
    await finishReading(tester);
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final entered = Completer<void>();
    late Future<void> transaction;
    await tester.runAsync(() async {
      transaction = (db as SembastSqfDb).db.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
    });
    await tester.runAsync(() async => tester.tap(find.text('Import songs')));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Shared link')))));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      release.complete();
      await transaction;
    });
    for (var attempt = 0; attempt < 200; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (library.entries.length == 2) break;
    }
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        find.text('2 songs added. 0 already in your library.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(library.entries, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final useBack in [false, true]) {
    testWidgets(
        'late picker cancellation preserves the library after ${useBack ? 'Back' : 'Cancel'}',
        (tester) async {
      final picked = Completer<List<Map<String, String>>?>();
      choose = () => picked.future;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Text('Home screen')),
        ),
      ));
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (context) => Scaffold(
                appBar: AppBar(title: const Text('Library screen')),
                body: TextButton(
                    onPressed: () => showTakeoutImport(context),
                    child: const Text('Open import')),
              ))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open import'));
      await tester.pump(const Duration(milliseconds: 300));
      if (useBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.text('Cancel'));
      }
      // The popped dialog is still mounted during its reverse animation.
      picked.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('Library screen'), findsOneWidget);
      expect(find.text('Home screen'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(library.entries, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('archive selection imports only the chosen collection',
      (tester) async {
    choose = () async => [
          file,
          {
            'name':
                'Takeout/YouTube and YouTube Music/playlists/Liked Music-videos.csv',
            'text': 'Video ID,Time Added\nZYXWVUTSRQP,2026-11-15\n',
          }
        ];
    await open(tester);
    await finishReading(tester);
    expect(find.textContaining('Missing titles use IDs'), findsOneWidget);
    expect(find.text('1 song ready. Existing songs will be kept.'),
        findsOneWidget);
    final selector = tester.widget<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>));
    selector.onChanged!(0);
    await tester.pumpAndSettle();
    expect(find.textContaining('may include songs you haven’t liked'),
        findsOneWidget);
    await confirm(tester);
    expect(library.entries.map((entry) => entry.id),
        ['abcdefghijk', 'lmnopqrstuv']);
  });

  testWidgets('a profile change during file selection cancels the import',
      (tester) async {
    final picked = Completer<List<Map<String, String>>?>();
    choose = () => picked.future;
    await open(tester);
    app.changed();
    picked.complete([file]);
    await finishReading(tester);
    expect(find.textContaining('The active profile changed.'), findsOneWidget);
    expect(find.text('Import songs'), findsNothing);
    expect(library.entries, isEmpty);
  });

  testWidgets('a profile change before confirmation prevents writes',
      (tester) async {
    await open(tester);
    await finishReading(tester);
    app.changed();
    await confirm(tester);
    expect(find.textContaining('The active profile changed.'), findsOneWidget);
    expect(library.entries, isEmpty);
  });

  testWidgets('unsupported files show an error without changing the library',
      (tester) async {
    choose = () async => [
          {'name': 'contacts.csv', 'text': 'Name,Email\nA,a@example.com'}
        ];
    await open(tester);
    await finishReading(tester);
    expect(find.textContaining('No supported Music library'), findsOneWidget);
    expect(find.text('Import songs'), findsNothing);
    expect(library.entries, isEmpty);
  });

  testWidgets('a recognized file with no valid IDs cannot be imported',
      (tester) async {
    choose = () async => [
          {
            'name': 'Liked Music.csv',
            'text': 'Video ID,Time Added\ninvalid,2026-11-15\n',
          }
        ];
    await open(tester);
    await finishReading(tester);
    expect(find.text('0 songs ready. Existing songs will be kept.'),
        findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(library.entries, isEmpty);
  });

  testWidgets('preview fits a small TV viewport and retains keyboard actions',
      (tester) async {
    tester.view.physicalSize = const Size(720, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester);
    await finishReading(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(find.text('Import songs').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
