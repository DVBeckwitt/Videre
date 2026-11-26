import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/local_music_albums.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout(), profileId: db.profileId));

  void publishProfile() => emit(state.copyWith(
        profileId: db.profileId,
        sessionRevision: state.sessionRevision + 1,
      ));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  List<LocalMusicTrack> queue = [];

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool songTap = false,
      bool collectionDetail = false}) async {
    queue = tracks;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const originalRoot = 'content://provider/tree/original';
  const remasterRoot = 'content://provider/tree/remaster';
  const originalFile = '$originalRoot/document/live-original.flac';
  const remasteredFile = '$remasterRoot/document/live-remaster.flac';
  final originalKey = 'a' * 64;
  final remasterKey = 'b' * 64;
  final unrelatedKey = 'c' * 64;
  late _App app;
  late _Player player;
  late LocalMusicLibrary library;
  late bool remasterAvailable;

  Map<String, Object> track(String uri, String title, String album,
          String albumKey, String folder) =>
      {
        'uri': uri,
        'title': title,
        'album': album,
        'artist': 'The ensemble',
        'albumArtist': 'The ensemble',
        'albumKey': albumKey,
        'folderLocations': [
          {
            'key': folder == 'Original masters' ? 'd' * 64 : 'e' * 64,
            'label': folder,
          },
        ],
      };

  setUp(() async {
    final wasTv = app_globals.isTv;
    addTearDown(() => app_globals.isTv = wasTv);
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _Player();
    library = LocalMusicLibrary(visibilityDatabase: () => db);
    remasterAvailable = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return {
            'roots': [
              {'uri': originalRoot, 'name': 'Original masters'},
              {'uri': remasterRoot, 'name': '2019 remaster'},
            ],
            'selectionId': 'library-session',
          };
        case 'checkFolderAccess':
          return call.arguments['treeUri'] != remasterRoot || remasterAvailable;
        case 'listTracks':
          if (call.arguments['treeUri'] == originalRoot) {
            return [
              track(originalFile, 'Original recording', 'Live', originalKey,
                  'Original masters'),
              track('$originalRoot/document/another.flac', 'Another concert',
                  'Live Again', unrelatedKey, 'Original masters'),
            ];
          }
          return [
            track(remasteredFile, 'Remastered recording', 'Live', remasterKey,
                '2019 remaster'),
          ];
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    library.dispose();
    await player.close();
    await app.close();
    await db.close();
  });

  Finder inBrowser(Finder finder) =>
      find.descendant(of: find.byType(BottomSheet), matching: finder);
  Finder inManager(Finder finder) =>
      find.descendant(of: find.byType(Dialog), matching: finder);
  Finder browseRow(String key) => inBrowser(find.byKey(ValueKey(key)));
  Finder editionRow(String key) => inManager(find.byKey(ValueKey(key)));
  Finder rowAction(Finder row, String tooltip) =>
      find.descendant(of: row, matching: find.byTooltip(tooltip));

  Future<void> browse(WidgetTester tester) async {
    await tester.tap(find.text('Browse device albums'));
    await tester.pumpAndSettle();
  }

  Future<void> show(WidgetTester tester) async {
    await library.refresh();
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLocalMusicAlbums(context, library),
              child: const Text('Browse device albums'),
            ),
          ),
        ),
      ),
    ));
    await browse(tester);
  }

  Future<void> manage(WidgetTester tester, String key) async {
    await tester
        .tap(rowAction(browseRow(key), 'Manage editions').hitTestable());
    await tester.pumpAndSettle();
    expect(
        inManager(find.text('Manage editions')).hitTestable(), findsOneWidget);
  }

  Future<void> addRemaster(WidgetTester tester) async {
    await tester.tap(inManager(find.text('Add edition')));
    await tester.pumpAndSettle();
    await tester.tap(editionRow(remasterKey));
    await tester.pumpAndSettle();
  }

  Future<void> choosePreferred(WidgetTester tester, String key) async {
    await tester.tap(editionRow(key));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    final previous = library.albumEditionGroups;
    await tester.runAsync(() async {
      final saved = Completer<void>();
      void onLibraryChanged() {
        if (!saved.isCompleted &&
            !listEquals(previous, library.albumEditionGroups)) {
          saved.complete();
        }
      }

      library.addListener(onLibraryChanged);
      try {
        await tester.tap(inManager(find.text('Save')).hitTestable());
        await saved.future.timeout(const Duration(seconds: 5));
      } finally {
        library.removeListener(onLibraryChanged);
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  }

  Future<void> preferRemaster(WidgetTester tester) async {
    await manage(tester, originalKey);
    await addRemaster(tester);
    await choosePreferred(tester, remasterKey);
    await save(tester);
  }

  testWidgets('groups exact editions, keeps exact playback, and can ungroup',
      (tester) async {
    await show(tester);
    expect(browseRow(originalKey), findsOneWidget);
    expect(browseRow(remasterKey), findsOneWidget);
    expect(browseRow(unrelatedKey), findsOneWidget);
    expect(inBrowser(find.textContaining('Original masters')), findsOneWidget);
    expect(inBrowser(find.textContaining('2019 remaster')), findsOneWidget);

    await tester.tap(browseRow(originalKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    final playing = player.queue;
    expect(playing.single.uri, originalFile);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await browse(tester);

    await preferRemaster(tester);
    expect(browseRow(originalKey), findsNothing);
    expect(browseRow(remasterKey), findsOneWidget);
    expect(browseRow(unrelatedKey), findsOneWidget);
    expect(player.queue, same(playing));
    expect(library.trackById(playing.single.playbackId)?.uri, originalFile);

    await manage(tester, remasterKey);
    await tester.tap(rowAction(editionRow(originalKey), 'Open edition'));
    await tester.pumpAndSettle();
    expect(find.text('Original recording'), findsOneWidget);
    expect(find.text('Remastered recording'), findsNothing);
    expect(player.queue, same(playing));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await browse(tester);
    await tester.tap(browseRow(remasterKey));
    await tester.pumpAndSettle();
    expect(find.text('Original recording'), findsNothing);
    expect(find.text('Remastered recording'), findsOneWidget);
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.queue.single.uri, remasteredFile);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await browse(tester);

    await manage(tester, remasterKey);
    await choosePreferred(tester, originalKey);
    await save(tester);
    expect(browseRow(originalKey), findsOneWidget);
    expect(browseRow(remasterKey), findsNothing);

    await manage(tester, originalKey);
    await tester
        .tap(rowAction(editionRow(remasterKey), 'Remove edition from group'));
    await tester.pumpAndSettle();
    await save(tester);
    expect(browseRow(originalKey), findsOneWidget);
    expect(browseRow(remasterKey), findsOneWidget);
    expect(browseRow(unrelatedKey), findsOneWidget);
    expect(player.queue.single.uri, remasteredFile);
  });

  testWidgets('falls back when the preferred grant is lost and restores it',
      (tester) async {
    await show(tester);
    await preferRemaster(tester);
    expect(browseRow(remasterKey), findsOneWidget);

    remasterAvailable = false;
    await library.revalidate();
    await tester.pumpAndSettle();
    expect(browseRow(remasterKey), findsNothing);
    expect(browseRow(originalKey), findsOneWidget);
    expect(browseRow(unrelatedKey), findsOneWidget);

    remasterAvailable = true;
    await library.revalidate();
    await library.refresh();
    await tester.pumpAndSettle();
    expect(browseRow(remasterKey), findsOneWidget);
    expect(browseRow(originalKey), findsNothing);
    expect(browseRow(unrelatedKey), findsOneWidget);
    expect(player.queue, isEmpty);
  });

  testWidgets('groups and an open editor stay with the captured profile',
      (tester) async {
    final originalProfile = db.profileId;
    final secondProfile =
        await tester.runAsync(() async => (await db.createProfile('Guest')).id);
    await show(tester);
    await preferRemaster(tester);
    await manage(tester, remasterKey);
    await choosePreferred(tester, originalKey);
    final saveButton = inManager(find.widgetWithText(FilledButton, 'Save'));
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);

    Future<void> switchProfile(String profile) async {
      await tester.runAsync(() => db.useProfile(profile));
      app.publishProfile();
      library.visibilityProfileChanged();
      await tester.pumpAndSettle();
    }

    await switchProfile(secondProfile!);
    expect(editionRow(originalKey), findsNothing);
    expect(saveButton, findsNothing);
    await tester.tap(inManager(find.text('Cancel')).hitTestable());
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    await browse(tester);
    expect(browseRow(originalKey), findsOneWidget);
    expect(browseRow(remasterKey), findsOneWidget);

    navigator.pop();
    await tester.pumpAndSettle();
    await switchProfile(originalProfile);
    await browse(tester);
    expect(browseRow(originalKey), findsNothing);
    expect(browseRow(remasterKey), findsOneWidget);
    expect(player.queue, isEmpty);
  });
}
