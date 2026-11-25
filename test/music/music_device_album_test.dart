import 'dart:async';

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
      {int startIndex = 0, String? queueTitle}) async {
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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const tree = 'content://provider/tree/music';
  final albumKey = 'a' * 64;
  final otherAlbumKey = 'b' * 64;
  final stableFileKey = 'd' * 64;
  final anchorId = 'device:$stableFileKey';
  late _App app;
  late _Player player;
  late LocalMusicLibrary library;
  late List<Map<String, Object>> rows;
  late String selection;
  late bool granted;
  late int scans;
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
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _Player();
    library = LocalMusicLibrary(visibilityDatabase: () => db);
    granted = true;
    scans = 0;
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
      {bool settle = true, bool fromLibrary = false}) async {
    final album = MusicDeviceAlbumPage(
        selectionId: 'original',
        playbackId: anchorId,
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
    await show(tester);
    expect(Focus.of(tester.element(find.text('Guest 40'))).hasFocus, isTrue);
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
