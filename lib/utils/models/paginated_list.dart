import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/utils/extensions/list_unique.dart';
import 'package:clipious/utils/models/item_with_continuation.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import '../../network/network_proxy.dart';
import '../../player/models/backend_playback.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/no_server_selected.dart';
import '../../subscription_management/services/subscription_account.dart';
import '../../videos/models/db/progress.dart';

import '../../globals.dart';

const _done = "NO_MORE_VIDEOS";

abstract class PaginatedList<T> {
  /// Reapply local visibility rules without refetching pages or losing cursors.
  Listenable? get changes => null;

  /// Retire displayed items and fetch from page one after the source changes.
  Listenable? get sourceChanges => null;

  List<T> visibleItems(List<T> items) => items;

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

typedef SubscriptionChannelFilter = ({Set<String> channelIds, bool exclude});

class _SubscriptionFeedChanged extends StateError {
  _SubscriptionFeedChanged() : super('The subscription source changed.');
}

/// The account feed and on-device subscriptions share the same page cursors.
class SubscriptionVideoList extends PaginatedList<Video> {
  final ValueListenable<SubscriptionChannelFilter?>? channelFilter;
  final maxResults = 50;
  int page = 1;
  bool hasMoreOnline = true;
  bool _retryOnlinePage = false;
  Set<String> _seenVideoIds = {};
  Map<String, String> continuations = {};

  SubscriptionVideoList({this.channelFilter});

  @override
  late final Listenable changes =
      Listenable.merge([playbackHistoryRevision, channelFilter]);

  @override
  Listenable get sourceChanges => SubscriptionAccount.revision;

  static String? _channelId(Video video) {
    final authorId = video.authorId;
    return authorId != null && authorId.isNotEmpty
        ? authorId
        : channelIdFromAuthorUrl(video.authorUrl);
  }

  @override
  List<Video> visibleItems(List<Video> items) {
    final filter = channelFilter?.value;
    final hideWatched =
        db.getSettings(hideWatchedSubscriptionsSettingName)?.value == 'true';
    if (filter == null && !hideWatched) return items;

    // Keep the unfiltered results in ItemListCubit. Hidden items still count
    // toward the source's page size and can reappear when a chip changes.
    return items.where((video) {
      if (filter != null &&
          filter.channelIds.contains(_channelId(video)) == filter.exclude) {
        return false;
      }
      return !hideWatched || !service.isVideoWatched(video.videoId);
    }).toList();
  }

  @override
  Future<List<Video>> getItems() async {
    final database = db;
    final profileId = database.profileId;
    final owner = database.forProfile(profileId);
    final api = service;
    final session = api.sessionRevision;
    final revision = SubscriptionAccount.revision.value;
    final proxyRevision = NetworkProxy.instance.revision;
    bool current() =>
        identical(db, database) &&
        database.profileId == profileId &&
        identical(service, api) &&
        session == api.sessionRevision &&
        revision == SubscriptionAccount.revision.value &&
        !NetworkProxy.instance.isChanging &&
        proxyRevision == NetworkProxy.instance.revision;
    final account = await SubscriptionAccount.resolve(owner);
    if (!current()) throw _SubscriptionFeedChanged();
    var admittedAccount = account;
    Future<void> check(Server requested) async {
      if (!current()) throw _SubscriptionFeedChanged();
      final latest = await SubscriptionAccount.resolve(owner);
      if (!current() ||
          latest == null ||
          !BackendPlayback(requested).matchesConnection(latest)) {
        throw _SubscriptionFeedChanged();
      }
      admittedAccount = requested;
    }

    if (account != null) await check(account);
    Server? playback;
    try {
      playback = await owner.getCurrentlySelectedServer();
    } on NoServerSelected {
      // An empty profile has no instance to fetch channel uploads from.
    }
    final offlineSubs = await owner.getOfflineSubscriptions();
    if (!current()) throw _SubscriptionFeedChanged();
    var nextHasMoreOnline = account != null && hasMoreOnline;
    Object? remoteError;
    StackTrace? remoteStack;
    List<Video> videos = [];

    if (nextHasMoreOnline) {
      try {
        final feed = await api.getUserFeed(
            page: page,
            maxResults: maxResults,
            serverOverride: account,
            beforeRequest: check);
        videos.addAll(feed.notifications ?? []);
        videos.addAll(feed.videos ?? []);
        nextHasMoreOnline = videos.length >= maxResults;
      } on _SubscriptionFeedChanged {
        rethrow;
      } catch (error, stack) {
        remoteError = error;
        remoteStack = stack;
      }
    }
    final futures =
        <Future<({String channelId, VideosWithContinuation response})>>[];

    for (final offlineSub in offlineSubs) {
      if (playback == null) break;
      final continuation = continuations[offlineSub.channelId];
      if (continuation == _done) continue;

      Future<({String channelId, VideosWithContinuation response})>
          loadVideos() async {
        final response = await api.getChannelVideos(
          offlineSub.channelId,
          continuation,
          serverOverride: playback,
        );
        return (channelId: offlineSub.channelId, response: response);
      }

      futures.add(loadVideos());
    }

    final nextContinuations = Map<String, String>.from(continuations);
    if (futures.isNotEmpty) {
      final offlineSubVideos = await Future.wait(futures);
      for (final result in offlineSubVideos) {
        videos.addAll(result.response.videos.map((video) =>
            _channelId(video) == null
                ? video.copyWith(authorId: result.channelId)
                : video));
        nextContinuations[result.channelId] =
            result.response.continuation ?? _done;
      }
    }

    videos = videos.unique(
      (element) => element.videoId,
    );
    videos.sort((a, b) => (b.published ?? 0).compareTo(a.published ?? 0));

    if (admittedAccount case final admitted?) await check(admitted);
    if (!current()) throw _SubscriptionFeedChanged();
    // Keep the failed account page for a later load when local uploads
    // supplied the visible results. Without results, preserve normal Retry.
    if (remoteError != null && videos.isEmpty) {
      Error.throwWithStackTrace(remoteError, remoteStack!);
    }
    hasMoreOnline = nextHasMoreOnline;
    _retryOnlinePage = remoteError != null;
    continuations = nextContinuations;
    return videos.where((video) => _seenVideoIds.add(video.videoId)).toList();
  }

  @override
  Future<List<Video>> getMoreItems() async {
    if (!getHasMore()) return [];
    final previousPage = page;
    if (hasMoreOnline && !_retryOnlinePage) {
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
    final previousRetryOnlinePage = _retryOnlinePage;
    final previousSeenVideoIds = _seenVideoIds;
    final previousContinuations = continuations;
    page = 1;
    hasMoreOnline = true;
    _retryOnlinePage = false;
    _seenVideoIds = {};
    continuations = {};
    try {
      return await getItems();
    } catch (_) {
      page = previousPage;
      hasMoreOnline = previousHasMoreOnline;
      _retryOnlinePage = previousRetryOnlinePage;
      _seenVideoIds = previousSeenVideoIds;
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
