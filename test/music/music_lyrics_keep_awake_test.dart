import 'package:clipious/music/views/components/music_lyrics_keep_awake.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Lyrics keep the screen on only while visible in the foreground',
      (tester) async {
    const channel = MethodChannel('videre/music_lyrics_screen');
    final binding = tester.binding;
    final calls = <bool>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'setReaderVisible');
      calls.add(call.arguments as bool);
      return Future.value();
    });
    addTearDown(() =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final originalLifecycle = binding.lifecycleState;
    addTearDown(() => binding.handleAppLifecycleStateChanged(
        originalLifecycle ?? AppLifecycleState.resumed));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final navigator = GlobalKey<NavigatorState>();
    final lyricsLoaded = ValueNotifier(true);
    addTearDown(lyricsLoaded.dispose);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('Player')),
    ));
    expect(calls, isEmpty);

    navigator.currentState!.push<void>(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: ValueListenableBuilder(
          valueListenable: lyricsLoaded,
          builder: (_, loaded, __) => loaded
              ? const MusicLyricsKeepAwake(child: Text('Lyrics'))
              : const Text('Unavailable'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(calls, [true]);

    navigator.currentState!.push<void>(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Other view')),
    ));
    await tester.pumpAndSettle();
    expect(calls, [true, false]);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calls, [true, false, true]);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(calls, [true, false, true, false]);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, [true, false, true, false, true]);

    lyricsLoaded.value = false;
    await tester.pump();
    expect(calls, [true, false, true, false, true, false]);

    lyricsLoaded.value = true;
    await tester.pump();
    expect(calls, [true, false, true, false, true, false, true]);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calls, [true, false, true, false, true, false, true, false]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
