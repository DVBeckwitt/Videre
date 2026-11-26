import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/m3u_playlist.dart';
import 'package:clipious/music/views/components/m3u_playlist_dialog.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  const documents = MethodChannel('videre/files');
  const music = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _App app;
  var tracksAvailable = true;
  var secondVolume = 'primary';

  const tree = 'content://documents/tree/primary%3AMusic';
  const first = '$tree/document/primary%3AMusic%2Ffirst.mp3';
  const second = '$tree/document/primary%3AMusic%2Fsecond.mp3';

  setUp(() async {
    tracksAvailable = true;
    secondVolume = 'primary';
    db = await SembastSqfDb.createInMemory();
    app = _App();
    messenger.setMockMethodCallHandler(documents, (call) async {
      expect(call.method, 'openM3u');
      return {
        'name': 'Drive.m3u8',
        'text': '#EXTM3U\n../Music/first.mp3\n../Music/missing.mp3\n'
            '../Music/second.mp3\n../Music/first.mp3\n',
        'location': {'volume': 'primary', 'path': 'Playlists/Drive.m3u8'},
      };
    });
    messenger.setMockMethodCallHandler(music, (call) async {
      switch (call.method) {
        case 'getFolder':
          return {
            'roots': [
              {'uri': tree, 'name': 'Music', 'selectionId': 'music-grant'},
            ],
            'selectionId': 'music-session',
          };
        case 'pendingRenames':
          return [];
        case 'checkFolderAccess':
          expect(call.arguments['treeUri'], tree);
          return true;
        case 'listMovedFileRepairs':
          return {};
        case 'listTracks':
          expect(call.arguments['treeUri'], tree);
          return [
            if (tracksAvailable) ...[
              {'uri': first, 'title': 'First', 'visibilityKey': 'a' * 64},
              {'uri': second, 'title': 'Second', 'visibilityKey': 'b' * 64},
            ],
          ];
        case 'playlistLocations':
          expect(
              call.arguments, {'treeUri': tree, 'selectionId': 'music-grant'});
          return {
            'locations': {
              first: {'volume': 'primary', 'path': 'Music/first.mp3'},
              second: {'volume': secondVolume, 'path': 'Music/second.mp3'},
            },
            'roots': {
              'primary': '/storage/emulated/0',
              'cafe-1234': '/storage/CAFE-1234',
            },
          };
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(documents, null);
    messenger.setMockMethodCallHandler(music, null);
    await app.close();
    await db.close();
  });

  Future<void> pumpExport(WidgetTester tester) async {
    final firstProof = 'a' * 64;
    final secondProof = 'b' * 64;
    final firstId = 'device:playlist:$firstProof';
    final secondId = 'device:playlist:$secondProof';
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => exportM3uPlaylist(
              context,
              session: MusicLibrarySession(app),
              title: 'Drive',
              deviceIds: [secondId, null, firstId, firstId],
              resolve: (index, id) {
                final track = LocalMusicLibrary.instance
                    .playlistTrackById(id, visibleOnly: true);
                return track == null ? null : index.byTrack(track);
              },
            ),
            child: const Text('Export review'),
          ),
        ),
      ),
    ));
  }

  Future<void> openExport(WidgetTester tester) async {
    await tester.tap(find.text('Export review'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseFormat(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButton<M3uExportPathStyle>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> reviewPathFormats(WidgetTester tester) async {
    secondVolume = 'cafe-1234';
    final writes = <Object?>[];
    messenger.setMockMethodCallHandler(documents, (call) async {
      switch (call.method) {
        case 'createM3u':
          return {
            'token': 'test-output',
            'location': {'volume': 'primary', 'path': 'Playlists/Drive.m3u8'},
          };
        case 'writeM3u':
          writes.add(call.arguments);
          return null;
      }
      throw MissingPluginException(call.method);
    });

    await pumpExport(tester);
    await openExport(tester);
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.textContaining('1 file will use an absolute path.'),
        findsOneWidget);

    await chooseFormat(tester, 'Relative');
    final skipped = find.textContaining(
      '1 local entry cannot use this path format and will be skipped.',
    );
    expect(skipped, findsOneWidget);
    expect(find.textContaining('will use an absolute path'), findsNothing);

    await chooseFormat(tester, 'Absolute');
    expect(skipped, findsNothing);
    expect(find.textContaining('3 files will use absolute paths.'),
        findsOneWidget);

    await chooseFormat(tester, 'Windows-style relative');
    expect(skipped, findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(writes, [
      {
        'token': 'test-output',
        'text': '#EXTM3U\n'
            r'..\Music\first.mp3'
            '\n'
            r'..\Music\first.mp3'
            '\n',
      },
    ]);
    expect(tester.takeException(), isNull);
  }

  Future<void> reviewCancellation(WidgetTester tester) async {
    var pickLocation = false;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(documents, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'createM3u':
          return pickLocation ? {'token': 'test-output'} : null;
        case 'cancelM3uSave':
          expect(call.arguments, {'token': 'test-output'});
          return null;
      }
      throw MissingPluginException(call.method);
    });

    await pumpExport(tester);
    await openExport(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(methods, ['createM3u']);

    pickLocation = true;
    await openExport(tester);
    await chooseFormat(tester, 'Relative');
    expect(
      find.textContaining('The file picker did not provide a folder path.'),
      findsOneWidget,
    );
    expect(find.textContaining('No tracks can use this path format.'),
        findsOneWidget);
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await chooseFormat(tester, 'Absolute');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(methods, ['createM3u', 'createM3u', 'cancelM3uSave']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'phone M3U review preserves repeats, selects paths, and cancels exports',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    String? result;
    String? savedTitle;
    final savedUris = <String>[];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showM3uImport(
                context,
                session: MusicLibrarySession(app),
                save: (title, tracks, isCurrent) async {
                  expect(isCurrent(), isTrue);
                  savedTitle = title;
                  savedUris.addAll(tracks.map((entry) => entry.track.uri));
                  return 'local:drive';
                },
              );
            },
            child: const Text('Open review'),
          ),
        ),
      ),
    ));
    Future<void> openReview() async {
      await tester.tap(find.text('Open review'));
      await tester.pump();

      // M3U parsing runs in a worker isolate.
      final reading = find.byType(CircularProgressIndicator);
      for (var attempt = 0;
          attempt < 200 && reading.evaluate().isNotEmpty;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(reading, findsNothing);
      await tester.pumpAndSettle();
    }

    await openReview();

    expect(
        find.text('3 tracks ready · 1 entry will be skipped'), findsOneWidget);
    expect(find.text('../Music/first.mp3'), findsWidgets);
    final missing = find.text('../Music/missing.mp3');
    await tester.scrollUntilVisible(
      missing,
      64,
      scrollable: find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(Scrollable)),
    );
    expect(missing.hitTestable(), findsOneWidget);
    expect(find.text('File unavailable'), findsOneWidget);
    expect(savedUris, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(savedTitle, 'Drive');
    expect(savedUris, [first, second, first]);
    expect(result, 'local:drive');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);

    tracksAvailable = false;
    await openReview();
    expect(find.text('0 tracks ready · 4 entries will be skipped'),
        findsOneWidget);
    final save =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(save.onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    tracksAvailable = true;

    final writes = <Object?>[];
    messenger.setMockMethodCallHandler(documents, (call) async {
      switch (call.method) {
        case 'createM3u':
          expect(call.arguments, {'name': 'Drive.m3u8'});
          return {
            'token': 'test-output',
            'location': {'volume': 'primary', 'path': 'Playlists/Drive.m3u8'},
          };
        case 'writeM3u':
          writes.add(call.arguments);
          return true;
      }
      throw MissingPluginException(call.method);
    });

    await pumpExport(tester);
    await openExport(tester);
    expect(find.text('Automatic'), findsOneWidget);
    expect(
      find.textContaining(
          '1 entry has no exportable local file and will be skipped.'),
      findsOneWidget,
    );
    expect(writes, isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(writes, [
      {
        'token': 'test-output',
        'text': '#EXTM3U\n../Music/second.mp3\n../Music/first.mp3\n'
            '../Music/first.mp3\n',
      }
    ]);
    expect(tester.takeException(), isNull);

    await reviewPathFormats(tester);
    await reviewCancellation(tester);
  });
}
