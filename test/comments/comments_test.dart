import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/comments/models/comment.dart';
import 'package:clipious/comments/models/comment_replies.dart';
import 'package:clipious/comments/models/video_comments.dart';
import 'package:clipious/comments/states/comments.dart';
import 'package:clipious/comments/views/components/comment.dart';
import 'package:clipious/comments/views/components/comments.dart';
import 'package:clipious/comments/views/components/comments_container.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _CommentsService extends Service {
  final requests = <({String? continuation, String? sortBy, String? source})>[];
  final responses = <Completer<VideoComments>>[];

  @override
  Future<VideoComments> getComments(String videoId,
      {String? continuation, String? sortBy, String? source}) {
    requests.add((continuation: continuation, sortBy: sortBy, source: source));
    final response = Completer<VideoComments>();
    responses.add(response);
    return response.future;
  }
}

class _CommentsPlayer extends TestPlayerCubit {
  _CommentsPlayer(super.initialState, super.settings);

  void showVideo(Video video, Duration position) {
    emit(state.copyWith(
      currentlyPlaying: video,
      isHidden: false,
      isMini: false,
      isPlaying: false,
      position: position,
      mediaEvent: const MediaEvent(state: MediaState.pause),
      mediaCommand: null,
    ));
  }

  void advancePlayback(Duration position) {
    emit(state.copyWith(
      isPlaying: true,
      position: position,
      mediaEvent: const MediaEvent(state: MediaState.playing),
    ));
  }
}

const _video = Video(videoId: 'video', lengthSeconds: 120);

