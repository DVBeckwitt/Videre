import 'package:clipious/home/models/content_mode.dart';
import 'package:clipious/home/views/components/content_mode_selector.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in ['en', 'sl', 'ta', 'or']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$locale mode labels remain in the toolbar at ${scale}x',
          (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var selected = HomeContentMode.videos;
        await tester.pumpWidget(MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: StatefulBuilder(builder: (context, setState) {
            return Scaffold(
              appBar: AppBar(
                titleSpacing: 8,
                toolbarHeight: 64,
                title: ContentModeSelector(
                  value: selected,
                  onChanged: (mode) => setState(() => selected = mode),
                ),
                actions: [
                  if (scale == 1)
                    IconButton(
                        onPressed: () {}, icon: const Icon(Icons.download)),
                  IconButton(
                      onPressed: () {}, icon: const Icon(Icons.more_vert)),
                  IconButton(
                      onPressed: () {}, icon: const Icon(Icons.settings)),
                ],
              ),
            );
          }),
        ));
        await tester.pumpAndSettle();
        final locals = AppLocalizations.of(
            tester.element(find.byType(ContentModeSelector)))!;
        final inheritedScale = MediaQuery.textScalerOf(
            tester.element(find.byType(ContentModeSelector)));
        final toolbar = tester.getRect(find.byType(AppBar));
        for (final label in [locals.videos, locals.music]) {
          final text = find.text(label);
          final bounds = tester.getRect(text);
          expect(bounds.top, greaterThanOrEqualTo(toolbar.top), reason: label);
          expect(bounds.bottom, lessThanOrEqualTo(toolbar.bottom),
              reason: label);
          expect(bounds.left, greaterThanOrEqualTo(toolbar.left),
              reason: label);
          expect(bounds.right, lessThanOrEqualTo(toolbar.right), reason: label);
          expect(
              tester.renderObject<RenderParagraph>(text).textScaler.scale(14),
              inheritedScale.scale(14));
          expect(find.byTooltip(label), findsOneWidget);
        }
        await tester.tap(find.text(locals.music));
        await tester.pumpAndSettle();
        expect(selected, HomeContentMode.music);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
