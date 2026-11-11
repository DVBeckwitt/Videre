import 'dart:async';

import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';
import 'package:clipious/channels/states/channel.dart';
import 'package:clipious/channels/views/tv/screens/channel.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ChannelService extends Service {
  final responses = <Completer<Channel>>[];

  @override
  Future<Channel> getChannel(String channelId,
      {bool saveLastSeen = true, Server? serverOverride}) {
    final response = Completer<Channel>();
    responses.add(response);
    return response.future;
  }

  @override
  Future<bool> isSubscribedToChannel(String channelId) =>
      throw StateError('Channel details must not depend on account access');
}

Channel _channel() => Channel('Channel', 'channel', '/channel/channel', [], [],
    10, 100, 0, false, true, 'Description', [], []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service originalService;
  late _ChannelService channelService;

  setUp(() {
    originalService = service;
    service = channelService = _ChannelService();
  });

  tearDown(() => service = originalService);

  test('channel loading coalesces requests and preserves changed sorting',
      () async {
    final cubit = ChannelCubit(const ChannelController(channelId: 'channel'));
    addTearDown(cubit.close);
    final loading = cubit.onReady();
    expect(channelService.responses, hasLength(1));
    cubit.onSortByChanged(ChannelSortBy.oldest);
    channelService.responses.single.complete(_channel());
    await loading;
    expect(cubit.state.channel?.authorId, 'channel');
    expect(cubit.state.sortBy, ChannelSortBy.oldest);
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.hasError, isFalse);
  });

  test('failed channel loads stop loading and allow retry', () async {
    final cubit = ChannelCubit(const ChannelController(channelId: 'channel'));
    addTearDown(cubit.close);
    final loading = cubit.onReady();
    channelService.responses.single.completeError(StateError('offline'));
    await loading;
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.hasError, isTrue);

    final retry = cubit.onReady();
    expect(cubit.state.loading, isTrue);
    expect(cubit.state.hasError, isFalse);
    expect(channelService.responses, hasLength(2));
    channelService.responses.last.complete(_channel());
    await retry;
    expect(cubit.state.channel?.authorId, 'channel');
    expect(cubit.state.hasError, isFalse);
  });

  for (final fails in [false, true]) {
    test('closed channel ignores late ${fails ? 'failure' : 'success'}',
        () async {
      final cubit = ChannelCubit(const ChannelController(channelId: 'channel'));
      final loading = cubit.onReady();
      await cubit.close();
      if (fails) {
        channelService.responses.single.completeError(StateError('offline'));
      } else {
        channelService.responses.single.complete(_channel());
      }
      await loading;
      await cubit.onReady();
      expect(channelService.responses, hasLength(1));
    });
  }

  testWidgets('TV channel failures provide a focused retry action',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: const TvChannelScreen(channelId: 'channel'),
    ));
    channelService.responses.single.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Could not fetch data'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(channelService.responses, hasLength(2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    channelService.responses.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
