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
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/utils/states/item_list.dart';

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

  test(
      'local subscriptions hide only watched videos and update without refetch',
      () async {
    final cubit =
        ItemListCubit<Video>(ItemListState(itemList: SubscriptionVideoList()));
    addTearDown(cubit.close);
    await cubit.stream.firstWhere((state) => !state.loading);
    await db.saveProgress(Progress(1, 'video-1'));
    expect(cubit.state.items.map((v) => v.videoId), ['video-1']);

    await db.saveSetting(
        SettingsValue(hideWatchedSubscriptionsSettingName, 'true'));
    playbackHistoryRevision.value++;
    expect(cubit.state.items, isEmpty);
    expect(cubit.state.itemList.getHasMore(), isTrue);
    await cubit.getMoreItems();
    expect(cubit.state.items.map((v) => v.videoId), ['video-2']);
    await db.saveProgress(Progress(0.89, 'video-2'));
    expect(cubit.state.items, hasLength(1));
    await db.saveProgress(Progress(0.9, 'video-2'));
    expect(cubit.state.items, isEmpty);
    expect(cubit.state.itemList.getHasMore(), isFalse);

    await db.saveSetting(
        SettingsValue(hideWatchedSubscriptionsSettingName, 'false'));
    playbackHistoryRevision.value++;
    expect(cubit.state.items.map((v) => v.videoId), ['video-1', 'video-2']);
    expect(fakeService.continuations, [null, 'next-page']);
  });

  test('a hidden account page retains its cursor and earlier items on opt-out',
      () async {
    fakeService.loggedIn = true;
    fakeService.onlineCounts.addAll({1: 50, 2: 1});
    await db.saveSetting(
        SettingsValue(hideWatchedSubscriptionsSettingName, 'true'));
    for (var i = 0; i < 50; i++) {
      await db.saveProgress(Progress(1, 'online-1-$i'));
    }
    await db.saveProgress(Progress(1, 'video-1'));
    final cubit =
        ItemListCubit<Video>(ItemListState(itemList: SubscriptionVideoList()));
    addTearDown(cubit.close);
    await cubit.stream.firstWhere((state) => !state.loading);
    expect(cubit.state.items, isEmpty);
    await cubit.getMoreItems();
    expect(cubit.state.items.map((v) => v.videoId), ['online-2-0', 'video-2']);
    expect(fakeService.feedPages, [1, 2]);
    await db.saveSetting(
        SettingsValue(hideWatchedSubscriptionsSettingName, 'false'));
    playbackHistoryRevision.value++;
    expect(cubit.state.items, hasLength(53));
    expect(fakeService.feedPages, [1, 2]);
  });

  test('history removal restores visibility and disposed feeds stop listening',
      () async {
    await db.saveSetting(
        SettingsValue(hideWatchedSubscriptionsSettingName, 'true'));
    await db.saveProgress(Progress(1, 'video-1'));
    final cubit =
        ItemListCubit<Video>(ItemListState(itemList: SubscriptionVideoList()));
    await cubit.stream.firstWhere((state) => !state.loading);
    expect(cubit.state.items, isEmpty);
    await db.clearLocalHistory();
    playbackHistoryRevision.value++;
    expect(cubit.state.items, hasLength(1));
    await cubit.close();
    await db.saveProgress(Progress(1, 'video-1'));
    expect(cubit.state.items, hasLength(1));
  });

  test('stores offline continuation by the requested channel id', () async {
    final list = SubscriptionVideoList();

    await list.getItems();
    await list.getItems();

    expect(fakeService.continuations, [null, 'next-page']);
  });

  test('overlapping progress writes leave visibility at the saved progress',
      () async {
    await db.saveSetting(
        SettingsValue(hideWatchedSubscriptionsSettingName, 'true'));
    final cubit =
        ItemListCubit<Video>(ItemListState(itemList: SubscriptionVideoList()));
    addTearDown(cubit.close);
    await cubit.stream.firstWhere((state) => !state.loading);
    var revisions = 0;
    void onChanged() => revisions++;
    playbackHistoryRevision.addListener(onChanged);
    addTearDown(() => playbackHistoryRevision.removeListener(onChanged));
    final watched = db.saveProgress(Progress(1, 'video-1'));
    final partial = db.saveProgress(Progress(0.5, 'video-1'));
    await watched;
    await partial;
    expect(db.getVideoProgress('video-1'), 0.5);
    expect(cubit.state.items.map((video) => video.videoId), ['video-1']);
    expect(revisions, 2);
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
