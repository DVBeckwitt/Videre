import 'dart:async';

import 'package:clipious/music/services/music_home_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/music_home_widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<Map<Object?, Object?>?> snapshots;
  late List<MusicHomeWidgetAction> actions;
  late MusicHomeWidgetPlayback? playback;
  late MusicHomeWidget widget;

  MusicHomeWidgetPlayback song(String profile, String id, int generation,
      {MusicHomeWidgetStatus status = MusicHomeWidgetStatus.playing,
      bool canNext = true,
      bool canSave = true}) {
    return (
      owner: (profile, id, generation),
      title: 'Song $id',
      artist: 'Artist',
      status: status,
      canPrevious: true,
      canNext: canNext,
      canSave: canSave,
    );
  }

  Future<bool> tap(Object? token, String action) async {
    final reply = Completer<bool>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
          MethodCall('transport', {'token': token, 'action': action})),
      (data) => reply.complete(channel.codec.decodeEnvelope(data!) as bool),
    );
    return reply.future;
  }

  setUp(() {
    snapshots = [];
    actions = [];
    playback = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setPlayback');
      snapshots.add(call.arguments as Map<Object?, Object?>?);
      return null;
    });
    widget = MusicHomeWidget(
      readPlayback: () => playback,
      onAction: actions.add,
      updates: const [],
    );
  });

  tearDown(() async {
    await widget.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('withdraws playback and rejects delayed clicks across profile changes',
      () async {
    playback = song('first profile', 'same song', 1);
    widget.refresh();
    final old = snapshots.single!;
    expect(old.values, isNot(contains('first profile')));
    expect(await tap(old['token'], 'next'), isTrue);

    playback = null;
    expect(await tap(old['token'], 'next'), isFalse);
    widget.refresh();
    expect(snapshots.last, isNull);

    playback = song('second profile', 'same song', 1);
    widget.refresh();
    final current = snapshots.last!;
    expect(current['token'], isNot(old['token']));
    expect(await tap(old['token'], 'save'), isFalse);
    expect(await tap(current['token'], 'save'), isTrue);
    expect(actions, [MusicHomeWidgetAction.next, MusicHomeWidgetAction.save]);
  });

  test('publishes play state and checks live transport availability', () async {
    playback = song('profile', 'first song', 1);
    widget.refresh();
    widget.refresh();
    final loaded = snapshots.single!;
    final token = loaded['token'];
    expect(loaded['playAction'], 'pause');
    expect(await tap(token, 'pause'), isTrue);

    playback = song('profile', 'first song', 1,
        status: MusicHomeWidgetStatus.paused, canNext: false, canSave: false);
    expect(await tap(token, 'pause'), isFalse);
    expect(await tap(token, 'next'), isFalse);
    expect(await tap(token, 'save'), isFalse);
    widget.refresh();
    expect(snapshots.last!['playAction'], 'play');
    expect(snapshots.last!['token'], token);
    expect(await tap(token, 'play'), isTrue);

    playback = song('profile', 'another song', 2);
    expect(await tap(token, 'previous'), isFalse);
    widget.refresh();
    expect(snapshots.last!['title'], 'Song another song');
    expect(actions, [MusicHomeWidgetAction.pause, MusicHomeWidgetAction.play]);
  });
}
