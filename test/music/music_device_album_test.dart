import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/screens/music_device_album.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout(), profileId: db.profileId));

  void switchSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  List<LocalMusicTrack> queue = [];
  int? start;
  String? source;

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool songTap = false,
      bool collectionDetail = false}) async {
    queue = tracks;
    start = startIndex;
    source = queueTitle;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const filesChannel = MethodChannel('videre/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const tree = 'content://provider/tree/music';
  final albumKey = 'a' * 64;
  final otherAlbumKey = 'b' * 64;
  final editedAlbumKey = 'c' * 64;
  final stableFileKey = 'd' * 64;
  final anchorId = 'device:$stableFileKey';
  late _App app;
  late _Player player;
  late LocalMusicLibrary library;
  late List<Map<String, Object>> rows;
  late String selection;
  late bool granted;
  late int scans;
  late List<Object?> tagReads;
  late List<Object?> tagWrites;
  late FutureOr<Object?> Function(Map<Object?, Object?>) writeTags;
  Completer<bool>? checkingAccess;

  Map<String, Object> song(int index) => {
        'uri': '$tree/document/$index',
        'title': index == 39 || index == 40 ? 'Reprise' : 'Song $index',
        'album': 'Live',
        'artist': 'Guest $index',
        'albumArtist': 'The ensemble',
        'albumKey': albumKey,
        if (index == 40) 'identityKey': stableFileKey,
      };

  Map<String, Object> editableSong(int index, int trackNumber) => {
        ...song(index),
        'title': 'Track $trackNumber',
        'fileName': 'track$trackNumber.mp3',
        'trackNumber': trackNumber,
        'discNumber': 1,
        'canEditTags': true,
      };

  String revisionFor(int index) => index.toRadixString(16).padLeft(64, '0');

  Map<String, Object?> savedTags(Map<Object?, Object?> arguments) {
    final row = rows.singleWhere((row) => row['uri'] == arguments['uri']);
    final changes = Map<String, Object?>.from(arguments['changes']! as Map);
    for (final field in ['trackNumber', 'discNumber']) {
      if (changes[field] case final String value) {
        changes[field] = int.parse(value);
      }
    }
    return {
      ...row,
      ...changes,
      if (changes.containsKey('album')) 'albumKey': editedAlbumKey,
    };
  }

  Map<String, Object?> tagTarget(int index) => {
        'treeUri': tree,
        'selectionId': selection,
        'uri': '$tree/document/$index',
      };
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _Player();
    library = LocalMusicLibrary(visibilityDatabase: () => db);
    granted = true;
    scans = 0;
    tagReads = [];
    tagWrites = [];
    writeTags = savedTags;
    checkingAccess = null;
    selection = 'original';
    rows = [
      for (var i = 0; i < 50; i++) song(i),
      {...song(80), 'albumKey': otherAlbumKey, 'title': 'Other edition'},
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
        case 'pickFolder':
          return {'uri': tree, 'name': 'Music', 'selectionId': selection};
        case 'checkFolderAccess':
          return checkingAccess?.future ?? granted;
        case 'listTracks':
          scans++;
          return rows;
        case 'readTrackTags':
          tagReads.add(call.arguments);
          final uri = call.arguments['uri'] as String;
          final row = rows.singleWhere((row) => row['uri'] == uri);
          final values = {
            'title': row['title'],
            'album': row['album'],
            'artist': row['artist'],
            'albumArtist': row['albumArtist'],
            'trackNumber': row['trackNumber']?.toString(),
            'trackTotal': '8',
            'discNumber': row['discNumber']?.toString(),
            'discTotal': '2',
            if (row.containsKey('genre')) 'genre': row['genre'],
            if (row.containsKey('releaseDate'))
              'releaseDate': row['releaseDate'],
          };
          return {
            'revision': revisionFor(int.parse(uri.split('/').last)),
            'values': values,
            'editableFields': values.keys.toList(),
            if (row['id3Version'] case final int version) 'id3Version': version,
            'artworkEditable': true,
            'hasArtwork': true,
          };
        case 'editTrackTags':
          tagWrites.add(call.arguments);
          return writeTags(Map<Object?, Object?>.from(call.arguments as Map));
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

  Future<void> show(WidgetTester tester,
      {bool settle = true,
      bool fromLibrary = false,
      bool anchored = true}) async {
    final album = MusicDeviceAlbumPage(
        selectionId: 'original',
        playbackId: anchored ? anchorId : null,
        albumKey: albumKey,
        library: library);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: fromLibrary
            ? Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(builder: (_) => album)),
                        child: const Text('Open device album'))))
            : album,
      ),
    ));
    if (fromLibrary) {
      await tester.tap(find.text('Open device album'));
    }
    if (settle) await tester.pumpAndSettle();
  }

  Finder inTagDialog(Finder matching) => find.descendant(
        of: find.byType(AlertDialog),
        matching: matching,
      );

  Future<void> openTagEditor(WidgetTester tester) async {
    await show(tester, fromLibrary: true);
    await tester.tap(find.text('Edit album tags'));
    await tester.pumpAndSettle();
  }

  Future<void> proposeAlbumName(WidgetTester tester) async {
    await tester
        .tap(inTagDialog(find.widgetWithText(CheckboxListTile, 'Album')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('album')), 'Live remaster');
    await tester.pumpAndSettle();
  }

  Future<void> reviewTags(WidgetTester tester) async {
    await tester
        .tap(inTagDialog(find.widgetWithText(FilledButton, 'Review changes')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'album action reviews only its source files and cancel writes nothing',
      (tester) async {
    rows = [
      editableSong(40, 1),
      editableSong(41, 2),
      {...editableSong(80, 1), 'albumKey': otherAlbumKey},
    ];
    await openTagEditor(tester);
    expect(tagReads, [tagTarget(40), tagTarget(41)]);
    await proposeAlbumName(tester);
    await reviewTags(tester);
    expect(find.text('Apply the changes below to 2 source files.'),
        findsOneWidget);
    expect(find.textContaining('Album → Live remaster'), findsNWidgets(2));
    expect(tagWrites, isEmpty);

    await tester.tap(inTagDialog(find.text('Cancel')));
    await tester.pumpAndSettle();

    expect(tagWrites, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(library.trackById(anchorId)?.album, 'Live');
  });

  testWidgets(
    'reviews and applies genre and release date for each album file',
    (tester) async {
      rows = [
        for (final (index, trackNumber, version) in [(40, 1, 3), (41, 2, 4)])
          {
            ...editableSong(index, trackNumber),
            'genre': 'Rock',
            'releaseDate': '1997',
            'id3Version': version,
          },
      ];
      await openTagEditor(tester);

      Future<Finder> enableField(String label, String key) async {
        final toggle = inTagDialog(
          find.widgetWithText(CheckboxListTile, label),
        );
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final field = find.byKey(ValueKey(key));
        await tester.ensureVisible(field);
        return field;
      }

      final genre = await enableField('Genre', 'genre');
      await tester.enterText(genre, 'Soul');
      final release = await enableField('Release date', 'releaseDate');
      await tester.enterText(release, '2023-04');
      await tester.pumpAndSettle();

      final review = inTagDialog(
        find.widgetWithText(FilledButton, 'Review changes'),
      );
      expect(tester.widget<FilledButton>(review).onPressed, isNull);
      expect(tagWrites, isEmpty);

      await tester.enterText(release, '2023-04-19');
      await tester.pumpAndSettle();
      await reviewTags(tester);
      expect(
        find.text('Apply the changes below to 2 source files.'),
        findsOneWidget,
      );
      expect(find.textContaining('Genre → Soul'), findsNWidgets(2));
      expect(
        find.textContaining('Release date → 2023-04-19'),
        findsNWidgets(2),
      );
      expect(tagWrites, isEmpty);

      await tester.tap(inTagDialog(find.text('Apply changes')));
      await tester.pumpAndSettle();

      expect(tagWrites, [
        for (final index in [40, 41])
          {
            ...tagTarget(index),
            'revision': revisionFor(index),
            'changes': {'genre': 'Soul', 'releaseDate': '2023-04-19'},
          },
      ]);
      expect(find.textContaining('Tags saved'), findsNWidgets(2));
      expect(library.tracks.map((track) => track.genre), ['Soul', 'Soul']);
      expect(library.tracks.map((track) => track.releaseDate), [
        '2023-04-19',
        '2023-04-19',
      ]);
    },
  );

  testWidgets(
      'combines reviewed edits and reports each file after a partial failure',
      (tester) async {
    rows = [
      editableSong(40, 1),
      editableSong(41, 2),
      editableSong(42, 3),
      editableSong(43, 4),
    ];
    writeTags = (arguments) {
      if (arguments['uri'] == '$tree/document/41') {
        throw PlatformException(code: 'TAGS_NO_SPACE');
      }
      return savedTags(arguments);
    };
    final artwork = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUB'
      'AScY42YAAAAASUVORK5CYII=',
    );
    var picks = 0;
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      expect(call.method, 'openPlaylistCover');
      expect(call.arguments, isNull);
      picks++;
      return artwork;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(filesChannel, null));

    await openTagEditor(tester);
    await proposeAlbumName(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final editorScroll = inTagDialog(find.byType(Scrollable)).first;
    final cover = inTagDialog(
      find.widgetWithText(TextButton, 'Choose front cover'),
    );
    await tester.scrollUntilVisible(cover.hitTestable(), 100,
        scrollable: editorScroll);
    await tester.tap(cover);
    await tester.pumpAndSettle();
    expect(picks, 1);

    final number = find.byKey(ValueKey((anchorId, 'trackNumber')));
    await tester.scrollUntilVisible(number, 100, scrollable: editorScroll);
    await tester.enterText(number, '7');
    final disc = find.byKey(ValueKey((anchorId, 'discNumber')));
    await tester.ensureVisible(disc);
    await tester.enterText(disc, '2');
    final excluded =
        inTagDialog(find.widgetWithText(CheckboxListTile, 'Track 3'));
    await tester.scrollUntilVisible(excluded, 100, scrollable: editorScroll);
    await tester.tap(excluded);
    await tester.pumpAndSettle();

    await reviewTags(tester);
    expect(find.text('Apply the changes below to 3 source files.'),
        findsOneWidget);
    expect(find.textContaining('Track number → 7'), findsOneWidget);
    expect(find.textContaining('Disc number → 2'), findsOneWidget);
    expect(find.textContaining('Replace front cover'), findsNWidgets(3));
    expect(tagWrites, isEmpty);

    await tester.tap(inTagDialog(find.text('Apply changes')));
    await tester.pumpAndSettle();

    expect(tagWrites, [
      for (final index in [40, 41, 43])
        {
          ...tagTarget(index),
          'revision': revisionFor(index),
          'changes': {
            'album': 'Live remaster',
            if (index == 40) ...{'trackNumber': '7', 'discNumber': '2'},
          },
          'artwork': artwork,
        },
    ]);
    expect(find.text('Album tag results'), findsOneWidget);
    expect(find.textContaining('Tags saved'), findsNWidgets(2));
    expect(
        find.textContaining('exceed the available tag space'), findsOneWidget);
    expect(find.textContaining('Not selected'), findsOneWidget);
    expect(library.trackById(anchorId)?.album, 'Live remaster');
    expect(library.trackById(anchorId)?.artist, 'Guest 40');
    expect(library.trackById(anchorId)?.trackNumber, 7);
    expect(
      {for (final track in library.tracks) track.uri: track.album},
      const {
        '$tree/document/40': 'Live remaster',
        '$tree/document/41': 'Live',
        '$tree/document/42': 'Live',
        '$tree/document/43': 'Live remaster',
      },
    );
  });

  testWidgets('stop waits for the current file and skips the remaining write',
      (tester) async {
    rows = [editableSong(40, 1), editableSong(41, 2)];
    final authorization = Completer<Object?>();
    Map<Object?, Object?>? pendingWrite;
    writeTags = (arguments) {
      pendingWrite = arguments;
      return authorization.future;
    };
    await openTagEditor(tester);
    await proposeAlbumName(tester);
    await reviewTags(tester);

    await tester.tap(inTagDialog(find.text('Apply changes')));
    await tester.pump();
    expect(tagWrites, hasLength(1));
    final stop =
        inTagDialog(find.widgetWithText(TextButton, 'Stop after current file'));
    await tester.tap(stop);
    await tester.pump();
    expect(tester.widget<TextButton>(stop).onPressed, isNull);
    expect(tagWrites, hasLength(1));

    authorization.complete(savedTags(pendingWrite!));
    await tester.pumpAndSettle();

    expect(tagWrites, hasLength(1));
    expect(find.text('Album tag results'), findsOneWidget);
    expect(find.textContaining('Tags saved'), findsOneWidget);
    expect(find.textContaining('Stopped before writing this file'),
        findsOneWidget);
  });

  testWidgets('browse opens one edition and plays in disc and track order',
      (tester) async {
    rows = [
      {
        ...song(21),
        'discNumber': 2,
        'discSubtitle': 'Rarities',
        'trackNumber': 1
      },
      {...song(10), 'discNumber': 1, 'trackNumber': 10},
      {...song(2), 'discNumber': 1, 'trackNumber': 2, 'releaseDate': '1997-09'},
      {...song(80), 'albumKey': otherAlbumKey, 'title': 'Other edition'},
    ];
    await show(tester, fromLibrary: true, anchored: false);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('The ensemble'), findsOneWidget);
    expect(find.text('1997-09'), findsOneWidget);
    expect(find.text('Other edition'), findsNothing);
    expect(find.text('Disc 1'), findsOneWidget);
    expect(find.text('Disc 2 · Rarities'), findsOneWidget);
    expect(find.text('1.2'), findsOneWidget);
    expect(find.text('1.10'), findsOneWidget);
    expect(find.text('2.1'), findsOneWidget);
    final first = find.text('Song 2');
    final next = find.text('Song 10');
    final last = find.text('Song 21');
    expect(tester.getTopLeft(find.text('Disc 1')).dy,
        lessThan(tester.getTopLeft(first).dy));
    expect(tester.getTopLeft(find.text('Disc 2 · Rarities')).dy,
        lessThan(tester.getTopLeft(last).dy));
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(next).dy));
    expect(tester.getTopLeft(next).dy, lessThan(tester.getTopLeft(last).dy));
    expect(player.queue, isEmpty);

    await tester.tap(next);
    await tester.pumpAndSettle();
    final expected = [
      '$tree/document/2',
      '$tree/document/10',
      '$tree/document/21',
    ];
    expect(player.queue.map((track) => track.uri), expected);
    expect(player.start, 1);
    expect(player.source, 'Live');

    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.queue.map((track) => track.uri), expected);
    expect(player.start, 0);
  });

  testWidgets('opens and reveals the selected file before any play action',
      (tester) async {
    await show(tester);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('The ensemble'), findsOneWidget);
    final anchor = find.byKey(ValueKey(anchorId)).hitTestable();
    expect(tester.widget<ListTile>(anchor).selected, isTrue);
    expect(find.text('Reprise').hitTestable(), findsNWidgets(2));
    expect(player.queue, isEmpty);
    final neighbor =
        library.tracks.firstWhere((track) => track.uri.endsWith('/39'));
    final neighborTile =
        find.byKey(ValueKey(neighbor.playbackId)).hitTestable();
    expect(tester.widget<ListTile>(neighborTile).selected, isFalse);
    await tester.tap(neighborTile);
    await tester.pumpAndSettle();
    expect(player.queue.length, 50);
    expect(player.queue.every((track) => track.albumKey == albumKey), isTrue);
    expect(player.queue[player.start!].playbackId, neighbor.playbackId);
    expect(player.source, 'Live');
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.start, 0);
  });

  testWidgets('tablet album keeps its track viewport when returning to phone',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await show(tester, fromLibrary: true);

    final details = find.byKey(const ValueKey('music-collection-details-pane'));
    final trackList = find.byType(ListView);
    final albumArtist = find.text('The ensemble');
    final anchor = find.byKey(ValueKey(anchorId)).hitTestable();
    expect(details, findsOneWidget);
    expect(tester.widget<ListTile>(anchor).selected, isTrue);
    expect(tester.getTopLeft(trackList).dx,
        greaterThan(tester.getTopRight(albumArtist).dx));
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    expect(player.queue.length, 50);
    expect(player.queue[player.start!].playbackId, anchorId);
    expect(player.source, 'Live');

    final controller = tester.widget<ListView>(trackList).controller!;
    final initialOffset = controller.offset;
    final artistPosition = tester.getTopLeft(albumArtist);
    await tester.drag(trackList, const Offset(0, 240));
    await tester.pumpAndSettle();
    final scrolledOffset = controller.offset;
    expect(scrolledOffset, lessThan(initialOffset));
    expect(tester.getTopLeft(albumArtist), artistPosition);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(tester.widget<ListView>(trackList).controller, same(controller));
    expect(controller.offset, closeTo(scrolledOffset, 1));
    expect(find.text('Play all').hitTestable(), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open device album'), findsOneWidget);
    expect(player.queue[player.start!].playbackId, anchorId);
  });

  testWidgets('a hidden playing file still opens its visible album members',
      (tester) async {
    rows = [
      song(39),
      {...song(40), 'visibilityKey': stableFileKey},
      song(41),
    ];
    await show(tester);
    expect(find.byKey(ValueKey(anchorId)), findsOneWidget);
    final anchor = library.trackById(anchorId)!;
    final hidden = await tester.runAsync(() => library.hideTrack(anchor));
    expect(hidden, isNotNull);
    await tester.pumpAndSettle();
    expect(find.text('Live'), findsOneWidget);
    expect(find.byKey(ValueKey(anchorId)), findsNothing);
    expect(find.text('Reprise'), findsOneWidget);
    expect(find.text('Song 41'), findsOneWidget);

    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.queue.map((track) => track.uri),
        ['$tree/document/39', '$tree/document/41']);
    expect(player.start, 0);
    expect(player.source, 'Live');
    expect(library.trackById(anchorId)?.uri, '$tree/document/40');
  });

  testWidgets(
      'TV opens with the captured file focused and Down moves to the next track',
      (tester) async {
    final wasTv = app_globals.isTv;
    addTearDown(() => app_globals.isTv = wasTv);
    app_globals.isTv = true;
    rows = [
      for (var index = 0; index < 50; index++)
        {
          ...song(index),
          'discNumber': index <= 40 ? 1 : 2,
          'trackNumber': index <= 40 ? index + 1 : index - 40,
          'discSubtitle': index <= 40 ? 'Main' : 'Rarities',
        },
    ];
    await show(tester);
    expect(Focus.of(tester.element(find.text('Guest 40'))).hasFocus, isTrue);
    expect(find.text('Disc 2 · Rarities').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('Guest 41'))).hasFocus, isTrue);
    expect(player.queue, isEmpty);
  });

  testWidgets(
      'retries a lost grant, then rejects a different selection with identical files',
      (tester) async {
    await show(tester);
    granted = false;
    await library.revalidate();
    await tester.pumpAndSettle();
    expect(find.text('Live'), findsNothing);
    expect(
        find.textContaining('Access to this folder was lost'), findsOneWidget);
    expect(find.text('Play all'), findsNothing);
    granted = true;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(anchorId)).hitTestable(), findsOneWidget);
    expect(scans, 2);
    selection = 'replacement';
    await library.chooseFolder();
    await tester.pumpAndSettle();
    expect(find.text('Live'), findsNothing);
    final previousScans = scans;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(scans, previousScans);
    expect(find.text('Play all'), findsNothing);
    expect(player.queue, isEmpty);
  });

  testWidgets(
      'rejects the same file retagged to a different edition and recovers after rescan',
      (tester) async {
    rows[40] = {...rows[40], 'albumKey': otherAlbumKey};
    await show(tester);
    expect(find.text('Live'), findsNothing);
    expect(find.text('No results found.'), findsOneWidget);
    expect(find.text('The ensemble'), findsNothing);
    rows[40] = song(40);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(anchorId)).hitTestable(), findsOneWidget);
    expect(player.queue, isEmpty);
  });

  testWidgets(
      'profile switch during access check never reveals or scans the album',
      (tester) async {
    checkingAccess = Completer<bool>();
    await show(tester, settle: false);
    await tester.pump();
    app.switchSession();
    checkingAccess!.complete(true);
    await tester.pumpAndSettle();
    expect(scans, 0);
    expect(find.text('Live'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Play all'), findsNothing);
    expect(player.queue, isEmpty);
  });
}
