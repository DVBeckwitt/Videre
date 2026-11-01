import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:flutter_test/flutter_test.dart';

class _OfflineSubscriptionService extends Service {
  final continuations = <String?>[];
  final feedPages = <int>[];
  bool loggedIn = false;
  bool failNextChannel = false;
  final onlineCounts = <int, int>{1: 1};

  @override
  Future<bool> isLoggedIn() async => loggedIn;

  @override
  Future<UserFeed> getUserFeed(
      {int? maxResults, int? page, bool saveLastSeen = true}) async {
    final requestedPage = page ?? 1;
    feedPages.add(requestedPage);
    return UserFeed([], [
      for (var i = 0; i < (onlineCounts[requestedPage] ?? 0); i++)
        Video(videoId: 'online-$requestedPage-$i'),
    ]);
  }

  @override
  Future<VideosWithContinuation> getChannelVideos(
    String channelId,
    String? continuation, {
    bool saveLastSeen = true,
    ChannelSortBy sortBy = ChannelSortBy.newest,
  }) async {
    continuations.add(continuation);
    if (failNextChannel) {
      failNextChannel = false;
      throw StateError('offline');
    }
    return VideosWithContinuation(
      [
        Video(
          videoId: 'video-${continuations.length}',
          authorUrl: '/channel/$channelId',
        ),
      ],
      continuation == null ? 'next-page' : null,
    );
  }
}

void main() {
  late _OfflineSubscriptionService fakeService;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.addOfflineSubscription(const OfflineSubscription(
      channelId: 'UC123',
      channelName: 'Channel',
    ));
    fakeService = _OfflineSubscriptionService();
    service = fakeService;
  });

  tearDown(() async {
    service = Service();
    await db.close();
  });

  test('stores offline continuation by the requested channel id', () async {
    final list = SubscriptionVideoList();

    await list.getItems();
    await list.getItems();

    expect(fakeService.continuations, [null, 'next-page']);
  });

  test('logged-out feeds stop once offline continuations are exhausted',
      () async {
    final list = SubscriptionVideoList();
    await list.getItems();
    expect(list.getHasMore(), isTrue);
    await list.getMoreItems();
    expect(list.getHasMore(), isFalse);
    expect(await list.getMoreItems(), isEmpty);
    expect(fakeService.continuations, [null, 'next-page']);
    expect(fakeService.feedPages, isEmpty);

    await list.refresh();
    expect(list.getHasMore(), isTrue);
    expect(fakeService.continuations.last, isNull);
  });

  test('logged-out feeds without subscriptions finish after the first request',
      () async {
    await db.deleteOfflineSubscription('UC123');
    final list = SubscriptionVideoList();
    expect(await list.getItems(), isEmpty);
    expect(list.getHasMore(), isFalse);
  });

  test('offline continuation does not refetch an exhausted online page',
      () async {
    fakeService.loggedIn = true;
    final list = SubscriptionVideoList();
    final first = await list.getItems();
    final second = await list.getMoreItems();
    expect(first.any((video) => video.videoId.startsWith('online-')), isTrue);
    expect(second.any((video) => video.videoId.startsWith('online-')), isFalse);
    expect(fakeService.feedPages, [1]);
    expect(list.getHasMore(), isFalse);

    await list.refresh();
    expect(fakeService.feedPages, [1, 1]);
  });

  test('a partial-source failure retries the same online and offline pages',
      () async {
    fakeService.loggedIn = true;
    fakeService.onlineCounts.addAll({1: 50, 2: 1});
    final list = SubscriptionVideoList();
    await list.getItems();
    fakeService.failNextChannel = true;
    await expectLater(list.getMoreItems(), throwsStateError);
    expect(list.page, 1);
    expect(list.getHasMore(), isTrue);

    final retry = await list.getMoreItems();
    expect(fakeService.feedPages, [1, 2, 2]);
    expect(fakeService.continuations, [null, 'next-page', 'next-page']);
    expect(retry.any((video) => video.videoId == 'online-2-0'), isTrue);
    expect(list.getHasMore(), isFalse);
  });

  test('failed refresh restores the cursors for the next pagination attempt',
      () async {
    fakeService.loggedIn = true;
    fakeService.onlineCounts.addAll({1: 50, 2: 1});
    final list = SubscriptionVideoList();
    await list.getItems();
    fakeService.failNextChannel = true;
    await expectLater(list.refresh(), throwsStateError);
    await list.getMoreItems();
    expect(fakeService.feedPages, [1, 1, 2]);
    expect(fakeService.continuations, [null, null, 'next-page']);
  });
}
