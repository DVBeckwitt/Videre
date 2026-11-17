import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/podcasts/services/podcast_downloads.dart';
import 'package:clipious/podcasts/services/podcast_feed_service.dart';
import 'package:clipious/podcasts/services/podcast_library_service.dart';
import 'package:clipious/podcasts/services/podcast_player.dart';
import 'package:clipious/podcasts/views/podcast_library.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const _episode = PodcastEpisode(
    id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    title: 'Local episode',
    mediaUrl: 'https://publisher.example/episode.mp3',
    mimeType: 'audio/mpeg',
    durationSeconds: 123);
const _feed = PodcastFeed(
    id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    feedUrl: 'https://publisher.example/feed.xml',
    title: 'Local podcast',
    author: 'Publisher',
    episodes: [_episode]);

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }
  @override
  onReady() {}
  @override
  initState() {}
  void changeSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));
}

class _Feeds extends PodcastFeedService {
  final calls = <String>[];
  Future<PodcastFeed> Function() result = () async => _feed;
  @override
  Future<PodcastFeed> fetch(String link) {
    calls.add(link);
    return result();
  }
}

class _Downloads extends ChangeNotifier implements PodcastDownloads {
  @override
  final entries = <PodcastDownload>[];
  @override
  final progress = <String, PodcastDownloadProgress>{};
  @override
  final errors = <String, String>{};
  @override
  String? activeId;
  String? path;
  int started = 0;
  @override
  Future<String?> localPath(String episodeId) async => path;
  @override
  Future<void> download(PodcastFeed feed, PodcastEpisode episode) async {
    started++;
    entries.add(PodcastDownload(
        feedId: feed.id, feedTitle: feed.title, episode: episode, bytes: 100));
    path = '/private/podcast.audio';
    notifyListeners();
  }

