import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/device_music_artwork_preferences.dart';
import 'package:clipious/music/models/local_music_album.dart';
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/device_music_artwork.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout(), profileId: db.profileId));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final queues = <({List<LocalMusicTrack> tracks, int start, String? title})>[];
  bool? lastSongTap;

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool songTap = false,
      bool collectionDetail = false}) async {
    queues.add((tracks: List.of(tracks), start: startIndex, title: queueTitle));
    lastSongTap = songTap;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String artworkPath(String filename) => File('assets/$filename')
      .absolute
      .path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'^[A-Za-z]:'), '');

  Iterable<ResizeImage> visibleThumbnails(WidgetTester tester) => tester
      .widgetList<Image>(find.descendant(
        of: find.byType(DeviceMusicCoverMosaic),
        matching: find.byType(Image),
      ))
      .map((image) => image.image as ResizeImage);

  Future<
      ({
        LocalMusicLibrary library,
        _Player player,
        Future<void> Function() reopen,
      })> showLibrary(
    WidgetTester tester, {
    required String source,
    required List<Map<String, Object>> tracks,
    bool Function()? hasAccess,
    String? additionalFolder,
    List<Map<String, Object>>? additionalTracks,
    List<Map<String, Object>>? playlists,
    Object? Function(MethodCall)? handleTagCall,
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
            return additionalTracks ??
                [
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
        case 'readTrackTags':
        case 'editTrackTags':
          if (handleTagCall != null) return handleTagCall(call);
          throw MissingPluginException(call.method);
        default:
          throw MissingPluginException(call.method);
      }
    });

    Future<void> reopen() async {
      final settings = TestSettingsCubit(SettingsState.init(), app);
      addTearDown(settings.close);
      await tester.pumpWidget(MultiBlocProvider(
        key: ObjectKey(settings),
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: settings),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: LocalMusicFolder.library(library: library)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    await reopen();
    return (library: library, player: player, reopen: reopen);
  }

  testWidgets('artist and genre indexes remember independent visible totals',
      (tester) async {
    const revoked = 'content://provider/tree/revoked';
    const retained = 'content://other.provider/tree/retained';
    const ambient = ('Ada', 'Ambient');
    const blues = ('Bea', 'Blues');
    const classical = ('Cleo', 'Classical');
    const disco = ('Dora', 'Disco');
    var granted = true;

    Map<String, Object> song(
      String root,
      int id,
      String title,
      (String, String) group, {
      int? durationMs,
      String? visibilityKey,
    }) =>
        {
          'uri': '$root/document/$id',
          'title': title,
          'artist': group.$1,
          'genre': group.$2,
          if (durationMs != null) 'durationMs': durationMs,
          if (visibilityKey != null) 'visibilityKey': visibilityKey,
        };

    final (:library, :player, :reopen) = await showLibrary(
      tester,
      source: revoked,
      hasAccess: () => granted,
      tracks: [
        song(revoked, 1, 'Ambient session', ambient, durationMs: 200000),
        song(revoked, 2, 'Ambient recording', ambient),
        song(revoked, 3, 'Disco session', disco, durationMs: 120000),
      ],
      additionalFolder: retained,
      additionalTracks: [
        song(retained, 1, 'Ambient single', ambient, durationMs: 50000),
        song(retained, 2, 'Blues single', blues, durationMs: 40000),
        song(retained, 3, 'Blues recording', blues),
        song(retained, 4, 'Classical recording', classical),
        song(retained, 5, 'Hidden blues', blues,
            durationMs: 500000, visibilityKey: 'c' * 64),
      ],
    );

    Future<void> tap(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    Future<void> back() async {
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    Future<void> sortBy(String choice) async {
      await tester.tap(find.byTooltip('Sort by'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(
          CheckedPopupMenuItem<Future<void> Function()>, choice));
      await tester.pumpAndSettle();
    }

    void expectOrder(List<String> expected) {
      final byPosition = [...expected]..sort((first, second) => tester
          .getTopLeft(find.text(first))
          .dy
          .compareTo(tester.getTopLeft(find.text(second)).dy));
      expect(byPosition, expected);
    }

    final hidden = library.visibleTracks.singleWhere(
      (track) => track.title == 'Hidden blues',
    );
    expect(await tester.runAsync(() => library.hideTrack(hidden)), isNotNull);
    await tester.pumpAndSettle();

    await tap('Genres');
    await tap('Blues');
    await tap('Blues recording');
    final queue = player.queues.single;
    expect(queue.tracks.map((track) => track.title),
        ['Blues single', 'Blues recording']);
    expect(queue.start, 1);
    await back();
    await back();

    await tap('Artists');
    expectOrder(['Ada', 'Bea', 'Cleo', 'Dora']);
    await sortBy('Duration');
    expectOrder(['Bea', 'Dora', 'Ada', 'Cleo']);
    await sortBy('Descending');
    expectOrder(['Ada', 'Dora', 'Bea', 'Cleo']);
    await sortBy('Song count');
    expectOrder(['Ada', 'Bea', 'Cleo', 'Dora']);
    await sortBy('Ascending');
    expectOrder(['Cleo', 'Dora', 'Bea', 'Ada']);
    await sortBy('Descending');
    await back();

    await tap('Genres');
    expectOrder(['Ambient', 'Blues', 'Classical', 'Disco']);
    await sortBy('Song count');
    expectOrder(['Classical', 'Disco', 'Blues', 'Ambient']);
    await sortBy('Descending');
    expectOrder(['Ambient', 'Blues', 'Classical', 'Disco']);
    await sortBy('Duration');
    expectOrder(['Ambient', 'Disco', 'Blues', 'Classical']);
    await sortBy('Ascending');
    expectOrder(['Blues', 'Disco', 'Ambient', 'Classical']);

    await reopen();
    await tap('Genres');
    expectOrder(['Blues', 'Disco', 'Ambient', 'Classical']);
    granted = false;
    await library.revalidate();
    await tester.pumpAndSettle();
    expect(find.text('Disco'), findsNothing);
    expectOrder(['Blues', 'Ambient', 'Classical']);

    await back();
    await tap('Artists');
    expect(find.text('Dora'), findsNothing);
    expectOrder(['Bea', 'Ada', 'Cleo']);
    expect(player.queues, [queue]);
  });

  testWidgets('genre mosaic hides cached artwork after revocation or opt-out',
      (tester) async {
    const source = 'content://provider/tree/music';
    const other = 'content://provider/tree/other';
    final revokedArt = artworkPath('icon.png');
    final keptArt = artworkPath('icon-with-background.png');
    var granted = true;
    final (:library, player: _, reopen: _) = await showLibrary(
      tester,
      source: source,
      additionalFolder: other,
      hasAccess: () => granted,
      tracks: [
        for (var i = 0; i < 3; i++)
          {
            'uri': '$source/document/$i',
            'title': 'Track $i',
            'genre': 'Jazz',
            'album': 'Jazz release $i',
            'albumKey': (i < 2 ? 'a' : 'b') * 64,
            'artPath': revokedArt,
          },
      ],
      additionalTracks: [
        {
          'uri': '$other/document/authorized',
          'title': 'Authorized track',
          'genre': 'jazz',
          'album': 'Quartet',
          'albumKey': 'c' * 64,
          'artPath': keptArt,
        },
      ],
    );
    List<String> covers() => visibleThumbnails(tester)
        .map((image) => (image.imageProvider as FileImage).file.path)
        .toList();
    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    final jazz = find.textContaining(RegExp(r'^jazz$', caseSensitive: false));
    expect(jazz, findsOneWidget);
    expect(covers(), [revokedArt, keptArt]);

    granted = false;
    await library.revalidate();
    await tester.pumpAndSettle();
    expect(jazz, findsOneWidget);
    expect(File('assets/icon.png').existsSync(), isTrue);
    expect(covers(), [keptArt]);

    await tester
        .runAsync(() => DeviceMusicArtworkPreferences.setLoadCovers(db, false));
    await tester.pumpAndSettle();
    expect(jazz, findsOneWidget);
    expect(covers(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist index keeps thumbnail requests bounded during scrolling',
      (tester) async {
    const source = 'content://provider/tree/music';
    final artwork = artworkPath('icon.png');
    await showLibrary(
      tester,
      source: source,
      tracks: [
        for (var i = 100; i < 220; i++)
          {
            'uri': '$source/document/$i',
            'title': 'Track $i',
            'artist': 'Artist $i',
            'album': 'Release $i',
            'albumKey': i.toRadixString(16).padLeft(64, '0'),
            'artPath': artwork,
          },
      ],
    );
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.text('Artist 100'), findsOneWidget);
    expect(find.text('Artist 219'), findsNothing);
    expect(visibleThumbnails(tester).length, lessThan(40));

    await tester.scrollUntilVisible(find.text('Artist 219'), 500,
        maxScrolls: 25);
    await tester.pumpAndSettle();
    expect(find.text('Artist 100'), findsNothing);
    expect(find.text('Artist 219'), findsOneWidget);
    final thumbnails = visibleThumbnails(tester).toList();
    expect(thumbnails, isNotEmpty);
    expect(thumbnails.length, lessThan(40));
    expect(thumbnails.map((image) => (image.width, image.height)).toSet(),
        {(144, 144)});

    expect(tester.takeException(), isNull);
  });

  testWidgets('genre pages queue only the current visible genre members',
      (tester) async {
    const source = 'content://provider/tree/music';
    var granted = true;
    final (:library, :player, reopen: _) = await showLibrary(tester,
        source: source,
        hasAccess: () => granted,
        tracks: [
          {
            'uri': '$source/document/1',
            'title': 'Shared title',
            'genre': 'Jazz; Ambient',
            'genres': ['Jazz', 'Ambient', 'jazz'],
            'visibilityKey': 'a' * 64,
          },
          {
            'uri': '$source/document/2',
            'title': 'Quiet piano',
            'artist': 'Jazz pianist',
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
    expect(find.text('Jazz; Ambient'), findsNothing);
    await tester.tap(find.text('Ambient'));
    await tester.pumpAndSettle();
    expect(find.text('Shared title'), findsOneWidget);
    expect(find.text('Quiet piano'), findsNothing);
    await tester.pageBack();
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
    expect(player.lastSongTap, isTrue);
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

  testWidgets(
      'genre artist links use visible credits and preserve scroll on Back',
      (tester) async {
    const source = 'content://provider/tree/music';
    final (:library, player: _, reopen: _) = await showLibrary(
      tester,
      source: source,
      tracks: [
        for (var index = 0; index < 18; index++)
          {
            'uri': '$source/document/filler-$index',
            'title': 'Filler track $index',
            'artist': 'Filler artist $index',
            'genre': 'Jazz',
          },
        {
          'uri': '$source/document/guest',
          'title': 'Guest performance',
          'artist': 'Guest Soloist',
          'albumArtist': 'House Band',
          'genre': 'Jazz',
        },
        {
          'uri': '$source/document/guest-live',
          'title': 'Live performance',
          'artist': ' guest soloist ',
          'genre': 'jazz',
        },
        {
          'uri': '$source/document/hidden',
          'title': 'Private recording',
          'artist': 'Hidden Soloist',
          'genre': 'Jazz',
          'visibilityKey': 'c' * 64,
        },
        {
          'uri': '$source/document/rock',
          'title': 'Rock recording',
          'artist': 'Genre Visitor',
          'genre': 'Rock',
        },
      ],
    );

    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    final jazz = find.textContaining(RegExp(r'^jazz$', caseSensitive: false));
    await tester.tap(jazz);
    await tester.pumpAndSettle();

    expect(find.text('Artists'), findsOneWidget);
    Finder artistRow(String name) => find.byWidgetPredicate((widget) {
          if (widget is! ListTile) return false;
          final title = widget.title;
          return title is Text && title.data?.trim().toLowerCase() == name;
        }, description: 'artist row for $name');

    final guest = artistRow('guest soloist');
    final hidden = artistRow('hidden soloist');
    final scrollable = find.descendant(
        of: find.byType(ListView), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(hidden, 250, scrollable: scrollable);
    expect(hidden, findsOneWidget);
    expect(artistRow('house band'), findsOneWidget);
    await tester.ensureVisible(guest);
    await tester.pumpAndSettle();
    expect(guest, findsOneWidget);
    expect(artistRow('genre visitor'), findsNothing);
    final scrollOffset =
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(scrollOffset, greaterThan(0));

    await tester.tap(guest);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.textContaining(
          RegExp(r'^guest soloist$', caseSensitive: false),
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('Guest performance'), findsOneWidget);
    expect(find.text('Live performance'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(jazz, findsOneWidget);
    expect(guest, findsOneWidget);
    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        scrollOffset);

    final hiddenTrack = library.visibleTracks.firstWhere(
      (track) => track.uri == '$source/document/hidden',
    );
    expect(
      await tester.runAsync(() => library.hideTrack(hiddenTrack)),
      isNotNull,
    );
    await tester.pumpAndSettle();
    expect(hidden, findsNothing);
    expect(guest, findsOneWidget);
  });

  testWidgets('device library opens genres for rows with only indexed values',
      (tester) async {
    const source = 'content://provider/tree/music';
    await showLibrary(tester, source: source, tracks: [
      {
        'uri': '$source/document/1',
        'title': 'Native genre track',
        'genres': ['Folk', 'Blues'],
      },
    ]);

    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    expect(find.text('Folk'), findsOneWidget);
    await tester.tap(find.text('Blues'));
    await tester.pumpAndSettle();
    expect(find.text('Native genre track'), findsOneWidget);
  });

  testWidgets('tag saves update the active genre and artist releases',
      (tester) async {
    const source = 'content://provider/tree/music';
    const song = {
      'uri': '$source/document/1',
      'title': 'Opening song',
      'artist': 'The Quartet',
      'album': 'Late Night',
      'genre': 'Jazz',
      'releaseDate': '1997',
      'canEditTags': true,
    };
    final trackData = {...song, 'albumKey': 'a' * 64};
    final revision = 'b' * 64;
    const changes = {'genre': 'Fusion', 'releaseDate': '1997-11'};
    final (:library, :player, reopen: _) = await showLibrary(
      tester,
      source: source,
      tracks: [trackData],
      handleTagCall: (call) {
        const target = {
          'treeUri': source,
          'selectionId': 'selected-music',
          'uri': '$source/document/1',
        };
        if (call.method == 'readTrackTags') {
          expect(call.arguments, target);
          const values = {
            'title': 'Opening song',
            'artist': 'The Quartet',
            'album': 'Late Night',
            'albumArtist': null,
            'genre': 'Jazz',
            'releaseDate': '1997',
          };
          return {
            'revision': revision,
            'values': values,
            'editableFields': values.keys.toList(),
            'id3Version': 4,
          };
        }
        expect(call.arguments,
            {...target, 'revision': revision, 'changes': changes});
        return {...trackData, ...changes};
      },
    );

    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jazz'));
    await tester.pumpAndSettle();
    expect(find.text('Opening song'), findsOneWidget);

    final track = library.visibleTracks.single;
    final original = (await library.readTags(track))!;
    expect(await library.editTags(track, original, changes), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Opening song'), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Jazz'), findsNothing);
    await tester.tap(find.text('Fusion'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opening song'));
    await tester.pumpAndSettle();
    expect(player.queues.single.tracks.single.playbackId, track.playbackId);
    expect(player.queues.single.title, 'Fusion');

    final artist = groupLocalMusicArtists(library.visibleTracks).single;
    expect(artist.name, 'The Quartet');
    expect(groupLocalMusicAlbums(artist.tracks).single.releaseDate, '1997-11');
  });

  testWidgets('indexed playlists keep exact volumes and duplicate occurrences',
      (tester) async {
    const source = 'content://media/external/audio/media';
    const primary = 'content://media/external_primary/audio/media';
    const anotherVolume = 'content://media/OtherVolume/audio/media';
    const folder = 'content://provider/tree/folder';
    var granted = true;
    final (:library, :player, reopen: _) = await showLibrary(
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
    expect(player.lastSongTap, isTrue);
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

  testWidgets('genre details stay beside scrolling songs on a wide tablet',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const source = 'content://provider/tree/music';
    final (:player, library: _, reopen: _) = await showLibrary(
      tester,
      source: source,
      tracks: [
        {
          'uri': '$source/document/ambient',
          'title': 'Unrelated track',
          'genre': 'Ambient',
        },
        for (var index = 0; index < 32; index++)
          {
            'uri': '$source/document/jazz-$index',
            'title': 'Jazz recording $index',
            'artist': 'Quartet',
            'genre': 'Jazz',
          },
      ],
    );

    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    final title = find.text('Jazz');
    await tester.tap(title);
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('music-collection-details-pane'));
    final tracks = find.byType(ListView);
    final playAll = find.text('Play all');
    expect(find.descendant(of: details, matching: title), findsOneWidget);
    expect(find.descendant(of: details, matching: playAll), findsOneWidget);
    expect(
        tester.getRect(details).right, lessThan(tester.getRect(tracks).left));
    final scrollable =
        find.descendant(of: tracks, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    final titlePosition = tester.getTopLeft(title);
    final actionPosition = tester.getTopLeft(playAll);

    await tester.drag(tracks, const Offset(0, -260));
    await tester.pumpAndSettle();
    final offset = position.pixels;
    expect(offset, greaterThan(0));
    expect(tester.getTopLeft(title), titlePosition);
    expect(tester.getTopLeft(playAll), actionPosition);

    tester.view.physicalSize = const Size(640, 960);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(find.descendant(of: find.byType(AppBar), matching: title),
        findsOneWidget);
    expect(playAll.hitTestable(), findsOneWidget);
    expect(tester.state<ScrollableState>(scrollable).position, same(position));
    expect(position.pixels, closeTo(offset, 1));

    tester.view.physicalSize = const Size(960, 640);
    await tester.pumpAndSettle();
    expect(find.descendant(of: details, matching: title), findsOneWidget);
    expect(tester.state<ScrollableState>(scrollable).position, same(position));
    expect(position.pixels, closeTo(offset, 1));
    await tester.tap(playAll);
    await tester.pumpAndSettle();
    expect(player.queues.single.title, 'Jazz');
    expect(player.queues.single.tracks, hasLength(32));
    expect(player.queues.single.tracks.map((track) => track.title),
        isNot(contains('Unrelated track')));
  });

  testWidgets('indexed playlist keeps its entries from phone to tablet',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const source = 'content://media/external/audio/media';
    const primary = 'content://media/external_primary/audio/media';
    final (:player, library: _, reopen: _) = await showLibrary(
      tester,
      source: source,
      tracks: [
        {'uri': '$primary/1', 'title': 'Opening song'},
        {'uri': '$primary/2', 'title': 'Looped song'},
      ],
      playlists: [
        {
          'id': 1,
          'name': 'Road set',
          'memberUris': ['$primary/2', '$primary/1', '$primary/2'],
        },
      ],
    );

    await tester.tap(find.text('Device playlists'));
    await tester.pumpAndSettle();
    final title = find.text('Road set');
    await tester.tap(title);
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('music-collection-details-pane'));
    final repeated = find.text('Looped song');
    final opening = find.text('Opening song');
    expect(details, findsNothing);
    expect(find.descendant(of: find.byType(AppBar), matching: title),
        findsOneWidget);
    expect(find.text('Play all').hitTestable(), findsOneWidget);
    expect(repeated.hitTestable(), findsNWidgets(2));
    expect(tester.getTopLeft(repeated.first).dy,
        lessThan(tester.getTopLeft(opening).dy));
    expect(tester.getTopLeft(opening).dy,
        lessThan(tester.getTopLeft(repeated.last).dy));

    tester.view.physicalSize = const Size(960, 640);
    await tester.pumpAndSettle();
    expect(find.descendant(of: details, matching: title), findsOneWidget);
    expect(repeated.hitTestable(), findsNWidgets(2));
    expect(tester.getTopLeft(repeated.first).dy,
        lessThan(tester.getTopLeft(opening).dy));
    expect(tester.getTopLeft(opening).dy,
        lessThan(tester.getTopLeft(repeated.last).dy));
    await tester.tap(repeated.last);
    await tester.pumpAndSettle();

    final queue = player.queues.single;
    expect(queue.title, 'Road set');
    expect(queue.start, 2);
    expect(queue.tracks.map((track) => track.uri),
        ['$primary/2', '$primary/1', '$primary/2']);
  });
}
