import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/local_music_browse.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_library_search.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/music/views/components/music_playing_device_artists.dart';
import 'package:clipious/music/views/screens/music_device_artist.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout(), profileId: db.profileId));

  void switchSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  @override
  final musicSelectionFailureRevision = ValueNotifier(0);

  @override
  int get playlistGeneration => 0;

  @override
  IdedVideo? get openingMusicEntry => null;

  List<OnDeviceMusicEntry> queue = [];
  String? title;
  int? start;
  bool? lastSongTap;
  bool? lastRetainQueueOrder;
  int playCalls = 0;

  void showTrack(LocalMusicTrack track) => emit(state.copyWith(
        offlineCurrentlyPlaying: localMusicPlaybackEntry(track, db.profileId),
        isAudio: true,
        isHidden: false,
        isMini: false,
      ));

  @override
  Future<void> playOnDeviceMusic(List<OnDeviceMusicEntry> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool collectionDetail = false,
      bool retainQueueOrder = false,
      bool Function()? isCurrent,
      bool songTap = false}) async {
    if (isCurrent?.call() == false) return;
    playCalls++;
    queue = tracks;
    title = queueTitle;
    start = startIndex;
    lastSongTap = songTap;
    lastRetainQueueOrder = retainQueueOrder;
  }

  @override
  Future<void> close() async {
    musicSelectionFailureRevision.dispose();
    await super.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const folder = 'content://provider/tree/music';
  final sharedAlbumKey = 'a' * 64;
  final unrelatedAlbumKey = 'b' * 64;
  final hiddenKey = 'c' * 64;
  late LocalMusicLibrary library;
  late _App app;
  late _Player player;
  late SettingsCubit settings;
  late List<Map<String, Object>> rows;
  late String selection;

  Map<String, Object> song(int id, String title, String artist,
          String? albumArtist, String albumKey) =>
      {
        'uri': '$folder/document/$id',
        'title': title,
        'artist': artist,
        if (albumArtist != null) 'albumArtist': albumArtist,
        'album': 'Live Sessions',
        'albumKey': albumKey,
        if (id == 3) 'visibilityKey': hiddenKey,
      };

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    library = LocalMusicLibrary(visibilityDatabase: () => db);
    app = _App();
    player = _Player();
    settings = TestSettingsCubit(SettingsState.init(), app);
    selection = 'original';
    rows = [
      song(1, 'Guest opening', 'Guest Band', 'The Ensemble', sharedAlbumKey),
      song(2, 'Ensemble performance', 'The Ensemble', 'The Ensemble',
          sharedAlbumKey),
      song(3, 'Guest reprise', 'guest band', 'The Ensemble', sharedAlbumKey),
      song(4, 'Different recording', 'Other', 'Other', unrelatedAlbumKey),
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'getFolder' || 'pickFolder' => {
            'uri': folder,
            'name': 'Music',
            'selectionId': selection,
          },
        'checkFolderAccess' => true,
        'listTracks' => rows,
        'forgetFolder' => null,
        _ => throw MissingPluginException(call.method),
      };
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    library.dispose();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> show(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ));
    await tester.pumpAndSettle();
  }

  test('credits preserve roles and keep literal joint and band names intact',
      () {
    const joint = LocalMusicTrack(
      uri: 'first',
      title: 'First',
      artist: '  A & B feat. C / D ',
      albumArtist: 'Ensemble',
    );
    const same = LocalMusicTrack(
      uri: 'second',
      title: 'Second',
      artist: 'ensemble',
      albumArtist: 'ENSEMBLE',
    );
    const unknown = LocalMusicTrack(
        uri: 'third', title: 'Third', artist: ' <unknown> ', albumArtist: ' ');
    expect(localMusicArtistCredits(joint).map((credit) => credit.name),
        ['A & B feat. C / D', 'Ensemble']);
    expect(localMusicArtistCredits(same).single.roles,
        [LocalMusicArtistRole.trackArtist, LocalMusicArtistRole.albumArtist]);
    expect(localMusicArtistCredits(unknown), isEmpty);
    expect(groupLocalMusicArtists([joint, same, unknown]).length, 2);
    expect(
        findLocalMusicArtist([joint, same], 'ensemble')!.tracks, [joint, same]);
  });

  testWidgets('indexed credits open separate artists and merge their roles',
      (tester) async {
    rows[0] = {
      ...song(1, 'Guest opening', 'AC/DC / Guest Band',
          'guest band / The Ensemble', sharedAlbumKey),
      'artists': ['AC/DC', 'Guest Band', 'guest band'],
      'albumArtists': ['guest band', 'The Ensemble'],
    };
    await show(tester,
        MusicDeviceArtistIndexPage(selectionId: 'original', library: library));

    expect(find.text('AC/DC'), findsOneWidget);
    expect(find.text('The Ensemble'), findsOneWidget);
    expect(find.text('AC/DC / Guest Band'), findsNothing);
    expect(find.text('guest band / The Ensemble'), findsNothing);
    await tester.tap(find.text('Guest Band'));
    await tester.pumpAndSettle();

    expect(find.text('Guest opening'), findsOneWidget);
    expect(find.text('Track artist · Album artist · Live Sessions'),
        findsOneWidget);
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.queue.map((entry) => entry.title),
        ['Guest opening', 'Guest reprise']);
  });

  testWidgets('browse and play a guest contribution or open its exact release',
      (tester) async {
    await show(tester,
        MusicDeviceArtistIndexPage(selectionId: 'original', library: library));
    expect(find.text('Guest Band'), findsOneWidget);
    expect(find.text('The Ensemble'), findsOneWidget);
    await tester.tap(find.text('Guest Band'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Share'), findsNothing);
    expect(find.byTooltip('Open externally'), findsNothing);
    expect(find.text('Guest opening'), findsOneWidget);
    expect(find.text('Guest reprise'), findsOneWidget);
    expect(find.text('Ensemble performance'), findsNothing);
    expect(find.text('Track artist · Live Sessions'), findsNWidgets(2));
    expect(player.queue, isEmpty);

    await tester.tap(find.text('Guest reprise'));
    await tester.pumpAndSettle();
    expect(player.queue.map((entry) => entry.title),
        ['Guest opening', 'Guest reprise']);
    expect(player.start, 1);
    expect(player.title, 'Guest Band');
    expect(player.lastSongTap, isTrue);

    await tester.tap(find.text('Unclassified releases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live Sessions').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Ensemble performance'), findsOneWidget);
    expect(find.text('Different recording'), findsNothing);
    expect(player.start, 1);

    await tester.tap(find.byTooltip('Open artist: The Ensemble'));
    await tester.pumpAndSettle();
    expect(find.text('Album artist · Live Sessions'), findsNWidgets(2));
  });

  testWidgets('artist detail sorts songs and plays the visible order',
      (tester) async {
    const track10 = 'Track 10';
    const track2 = 'Track 2';
    const middle = 'Middle';
    const untagged = 'Untagged';
    const alpha = 'Alpha';
    const members = [track10, track2, middle, untagged, alpha];

    rows = [
      {
        'uri': '$folder/document/1',
        'title': track10,
        'artist': 'Fixture Artist',
        'album': 'Album A',
        'releaseDate': '1991-03',
        'durationMs': 1900,
      },
      {
        'uri': '$folder/document/2',
        'title': track2,
        'artist': 'Fixture Artist',
        'album': 'Album Z',
        'originalReleaseDate': '2005',
        'durationMs': 900,
      },
      {
        'uri': '$folder/document/3',
        'title': middle,
        'artist': 'Fixture Artist',
        'album': 'Album A',
        'releaseDate': '1999-09-15',
        'originalReleaseDate': '1988',
        'durationMs': 1900,
      },
      {
        'uri': '$folder/document/4',
        'title': untagged,
        'artist': 'Fixture Artist',
      },
      {
        'uri': '$folder/document/5',
        'title': alpha,
        'artist': 'Fixture Artist',
        'album': 'Album B',
        'releaseDate': '1996',
        'durationMs': 3100,
      },
    ];
    await show(
        tester,
        MusicDeviceArtistPage(
          selectionId: 'original',
          artistKey: 'fixture artist',
          library: library,
        ));

    Future<void> sortBy(String label) async {
      await tester.tap(find.byTooltip('Sort by'));
      await tester.pumpAndSettle();
      expect(find.text('Artist'), findsNothing);
      await tester.tap(find.widgetWithText(
          CheckedPopupMenuItem<LocalMusicDetailSongOrder>, label));
      await tester.pumpAndSettle();
    }

    Future<void> expectOrderAndPlay(List<String> expected,
        {bool retainQueueOrder = true}) async {
      final visible = [...members]..sort((a, b) => tester
          .getCenter(find.text(a).hitTestable())
          .dy
          .compareTo(tester.getCenter(find.text(b).hitTestable()).dy));
      expect(visible, expected);
      await tester.tap(find.text('Play all'));
      await tester.pumpAndSettle();
      expect(player.queue.map((entry) => entry.title), visible);
      expect(player.start, 0);
      expect(player.lastSongTap, isFalse);
      expect(player.lastRetainQueueOrder, retainQueueOrder);
    }

    await expectOrderAndPlay(members, retainQueueOrder: false);
    player.showTrack(player.queue.first.deviceTrack!);
    await tester.pumpAndSettle();
    final playingQueue = player.queue;
    final playingState = player.state;
    final playCalls = player.playCalls;
    await sortBy('Title');
    expect(player.playCalls, playCalls);
    expect(player.queue, same(playingQueue));
    expect(player.state, same(playingState));
    await expectOrderAndPlay([alpha, middle, track2, track10, untagged]);

    await sortBy('Album');
    await expectOrderAndPlay([middle, track10, alpha, track2, untagged]);
    await sortBy('Release date');
    await expectOrderAndPlay([track10, alpha, middle, track2, untagged]);
    await sortBy('Duration');
    await expectOrderAndPlay([track2, middle, track10, alpha, untagged]);

    await sortBy('Descending');
    const durationDescending = [alpha, middle, track10, track2, untagged];
    await expectOrderAndPlay(durationDescending);
    await tester.tap(find.text(track2));
    await tester.pumpAndSettle();
    expect(player.queue.map((entry) => entry.title), durationDescending);
    expect(player.start, 3);
    expect(player.lastSongTap, isTrue);

    await sortBy('Release date');
    await expectOrderAndPlay([track2, middle, alpha, track10, untagged]);
    await sortBy('Album');
    await expectOrderAndPlay([track2, alpha, middle, track10, untagged]);
    await sortBy('Title');
    await expectOrderAndPlay([untagged, track10, track2, middle, alpha]);
    await sortBy('Default order');
    await expectOrderAndPlay(members, retainQueueOrder: false);
  });

  testWidgets('Artists index remembers and applies explicit album credits',
      (tester) async {
    // Keep The Ensemble as an album-only credit.
    rows.removeAt(1);
    rows.addAll([
      song(5, 'Missing album artist', 'Untagged Performer', null, 'd' * 64),
      song(6, 'Unknown album artist', 'Another Performer', '<unknown>',
          'e' * 64),
    ]);
    await show(
        tester, Scaffold(body: LocalMusicFolder.library(library: library)));
    final entry = find.text('Artists').hitTestable();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    final filter =
        find.widgetWithText(SwitchListTile, 'Show only album artists');
    expect(tester.widget<SwitchListTile>(filter).value, isFalse);
    expect(find.text('Guest Band'), findsOneWidget);
    expect(find.text('Untagged Performer'), findsOneWidget);
    expect(find.text('Another Performer'), findsOneWidget);

    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text('Guest Band'), findsNothing);
    expect(find.text('Untagged Performer'), findsNothing);
    expect(find.text('Another Performer'), findsNothing);
    expect(find.text('<unknown>'), findsNothing);
    expect(find.text('The Ensemble'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);

    final search = MusicLibrarySearch(deviceLibrary: library);
    addTearDown(search.dispose);
    await tester.runAsync(() => search
        .refreshFiles(database: db, profileId: db.profileId, downloads: []));
    expect(
        search
            .search('Guest Band', database: db, profileId: db.profileId)
            .whereType<MusicLibrarySearchFile>()
            .map((hit) => hit.title),
        unorderedEquals(['Guest opening', 'Guest reprise']));

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(filter).value, isTrue);
    expect(find.text('Guest Band'), findsNothing);

    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text('Guest Band'), findsOneWidget);
  });

  testWidgets('TV can clear the Artists index filter when no credits match',
      (tester) async {
    final previousTv = app_globals.isTv;
    app_globals.isTv = true;
    addTearDown(() => app_globals.isTv = previousTv);
    rows = [
      song(5, 'Missing album artist', 'Untagged Performer', null, 'd' * 64)
    ];
    await show(tester,
        MusicDeviceArtistIndexPage(selectionId: 'original', library: library));

    final artist = find.text('Untagged Performer');
    final filterLabel = find.text('Show only album artists');
    expect(Focus.of(tester.element(artist)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(filterLabel)).hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    expect(artist, findsNothing);
    expect(Focus.of(tester.element(filterLabel)).hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(artist, findsOneWidget);
  });

  testWidgets('artist aliases preserve distinct device credits and reset',
      (tester) async {
    const alias = 'Shared artist name';
    const editButton = ValueKey('music-edit-device-artist-alias');
    const aliasInput = ValueKey('music-artist-alias-input');
    await show(tester,
        MusicDeviceArtistIndexPage(selectionId: 'original', library: library));

    Future<void> openArtist(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> saveAlias() async {
      await tester.tap(find.byKey(editButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(aliasInput), alias);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    await openArtist('guest band');
    await saveAlias();
    expect(find.widgetWithText(AppBar, alias), findsOneWidget);
    expect(find.text('Guest opening'), findsOneWidget);
    expect(find.text('Ensemble performance'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await openArtist('the ensemble');
    await saveAlias();
    expect(find.widgetWithText(AppBar, alias), findsOneWidget);
    expect(find.text('Ensemble performance'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text(alias), findsNWidgets(2));
    expect(find.text('Guest Band'), findsOneWidget);
    expect(find.text('The Ensemble'), findsOneWidget);

    await openArtist('guest band');
    expect(find.text('Ensemble performance'), findsNothing);
    await tester.tap(find.byKey(editButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to original'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Guest Band'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(alias), findsOneWidget);
    await openArtist('the ensemble');
    expect(find.widgetWithText(AppBar, alias), findsOneWidget);
    expect(find.text('Ensemble performance'), findsOneWidget);
    expect(library.tracks.first.artist, 'Guest Band');
    expect(library.tracks.first.albumArtist, 'The Ensemble');
  });

  testWidgets('groups tagged and unclassified releases with the same title',
      (tester) async {
    final unclassifiedKey = 'd' * 64;
    rows = [
      song(1, 'EP guest track', 'Guest Band', 'The Ensemble', sharedAlbumKey),
      {
        ...song(
            2, 'EP band track', 'The Ensemble', 'The Ensemble', sharedAlbumKey),
        'releaseKind': 'ep',
      },
      {
        ...song(3, 'Live guest track', 'Guest Band', 'Guest Band',
            unrelatedAlbumKey),
        'releaseKind': 'live',
      },
      song(4, 'Untagged guest track', 'Guest Band', 'Guest Band',
          unclassifiedKey),
    ];
    await show(tester,
        MusicDeviceArtistIndexPage(selectionId: 'original', library: library));
    await tester.tap(find.text('Guest Band'));
    await tester.pumpAndSettle();

    final releases = [
      ('EPs', sharedAlbumKey, 'EP guest track'),
      ('Live releases', unrelatedAlbumKey, 'Live guest track'),
      ('Unclassified releases', unclassifiedKey, 'Untagged guest track'),
    ];
    for (final (label, _, _) in releases) {
      expect(find.text(label), findsOneWidget);
    }
    for (final (label, key, title) in releases) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      final section = find.widgetWithText(ExpansionTile, label);
      final release =
          find.descendant(of: section, matching: find.byKey(ValueKey(key)));
      expect(find.descendant(of: release, matching: find.text('Live Sessions')),
          findsOneWidget);
      await tester.tap(release);
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      for (final (_, otherKey, otherTitle) in releases) {
        if (otherKey != key) expect(find.text(otherTitle), findsNothing);
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('album-artist membership follows visibility and session scope',
      (tester) async {
    await show(
        tester,
        MusicDeviceArtistPage(
          selectionId: 'original',
          artistKey: 'the ensemble',
          library: library,
        ));
    expect(find.text('Album artist · Live Sessions'), findsNWidgets(2));
    expect(find.text('Track artist · Album artist · Live Sessions'),
        findsOneWidget);
    final hidden = library.visibleTracks.lastWhere((t) => t.uri.endsWith('/3'));
    await tester.runAsync(() => library.hideTrack(hidden));
    await tester.pumpAndSettle();
    expect(find.text('Guest reprise'), findsNothing);
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.queue.map((entry) => entry.title),
        ['Guest opening', 'Ensemble performance']);
    expect(player.lastSongTap, isFalse);

    app.switchSession();
    await tester.pumpAndSettle();
    expect(find.text('The Ensemble'), findsNothing);
    expect(find.text('Play all'), findsNothing);
  });

  testWidgets('a route cannot be used with a replaced source selection',
      (tester) async {
    await show(
        tester,
        MusicDeviceArtistPage(
          selectionId: 'original',
          artistKey: 'guest band',
          library: library,
        ));
    expect(find.text('Guest opening'), findsOneWidget);
    selection = 'replacement';
    await library.chooseFolder();
    await tester.pumpAndSettle();
    expect(find.text('Guest opening'), findsNothing);
    expect(find.text('Play all'), findsNothing);
    expect(player.queue, isEmpty);
  });

  testWidgets('now playing offers both roles and rejects an old credit menu',
      (tester) async {
    final source = LocalMusicLibrary.instance;
    addTearDown(source.disable);
    await source.refresh();
    final guest = source.tracks.first;
    player.showTrack(guest);

    await show(tester, Scaffold(
      body: BlocBuilder<PlayerCubit, PlayerState>(builder: (context, state) {
        return MusicPlayingDeviceArtists(
          byline: state.offlineCurrentlyPlaying?.author ?? '',
          occurrence: (db.profileId, 0, 0, state.currentQueueId),
          television: false,
        );
      }),
    ));
    await tester.tap(find.byTooltip('Artist credits'));
    await tester.pumpAndSettle();
    expect(find.text('Track artist'), findsOneWidget);
    expect(find.text('Album artist'), findsOneWidget);

    await tester.tap(find.text('Track artist'));
    await tester.pumpAndSettle();
    expect(find.text('Guest Band'), findsOneWidget);
    expect(find.text('Guest opening'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Artist credits'));
    await tester.pumpAndSettle();

    // The new occurrence shares the album artist but must not inherit an old
    // menu selection created for the previous playing file.
    player.showTrack(source.tracks[1]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Album artist'));
    await tester.pumpAndSettle();
    expect(find.byType(MusicDeviceArtistPage), findsNothing);

    await tester.tap(find.byTooltip('Open artist: The Ensemble'));
    await tester.pumpAndSettle();
    expect(find.byType(MusicDeviceArtistPage), findsOneWidget);
    expect(find.text('Guest opening'), findsOneWidget);
    expect(player.queue, isEmpty);

    await tester
        .tap(find.byKey(const ValueKey('music-edit-device-artist-alias')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('music-artist-alias-input')),
        'Live Ensemble');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Open artist: Live Ensemble'), findsOneWidget);
  });
}
