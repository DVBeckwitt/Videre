import 'dart:async';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/views/components/download_folder.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = DownloadedVideo(
  videoId: 'abcdefghijk',
  title: 'Test song',
  musicMetadata: MusicMetadata(title: 'Test song', artist: 'Artist'),
  audioOnly: true,
  downloadComplete: true,
  lengthSeconds: 180,
  quality: 'audio',
);

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads() : super(const DownloadManagerState());

  final requests = <DownloadedVideo>[];
  late final result = Completer<bool>();
  final destinations = <String>[];

  @override
  Future<void> useDefaultFolder() async {
    destinations.add('default');
    emit(state.copyWith(usePrivateStorage: false));
  }

  @override
  Future<void> usePrivateFolder() async {
    destinations.add('private');
    emit(state.copyWith(usePrivateStorage: true));
  }

  @override
  Future<void> chooseFolder() async {
    // A dismissed Android picker leaves the current selection in place.
    destinations.add('picker');
  }

  @override
  Future<bool> exportMusic(DownloadedVideo video) {
    requests.add(video);
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Downloads downloads;
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    downloads = _Downloads();
  });
  tearDown(() async {
    await downloads.close();
    await db.close();
  });

  Future<AppLocalizations> mount(WidgetTester tester, Widget body) async {
    await tester.pumpWidget(BlocProvider<DownloadManagerCubit>.value(
        value: downloads,
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(body: body))));
    return AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
  }

  Future<AppLocalizations> openSheet(WidgetTester tester, DownloadedVideo video,
      {bool mountRow = true}) async {
    final row = DownloadedVideoView(video: video);
    final locals = await mount(
        tester,
        mountRow
            ? row
            : Builder(
                builder: (context) => TextButton(
                      onPressed: () => row.openVideoSheet(context),
                      child: const Text('Options'),
                    )));
    await tester.tap(
        mountRow ? find.byTooltip(locals.downloads) : find.text('Options'));
    await tester.pumpAndSettle();
    return locals;
  }

  testWidgets(
      'folder selection distinguishes default and private and survives picker cancellation',
      (tester) async {
    final locals = await mount(
        tester,
        Builder(
            builder: (context) => TextButton(
                  onPressed: () => showDownloadFolder(context),
                  child: const Text('Destination'),
                )));
    await tester.tap(find.text('Destination'));
    await tester.pumpAndSettle();
    void expectSelected(String label) {
      expect(
          find.descendant(
              of: find.widgetWithText(ListTile, label),
              matching: find.byIcon(Icons.radio_button_checked)),
          findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    }

    Future<void> choose(String label) async {
      final tile = find.widgetWithText(ListTile, label);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }

    expectSelected(locals.downloadFolderDefault);
    await choose(locals.downloadFolderPrivate);
    expectSelected(locals.downloadFolderPrivate);
    await choose(locals.downloadFolderChoose);
    expectSelected(locals.downloadFolderPrivate);
    await choose(locals.downloadFolderDefault);
    expectSelected(locals.downloadFolderDefault);
    expect(downloads.destinations, ['private', 'picker', 'default']);
  });

  final export = find.byKey(ValueKey('export-music-${_song.videoId}'));
  for (final entry in [
    (
      label: 'unfinished music',
      video: _song.copyWith(downloadComplete: false),
      copy: false
    ),
    (
      label: 'published Music document',
      video: _song.copyWith(
          storageUri: 'content://exported/song',
          musicFormat: MusicDownloadFormat.mp3),
      copy: false
    ),
    (
      label: 'private video',
      video: _song.copyWith(audioOnly: false),
      copy: true
    ),
    (
      label: 'private audio without music metadata',
      video: _song.copyWith(musicMetadata: null),
      copy: true
    ),
  ]) {
    testWidgets('Downloads sheet omits song export for ${entry.label}',
        (tester) async {
      // The untagged audio row normally starts a filesystem thumbnail poll.
      // Exercise its same sheet builder without mounting that unrelated image.
      final locals = await openSheet(tester, entry.video,
          mountRow: entry.video.musicMetadata != null);
      expect(export, findsNothing);
      expect(find.text(locals.copyToDownloadFolder),
          entry.copy ? findsOneWidget : findsNothing);
      expect(downloads.requests, isEmpty);
    });
  }

  for (final (source, video, outcome) in [
    (
      'legacy shared document',
      _song.copyWith(storageUri: 'content://legacy/song'),
      'success'
    ),
    (
      'tagged private song',
      _song.copyWith(musicFormat: MusicDownloadFormat.mp3),
      'cancel'
    ),
    ('private song', _song, 'error'),
  ]) {
    testWidgets('$source export handles $outcome once', (tester) async {
      final locals = await openSheet(tester, video);
      expect(export, findsOneWidget);
      expect(find.text(locals.exportMusicDownload), findsOneWidget);
      expect(find.text(locals.copyToDownloadFolder), findsNothing);
      await tester.tap(export);
      await tester.pump();
      expect(downloads.requests, [video]);
      expect(tester.widget<ListTile>(export).enabled, isFalse);
      await tester.tap(export, warnIfMissed: false);
      await tester.pump();
      expect(downloads.requests, [video]);
      expect(find.byType(SnackBar), findsNothing);

      if (outcome == 'error') {
        downloads.result.completeError(StateError('private test detail'));
      } else {
        downloads.result.complete(outcome == 'success');
      }
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(locals.musicDownloadExported),
          outcome == 'success' ? findsOneWidget : findsNothing);
      expect(find.text(locals.musicDownloadExportFailed),
          outcome == 'error' ? findsOneWidget : findsNothing);
      if (outcome == 'cancel') expect(find.byType(SnackBar), findsNothing);
      if (outcome != 'error') expect(export, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
