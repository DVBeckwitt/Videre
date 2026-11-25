import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/local_music_track.dart';
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
  late bool previousTv;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
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

  Future<void> showDevice(WidgetTester tester, LocalMusicTrack track) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showMusicTrackDetails(context, device: track),
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

  testWidgets('song actions expose catalog details and close on remote Select',
      (tester) async {
    await pump(tester, const MusicLibraryActions(videos: [song]));
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song details'));
    await tester.pumpAndSettle();

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

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byTooltip('Music actions'), findsOneWidget);
  });

  for (final sameFile in [true, false]) {
    testWidgets('download details verify the selected file (same: $sameFile)',
        (tester) async {
      const storage = MethodChannel('videre/download_storage');
      final messenger = tester.binding.defaultBinaryMessenger;
      final download = DownloadedVideo(
        videoId: 'downloaded-song',
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
      messenger.setMockMethodCallHandler(storage, (call) async {
        expect(call.method, 'probeMusicFiles');
        expect(call.arguments['profileId'], db.profileId);
        return {
          download.videoId: {
            'identity': (sameFile ? 'a' : 'b') * 64,
            'byteLength': 2400,
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
      expect(field('File name', 'Unknown'), findsOneWidget);
      expect(
          field('File size', sameFile ? '2.4 KB' : 'Unknown'), findsOneWidget);
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

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
}
