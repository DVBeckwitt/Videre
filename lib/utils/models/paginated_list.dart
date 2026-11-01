import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/utils/extensions/list_unique.dart';
import 'package:clipious/utils/models/item_with_continuation.dart';
import 'package:clipious/videos/models/user_feed.dart';
import 'package:clipious/videos/models/video.dart';

import '../../globals.dart';

const _done = "NO_MORE_VIDEOS";

abstract class PaginatedList<T> {
  Future<List<T>> getItems();

  Future<List<T>> getMoreItems();

  Future<List<T>> refresh();

  bool hasRefresh();

  bool getHasMore();
}

/// Paginated video list that uses the continuation concept
class ContinuationList<T> extends PaginatedList<T> {
  String? continuation;
  Future<ItemtWithContinuation<T>> Function(String? continuation) serviceCall;

  ContinuationList(this.serviceCall);

  @override
  bool getHasMore() {
    return continuation != null;
  }

  @override
  Future<List<T>> getMoreItems() async {
    return getItems();
  }

  @override
  Future<List<T>> getItems() async {
    ItemtWithContinuation<T> videos = await serviceCall(continuation);

    continuation = videos.continuation;
    return videos.getItems();
  }

  @override
  bool hasRefresh() {
    return true;
  }

  @override
  Future<List<T>> refresh() async {
    final previous = continuation;
    continuation = null;
    try {
      return await getItems();
    } catch (_) {
      continuation = previous;
      rethrow;
    }
  }
}

/// Video list with one endpoint call, no pagination or continuation
class SingleEndpointList<T> extends PaginatedList<T> {
  Future<List<T>> Function() serviceCall;

  SingleEndpointList(this.serviceCall);

  @override
  bool getHasMore() {
    return false;
  }

  @override
  Future<List<T>> getMoreItems() async {
    return [];
  }

  @override
  Future<List<T>> getItems() async {
    return serviceCall();
  }

  @override
  Future<List<T>> refresh() async {
    return getItems();
  }

  @override
  bool hasRefresh() {
    return true;
  }
}

/// List of videos with no service calls, just a plain list
/// sounds too simple to use this but it is to have a standard component to handle item lists
class FixedItemList<T> extends PaginatedList<T> {
  List<T> items;

  FixedItemList(this.items);

  @override
  bool getHasMore() {
    return false;
  }

  @override
  Future<List<T>> getMoreItems() async {
    return [];
  }

  @override
  Future<List<T>> getItems() async {
    return items;
  }

  @override
  Future<List<T>> refresh() async {
    return items;
  }

  @override
  bool hasRefresh() {
    return false;
  }
}

/// User subscription_management
class SubscriptionVideoList extends PaginatedList<Video> {
  final maxResults = 50;
  int page = 1;
  bool hasMoreOnline = true;
  Map<String, String> continuations = {};

  @override
  Future<List<Video>> getItems() async {
    final isLoggedIn = await service.isLoggedIn();
    var nextHasMoreOnline = isLoggedIn && hasMoreOnline;

    List<Video> videos = [];

    if (nextHasMoreOnline) {
      UserFeed feed =
          await service.getUserFeed(page: page, maxResults: maxResults);
      videos.addAll(feed.notifications ?? []);
      videos.addAll(feed.videos ?? []);
      nextHasMoreOnline = videos.length >= maxResults;
    }

    final offlineSubs = await db.getOfflineSubscriptions();
    final futures =
        <Future<({String channelId, VideosWithContinuation response})>>[];

    for (final offlineSub in offlineSubs) {
      final continuation = continuations[offlineSub.channelId];
      if (continuation == _done) continue;

      Future<({String channelId, VideosWithContinuation response})>
          loadVideos() async {
        final response = await service.getChannelVideos(
          offlineSub.channelId,
          continuation,
        );
        return (channelId: offlineSub.channelId, response: response);
      }

      futures.add(loadVideos());
    }

    final nextContinuations = Map<String, String>.from(continuations);
    if (futures.isNotEmpty) {
      final offlineSubVideos = await Future.wait(futures);
      for (final result in offlineSubVideos) {
        videos.addAll(result.response.videos);
        nextContinuations[result.channelId] =
            result.response.continuation ?? _done;
      }
    }

    videos = videos.unique(
      (element) => element.videoId,
    );
    videos.sort((a, b) => (b.published ?? 0).compareTo(a.published ?? 0));

    // Commit cursors only once all sources succeed so retry cannot skip a page.
    hasMoreOnline = nextHasMoreOnline;
    continuations = nextContinuations;
    return videos;
  }

  @override
  Future<List<Video>> getMoreItems() async {
    if (!getHasMore()) return [];
    final previousPage = page;
    if (hasMoreOnline) {
      page = page + 1;
    }
    try {
      return await getItems();
    } catch (_) {
      page = previousPage;
      rethrow;
    }
  }

  @override
  Future<List<Video>> refresh() async {
    final previousPage = page;
    final previousHasMoreOnline = hasMoreOnline;
    final previousContinuations = continuations;
    page = 1;
    hasMoreOnline = true;
    continuations = {};
    try {
      return await getItems();
    } catch (_) {
      page = previousPage;
      hasMoreOnline = previousHasMoreOnline;
      continuations = previousContinuations;
      rethrow;
    }
  }

  @override
  bool getHasMore() {
    return hasMoreOnline || continuations.values.any((v) => v != _done);
  }

  @override
  bool hasRefresh() {
    return true;
  }
}

class PageBasedPaginatedList<T> extends PaginatedList<T> {
  final int maxResults;
  int page = 1;
  bool hasMore = true;
  final Future<List<T>> Function(int page, int maxResults) getItemsFunc;

  PageBasedPaginatedList(
      {required this.maxResults, required this.getItemsFunc});

  @override
  bool getHasMore() {
    return hasMore;
  }

  @override
  Future<List<T>> getItems() async {
    var list = await getItemsFunc(page, maxResults);
    hasMore = list.length == maxResults;
    return list;
  }

  @override
  Future<List<T>> getMoreItems() async {
    try {
      page++;
      return await getItems();
    } catch (err) {
      page--;
      rethrow;
    }
  }

  @override
  bool hasRefresh() {
    return true;
  }

  @override
  Future<List<T>> refresh() async {
    final items = <T>[];
    var refreshedPage = 1;
    var refreshedHasMore = true;
    // Some endpoints (including search) have a fixed page size. Reload each
    // visible page rather than assuming they honor a larger result limit.
    while (true) {
      final next = await getItemsFunc(refreshedPage, maxResults);
      items.addAll(next);
      refreshedHasMore = next.length == maxResults;
      if (!refreshedHasMore || refreshedPage >= page) break;
      refreshedPage++;
    }
    // Preserve the old cursor if any of the requests fail.
    page = refreshedPage;
    hasMore = refreshedHasMore;
    return items;
  }
}