  @override
  Future<void> remove(String id) async {
    entries.removeWhere((item) => item.episode.id == id);
    path = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Podcasts extends ChangeNotifier implements PodcastPlayer {
  final calls = <(String, String?, String)>[];
  @override
  bool get active => false;
  @override
  Future<void> playEpisode(
      {required PodcastEpisode episode,
      required String feedTitle,
      required String profileId,
      String? localPath}) async {
    calls.add((episode.id, localPath, profileId));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  @override
  final _Podcasts podcasts = _Podcasts();
  _Player() : super(PlayerState.init(null));
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _App app;
  late _Player player;
  late _Feeds feeds;
  late _Downloads downloads;
  late PodcastLibraryService library;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _Player();
    feeds = _Feeds();
    downloads = _Downloads();
    library =
        PodcastLibraryService.forProfile(db, db.profileId, feedService: feeds);
  });
  tearDown(() async {
    downloads.dispose();
    player.podcasts.dispose();
    await player.close();
    await app.close();
    await db.close();
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
                body: PodcastLibraryPage(
                    library: library, downloads: downloads)))));
    await tester.pumpAndSettle();
  }

  Future<void> addDialog(WidgetTester tester) async {
    await tester.tap(find.text('Add podcast'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _feed.feedUrl);
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('add saves locally, shows episodes and does not refresh on open',
      (tester) async {
    await show(tester);
    expect(feeds.calls, isEmpty);
    await addDialog(tester);
    expect(find.textContaining('Subscriptions stay on this device'),
        findsOneWidget);
    await submit(tester);
    expect(library.feeds.single.title, 'Local podcast');
    expect(find.text('Local episode'), findsOneWidget);
    expect(feeds.calls, [_feed.feedUrl]);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await addDialog(tester);
    await submit(tester);
    expect(library.feeds, hasLength(1));
    expect(feeds.calls, hasLength(1));
  });

  testWidgets('cancel during fetch leaves the local library unchanged',
      (tester) async {
    final pending = Completer<PodcastFeed>();
    feeds.result = () => pending.future;
    await show(tester);
    await addDialog(tester);
    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    // Finish while the dismissing dialog is still mounted: it must neither
    // commit the feed nor pop the underlying screen during its exit animation.
    await tester.runAsync(() async {
      pending.complete(_feed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(library.feeds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile change during add cannot write its fetched feed',
      (tester) async {
    final pending = Completer<PodcastFeed>();
    feeds.result = () => pending.future;
    await show(tester);
    await addDialog(tester);
    await tester.tap(find.text('Add'));
    await tester.pump();
    app.changeSession();
    await tester.runAsync(() async {
      pending.complete(_feed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(library.feeds, isEmpty);
  });

  for (final succeeds in [true, false]) {
    testWidgets(
        'covered add dialog handles ${succeeds ? 'success' : 'failure'} without losing navigation',
        (tester) async {
      final pending = Completer<PodcastFeed>();
      feeds.result = () => pending.future;
      await show(tester);
      await addDialog(tester);
      await tester.tap(find.text('Add'));
      await tester.pump();
      final navigator = Navigator.of(tester.element(find.byType(AlertDialog)));
      unawaited(navigator.push<void>(MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Linked page')))));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        if (succeeds) {
          pending.complete(_feed);
        } else {
          pending.completeError(StateError('offline'));
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.text('Linked page'), findsOneWidget);
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      if (succeeds) {
        expect(library.feeds, hasLength(1));
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Local episode'), findsOneWidget);
      } else {
        expect(library.feeds, isEmpty);
        expect(find.textContaining('Could not add this feed'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('invalid Google feed is blocked before a publisher fetch',
      (tester) async {
    await show(tester);
    await addDialog(tester);
    await tester.enterText(
        find.byType(TextField), 'https://youtube.com/feed.xml');
    await submit(tester);
    expect(feeds.calls, isEmpty);
    expect(library.feeds, isEmpty);
    expect(find.textContaining('Could not add this feed'), findsOneWidget);
  });

  testWidgets('cached feeds stay visible when a refresh fails', (tester) async {
    await tester.runAsync(() => library.subscribe(_feed.feedUrl));
    feeds.calls.clear();
    await show(tester);
    expect(find.text('Local podcast'), findsOneWidget);
    expect(feeds.calls, isEmpty);
    await tester.tap(find.text('Local podcast'));
    await tester.pumpAndSettle();
    feeds.result = () async => throw StateError('offline');
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Local episode'), findsOneWidget);
    expect(find.textContaining('Could not refresh this feed'), findsOneWidget);
    expect(library.feeds, hasLength(1));
  });

  testWidgets(
      'cached feed and episode notes display locally and full notes scroll with the remote',
      (tester) async {
    final description = List.filled(
            40, 'Publisher notes with a detailed account of this episode.')
        .join(' ');
    final episode = PodcastEpisode(
        id: _episode.id,
        title: _episode.title,
        mediaUrl: _episode.mediaUrl,
        mimeType: _episode.mimeType,
        durationSeconds: _episode.durationSeconds,
        description: description);
    feeds.result = () async => PodcastFeed(
          id: _feed.id,
          feedUrl: _feed.feedUrl,
          title: _feed.title,
          author: _feed.author,
          description: 'About this feed',
          episodes: [episode],
        );
    await tester.runAsync(() => library.subscribe(_feed.feedUrl));
    feeds.calls.clear();
    await show(tester);
    await tester.tap(find.text(_feed.title));
    await tester.pumpAndSettle();

    expect(find.text(_feed.author), findsOneWidget);
    expect(find.text('About this feed'), findsOneWidget);
    final row = find.byKey(ValueKey('podcast-episode-${episode.id}'));
    final preview = find.descendant(of: row, matching: find.text(description));
    expect(tester.widget<Text>(preview).maxLines, 2);
    expect(find.descendant(of: row, matching: find.byTooltip('Download')),
        findsOneWidget);
    await tester
        .tap(find.descendant(of: row, matching: find.byTooltip('Description')));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    final notes = tester.widget<Text>(
        find.descendant(of: dialog, matching: find.text(description)));
    expect(notes.maxLines, isNull);
    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: dialog, matching: find.byType(Scrollable)).first);
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(player.podcasts.calls, isEmpty);

    await tester.tap(find.text(episode.title));
    await tester.pumpAndSettle();
    expect(player.podcasts.calls, [(episode.id, null, db.profileId)]);
    expect(feeds.calls, isEmpty);
  });

  testWidgets('downloaded episodes remain playable after unsubscribing',
      (tester) async {
    await tester.runAsync(() => library.subscribe(_feed.feedUrl));
    await downloads.download(_feed, _episode);
    await tester.runAsync(() => library.remove(_feed.id));
    feeds.calls.clear();
    await show(tester);
    await tester.tap(find.text('Downloaded episodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local episode'));
    await tester.pumpAndSettle();
    expect(player.podcasts.calls,
        [(_episode.id, '/private/podcast.audio', db.profileId)]);
    expect(feeds.calls, isEmpty);
  });

  testWidgets('an older download shows newly cached notes without fetching',
      (tester) async {
    await tester.runAsync(() => library.subscribe(_feed.feedUrl));
    await downloads.download(_feed, _episode);
    const description = 'Notes cached by the subsequent feed refresh';
    feeds.result = () async => PodcastFeed(
          id: _feed.id,
          feedUrl: _feed.feedUrl,
          title: _feed.title,
          episodes: [
            PodcastEpisode(
                id: _episode.id,
                title: 'Updated publisher title',
                mediaUrl: 'https://publisher.example/updated.mp3',
                mimeType: _episode.mimeType,
                description: description),
          ],
        );
    await tester.runAsync(() => library.refresh(_feed.id));
    feeds.calls.clear();
    await show(tester);
    await tester.tap(find.text('Downloaded episodes'));
    await tester.pumpAndSettle();

    expect(find.text(description), findsOneWidget);
    expect(find.text('Updated publisher title'), findsNothing);
    await tester.tap(find.byTooltip('Description'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.text(description)),
        findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_episode.title));
    await tester.pumpAndSettle();
    expect(player.podcasts.calls,
        [(_episode.id, '/private/podcast.audio', db.profileId)]);
    expect(downloads.entries.single.episode, same(_episode));
    expect(feeds.calls, isEmpty);
  });

  testWidgets('missing offline file never falls back to streaming',
      (tester) async {
    await downloads.download(_feed, _episode);
    downloads.path = null;
    await show(tester);
    await tester.tap(find.text('Downloaded episodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local episode'));
    await tester.pumpAndSettle();
    expect(player.podcasts.calls, isEmpty);
    expect(find.textContaining('downloaded audio is missing'), findsOneWidget);
  });

  testWidgets('episode download action and removal update the offline view',
      (tester) async {
    await tester.runAsync(() => library.subscribe(_feed.feedUrl));
    await show(tester);
    await tester.tap(find.text('Local podcast'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(downloads.started, 1);
    expect(find.textContaining('On this device'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove downloaded episode'));
    await tester.pumpAndSettle();
    expect(downloads.entries, isEmpty);
    expect(find.byTooltip('Download'), findsOneWidget);
  });
}
