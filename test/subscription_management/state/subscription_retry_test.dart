import 'package:clipious/globals.dart';
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

  @override
  Future<bool> isLoggedIn() async => false;

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
  Future<bool> isSubscribedToChannel(String channelId) async => subscribed;
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
}
