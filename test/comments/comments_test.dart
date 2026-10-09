import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/comments/models/comment.dart';
import 'package:clipious/comments/models/comment_replies.dart';
import 'package:clipious/comments/models/video_comments.dart';
import 'package:clipious/comments/states/comments.dart';
import 'package:clipious/comments/views/components/comment.dart';
import 'package:clipious/comments/views/components/comments.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
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

final _video = Video(videoId: 'video');

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

Future<void> _pumpComments(WidgetTester tester, Widget child) async {
  final app = TestAppCubit(AppState(0, null, HomeLayout()));
  app.intentDataStreamSubscription = const Stream<void>.empty().listen((_) {});
  final settings = TestSettingsCubit(SettingsState.init(), app);
  final player = TestPlayerCubit(PlayerState.init(null), settings);
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
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CommentsService fakeService;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
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
