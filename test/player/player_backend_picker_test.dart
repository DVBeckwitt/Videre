import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/backend_retry_notice.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final selector = BackendSelector(
      'COMPANION_ID',
      const [
        BackendOption('1', 'Backend 1'),
        BackendOption('2', 'Backend 2'),
        BackendOption('3', 'Backend 3'),
      ],
      automaticFallback: true);
  final server = selector.withSelection(
      Server(url: 'https://example.test', backendSelector: selector), '1');
  final tryButton = find.byKey(const ValueKey('player-backend-try'));
  final savePreference =
      find.byKey(const ValueKey('player-backend-save-preference'));
  Finder choice(String? value) =>
      find.byKey(ValueKey('player-backend-${value ?? 'default'}'));
  PlayerBackendChoice? result;

  Widget host(Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      );

  Future<void> openPicker(WidgetTester tester, {Server? initial}) async {
    result = null;
    await tester.pumpWidget(host(Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await showDialog<PlayerBackendChoice>(
              context: context,
              builder: (_) => PlayerBackendPicker(server: initial ?? server));
        },
        child: const Text('Open'),
      ),
    )));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('manual choice is temporary unless explicitly saved',
      (tester) async {
    await openPicker(tester);
    expect(tester.widget<ListTile>(choice('1')).selected, isTrue);
    expect(tester.widget<CheckboxListTile>(savePreference).value, isFalse);
    await tester.tap(choice('2'));
    await tester.tap(tryButton);
    await tester.pumpAndSettle();
    expect(result?.value, '2');
    expect(result?.saveAsPreferred, isFalse);
    expect(selector.selectedValue(server), '1');
  });

  testWidgets('explicit save and server default are returned together',
      (tester) async {
    await openPicker(tester);
    await tester.tap(choice(null));
    await tester.ensureVisible(savePreference);
    await tester.tap(savePreference);
    await tester.tap(tryButton);
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.value, isNull);
    expect(result!.saveAsPreferred, isTrue);
  });

  testWidgets('cancel discards selection and save preference', (tester) async {
    await openPicker(tester);
    await tester.tap(choice('3'));
    await tester.ensureVisible(savePreference);
    await tester.tap(savePreference);
    await tester.tap(find.byKey(const ValueKey('player-backend-cancel')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(PlayerBackendPicker), findsNothing);
  });

  testWidgets('same backend can be explicitly retried with remote Select',
      (tester) async {
    await openPicker(tester);
    expect(tester.widget<FilledButton>(tryButton).onPressed, isNotNull);
    Focus.of(tester.element(
            find.descendant(of: tryButton, matching: find.byType(Text))))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(result?.value, '1');
    expect(result?.saveAsPreferred, isFalse);
  });

  testWidgets('unknown saved route requires a known choice before retry',
      (tester) async {
    await openPicker(tester,
        initial:
            server.copyWith(customHeaders: {'Cookie': 'COMPANION_ID=old'}));
    expect(find.text('Custom selection'), findsOneWidget);
    expect(tester.widget<FilledButton>(tryButton).onPressed, isNull);
    await tester.tap(choice('2'));
    await tester.pump();
    expect(tester.widget<FilledButton>(tryButton).onPressed, isNotNull);
  });

  testWidgets('long list remains usable on a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final many = BackendSelector('COMPANION_ID', [
      for (var i = 1; i <= 8; i++) BackendOption('$i', 'Backend $i · Europe'),
    ]);
    await openPicker(tester, initial: server.copyWith(backendSelector: many));
    await tester.ensureVisible(choice('8'));
    await tester.pumpAndSettle();
    await tester.tap(choice('8'));
    await tester.ensureVisible(savePreference);
    await tester.pumpAndSettle();
    await tester.tap(savePreference);
    await tester.tap(tryButton);
    await tester.pumpAndSettle();
    expect(result?.value, '8');
    expect(result?.saveAsPreferred, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('picker is only available for supported online current playback', () {
    final request = BackendPlayback(server);
    final supported = PlayerState.init(null).copyWith(
        currentlyPlaying: Video(videoId: 'video', backendPlayback: request));
    expect(canChoosePlayerBackend(supported), isTrue);
    expect(
        canChoosePlayerBackend(supported.copyWith(isClosing: true)), isFalse);
    expect(canChoosePlayerBackend(PlayerState.init(null)), isFalse);
    expect(
        canChoosePlayerBackend(PlayerState.init(null)
            .copyWith(currentlyPlaying: const Video(videoId: 'video'))),
        isFalse);
  });

  testWidgets('recovery reports attempt count, readiness and playback outcome',
      (tester) async {
    final first = BackendPlayback(server).next()!;
    BackendRecovery recovery(BackendRecoveryPhase phase,
            {BackendPlayback? request}) =>
        BackendRecovery(
            phase: phase,
            request: request ?? first,
            videoId: 'video',
            manual: false);
    Future<void> render(BackendRecovery status) async {
      await tester.pumpWidget(host(BackendRecoveryNotice(recovery: status)));
      await tester.pump();
    }

    await render(recovery(BackendRecoveryPhase.trying));
    expect(find.text('Trying Backend 2…'), findsOneWidget);
    expect(find.text('Alternative 1 of 2'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Playback resumed'), findsNothing);

    await render(recovery(BackendRecoveryPhase.ready));
    expect(find.text('Backend ready · Paused'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Playback resumed'), findsNothing);

    await render(recovery(BackendRecoveryPhase.succeeded));
    expect(find.text('Playback resumed'), findsOneWidget);
    expect(find.textContaining('Switched successfully'), findsNothing);

    await render(recovery(BackendRecoveryPhase.failed));
    expect(find.text('Couldn’t resume playback after trying 1 alternative.'),
        findsOneWidget);
    await render(recovery(BackendRecoveryPhase.failed, request: first.next()!));
    expect(find.text('Couldn’t resume playback after trying 2 alternatives.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('alternative count fits below controls at large text scale',
      (tester) async {
    await tester.pumpWidget(host(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: const Center(
        child: SizedBox(
          width: 360,
          height: 124,
          child: BackendRetryNotice(
            backendName: 'A very long backend name with region and number 123',
            alternativeIndex: 2,
          ),
        ),
      ),
    )));
    await tester.pump();
    expect(find.text('Alternative 2 of 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
