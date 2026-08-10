import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

class _OfflineSubscriptionService extends Service {
  final continuations = <String?>[];

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<VideosWithContinuation> getChannelVideos(
    String channelId,
    String? continuation, {
    bool saveLastSeen = true,
    ChannelSortBy sortBy = ChannelSortBy.newest,
  }) async {
    continuations.add(continuation);
    return VideosWithContinuation(
      [
        Video(
          videoId: 'video-${continuations.length}',
          authorUrl: '/channel/$channelId',
        ),
      ],
      continuations.length == 1 ? 'next-page' : null,
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
}
