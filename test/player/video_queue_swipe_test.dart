import 'dart:collection';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/video_queue.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/selected_server.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _QueuePlayer extends Cubit<PlayerState> implements PlayerCubit {
  _QueuePlayer(super.initialState);

  final removed = <String>[];

  @override
  final playlistLoadingRevision = ValueNotifier(0);

  @override
  int get playlistGeneration => 0;

  @override
  Object? get playlistLoadingError => null;

  @override
  bool get isPlaylistLoading => false;

  void advanceTo(Video video) => emit(state.copyWith(
        currentlyPlaying: video,
        playedVideos: [state.currentQueueId!],
        playQueue:
            ListQueue.of(state.playQueue.where((id) => id != video.videoId)),
      ));

  @override
  void removeVideoFromQueue(String queueId) => removed.add(queueId);

  @override
  Future<void> close() {
    playlistLoadingRevision.dispose();
    return super.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async => db = await SembastSqfDb.createInMemory());
  tearDown(() => db.close());

  for (final advance in [false, true]) {
    testWidgets(
        'queue removal requires a hold and confirmation; advance=$advance',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const first = Video(videoId: 'first', title: 'First');
      const next = Video(videoId: 'next', title: 'Next');
      const last = Video(videoId: 'last', title: 'Last');
      final player =
          _QueuePlayer(PlayerState.init([first, next, last]).copyWith(
        currentlyPlaying: first,
        playQueue: ListQueue.of(['next', 'last']),
      ));
      addTearDown(player.close);
      await tester.pumpWidget(BlocProvider<PlayerCubit>.value(
        value: player,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ServerScope(server: null, child: VideoQueue())),
        ),
      ));
      await tester.pumpAndSettle();

      final nextRow = find.byKey(const ValueKey('next'));
      final originalHeight = tester.getSize(nextRow).height;
      await tester.drag(nextRow, const Offset(-340, 0));
      await tester.pumpAndSettle();
      await tester.drag(nextRow, const Offset(340, 0));
      await tester.pumpAndSettle();
      expect(player.removed, isEmpty);
      expect(tester.getSize(nextRow).height, originalHeight);

      await tester.longPress(nextRow);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(player.removed, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(player.removed, isEmpty);

      await tester.longPress(nextRow);
      await tester.pumpAndSettle();
      if (advance) player.advanceTo(next);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(player.removed, advance ? isEmpty : ['next']);
      expect(tester.getSize(nextRow).height, originalHeight);
      expect(
        tester
            .widget<CompactVideo>(find.descendant(
                of: nextRow, matching: find.byType(CompactVideo)))
            .highlighted,
        advance,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
