import 'dart:async';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_recording_rating_store.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_track_details.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  void advanceSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));

  @override
  onReady() {}

  @override
  initState() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = Video(
    videoId: 'catalogsong',
    title: 'Catalog fallback title',
    musicMetadata: MusicMetadata(title: 'Catalog song', artist: 'Singer'),
  );
  late _App app;
  late MusicRecordingRatingStore store;
  late bool previousTv;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    store = MusicRecordingRatingStore.forProfile(db, db.profileId);
    app = _App();
    previousTv = app_globals.isTv;
    app_globals.isTv = false;
  });

  tearDown(() async {
    await app.close();
    await db.close();
    app_globals.isTv = previousTv;
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    ));
  }

  Future<void> showDevice(WidgetTester tester, LocalMusicTrack track,
      {LocalMusicLibrary? library}) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showMusicTrackDetails(context, device: track, library: library),
          child: const Text('Inspect'),
        ),
      ),
    );
    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();
  }

  Finder field(String label, String value) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Column &&
              widget.children.length == 2 &&
              widget.children.last is Text &&
              (widget.children.last as Text).data == value,
        ),
      );

  final rating = find.byKey(const ValueKey('music-recording-rating'));

  Future<void> openSongDetails(WidgetTester tester, Video song) async {
    await pump(tester, MusicLibraryActions(videos: [song]));
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song details'));
    await tester.pumpAndSettle();
  }

  testWidgets('song actions expose catalog details and close on remote Select',
      (tester) async {
    await openSongDetails(tester, song);

    expect(find.text('Song details'), findsOneWidget);
    expect(find.text('Catalog song'), findsOneWidget);
    expect(find.text('Catalog fallback title'), findsNothing);
    expect(field('Source', 'Online catalog'), findsOneWidget);
    expect(field('Artist', 'Singer'), findsOneWidget);
    expect(field('Album', 'Unknown'), findsOneWidget);
    expect(field('Duration', 'Unknown'), findsOneWidget);
    expect(find.text('File name'), findsNothing);
    expect(find.text('File extension'), findsNothing);
    expect(find.text('File size'), findsNothing);
    expect(find.text('Codec'), findsNothing);
    expect(find.text('Track number'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byTooltip('Music actions'), findsOneWidget);
  });

  testWidgets('rate a catalog recording with the D-pad and clear it by touch',
      (tester) async {
    await openSongDetails(tester, song.copyWith(queueEntryId: 'occurrence-2'));
    expect(tester.widget<DropdownButton<int>>(rating).value, isNull);

    Future<void> commit(Future<void> Function() choose) =>
        tester.runAsync(() async {
          final committed = Completer<void>();
          void onChanged() => committed.complete();
          store.changes.addListener(onChanged);
          try {
            await choose();
            await tester.pumpAndSettle();
            await committed.future.timeout(const Duration(seconds: 5));
          } finally {
            store.changes.removeListener(onChanged);
          }
        });

    await commit(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('1 star'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
    });
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(rating).value, 1);
    expect(store.ratings, {song.videoId: 1});

    await commit(() async {
      await tester.tap(rating);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unrated').last);
    });
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(rating).value, isNull);
    expect(store.ratings, isEmpty);
  });

  testWidgets('dismisses open rating choices after the session changes',
      (tester) async {
    await openSongDetails(tester, song);
    await tester.tap(rating);
    await tester.pumpAndSettle();
    expect(find.text('1 star'), findsWidgets);

    app.advanceSession();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('1 star'), findsNothing);
    expect(MusicRecordingRatingStore.forProfile(db, db.profileId).ratings,
        isEmpty);
  });

  testWidgets('Android Back closes rating choices before the player',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(
        () => store.setRating(song.videoId, 5, isCurrent: () => true));
    var playerBacks = 0;
    bool playerBack(bool stopped, RouteInfo info) {
      playerBacks++;
      return true;
    }

    BackButtonInterceptor.add(playerBack, zIndex: 2, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.remove(playerBack));
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showMusicTrackDetails(context, song: song, inPlayer: true),
          child: const Text('Inspect'),
        ),
      ),
    );
    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();
    await tester.tap(rating);
    await tester.pumpAndSettle();
    final popupOption = find.text('4 stars').hitTestable();
    expect(popupOption, findsOneWidget);

    Future<void> back() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(const MethodCall('popRoute')),
        null,
      );
      await tester.pumpAndSettle();
    }

    await back();
    expect(popupOption, findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.widget<DropdownButton<int>>(rating).value, 5);
    await back();
    expect(find.byType(AlertDialog), findsNothing);
    expect(playerBacks, 0);
  });

  for (final sameFile in [true, false]) {
    testWidgets('download details verify the selected file (same: $sameFile)',
        (tester) async {
      const storage = MethodChannel('videre/download_storage');
      final messenger = tester.binding.defaultBinaryMessenger;
      final download = DownloadedVideo(
        videoId: song.videoId,
        profileId: db.profileId,
        title: 'Downloaded song',
        musicMetadata: const MusicMetadata(
            title: 'Downloaded song', artist: 'Singer', album: 'Release'),
        lengthSeconds: 42,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true,
        musicFormat: MusicDownloadFormat.mp3,
        storageUri: 'content://test/document/shared-file',
        folderUri: 'content://test/tree/music',
      );
      await tester.runAsync(() =>
          MusicRecordingRatingStore.forProfile(db, db.profileId)
              .setRating(song.videoId, 4, isCurrent: () => true));
      messenger.setMockMethodCallHandler(storage, (call) async {
        expect(call.method, 'probeMusicFiles');
        expect(call.arguments['profileId'], db.profileId);
        expect(call.arguments['includeAudioFormat'], isTrue);
        expect(call.arguments['files'].single['expectedIdentity'], 'a' * 64);
        return {
          download.videoId: {
            'identity': (sameFile ? 'a' : 'b') * 64,
            'byteLength': 2400,
            'audioFormat': {
              'codecMimeType': 'audio/mpeg',
              'bitrateBps': 192000,
              'sampleRateHz': 48000,
            },
          }
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(storage, null));
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMusicTrackDetails(context,
                download: download, downloadFileProof: 'a' * 64),
            child: const Text('Inspect'),
          ),
        ),
      );
      await tester.tap(find.text('Inspect'));
      await tester.pumpAndSettle();

      expect(field('Source', 'Videre download'), findsOneWidget);
      expect(field('File format', 'MP3'), findsOneWidget);
      expect(tester.widget<DropdownButton<int>>(rating).value, 4);
      expect(field('File name', 'Unknown'), findsOneWidget);
      expect(
          field('File size', sameFile ? '2.4 KB' : 'Unknown'), findsOneWidget);
      if (sameFile) {
        expect(field('Codec', 'MP3'), findsOneWidget);
        expect(field('Bitrate', '192 kbps'), findsOneWidget);
        expect(field('Sample rate', '48 kHz'), findsOneWidget);
      } else {
        expect(find.text('Codec'), findsNothing);
        expect(find.text('Bitrate'), findsNothing);
        expect(find.text('Sample rate'), findsNothing);
      }
      expect(find.text(download.storageUri!), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));
  }

  testWidgets('a device file exposes verified size and filename extension',
      (tester) async {
    final source = LocalMusicTrack.systemSource;
    final track = LocalMusicTrack.fromDocument({
      'uri': '$source/1',
      'title': 'Device recording',
      'artist': 'Local singer',
      'album': 'Local album',
      'fileName': 'device-recording.flac',
      'durationMs': 65000,
      'sizeBytes': 2400000,
    }, source)!;

    await showDevice(tester, track);

    expect(find.text('File details'), findsOneWidget);
    expect(find.text('Device recording'), findsOneWidget);
    expect(field('Source', 'Device file'), findsOneWidget);
    expect(field('Artist', 'Local singer'), findsOneWidget);
    expect(field('Album', 'Local album'), findsOneWidget);
    expect(field('Duration', '01:05'), findsOneWidget);
    expect(field('File name', 'device-recording.flac'), findsOneWidget);
    expect(field('File extension', 'FLAC'), findsOneWidget);
    expect(field('File size', '2.4 MB'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('file details display published tags and verified audio units', (
    tester,
  ) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    final messenger = tester.binding.defaultBinaryMessenger;
    final source = LocalMusicTrack.systemSource;
    final library = LocalMusicLibrary();
    addTearDown(library.dispose);
    final uri = '$source/1';
    var audioReads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return {'uri': '$source', 'name': 'Device', 'selectionId': 'system'};
        case 'listTracks':
          return [
            {
              'uri': uri,
              'title': 'Tagged song',
              // The file extension does not determine the codec.
              'fileName': 'recording.ogg',
              'trackNumber': 7,
              'discNumber': 2,
              'genre': ' Jazz ',
              'replayGain': {
                'trackGainDb': -7.25,
                'albumGainDb': 0.0,
                'trackPeak': 0.923614,
                'albumPeak': 1.01,
              },
            },
          ];
        case 'readTrackAudioFormat':
          ++audioReads;
          expect(call.arguments['treeUri'], '$source');
          expect(call.arguments['selectionId'], 'system');
          expect(call.arguments['trackUri'], uri);
          expect(call.arguments['trackId'], library.tracks.single.playbackId);
          return {
            'codecMimeType': 'audio/opus',
            'bitrateBps': 96000,
            'sampleRateHz': 44100,
          };
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await library.refresh();
    expect(audioReads, 0);
    await showDevice(tester, library.tracks.single, library: library);

    expect(audioReads, 1);
    expect(field('Track number', '7'), findsOneWidget);
    expect(field('Disc number', '2'), findsOneWidget);
    expect(field('Genre', 'Jazz'), findsOneWidget);
    expect(field('Codec', 'Opus'), findsOneWidget);
    expect(field('Bitrate', '96 kbps'), findsOneWidget);
    expect(field('Sample rate', '44.1 kHz'), findsOneWidget);
    expect(field('ReplayGain track gain', '-7.25 dB'), findsOneWidget);
    expect(field('ReplayGain album gain', '0 dB'), findsOneWidget);
    expect(field('ReplayGain track peak', '0.923614'), findsOneWidget);
    expect(field('ReplayGain album peak', '1.01'), findsOneWidget);
  });

  testWidgets('remote arrows scroll file details and Select closes the dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await showDevice(
        tester,
        const LocalMusicTrack(
          uri: 'content://media/external/audio/media/1',
          title: 'Device recording',
          fileName: 'device-recording.flac',
        ));

    final scroll = tester.widget<SingleChildScrollView>(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView)));
    expect(scroll.controller!.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scroll.controller!.offset, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a device file with malformed metadata displays unknown fields',
      (tester) async {
    final source = LocalMusicTrack.systemSource;
    final track = LocalMusicTrack.fromDocument({
      'uri': '$source/2',
      'title': 'Unmeasured song',
      'artist': '<unknown>',
      'fileName': '/storage/private/device-recording.flac',
      'durationMs': -1,
      'sizeBytes': -1,
      'trackNumber': 0,
      'discNumber': -1,
      'genre': '<unknown>',
      'replayGain': {'trackGainDb': double.nan, 'trackPeak': 0},
    }, source)!;

    await showDevice(tester, track);

    expect(find.text('Unmeasured song'), findsOneWidget);
    expect(field('Artist', 'Unknown'), findsOneWidget);
    expect(field('Album', 'Unknown'), findsOneWidget);
    expect(field('Duration', 'Unknown'), findsOneWidget);
    expect(field('File name', 'Unknown'), findsOneWidget);
    expect(field('File extension', 'Unknown'), findsOneWidget);
    expect(field('File size', 'Unknown'), findsOneWidget);
    expect(find.text('/storage/private/device-recording.flac'), findsNothing);
    for (final label in [
      'Track number',
      'Disc number',
      'Genre',
      'Codec',
      'Bitrate',
      'Sample rate',
      'ReplayGain track gain',
      'ReplayGain album gain',
      'ReplayGain track peak',
      'ReplayGain album peak',
    ]) {
      expect(find.text(label), findsNothing);
    }

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
}
