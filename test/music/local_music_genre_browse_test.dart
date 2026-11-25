import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout(), profileId: db.profileId));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final queues = <({List<LocalMusicTrack> tracks, int start, String? title})>[];

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0, String? queueTitle, bool songTap = false}) async {
    queues.add((tracks: List.of(tracks), start: startIndex, title: queueTitle));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({LocalMusicLibrary library, _Player player})> showLibrary(
    WidgetTester tester, {
    required String source,
    required List<Map<String, Object>> tracks,
    bool Function()? hasAccess,
    String? additionalFolder,
    List<Map<String, Object>>? playlists,
  }) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    const selectionId = 'selected-music';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final database = (await tester.runAsync(SembastSqfDb.createInMemory))!;
    db = database;
    final library = LocalMusicLibrary(visibilityDatabase: () => database);
    final app = _App();
    final player = _Player();
    var tracksScanned = false;
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      library.dispose();
      await player.close();
      await app.close();
      await database.close();
    });

    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          final root = {
            'uri': source,
            'name': 'Test music',
            'selectionId': selectionId,
          };
          if (additionalFolder == null) return root;
          return {
            'selectionId': 'library-session',
            'roots': [
              root,
              {
                'uri': additionalFolder,
                'name': 'Test folder',
                'selectionId': 'selected-folder',
              },
            ],
          };
        case 'checkFolderAccess':
          if (call.arguments['treeUri'] == source) {
            return hasAccess?.call() ?? true;
          }
          expect(call.arguments['treeUri'], additionalFolder);
          return true;
        case 'listTracks':
          if (additionalFolder != null &&
              call.arguments['treeUri'] == additionalFolder) {
            return [
              {
                'uri': '$additionalFolder/document/1',
                'title': 'Folder song',
                'genre': 'Folk',
              },
            ];
          }
          expect(call.arguments['treeUri'], source);
          tracksScanned = true;
          return tracks;
        case 'listIndexedPlaylists':
          expect(playlists, isNotNull);
          expect(tracksScanned, isTrue);
          expect(call.arguments['treeUri'], source);
          expect(call.arguments['selectionId'], selectionId);
          return playlists;
        default:
          throw MissingPluginException(call.method);
      }
    });

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LocalMusicFolder.library(library: library)),
      ),
    ));
    await tester.pumpAndSettle();
    return (library: library, player: player);
  }

  testWidgets('genre pages queue only the current visible genre members',
      (tester) async {
    const source = 'content://provider/tree/music';
    var granted = true;
    final (:library, :player) = await showLibrary(tester,
        source: source,
        hasAccess: () => granted,
        tracks: [
          {
            'uri': '$source/document/1',
            'title': 'Shared title',
            'genre': ' Jazz ',
            'visibilityKey': 'a' * 64,
          },
          {
            'uri': '$source/document/2',
            'title': 'Quiet piano',
            'genre': 'jazz',
          },
          {
            'uri': '$source/document/3',
            'title': 'Shared title',
            'genre': 'Rock',
          },
          {
            'uri': '$source/document/4',
            'title': 'Composite track',
            'genre': 'Jazz / Fusion',
          },
          {'uri': '$source/document/5', 'title': 'Untagged track'},
        ]);

    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    final jazz = find.textContaining(RegExp(r'^jazz$', caseSensitive: false));
    expect(jazz, findsOneWidget);
    expect(find.text('Jazz / Fusion'), findsOneWidget);
    expect(find.text('Rock'), findsOneWidget);
    final genre = tester.widget<Text>(jazz).data!;
    await tester.tap(jazz);
    await tester.pumpAndSettle();

    expect(find.text(genre), findsOneWidget);
    expect(find.text('Shared title'), findsOneWidget);
    expect(find.text('Composite track'), findsNothing);
    expect(find.text('Untagged track'), findsNothing);
    final piano = find.text('Quiet piano');
    await tester.tap(piano);
    await tester.pumpAndSettle();

    final firstQueue = player.queues.single;
    expect(firstQueue.title, genre);
    expect(firstQueue.tracks.map((track) => track.uri),
        unorderedEquals(['$source/document/1', '$source/document/2']));
    expect(firstQueue.tracks[firstQueue.start].uri, '$source/document/2');

    final hiddenTrack = library.tracks.firstWhere(
      (track) => track.uri == '$source/document/1',
    );
    expect(
        await tester.runAsync(() => library.hideTrack(hiddenTrack)), isNotNull);
    await tester.pumpAndSettle();
    expect(find.text('Shared title'), findsNothing);
    await tester.tap(piano);
    await tester.pumpAndSettle();
    expect(player.queues.last.tracks.map((track) => track.uri),
        ['$source/document/2']);

    granted = false;
    await library.revalidate();
    await tester.pumpAndSettle();
    expect(piano, findsNothing);
    expect(player.queues, hasLength(2));
  });

  testWidgets('indexed playlists keep exact volumes and duplicate occurrences',
      (tester) async {
    const source = 'content://media/external/audio/media';
    const primary = 'content://media/external_primary/audio/media';
    const anotherVolume = 'content://media/OtherVolume/audio/media';
    const folder = 'content://provider/tree/folder';
    var granted = true;
    final (:library, :player) = await showLibrary(
      tester,
      source: source,
      additionalFolder: folder,
      hasAccess: () => granted,
      tracks: [
        {'uri': '$primary/1', 'title': 'Opening song'},
        {
          'uri': '$primary/2',
          'title': 'Looped song',
          'visibilityKey': 'b' * 64,
        },
        {'uri': '$primary/9', 'title': 'Same row on a different volume'},
      ],
      playlists: [
        {
          'id': 1,
          'name': 'Road set',
          'memberUris': [
            '$primary/2',
            '$primary/1',
            '$primary/2',
            '$anotherVolume/9',
            '$folder/document/1',
          ],
        },
      ],
    );

    await tester.tap(find.text('Device playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Road set'));
    await tester.pumpAndSettle();

    expect(find.text('Road set'), findsOneWidget);
    expect(find.text('Same row on a different volume'), findsNothing);
    expect(find.text('Folder song'), findsNothing);
    final repeated = find.text('Looped song');
    expect(repeated, findsNWidgets(2));
    await tester.tap(repeated.at(1));
    await tester.pumpAndSettle();
    final queue = player.queues.single;
    expect(queue.title, 'Road set');
    expect(queue.start, 2);
    expect(queue.tracks.map((track) => track.uri),
        ['$primary/2', '$primary/1', '$primary/2']);

    final hiddenTrack =
        library.tracks.firstWhere((track) => track.uri == '$primary/2');
    expect(
        await tester.runAsync(() => library.hideTrack(hiddenTrack)), isNotNull);
    await tester.pumpAndSettle();
    expect(repeated, findsNothing);
    await tester.tap(find.text('Opening song'));
    await tester.pumpAndSettle();
    expect(player.queues.last.tracks.map((track) => track.uri), ['$primary/1']);

    granted = false;
    await library.revalidate();
    await tester.pumpAndSettle();
    expect(library.visibleTracks.single.uri, '$folder/document/1');
    expect(find.text('Road set'), findsNothing);
    expect(find.text('Opening song'), findsNothing);
    expect(find.text('Play all'), findsNothing);
    expect(player.queues, hasLength(2));
  });
}
