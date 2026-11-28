import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/recommendations/subscription_recommendations.dart';
import 'package:clipious/recommendations/subscription_revision.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/subscription_management/models/subscription.dart';
import 'package:clipious/subscription_management/services/subscription_account.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

final first = 'UC${'a' * 22}';
final second = 'UC${'b' * 22}';

class _Api extends Service {
  final fetched = <String?>[];
  final subscriptions = <String>[];
  final uploadAccounts = <String>[];
  Map<String?, List<Video>> uploads = {};
  List<Subscription> follows = [];
  InvidiousServiceError? failure;

  @override
  Future<List<Subscription>> getRecommendationSubscriptions(
      {required Server server,
      required Future<void> Function() beforeRequest}) async {
    await beforeRequest();
    subscriptions.add(server.accountId);
    if (failure case final error?) throw error;
    return follows;
  }

  @override
  Future<List<Video>> getVideoRecommendationCandidates(
      {required Server server,
      required Future<void> Function() beforeRequest,
      String? query,
      String? channelId}) async {
    await beforeRequest();
    fetched.add(channelId);
    uploadAccounts.add(server.accountId);
    return uploads[channelId] ?? [];
  }
}

class _HeldCache extends Fake implements IDbClient {
  final writeAllowed = Completer<void>();
  SettingsValue? row;
  bool deleted = false;

  @override
  String get profileId => 'held-cache-profile';

  @override
  Future<void> upsertServer(Server server) => throw UnimplementedError();

  @override
  Future<void> insertLogs(AppLog log) => throw UnimplementedError();

  @override
  Future<void> saveSetting(SettingsValue setting) async {
    await writeAllowed.future;
    row = setting;
  }

  @override
  Future<void> deleteSetting(String name) async {
    deleted = true;
    row = null;
  }
}

class _VerifiedCatalog extends MusicCatalogService {
  final examined = <String>[];

  @override
  Future<List<MusicTrack>> getSubscriptionSongs(Iterable<Video> uploads,
      {required Server expectedServer, bool Function()? isCurrent}) async {
    examined.addAll(uploads.map((video) => video.videoId));
    return [
      MusicTrack(
          videoId: 'recording01', title: 'Music', uploaderChannelId: first),
      MusicTrack(
          videoId: 'recording02',
          title: 'Wrong uploader',
          uploaderChannelId: first),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late Server server;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    server = const Server(
        url: 'https://instance.example', inUse: true, id: 'owner-a');
    await db.upsertServer(server);
    api = _Api();
  });

  tearDown(() => db.close());

  test('follow invalidation drains a previously admitted cache write',
      () async {
    final store = _HeldCache();
    final revision = recommendationSubscriptionRevision.value;
    final writing = writeSubscriptionRecommendationCache(store, 'old follows');
    final invalidating = invalidateStoredSubscriptionRecommendations(store);
    expect(recommendationSubscriptionRevision.value, revision + 1);
    expect(store.deleted, isFalse);
    store.writeAllowed.complete();
    await Future.wait([writing, invalidating]);
    expect(store.deleted, isTrue);
    expect(store.row, isNull);
  });

  test('a broken signed-in follow request leaves local seeds usable', () async {
    await db.addOfflineSubscription(
        OfflineSubscription(channelId: first, channelName: 'First'));
    server = server.copyWith(sidCookie: 'fixture-a');
    await db.upsertServer(server);
    final source = SubscriptionRecommendationSource(db, api: api);
    for (final status in [400, 401, 429]) {
      api.failure = InvidiousServiceError('Unavailable', statusCode: status);
      final batches = await source
          .warm(server: server, isCurrent: () => true, forceRefresh: true)
          .toList();
      expect(batches.single.channels, {first: 'First'});
      expect(batches.single.videos, isEmpty);
    }
    expect(api.fetched, isEmpty);
  });

