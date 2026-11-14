import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/subscription_management/states/subscribe_button.dart';

import '../../utils/server.dart';

void main() {
  setUp(() async => await setUpTestsForTestServer());

  tearDown(() async => await cleanUpTestServer());

  test('test subscribe button', () async {
    const channelId = 'UCHDxYLv8iovIbhrfl16CNyg';
    final button = SubscribeButtonCubit(SubscribeButtonState.init(channelId));
    addTearDown(button.close);

    // the cubit checks subscription status on start
    await button.stream.firstWhere((state) => !state.loading);
    expect(button.state.isLoggedIn, isTrue);
    expect(button.state.isAccountSubscribed,
        await service.isSubscribedToChannel(channelId));

    await button.setAccountSubscription(true);
    expect(await service.isSubscribedToChannel(channelId), isTrue);
    expect(button.state.isAccountSubscribed, isTrue);

    await button.unsubscribe();
    expect(await service.isSubscribedToChannel(channelId), isFalse);
    expect(button.state.isAccountSubscribed, isFalse);
  });
}
