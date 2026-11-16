import 'dart:async';

import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/podcasts/services/podcast_feed_service.dart';
import 'package:clipious/podcasts/services/podcast_library_service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

class _Feeds extends PodcastFeedService {
  int requests = 0;
  Future<PodcastFeed> Function(String)? response;
  @override
  Future<PodcastFeed> fetch(String link) async {
    requests++;
    if (response != null) return await response!(link);
    return _feed(link);
  }
}

PodcastFeed _feed(String url, {String title = 'Publisher'}) =>
    PodcastFeedParser.parse(
        '<rss><channel><title>$title</title><item>'
        '<title>Episode</title><guid>one</guid>'
        '<enclosure url="https://media.example/one.mp3" type="audio/mpeg"/>'
        '</item></channel></rss>',
        feedUrl: Uri.parse(url));

void main() {
  late SembastSqfDb database;
  late _Feeds source;
  late PodcastLibraryService library;
  const url = 'https://publisher.example/feed';

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    source = _Feeds();
    library = PodcastLibraryService.forProfile(database, database.profileId,
        feedService: source);
  });
  tearDown(() async => database.close());

  test(
      'subscriptions survive database reopen with cached episodes and no network',
      () async {
    final factory = newDatabaseFactoryMemory();
    var connection = await factory.openDatabase('podcasts');
    var store = SembastSqfDb(connection);
    await store.getProfiles();
    var saved = PodcastLibraryService.forProfile(store, store.profileId,
        feedService: source);
    await saved.subscribe(url);
    await store.close();
    connection = await factory.openDatabase('podcasts');
    store = SembastSqfDb(connection);
    await store.getProfiles();
    saved = PodcastLibraryService.forProfile(store, store.profileId,
        feedService: source);
    expect(saved.feeds.single.title, 'Publisher');
    expect(saved.feeds.single.episodes.single.title, 'Episode');
    expect(source.requests, 1);
    await store.close();
  });

  test(
      'duplicate subscribe is local and distinct concurrent subscriptions both persist',
      () async {
    await library.subscribe(url);
    await library.subscribe(url);
    expect(source.requests, 1);
    await Future.wait([
      library.subscribe('https://second.example/rss'),
      library.subscribe('https://third.example/rss')
    ]);
    expect(library.feeds, hasLength(3));
  });

  test(
      'refresh updates metadata and removing during refresh cannot resurrect a feed',
      () async {
    final first = await library.subscribe(url);
    source.response = (link) async => _feed(link, title: 'Updated');
    await library.refresh(first.id);
    expect(library.feeds.single.title, 'Updated');
    final pending = Completer<PodcastFeed>();
    source.response = (_) => pending.future;
    final refresh = library.refresh(first.id);
    final expectation = expectLater(refresh, throwsStateError);
    await library.remove(first.id);
    pending.complete(_feed(url, title: 'Late'));
    await expectation;
    expect(library.feeds, isEmpty);
  });

  test('profile switch before completion cancels subscription without writes',
      () async {
    final pending = Completer<PodcastFeed>();
    source.response = (_) => pending.future;
    var current = true;
    final add = library.subscribe(url, isCurrent: () => current);
    final expectation = expectLater(add, throwsStateError);
    current = false;
    pending.complete(_feed(url));
    await expectation;
    expect(library.feeds, isEmpty);
    expect(database.getSettings(podcastLibrarySettingName), isNull);
  });

  test('fixed owner writes and notifications never change another profile',
      () async {
    var notices = 0;
    library.changes.addListener(() => notices++);
    final second = await database.createProfile('Other');
    final other = PodcastLibraryService.forProfile(database, second.id,
        feedService: source);
    await database.useProfile(second.id);
    await library.subscribe(url);
    expect(library.feeds.single.feedUrl, url);
    expect(other.feeds, isEmpty);
    expect(notices, 1);
    await other.subscribe('https://other.example/rss');
    await library.remove(library.feeds.single.id);
    expect(other.feeds.single.feedUrl, 'https://other.example/rss');
  });

  test(
      'feed errors preserve cached metadata and rejected writes do not poison later work',
      () async {
    final first = await library.subscribe(url);
    source.response =
        (_) async => throw const FormatException('Publisher unavailable');
    await expectLater(library.refresh(first.id), throwsFormatException);
    expect(library.feeds.single.toJson(), first.toJson());
    await expectLater(
        library.subscribe('https://youtube.com/rss'), throwsFormatException);
    source.response = null;
    await library.subscribe('https://second.example/rss');
    expect(library.feeds, hasLength(2));
  });
}