  test('an existing local follow seeds before uploads and unfollow removes it',
      () async {
    await db.addOfflineSubscription(
        OfflineSubscription(channelId: first, channelName: 'First'));
    api.uploads[first] = [
      Video(videoId: 'recording01', title: 'Followed', authorId: first)
    ];
    final source = SubscriptionRecommendationSource(db, api: api);
    final batches =
        await source.warm(server: server, isCurrent: () => true).toList();
    expect(batches.first.channels, {first: 'First'});
    expect(batches.first.videos, isEmpty);
    expect(batches.last.videos.single.videoId, 'recording01');
    expect(api.fetched, [first]);
    await db.deleteOfflineSubscription(first);
    expect(
        await source
            .warm(server: server, isCurrent: () => true, forceRefresh: true)
            .toList(),
        isEmpty);
    expect(api.fetched, [first]);
  });

  test('cached signed-in follows never cross account or credential changes',
      () async {
    server = server.copyWith(sidCookie: 'fixture-a');
    await db.upsertServer(server);
    api.follows = [Subscription('First', first)];
    final source = SubscriptionRecommendationSource(db, api: api);
    final firstLaunch =
        await source.warm(server: server, isCurrent: () => true).toList();
    expect(firstLaunch.first.channels, {first: 'First'});
    expect(api.subscriptions, ['owner-a']);
    final restart = SubscriptionRecommendationSource(db, api: api);
    expect(
        (await restart.warm(server: server, isCurrent: () => true).first)
            .channels,
        {first: 'First'});
    expect(api.subscriptions, ['owner-a']);
    await SubscriptionRecommendationSource.duringAccountChange(db, () async {
      expect(await source.warm(server: server, isCurrent: () => true).toList(),
          isEmpty);
      await db.upsertServer(server.copyWith(inUse: false));
      server = server.copyWith(id: 'owner-b', sidCookie: 'fixture-b');
      await db.upsertServer(server);
      await db.useServer(server);
    });
    api.follows = [Subscription('Second', second)];
    expect(
        (await restart.warm(server: server, isCurrent: () => true).first)
            .channels,
        {second: 'Second'});
    expect(api.subscriptions, ['owner-a', 'owner-b']);
    final other = await db.createProfile('Other person');
    await db.useProfile(other.id);
    expect(await restart.warm(server: server, isCurrent: () => true).toList(),
        isEmpty);
  });

  test('uses the pinned account for the feed and playback for local follows',
      () async {
    const subscription = Server(
        id: 'subscription',
        url: 'https://subscriptions.example',
        authToken: 'fixture');
    await db.upsertServer(subscription);
    await SubscriptionAccount.save(db, subscription.accountId);
    await db.addOfflineSubscription(
        OfflineSubscription(channelId: first, channelName: 'First'));
    api.follows = [Subscription('Second', second)];
    api.uploads[first] = [
      Video(videoId: 'recording01', title: 'Local follow', authorId: first),
    ];
    api.uploads[null] = [
      Video(videoId: 'recording02', title: 'Account follow', authorId: second),
    ];
    final source = SubscriptionRecommendationSource(db, api: api);

    final batches =
        await source.warm(server: server, isCurrent: () => true).toList();
    expect(api.subscriptions, [subscription.accountId]);
    expect(api.uploadAccounts, [subscription.accountId, server.accountId]);
    expect(batches.last.videos.map((video) => video.videoId),
        ['recording02', 'recording01']);
  });

  test('Music receives only verified recordings from their followed uploader',
      () async {
    await db.addOfflineSubscription(
        OfflineSubscription(channelId: first, channelName: 'First'));
    await db.addOfflineSubscription(
        OfflineSubscription(channelId: second, channelName: 'Second'));
    api.uploads[first] = [
      Video(videoId: 'recording01', title: 'Music', authorId: first)
    ];
    api.uploads[second] = [
      Video(videoId: 'recording02', title: 'Other', authorId: second)
    ];
    final catalog = _VerifiedCatalog();
    final source =
        SubscriptionRecommendationSource(db, api: api, catalog: catalog);
    final batch = await source
        .warm(server: server, isCurrent: () => true, music: true)
        .single;
    expect(catalog.examined, unorderedEquals(['recording01', 'recording02']));
    expect(batch.channels, {first: 'First'});
    expect(batch.music.single.videoId, 'recording01');
    expect(batch.videos, isEmpty);
    expect(
        await source
            .warm(server: server, isCurrent: () => false, music: true)
            .toList(),
        isEmpty);
  });
}
