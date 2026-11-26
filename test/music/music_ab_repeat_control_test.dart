import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/components/music_ab_repeat_control.dart';
import 'package:clipious/player/models/music_ab_repeat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Music A–B repeat exposes marker, range and exit controls',
      (tester) async {
    Duration? start;
    Duration? end;
    var canMark = false;

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 190,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
              child: StatefulBuilder(builder: (context, update) {
                return MusicAbRepeatControl(
                  controls: MusicAbRepeatControls(
                    generation: 1,
                    sourceRevision: 1,
                    start: start,
                    end: end,
                    mark: () {
                      if (!canMark) return false;
                      update(() {
                        if (start == null) {
                          start = const Duration(seconds: 8);
                        } else {
                          end = const Duration(seconds: 12);
                        }
                      });
                      return true;
                    },
                    clear: () => update(() {
                      start = null;
                      end = null;
                    }),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    ));

    final setA = find.byTooltip('Set A at the current position');
    final setB = find.byTooltip('Set B at the current position');
    final clearA = find.byTooltip('Clear marker A');
    final exit = find.byTooltip('Exit A–B repeat');
    final invalidA =
        find.text('Set A at least one second before the end of the song.');
    final invalidB = find.text('Set B at least one second after A.');

    final marker = tester.widget<Tooltip>(setA).child! as TextButton;
    final markerFocus = marker.focusNode!;
    markerFocus.requestFocus();
    await tester.pump();

    Future<void> activate() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    await activate();
    expect(invalidA, findsOneWidget);

    canMark = true;
    await activate();
    expect(invalidA, findsNothing);
    expect(find.text('A 00:08 · Set B'), findsOneWidget);
    expect(setB, findsOneWidget);

    final clear = tester.widget<IconButton>(
        find.byKey(const ValueKey('music-ab-repeat-clear')));
    clear.focusNode!.requestFocus();
    await tester.pump();
    await activate();
    expect(setA, findsOneWidget);
    expect(markerFocus.hasPrimaryFocus, isTrue);

    await activate();
    canMark = false;
    await activate();
    expect(invalidB, findsOneWidget);
    expect(clearA, findsOneWidget);

    canMark = true;
    await activate();
    expect(invalidB, findsNothing);
    expect(find.text('A 00:08 – B 00:12'), findsOneWidget);
    expect(exit, findsOneWidget);
    expect(markerFocus.hasPrimaryFocus, isTrue);

    await activate();
    expect(setA, findsOneWidget);
    expect(exit, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
