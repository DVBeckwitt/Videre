import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/music_playing_device_artists.dart';
import 'package:clipious/music/views/screens/music_device_artist.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/ided_video.dart';
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

  @override
  final musicSelectionFailureRevision = ValueNotifier(0);

  @override
  int get playlistGeneration => 0;

  @override
  IdedVideo? get openingMusicEntry => null;

  List<OnDeviceMusicEntry> queue = [];
  String? title;
  int? start;

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
      bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return;
    queue = tracks;
    title = queueTitle;
    start = startIndex;
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
  late List<Map<String, Object>> rows;
  late String selection;

  Map<String, Object> song(int id, String title, String artist,
          String albumArtist, String albumKey) =>
      {
        'uri': '$folder/document/$id',
        'title': title,
        'artist': artist,
        'albumArtist': albumArtist,
        'album': 'Live Sessions',
        'albumKey': albumKey,
        if (id == 3) 'visibilityKey': hiddenKey,
      };

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    library = LocalMusicLibrary(visibilityDatabase: () => db);
    app = _App();
    player = _Player();
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
    await app.close();
    await db.close();
  });

  Future<void> show(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<PlayerCubit>.value(value: player),
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

  testWidgets('browse and play a guest contribution or open its exact release',
      (tester) async {
    await show(tester,
        MusicDeviceArtistIndexPage(selectionId: 'original', library: library));
    expect(find.text('Guest Band'), findsOneWidget);
    expect(find.text('The Ensemble'), findsOneWidget);
    await tester.tap(find.text('Guest Band'));
    await tester.pumpAndSettle();
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

    await tester.tap(find.text('Releases'));
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
  });
}
