import 'dart:async';

import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/subscription_management/models/subscription_group.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('group writes and deletion stay with their profile', () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final original = database.forProfile(database.profileId);
    final secondProfile = await database.createProfile('Second person');
    final second = database.forProfile(secondProfile.id);
    const channel = OfflineSubscription(
      channelId: 'UC1234567890123456789012',
      channelName: 'A shared channel',
    );
    const otherChannel = OfflineSubscription(
      channelId: 'UC9876543210987654321098',
      channelName: 'An independent channel',
    );
    await original.addOfflineSubscription(channel);
    await second.addOfflineSubscription(otherChannel);

    final changes = StreamIterator(database.watchSubscriptionGroups());
    addTearDown(changes.cancel);
    expect(await changes.moveNext(), isTrue);
    expect(changes.current, isEmpty);
    await database.useProfile(secondProfile.id);

    await second.saveSubscriptionGroup(
      SubscriptionGroup(
        id: 'group-1',
        name: 'Second person group',
        channelIds: {otherChannel.channelId},
      ),
    );
    await original.saveSubscriptionGroup(
      SubscriptionGroup(
        id: 'group-1',
        name: 'Trips',
        channelIds: {channel.channelId},
      ),
    );
    expect(await changes.moveNext(), isTrue);
    expect(changes.current.single.name, 'Trips');

    await original.saveSubscriptionGroup(
      SubscriptionGroup(
        id: 'group-2',
        name: 'Favorites',
        channelIds: {channel.channelId},
      ),
    );
    expect(await changes.moveNext(), isTrue);
    expect(changes.current.map((group) => group.name), ['Favorites', 'Trips']);
    expect(
      changes.current.map((group) => group.channelIds),
      everyElement({channel.channelId}),
    );

    await original.saveSubscriptionGroup(
      SubscriptionGroup(
        id: 'group-2',
        name: 'Favorites renamed',
        channelIds: {channel.channelId},
      ),
    );
    expect(await changes.moveNext(), isTrue);
    expect(changes.current.first.name, 'Favorites renamed');

    await original.deleteSubscriptionGroup('group-1');
    expect(await changes.moveNext(), isTrue);
    expect(changes.current.single.id, 'group-2');
    expect(changes.current.single.channelIds, {channel.channelId});
    expect(await original.getOfflineSubscriptions(), [channel]);
    expect(await database.getOfflineSubscriptions(), [otherChannel]);

    final independentGroups = await database.watchSubscriptionGroups().first;
    expect(independentGroups.single.id, 'group-1');
    expect(independentGroups.single.name, 'Second person group');
    expect(independentGroups.single.channelIds, {otherChannel.channelId});
  });
}