Comment _comment(String content, {CommentReplies? replies}) => Comment(
    'Author',
    [],
    'author',
    '',
    false,
    content,
    'today',
    0,
    content,
    false,
    null,
    replies);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<_CommentsPlayer> _pumpComments(
  WidgetTester tester,
  Widget child, {
  bool scrollable = true,
  Video? playingVideo,
}) async {
  final app = TestAppCubit(AppState(0, null, HomeLayout()));
  app.intentDataStreamSubscription = const Stream<void>.empty().listen((_) {});
  final settings = TestSettingsCubit(SettingsState.init(), app);
  final player = _CommentsPlayer(PlayerState.init(null), settings);
  if (playingVideo != null) {
    player.showVideo(playingVideo, const Duration(seconds: 6));
  }
  addTearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
  });
  await tester.pumpWidget(BlocProvider<PlayerCubit>.value(
    value: player,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: scrollable ? SingleChildScrollView(child: child) : child,
      ),
    ),
  ));
  return player;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CommentsService fakeService;

  setUp(() async {
    db = await createPlayerTestDatabase();
    service = fakeService = _CommentsService();
  });

  tearDown(() async {
    service = Service();
    await db.close();
  });

  test('failed comments stop loading and can retry the same reply page',
      () async {
    final cubit = CommentsCubit(CommentsState.init(
        video: _video,
        continuation: 'replies',
        source: 'youtube',
        sortBy: 'new'));
    addTearDown(cubit.close);
    fakeService.responses.single
        .completeError(InvidiousServiceError('Offline'));
    await _flush();
    expect(cubit.state.loadingComments, isFalse);
    expect(cubit.state.error, 'Offline');

    final retry = cubit.getComments();
    expect(cubit.state.error, isEmpty);
    expect(fakeService.requests.last,
        (continuation: 'replies', source: 'youtube', sortBy: 'new'));
    fakeService.responses.last
        .complete(VideoComments(1, 'video', null, [_comment('Reply')]));
    await retry;
    expect(cubit.state.comments.comments.single.content, 'Reply');
    expect(cubit.state.loadingComments, isFalse);
  });

  test('pagination preserves options and old state and ignores duplicate loads',
      () async {
    final cubit = CommentsCubit(
        CommentsState.init(video: _video, source: 'reddit', sortBy: 'new'));
    addTearDown(cubit.close);
    final duplicate = cubit.getComments();
    expect(fakeService.requests, hasLength(1));
    fakeService.responses.first
        .complete(VideoComments(2, 'video', 'next', [_comment('First')]));
    await _flush();
    await duplicate;
    final before = cubit.state;

    final next = cubit.loadMore();
    final duplicateNext = cubit.loadMore();
    expect(fakeService.requests, hasLength(2));
    expect(fakeService.requests.last,
        (continuation: 'next', source: 'reddit', sortBy: 'new'));
    fakeService.responses.last
        .complete(VideoComments(null, 'video', null, [_comment('Second')]));
    await next;
    await duplicateNext;
    expect(before.comments.comments.map((c) => c.content), ['First']);
    expect(cubit.state.comments.comments.map((c) => c.content),
        ['First', 'Second']);
    expect(cubit.state.comments.commentCount, 2);
    await cubit.loadMore();
    expect(fakeService.requests, hasLength(2));
  });

  test('pagination failure keeps comments and retries without losing them',
      () async {
    final cubit = CommentsCubit(CommentsState.init(video: _video));
    addTearDown(cubit.close);
    fakeService.responses.single
        .complete(VideoComments(2, 'video', 'next', [_comment('First')]));
    await _flush();
    final next = cubit.loadMore();
    fakeService.responses.last.completeError(StateError('Connection lost'));
    await next;
    expect(cubit.state.loadingComments, isFalse);
    expect(cubit.state.error, contains('Connection lost'));
    expect(cubit.state.comments.comments.single.content, 'First');
    expect(cubit.state.continuation, 'next');

    final retry = cubit.getComments();
    fakeService.responses.last
        .complete(VideoComments(2, 'video', null, [_comment('Second')]));
    await retry;
    expect(cubit.state.comments.comments.map((c) => c.content),
        ['First', 'Second']);
    expect(cubit.state.error, isEmpty);
  });

  for (final fails in [false, true]) {
    test('request ${fails ? 'error' : 'success'} after closing is ignored',
        () async {
      final cubit = CommentsCubit(CommentsState.init(video: _video));
      await cubit.close();
      if (fails) {
        fakeService.responses.single.completeError(StateError('Offline'));
      } else {
        fakeService.responses.single
            .complete(VideoComments(0, 'video', null, []));
      }
      await _flush();
      await cubit.getComments();
      expect(fakeService.requests, hasLength(1));
    });
  }

  testWidgets('comments keep prior content and offer a full-size retry button',
      (tester) async {
    await _pumpComments(tester, CommentsView(video: _video));
    fakeService.responses.single
        .complete(VideoComments(2, 'video', 'next', [_comment('First')]));
    await tester.pumpAndSettle();
    final loadMore = find.widgetWithText(FilledButton, 'Load more');
    expect(tester.getSize(loadMore).height, greaterThanOrEqualTo(48));
    await tester.tap(loadMore);
    fakeService.responses.last.completeError(InvidiousServiceError('Offline'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final retry = find.widgetWithText(FilledButton, 'Retry');
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    await tester.tap(retry);
    expect(fakeService.requests.last.continuation, 'next');
    fakeService.responses.last
        .complete(VideoComments(2, 'video', null, [_comment('Second')]));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets(
      'Timed indexes loaded Top pages, retries, and keeps Top and New available',
      (tester) async {
    const earlier = '0:15 Explains the setup';
    const later = '1:20 Shows the result';
    const invalid = '0:75 Invalid seconds';
    const outOfRange = '2:30 Past the end';
    final top = find.widgetWithText(ChoiceChip, 'Top');
    final newest = find.widgetWithText(ChoiceChip, 'New');
    final timed = find.widgetWithText(ChoiceChip, 'Timed');
    final loadMore = find.text('Load more');
    final earlierRow = find.text(earlier, findRichText: true);
    final laterRow = find.text(later, findRichText: true);

    await _pumpComments(
      tester,
      CommentsContainer(
        video: _video,
        watchStyle: true,
        topPage: VideoComments(
          4,
          _video.videoId,
          'next',
          [_comment(invalid), _comment(outOfRange)],
        ),
      ),
      scrollable: false,
    );
    await tester.tap(timed);
    await tester.pumpAndSettle();
    expect(fakeService.requests, isEmpty);
    expect(find.text('No valid timestamps in the loaded comments.'),
        findsOneWidget);
    expect(
      find.text('Uses loaded Top comments from your provider. '
          'More comments are available.'),
      findsOneWidget,
    );
    expect(find.text(invalid, findRichText: true), findsNothing);
    expect(find.text(outOfRange, findRichText: true), findsNothing);

    await tester.tap(loadMore);
    expect(fakeService.requests.single,
        (continuation: 'next', sortBy: 'top', source: 'youtube'));
    fakeService.responses.last
        .complete(VideoComments(4, _video.videoId, 'last', [_comment(later)]));
    await tester.pumpAndSettle();
    expect(laterRow, findsOneWidget);

    await tester.tap(loadMore);
    fakeService.responses.last.completeError(InvidiousServiceError('Offline'));
    await tester.pumpAndSettle();
    expect(laterRow, findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(fakeService.requests.last,
        (continuation: 'last', sortBy: 'top', source: 'youtube'));
    fakeService.responses.last
        .complete(VideoComments(4, _video.videoId, null, [_comment(earlier)]));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(earlierRow).dy,
        lessThan(tester.getTopLeft(laterRow).dy));
    expect(find.text('Uses Top comments available from your provider.'),
        findsOneWidget);
    expect(loadMore, findsNothing);

    await tester.tap(newest);
    await tester.pump();
    expect(fakeService.requests.last,
        (continuation: null, sortBy: 'new', source: 'youtube'));
    fakeService.responses.last
        .complete(VideoComments(1, _video.videoId, null, [_comment('Newest')]));
    await tester.pumpAndSettle();
    expect(find.text('Newest'), findsOneWidget);

    await tester.tap(top);
    await tester.pumpAndSettle();
    expect(find.text(invalid, findRichText: true), findsOneWidget);
    await tester.tap(timed);
    await tester.pumpAndSettle();
    expect(earlierRow, findsOneWidget);
    expect(laterRow, findsOneWidget);
    expect(fakeService.requests, hasLength(4));
  });

  testWidgets(
      'Timed follows playback, pauses for a drag, and guards stale seeks',
      (tester) async {
    final follow = find.text('Follow playback');
    final pause = find.text('Pause follow');
    final timedList = find.byKey(const ValueKey('timed-comments-list'));
    Finder seekButton(String timestamp) =>
        find.widgetWithText(TextButton, timestamp);

    final player = await _pumpComments(
      tester,
      CommentsContainer(
        video: _video,
        watchStyle: true,
        topPage: VideoComments(
          14,
          _video.videoId,
          null,
          [
            for (var number = 1; number <= 14; number++)
              _comment(
                  '0:${(number * 4).toString().padLeft(2, '0')} Scene $number'),
          ],
        ),
      ),
      scrollable: false,
      playingVideo: _video,
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Timed'));
    await tester.pumpAndSettle();
    expect(pause, findsNothing);
    final scrollable =
        find.descendant(of: timedList, matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(scrollable).position;

    final seekFromOldRow =
        tester.widget<TextButton>(seekButton('00:08')).onPressed!;
    await tester.tap(seekButton('00:08'));
    await tester.pumpAndSettle();
    expect(player.state.mediaCommand?.type, MediaCommandType.seek);
    expect(player.state.position, const Duration(seconds: 8));
    expect(player.state.isPlaying, isFalse);

    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(pause, findsOneWidget);
    player.advancePlayback(const Duration(seconds: 43));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(seekButton('00:40').hitTestable(), findsOneWidget);

    await tester.dragFrom(
      tester.getTopLeft(scrollable) +
          Offset(12, tester.getSize(scrollable).height / 2),
      const Offset(0, 64),
    );
    await tester.pumpAndSettle();
    expect(follow, findsOneWidget);
    final manualOffset = position.pixels;
    expect(manualOffset, greaterThan(0));

    player.seek(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(position.pixels, manualOffset);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(pause, findsOneWidget);
    expect(position.pixels, lessThan(manualOffset));
    expect(seekButton('00:04').hitTestable(), findsOneWidget);

    player.showVideo(const Video(videoId: 'next-video', lengthSeconds: 200),
        const Duration(seconds: 7));
    seekFromOldRow();
    await tester.pumpAndSettle();
    expect(player.state.currentlyPlaying?.videoId, 'next-video');
    expect(player.state.position, const Duration(seconds: 7));
    expect(player.state.mediaCommand, isNull);
    expect(pause, findsNothing);
  });

  testWidgets('switching videos starts a fresh Timed index', (tester) async {
    final shown = ValueNotifier(_video);
    addTearDown(shown.dispose);
    const nextVideo = Video(videoId: 'next-video', lengthSeconds: 120);
    const oldComment = '0:15 An old comment';
    const lateComment = '0:30 An old page completed late';
    const newComment = '0:20 A comment for the new video';
    final timed = find.widgetWithText(ChoiceChip, 'Timed');

    await _pumpComments(
      tester,
      ValueListenableBuilder<Video>(
        valueListenable: shown,
        builder: (context, video, _) => CommentsContainer(
          video: video,
          watchStyle: true,
          topPage: video == _video
              ? VideoComments(2, _video.videoId, 'next', [_comment(oldComment)])
              : null,
        ),
      ),
      scrollable: false,
    );
    await tester.tap(timed);
    await tester.pumpAndSettle();
    expect(find.text(oldComment, findRichText: true), findsOneWidget);
    await tester.tap(find.text('Load more'));
    final pendingPage = fakeService.responses.single;

    shown.value = nextVideo;
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Top'))
          .selected,
      isTrue,
    );
    expect(fakeService.requests.last,
        (continuation: null, sortBy: 'top', source: 'youtube'));
    pendingPage.complete(
        VideoComments(2, _video.videoId, null, [_comment(lateComment)]));
    fakeService.responses.last.complete(
        VideoComments(1, nextVideo.videoId, null, [_comment(newComment)]));
    await tester.pumpAndSettle();
    await tester.tap(timed);
    await tester.pumpAndSettle();
    expect(find.text(newComment, findRichText: true), findsOneWidget);
    expect(find.text(oldComment, findRichText: true), findsNothing);
    expect(find.text(lateComment, findRichText: true), findsNothing);
  });

  testWidgets(
      'reply toggle stays available to collapse with a full-size target',
      (tester) async {
    await _pumpComments(
        tester,
        SingleCommentView(
          video: _video,
          comment: _comment('Parent', replies: CommentReplies(1, 'replies')),
        ));
    final toggle = find.ancestor(
        of: find.text('1 reply'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    fakeService.responses.single
        .complete(VideoComments(1, 'video', null, [_comment('Child')]));
    await tester.pumpAndSettle();
    expect(find.text('Child'), findsOneWidget);
    expect(toggle, findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Child'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });
}
