import 'dart:async';

import 'package:clipious/music/views/components/music_screen_privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('videre/music_screen_privacy');

Widget _app({
  required Widget home,
  GlobalKey<NavigatorState>? navigator,
  bool enabled = true,
}) =>
    MaterialApp(
      navigatorKey: navigator,
      builder: (_, child) =>
          MusicScreenPrivacyScope(enabled: enabled, child: child!),
      home: home,
    );

class _RecordPaint extends CustomPainter {
  const _RecordPaint(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(covariant _RecordPaint oldDelegate) => false;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late List<bool> requests;
  Future<void> Function(bool)? waitForReply;

  setUp(() {
    requests = [];
    waitForReply = null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'setProtected');
      final protect = call.arguments as bool;
      requests.add(protect);
      await waitForReply?.call(protect);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  testWidgets('waits for Android before painting or accepting taps', (
    tester,
  ) async {
    final enable = Completer<void>();
    waitForReply = (protect) async {
      if (protect) await enable.future;
    };
    addTearDown(() {
      if (!enable.isCompleted) enable.complete();
    });
    var paints = 0;
    var taps = 0;
    const songKey = ValueKey('private-song');
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MusicScreenPrivacySurface(
            child: Center(
              child: CustomPaint(
                painter: _RecordPaint(() => paints++),
                child: TextButton(
                  key: songKey,
                  onPressed: () => taps++,
                  child: const Text('Private song'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(requests, [true]);
    expect(paints, 0);
    expect(find.byKey(songKey).hitTestable(), findsNothing);

    enable.complete();
    await tester.pumpAndSettle();

    expect(paints, greaterThan(0));
    await tester.tap(find.byKey(songKey));
    expect(taps, 1);
  });

  testWidgets('keeps protection through dialogs and opaque transitions', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _app(
        navigator: navigator,
        home: const Scaffold(
          body: MusicScreenPrivacySurface(child: Text('Music')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final routes = navigator.currentState!;
    unawaited(
      routes.push<void>(
        DialogRoute<void>(
          context: routes.context,
          builder: (_) => const AlertDialog(content: Text('Music options')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Music options'), findsOneWidget);
    expect(requests, [true]);

    routes.pop();
    await tester.pumpAndSettle();
    expect(requests, [true]);

    unawaited(
      routes.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Videos')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(requests, [true]);
    await tester.pumpAndSettle();
    expect(find.text('Videos'), findsOneWidget);
    expect(requests, [true, false]);

    routes.pop();
    await tester.pumpAndSettle();
    expect(find.text('Music'), findsOneWidget);
    expect(requests, [true, false, true]);
  });

  testWidgets('retained tabs release protection only after leaving Music', (
    tester,
  ) async {
    final tab = ValueNotifier(0);
    addTearDown(tab.dispose);
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: tab,
            builder: (_, index, __) => IndexedStack(
              index: index,
              children: [
                TickerMode(
                  enabled: index == 0,
                  child: const MusicScreenPrivacySurface(child: Text('Search')),
                ),
                TickerMode(
                  enabled: index == 1,
                  child: const MusicScreenPrivacySurface(
                    child: Text('Library'),
                  ),
                ),
                const Text('Videos'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [true]);

    tab.value = 1;
    await tester.pumpAndSettle();
    expect(requests, [true]);

    tab.value = 2;
    await tester.pumpAndSettle();
    expect(requests, [true, false]);

    tab.value = 0;
    await tester.pumpAndSettle();
    expect(requests, [true, false, true]);
  });

  testWidgets('backgrounding a visible Music screen never clears protection', (
    tester,
  ) async {
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    await tester.pumpWidget(
      _app(
        home: const Scaffold(
          body: MusicScreenPrivacySurface(child: Text('Music')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [true]);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      expect(requests, isNot(contains(false)), reason: state.name);
    }
  });

  testWidgets('disabling the preference releases the visible Music screen', (
    tester,
  ) async {
    const home = Scaffold(
      body: MusicScreenPrivacySurface(child: Text('Music')),
    );
    await tester.pumpWidget(_app(home: home, enabled: false));
    await tester.pumpAndSettle();
    expect(requests, isNot(contains(true)));
    expect(find.text('Music'), findsOneWidget);

    await tester.pumpWidget(_app(home: home));
    await tester.pumpAndSettle();
    expect(requests.last, isTrue);

    await tester.pumpWidget(_app(home: home, enabled: false));
    await tester.pumpAndSettle();
    expect(requests.last, isFalse);
    expect(find.text('Music'), findsOneWidget);
  });
}
