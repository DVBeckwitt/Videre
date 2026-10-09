import 'dart:async';

import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/subscription_management/states/manage_subscriptions.dart';
import 'package:clipious/subscription_management/states/subscribe_button.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

class _RetryDetectingService extends Service {
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;
  bool subscribed = false;
  bool loggedIn = false;
  bool failStatus = false;
  Completer<bool>? login;
  Completer<bool>? subscription;
  Completer<Channel>? channel;

  @override
  Future<bool> isLoggedIn() => login?.future ?? Future.value(loggedIn);

  @override
  Future<bool> subscribe(String channelId) async {
    subscribeCalls++;
    if (subscribeCalls > 1) throw StateError('subscribe retried');
    return true;
  }

  @override
  Future<bool> unSubscribe(String channelId) async {
    unsubscribeCalls++;
    if (unsubscribeCalls > 1) throw StateError('unsubscribe retried');
    return true;
  }

  @override
  Future<bool> isSubscribedToChannel(String channelId) {
    if (failStatus) return Future.error(StateError('Instance unavailable'));
    return subscription?.future ?? Future.value(subscribed);
  }

  @override
  Future<Channel> getChannel(String channelId) =>
      channel?.future ?? Future.error(StateError('Channel unavailable'));
}

class _ManualSubscribeButton extends SubscribeButtonCubit {
  _ManualSubscribeButton() : super(SubscribeButtonState.init('UC123'));

  @override
  Future<void> onReady() async {}

  Future<void> load() => super.onReady();
}

void main() {
  late _RetryDetectingService fakeService;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    fakeService = _RetryDetectingService();
    service = fakeService;
  });

  tearDown(() async {
    service = Service();
    await db.close();
  });

  test('subscribe button reports a state mismatch without retrying', () async {
    final cubit = SubscribeButtonCubit(SubscribeButtonState.init('UC123'));
    if (cubit.state.loading) {
      await cubit.stream.firstWhere((state) => !state.loading);
    }

    await expectLater(
      cubit.setAccountSubscription(true),
      throwsA(isA<InvidiousServiceError>()),
    );

    expect(fakeService.subscribeCalls, 1);
    expect(cubit.state.loading, isFalse);
    await cubit.close();
  });

  test('subscription manager reports a stale state without retrying', () async {
    fakeService.subscribed = true;
    final cubit = ManageSubscriptionCubit(const ManageSubscriptionsState());
    if (cubit.state.loading) {
      await cubit.stream.firstWhere((state) => !state.loading);
    }

    await expectLater(
      cubit.unsubscribe('UC123'),
      throwsA(isA<InvidiousServiceError>()),
    );

    expect(fakeService.unsubscribeCalls, 1);
    expect(cubit.state.loading, isFalse);
    await cubit.close();
  });

  test('subscription status can finish after leaving the screen', () async {
    fakeService.login = Completer<bool>();
    final cubit = _ManualSubscribeButton();
    final loading = cubit.load();
    await cubit.close();
    fakeService.login!.complete(false);
    await expectLater(loading, completes);
  });

  test('initial status failure keeps local subscriptions and permits retry',
      () async {
    fakeService.loggedIn = true;
    fakeService.failStatus = true;
    await db.addOfflineSubscription(
        const OfflineSubscription(channelId: 'UC123', channelName: 'Channel'));
    final cubit = SubscribeButtonCubit(SubscribeButtonState.init('UC123'));
    addTearDown(cubit.close);
    await cubit.stream
        .firstWhere((state) => !state.loading)
        .timeout(const Duration(seconds: 1));
    expect(cubit.state.isOfflineSubscribed, isTrue);
    expect(cubit.state.isLoggedIn, isTrue);
    expect(cubit.state.isAccountSubscribed, isFalse);

    fakeService.failStatus = false;
    fakeService.subscribed = true;
    await cubit.setAccountSubscription(true);
    expect(cubit.state.isAccountSubscribed, isTrue);
    expect(cubit.state.loading, isFalse);
  });

  test('account subscription can finish after leaving the screen', () async {
    final cubit = _ManualSubscribeButton();
    fakeService.subscription = Completer<bool>();
    final changing = cubit.setAccountSubscription(true);
    await cubit.close();
    fakeService.subscription!.complete(true);
    await expectLater(changing, completes);
  });

  test('offline subscription can finish after leaving the screen', () async {
    final cubit = _ManualSubscribeButton();
    fakeService.channel = Completer<Channel>();
    final changing = cubit.setOfflineSubscription(true);
    await cubit.close();
    fakeService.channel!.complete(Channel('Channel', 'UC123', '', null, [], 0,
        null, null, false, null, '', null, null));
    await expectLater(changing, completes);
    expect(await db.isOfflineSubscribed('UC123'), isTrue);
  });

  test('failed offline subscription stops loading and allows retry', () async {
    final cubit = _ManualSubscribeButton();
    await expectLater(cubit.setOfflineSubscription(true), throwsStateError);
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.isOfflineSubscribed, isFalse);
    await cubit.close();
  });
}
