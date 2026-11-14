import 'dart:io';

import 'package:clipious/channels/states/channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../utils/server.dart';

class _LiveNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _LiveNetworkBinding();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    // Loading a channel also needs storage for its notification cursor.
    final documents =
        await Directory.systemTemp.createTemp('videre-live-channel-test-');
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathProvider, null);
      await documents.delete(recursive: true);
    });
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    await setUpTestsForTestServer();
  });

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
