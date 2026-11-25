import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/components/music_fast_scroll.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _jump = ValueKey('music-fast-scroll');
const _header = ValueKey('pinned-toolbar');

final _tracks = [
  for (final letter in ['A', 'B', 'C'])
    for (var number = 0; number < 35; number++) '$letter track $number',
];

Widget _browser(ScrollController scroll, ValueNotifier<List<String>> display) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ValueListenableBuilder(
        valueListenable: display,
        builder: (context, tracks, _) => MusicFastScroll(
          scope: tracks,
          leadingItems: 1,
          sections: musicFastScrollSectionsFor(context, tracks,
              sortValue: (track) => track),
          child: CustomScrollView(
            controller: scroll,
            slivers: [
              const PinnedHeaderSliver(
                  child: SizedBox(key: _header, height: 52)),
              SliverList.builder(
                itemCount: tracks.length + 1,
                itemBuilder: (_, index) {
                  if (index == 0) {
                    return const SizedBox(height: 86, child: Text('Shortcut'));
                  }
                  final title = tracks[index - 1];
                  final base = title.startsWith('A') ? 40.0 : 118.0;
                  return SizedBox(
                    height: base + index % 4 * 9,
                    child: Text(title),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Finder _option(String label) =>
    find.descendant(of: find.byType(SimpleDialog), matching: find.text(label));

void main() {
  testWidgets('jumps to distant variable-height rows below a pinned toolbar',
      (tester) async {
    final scroll = ScrollController();
    final display = ValueNotifier(_tracks);
    addTearDown(scroll.dispose);
    addTearDown(display.dispose);
    await tester.pumpWidget(_browser(scroll, display));
    expect(find.text('C track 0'), findsNothing);

    for (final section in ['C', 'A']) {
      await tester.tap(find.byKey(_jump));
      await tester.pumpAndSettle();
      await tester.tap(_option(section));
      await tester.pumpAndSettle();

      final target = tester.getTopLeft(find.text('$section track 0'));
      final header = tester.getBottomLeft(find.byKey(_header));
      expect(target.dy, closeTo(header.dy, 1));
    }
  });

  testWidgets('keyboard dismissal restores control focus and scroll offset',
      (tester) async {
    final scroll = ScrollController();
    final display = ValueNotifier(_tracks);
    addTearDown(scroll.dispose);
    addTearDown(display.dispose);
    await tester.pumpWidget(_browser(scroll, display));
    scroll.jumpTo(600);
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    final focus = Focus.of(tester.element(find.text('Jump to section')));
    focus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(_option('A'), findsOneWidget);
    expect(scroll.offset, offset);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(focus.hasPrimaryFocus, isTrue);
    expect(scroll.offset, offset);
  });

  testWidgets('ignores a stale section and reopens in filtered display order',
      (tester) async {
    final scroll = ScrollController();
    final display = ValueNotifier(_tracks);
    addTearDown(scroll.dispose);
    addTearDown(display.dispose);
    await tester.pumpWidget(_browser(scroll, display));
    await tester.tap(find.byKey(_jump));
    await tester.pumpAndSettle();

    display.value = _tracks.reversed
        .where((track) => !track.startsWith('B'))
        .toList(growable: false);
    await tester.pumpAndSettle();
    await tester.tap(_option('C'));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);

    await tester.tap(find.byKey(_jump));
    await tester.pumpAndSettle();
    expect(_option('B'), findsNothing);
    expect(tester.getTopLeft(_option('C')).dy,
        lessThan(tester.getTopLeft(_option('A')).dy));
    await tester.tap(_option('A'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('A track 34')).dy,
        closeTo(tester.getBottomLeft(find.byKey(_header)).dy, 1));
  });
}
