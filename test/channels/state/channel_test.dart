import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/channels/states/channel.dart';

import '../../utils/server.dart';

void main() {
  setUp(() async => setUpTestsForTestServer());

  tearDown(() => cleanUpTestServer());

  test('channel details', () async {
    const channelId = 'UCl2mFZoRqjw_ELax4Yisf6w';
    var channel = ChannelCubit(const ChannelController(channelId: channelId));
    addTearDown(channel.close);
    await channel.onReady();
    expect(channel.state.channel?.authorId, channelId);
    expect(channel.state.loading, isFalse);
    expect(channel.state.hasError, isFalse);
  });
}
