import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/local_music_library.dart';
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

  const tree = 'content://documents/tree/primary%3AMusic';
  const first = '$tree/document/primary%3AMusic%2Ffirst.mp3';
  const second = '$tree/document/primary%3AMusic%2Fsecond.mp3';

  setUp(() async {
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
              second: {'volume': 'primary', 'path': 'Music/second.mp3'},
            },
            'roots': {'primary': '/storage/emulated/0'},
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

  testWidgets(
      'phone import and export review missing files and preserve repeats',
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

    final firstProof = 'a' * 64;
    final firstId = 'device:playlist:$firstProof';
    final secondProof = 'b' * 64;
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
    await tester.tap(find.text('Export review'));
    await tester.pumpAndSettle();
    expect(
      find.text('1 entry has no exportable local file and will be skipped.'),
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
  });
}
