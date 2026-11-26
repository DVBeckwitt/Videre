import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/watch_notes.dart';
import 'package:clipious/videos/views/components/watch_notes_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _NotesApp extends Fake implements AppCubit {
  _NotesApp(String profileId)
      : state = AppState(0, null, HomeLayout(), profileId: profileId);

  @override
  final AppState state;

  @override
  bool get isClosed => false;

  @override
  Stream<AppState> get stream => const Stream.empty();
}

class _NotesPlayer extends Fake implements PlayerCubit {
  _NotesPlayer(this.state);

  @override
  PlayerState state;

  final seekPositions = <Duration>[];

  @override
  bool get isClosed => false;

  @override
  Stream<PlayerState> get stream => const Stream.empty();

  @override
  void seek(Duration position) {
    seekPositions.add(position);
    state = state.copyWith(position: position);
  }
}

const _videoId = 'abcdefghijk';
const _video = Video(videoId: _videoId, lengthSeconds: 120);
const _download = DownloadedVideo(
  videoId: _videoId,
  title: 'Downloaded video',
  lengthSeconds: 120,
  quality: '720p',
  downloadComplete: true,
);
const _first = Duration(seconds: 15);
const _second = Duration(milliseconds: 42321);
const _testTimeout = Timeout(Duration(seconds: 45));

void main() {
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    addTearDown(() => db.close());
  });

  Future<_NotesPlayer> mount(
    WidgetTester tester, {
    Video? video,
    DownloadedVideo? download,
    bool isAudio = false,
    Future<void> Function(Duration)? onStartAt,
  }) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final app = _NotesApp(db.profileId);
    final player = _NotesPlayer(
      PlayerState.init(null).copyWith(
        currentlyPlaying: video,
        offlineCurrentlyPlaying: download,
        isHidden: video == null && download == null,
        isMini: false,
        isAudio: isAudio,
        mediaEvent: const MediaEvent(state: MediaState.pause),
      ),
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: WatchNotesButton(
              videoId: _videoId,
              labeled: true,
              onStartAt: onStartAt,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return player;
  }

  Finder noteTile(String body) =>
      find.ancestor(of: find.text(body), matching: find.byType(ListTile));

  Future<void> tap(WidgetTester tester, Finder control) async {
    await tester.tap(control);
    await tester.pumpAndSettle();
  }

  Future<void> saveNote(WidgetTester tester, String body) async {
    await tester.enterText(find.byType(TextField), body);
    await tester.pump();
    final store = WatchNotes.forVideo(db, _videoId);
    final saved = await tester.runAsync(() async {
      await tester.tap(find.text('Save')).timeout(const Duration(seconds: 3));
      await tester.pump();
      for (var attempt = 0; attempt < 150; attempt++) {
        if (store.list().any((note) => note.text == body)) return true;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return false;
    });
    expect(saved, isTrue, reason: 'The note should save to the local profile.');
    await tester.pumpAndSettle();
  }

  testWidgets(
    'restores two notes in the download player and seeks the second',
    (tester) async {
      try {
        final player = await mount(tester, video: _video);
        player.seek(_first);
        await tap(tester, find.text('Notes'));
        await tap(tester, find.text('Add note'));
        await saveNote(tester, 'First explanation');

        player.seek(_second);
        await tap(tester, find.text('Add note'));
        player.seek(const Duration(seconds: 70));
        await saveNote(tester, 'Second explanation');
        await tap(
          tester,
          find.descendant(
            of: noteTile('Second explanation'),
            matching: find.byTooltip('Edit note'),
          ),
        );
        await saveNote(tester, 'Revised second explanation');

        final offline = await mount(tester, download: _download);
        await tap(tester, find.text('Notes'));
        expect(find.text('First explanation'), findsOneWidget);
        expect(find.text('Revised second explanation'), findsOneWidget);
        expect(find.text('Second explanation'), findsNothing);
        expect(find.text('00:15'), findsOneWidget);

        await tap(tester, find.text('00:42'));
        expect(offline.seekPositions, [_second]);
        expect(offline.state.position, _second);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    timeout: _testTimeout,
  );

  testWidgets(
    'starts Watch from idle and audio mode and keeps notes private',
    (tester) async {
      try {
        final player = await mount(tester, video: _video);
        player.seek(_second);
        await tap(tester, find.text('Notes'));
        await tap(tester, find.text('Add note'));
        await saveNote(tester, 'Private explanation');
        await tap(tester, find.text('Add note'));
        await tap(tester, find.text('Include timestamp'));
        await saveNote(tester, 'Note without a time');

        final starts = <Duration>[];
        Future<void> start(Duration position) async => starts.add(position);

        final idle = await mount(tester, onStartAt: start);
        await tap(tester, find.text('Notes'));
        expect(
          tester.widget<ListTile>(noteTile('Note without a time')).subtitle,
          isNull,
        );
        await tap(tester, find.text('00:42'));
        expect(starts, [_second]);
        expect(idle.seekPositions, isEmpty);

        final audio = await mount(
          tester,
          video: _video,
          isAudio: true,
          onStartAt: start,
        );
        await tap(tester, find.text('Notes'));
        await tap(tester, find.text('00:42'));
        expect(starts, [_second, _second]);
        expect(audio.seekPositions, isEmpty);

        await tester.runAsync(() async {
          final secondProfile = await db.createProfile('Second viewer');
          await db.useProfile(secondProfile.id);
        });
        await mount(tester, onStartAt: start);
        await tap(tester, find.text('Notes'));
        expect(find.text('No notes for this video.'), findsOneWidget);
        expect(find.text('Private explanation'), findsNothing);
        expect(find.text('Note without a time'), findsNothing);
        expect(find.text('00:42'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    timeout: _testTimeout,
  );
}
