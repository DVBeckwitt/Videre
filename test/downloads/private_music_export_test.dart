import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/views/components/download_folder.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/downloads/views/screens/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

const _song = DownloadedVideo(
  videoId: 'abcdefghijk',
  title: 'Test song',
  musicMetadata: MusicMetadata(title: 'Test song', artist: 'Artist'),
  audioOnly: true,
  downloadComplete: true,
  lengthSeconds: 180,
  quality: 'audio',
);

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void initState() {}

  @override
  void onReady() {}
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final plays = <List<DownloadedVideo>>[];

  @override
  int get playlistGeneration => 0;

  @override
  bool canAddMusicRequest(IdedVideo entry) => false;

  @override
  Future<void> playOfflineVideos(
    List<DownloadedVideo> videos, {
    int startIndex = 0,
    bool fromMusic = false,
    bool songTap = false,
  }) async {
    plays.add(videos);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RemovalApproval extends Fake implements MusicDownloadDeletionApproval {
  _RemovalApproval(List<DownloadedVideo> rows) : rows = List.unmodifiable(rows);

  final List<DownloadedVideo> rows;
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads() : super(const DownloadManagerState());

  final requests = <DownloadedVideo>[];
  late final result = Completer<bool>();
  final destinations = <String>[];
  DateTime? retryAt;
  final actions = <String>[];
  final approvedRemovals = <List<DownloadedVideo>>[];

  @override
  bool canPlayAll() => false;

  @override
  bool isMusicDownloadRequiredByPlaylist(String videoId) => false;

  @override
  _RemovalApproval captureMusicDeletion(List<DownloadedVideo> selection) =>
      _RemovalApproval(selection);

  @override
  Future<int> deleteMusicSelection(
    MusicDownloadDeletionApproval approval, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return 0;
    final selected = (approval as _RemovalApproval).rows;
    approvedRemovals.add(selected);
    emit(
      state.copyWith(
        videos: state.videos.where((row) => !selected.contains(row)).toList(),
      ),
    );
    return selected.length;
  }

  void setPending(DownloadManagerState next) => emit(next);

  @override
  DateTime? retryAtFor(DownloadedVideo video) => retryAt;

  @override
  Future<void> pauseDownload(DownloadedVideo video) async =>
      actions.add('pause');

  @override
  Future<void> retryDownload(DownloadedVideo video) async =>
      actions.add('resume');

  @override
  Future<void> useDefaultFolder({bool audioOnly = false}) async {
    destinations.add(audioOnly ? 'audio-default' : 'video-default');
    emit(audioOnly
        ? state.copyWith(usePrivateAudioStorage: false)
        : state.copyWith(usePrivateStorage: false));
  }

  @override
  Future<void> usePrivateFolder({bool audioOnly = false}) async {
    destinations.add(audioOnly ? 'audio-private' : 'video-private');
    emit(audioOnly
        ? state.copyWith(usePrivateAudioStorage: true)
        : state.copyWith(usePrivateStorage: true));
  }

  @override
  Future<void> chooseFolder({bool audioOnly = false}) async {
    // A dismissed Android picker leaves the current selection in place.
    destinations.add(audioOnly ? 'audio-picker' : 'video-picker');
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
      'Downloads long press selects, Back exits and confirmation '
      'deletes only the chosen songs in display order', (tester) async {
    final app = _App();
    final player = _Player();
    addTearDown(app.close);
    addTearDown(player.close);

    DownloadedVideo song(String id, String title) => _song.copyWith(
          videoId: id,
          title: title,
          musicMetadata: MusicMetadata(title: title, artist: 'Artist'),
        );
    final first = song('firstsong01', 'First song');
    final middle = song('middlesong1', 'Middle song');
    final last = song('lastsong001', 'Last song');
    await tester.runAsync(() async {
      for (final row in [first, middle, last]) {
        await db.upsertDownload(row);
      }
    });
    downloads.setPending(DownloadManagerState(videos: [first, middle, last]));

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => const DownloadManagerScreen(),
                  ),
                ),
                child: const Text('Open Downloads'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Downloads'));
    await tester.pumpAndSettle();
    final locals = AppLocalizations.of(
      tester.element(find.byType(DownloadManagerScreen)),
    )!;

    Future<void> openDelete() async {
      await tester.tap(find.byTooltip(locals.musicPlaylistSelectionActions));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locals.musicRemoveSelectedDownloads));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    }

    expect(find.byTooltip(locals.musicSongActions), findsNWidgets(3));
    await tester.tap(find.text(middle.title));
    expect(player.plays, [
      [middle],
    ]);

    await tester.longPress(find.text(last.title),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text(locals.musicQueueSelected(1)), findsOneWidget);
    await tester.tap(find.text(first.title));
    await tester.pumpAndSettle();
    expect(find.text(locals.musicQueueSelected(2)), findsOneWidget);
    expect(player.plays, [
      [middle],
    ]);
    await openDelete();
    await tester.tap(find.text(locals.cancel));
    await tester.pumpAndSettle();
    expect(downloads.approvedRemovals, isEmpty);
    expect(find.text(locals.musicQueueSelected(2)), findsOneWidget);

    await tester.tap(find.text(last.title));
    await tester.pumpAndSettle();
    expect(find.text(locals.musicQueueSelected(1)), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DownloadManagerScreen), findsOneWidget);
    expect(find.text(locals.musicQueueSelected(1)), findsNothing);
    expect(find.byTooltip(locals.musicQueueSelect), findsOneWidget);

    await tester.tap(find.byTooltip(locals.musicSongActions).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-song-play')), findsOneWidget);
    await tester.tap(find.text(locals.musicSelectSong));
    await tester.pumpAndSettle();
    expect(find.text(locals.musicQueueSelected(1)), findsOneWidget);
    await tester.tap(find.byTooltip(locals.musicQueueSelectAll));
    await tester.pumpAndSettle();
    expect(find.text(locals.musicQueueSelected(3)), findsOneWidget);
    await tester.tap(find.text(middle.title));
    await tester.pumpAndSettle();
    expect(find.text(locals.musicQueueSelected(2)), findsOneWidget);
    await openDelete();
    await tester.tap(find.text(locals.musicRemoveSelectedDownloads));
    await tester.pumpAndSettle();
    expect(downloads.approvedRemovals, [
      [first, last],
    ]);
    expect(find.text(first.title), findsNothing);
    expect(find.text(last.title), findsNothing);
    expect(find.text(middle.title), findsOneWidget);
    expect(player.plays, [
      [middle],
    ]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open Downloads'), findsOneWidget);
  });

  testWidgets(
      'audio destination distinguishes default and private and survives picker cancellation',
      (tester) async {
    await mount(
        tester,
        Builder(
            builder: (context) => TextButton(
                  onPressed: () => showDownloadFolder(context),
                  child: const Text('Destination'),
                )));
    await tester.tap(find.text('Destination'));
    await tester.pumpAndSettle();
    Finder audioOption(String name) =>
        find.byKey(ValueKey('download-folder-audio-$name'));
    void expectSelected(String name) {
      expect(
          find.descendant(
              of: audioOption(name),
              matching: find.byIcon(Icons.radio_button_checked)),
          findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsNWidgets(2));
    }

    Future<void> choose(String name) async {
      final tile = audioOption(name);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }

    expectSelected('standard');
    await choose('private');
    expectSelected('private');
    await choose('custom');
    expectSelected('private');
    await choose('standard');
    expectSelected('standard');
    expect(downloads.destinations,
        ['audio-private', 'audio-picker', 'audio-default']);
  });

  final export = find.byKey(ValueKey('export-music-${_song.videoId}'));
  testWidgets(
      'a short download cooldown shows automatic retry and permits pause',
      (tester) async {
    final video = _song.copyWith(downloadComplete: false);
    downloads.setPending(DownloadManagerState(downloadProgresses: {
      video.videoId: DownloadProgress(CancelToken(),
          retryAt: DateTime.now().add(const Duration(seconds: 2))),
    }));
    final locals = await openSheet(tester, video);
    expect(find.text(locals.downloadRetryWaiting), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(locals.delete), findsOneWidget);
    await tester.tap(find.text(locals.pauseDownload));
    await tester.pumpAndSettle();
    expect(downloads.actions, ['pause']);
  });

  testWidgets('a download short on space can be retried or manually paused',
      (tester) async {
    final video = _song.copyWith(downloadComplete: false);
    final blocked = DownloadManagerState(
      videos: [video],
      networkConnected: false,
      spaceBlockedVideoIds: {video.videoId},
    );
    downloads.setPending(blocked);
    final locals = await openSheet(tester, video);
    expect(find.text(locals.downloadsWaitingForSpace), findsOneWidget);
    expect(find.text(locals.downloadsWaitingForNetwork), findsNothing);
    expect(find.text(locals.downloadFreeSpaceToResume), findsOneWidget);
    expect(find.text(locals.pauseDownload), findsOneWidget);

    await tester.tap(find.text(locals.downloadCheckSpace));
    await tester.pumpAndSettle();
    expect(downloads.actions, ['resume']);

    await tester.tap(find.byTooltip(locals.downloads));
    await tester.pumpAndSettle();
    await tester.tap(find.text(locals.pauseDownload));
    await tester.pumpAndSettle();
    expect(downloads.actions, ['resume', 'pause']);

    downloads.setPending(blocked.copyWith(pausedVideoIds: {video.videoId}));
    await tester.pumpAndSettle();
    expect(find.text(locals.downloadPaused), findsOneWidget);
    expect(find.text(locals.downloadsWaitingForSpace), findsNothing);
  });

  testWidgets('a network wait clears when the connection returns',
      (tester) async {
    final video = _song.copyWith(downloadComplete: false);
    final blocked = DownloadManagerState(
      videos: [video],
      networkConnected: false,
    );
    downloads.setPending(blocked);
    final locals = await mount(tester, DownloadedVideoView(video: video));
    expect(find.text(locals.downloadsWaitingForNetwork), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    downloads.setPending(blocked.copyWith(networkConnected: true));
    await tester.pump();
    expect(find.text(locals.downloadsWaitingForNetwork), findsNothing);
    expect(find.text(locals.downloadQueued), findsOneWidget);
    expect(downloads.actions, isEmpty);
  });

  testWidgets(
      'the paused row clears its resume deadline without another state change',
      (tester) async {
    final video = _song.copyWith(downloadComplete: false);
    downloads.retryAt = DateTime.now().add(const Duration(minutes: 2));
    downloads.setPending(DownloadManagerState(pausedVideoIds: {video.videoId}));
    final locals = await mount(tester, DownloadedVideoView(video: video));
    expect(find.textContaining('Paused. Resume after'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    expect(find.text(locals.downloadPaused), findsOneWidget);
    expect(find.textContaining('Paused. Resume after'), findsNothing);
    expect(downloads.actions, isEmpty);
  });

  testWidgets(
      'a paused download enables explicit resume when its cooldown ends',
      (tester) async {
    final video = _song.copyWith(downloadComplete: false);
    downloads.retryAt = DateTime.now().add(const Duration(minutes: 2));
    downloads.setPending(DownloadManagerState(pausedVideoIds: {video.videoId}));
    final locals = await openSheet(tester, video);
    ListTile resumeAction() => tester
        .widget<ListTile>(find.widgetWithText(ListTile, locals.resumeDownload));
    expect(find.textContaining('Paused. Resume after'), findsNWidgets(2));
    expect(resumeAction().enabled, isFalse);
    expect(find.text(locals.delete), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    expect(resumeAction().enabled, isTrue);
    expect(downloads.actions, isEmpty);
    await tester.tap(find.text(locals.resumeDownload));
    await tester.pumpAndSettle();
    expect(downloads.actions, ['resume']);
  });

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
