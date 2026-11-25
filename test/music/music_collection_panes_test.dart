import 'dart:ui' show SemanticsRole;

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/music/views/components/music_collection_panes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _detailsScroll = ValueKey('test-collection-details-scroll');
const _tracksScroll = ValueKey('test-collection-tracks-scroll');
const _detailsPane = ValueKey('music-collection-details-pane');
const _tracksPane = ValueKey('music-collection-tracks-pane');

class _TrackViewport extends StatefulWidget {
  const _TrackViewport({this.compactDetails, required this.onActivate});

  final Widget? compactDetails;
  final VoidCallback onActivate;

  @override
  State<_TrackViewport> createState() => _TrackViewportState();
}

class _TrackViewportState extends State<_TrackViewport> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
        key: _tracksScroll,
        controller: controller,
        children: [
          if (widget.compactDetails case final details?) details,
          TextButton(
              onPressed: widget.onActivate, child: const Text('First track')),
          for (var index = 2; index <= 30; index++)
            ListTile(title: Text('Track $index')),
        ],
      );
}

void main() {
  void useView(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wasTv = app.isTv;
    app.isTv = false;
    addTearDown(() => app.isTv = wasTv);
  }

  Future<void> show(WidgetTester tester,
      {double? width,
      double textScale = 1,
      TextDirection direction = TextDirection.ltr,
      VoidCallback? onTrackActivate}) async {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton(onPressed: () {}, child: const Text('Collection action')),
        for (var index = 1; index <= 18; index++)
          Text('Collection credit $index with a long performer name'),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Directionality(
          textDirection: direction,
          child: Center(
            child: SizedBox(
              width: width ?? double.infinity,
              child: MusicCollectionPanes(
                details: details,
                detailsKey: _detailsScroll,
                buildTracks: (_, split) => _TrackViewport(
                  compactDetails: split ? null : details,
                  onActivate: onTrackActivate ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('wide tablet exposes separately scrollable regions at large text',
      (tester) async {
    useView(tester, const Size(1000, 700));
    await show(tester, textScale: 2);
    final details = find.byKey(_detailsPane);
    final tracks = find.byKey(_tracksPane);
    final detailsSemantics = tester.getSemantics(details).getSemanticsData();
    final tracksSemantics = tester.getSemantics(tracks).getSemanticsData();
    expect(detailsSemantics.label, 'Collection details');
    expect(detailsSemantics.role, SemanticsRole.region);
    expect(tracksSemantics.label, 'Collection tracks');
    expect(tracksSemantics.role, SemanticsRole.region);
    expect(
        tester.getRect(details).right, lessThan(tester.getRect(tracks).left));

    final detailsScrollable = find.descendant(
        of: find.byKey(_detailsScroll), matching: find.byType(Scrollable));
    final detailsPosition =
        tester.state<ScrollableState>(detailsScrollable).position;
    final trackPosition = tester
        .state<_TrackViewportState>(find.byType(_TrackViewport))
        .controller
        .position;
    await tester.drag(find.byKey(_detailsScroll), const Offset(0, -260));
    await tester.pumpAndSettle();
    final detailsOffset = detailsPosition.pixels;
    expect(detailsOffset, greaterThan(0));
    expect(trackPosition.pixels, 0);

    await tester.drag(find.byKey(_tracksScroll), const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(trackPosition.pixels, greaterThan(0));
    expect(detailsPosition.pixels, detailsOffset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL places details at the start and keeps directional focus',
      (tester) async {
    useView(tester, const Size(1000, 700));
    var activated = 0;
    await show(tester,
        direction: TextDirection.rtl, onTrackActivate: () => activated++);
    final details = find.text('Collection action');
    final firstTrack = find.text('First track');
    expect(tester.getRect(find.byKey(_detailsPane)).left,
        greaterThan(tester.getRect(find.byKey(_tracksPane)).right));
    final detailsFocus = Focus.of(tester.element(details));
    final trackFocus = Focus.of(tester.element(firstTrack));
    expect(detailsFocus.hasFocus, isFalse);
    expect(trackFocus.hasFocus, isFalse);
    detailsFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(trackFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activated, 1);
  });

  testWidgets('width breakpoint keeps the track viewport mounted',
      (tester) async {
    useView(tester, const Size(1000, 700));
    await show(tester, width: 720);
    final trackViewport = find.byType(_TrackViewport);
    final trackState = tester.state<_TrackViewportState>(trackViewport);
    final trackPosition = trackState.controller.position;
    expect(find.byKey(_detailsPane), findsOneWidget);
    trackState.controller.jumpTo(175);
    await tester.pump();

    await show(tester, width: 719);
    expect(find.byKey(_detailsPane), findsNothing);
    expect(find.bySemanticsLabel('Collection tracks'), findsNothing);
    expect(tester.state<_TrackViewportState>(trackViewport), same(trackState));
    expect(trackState.controller.position, same(trackPosition));
    expect(trackPosition.pixels, 175);

    await show(tester, width: 720);
    expect(find.byKey(_detailsPane), findsOneWidget);
    expect(tester.state<_TrackViewportState>(trackViewport), same(trackState));
    expect(trackPosition.pixels, 175);
  });

  testWidgets('phone and TV use the compact collection despite ample width',
      (tester) async {
    useView(tester, const Size(900, 500));
    await show(tester);
    for (final tv in [false, true]) {
      if (tv) {
        tester.view.physicalSize = const Size(1100, 720);
        app.isTv = true;
        await show(tester);
      }
      final compact = find.byKey(_tracksScroll);
      expect(find.byKey(_detailsPane), findsNothing);
      expect(find.bySemanticsLabel('Collection details'), findsNothing);
      expect(find.bySemanticsLabel('Collection tracks'), findsNothing);
      expect(
          find.descendant(
              of: compact, matching: find.text('Collection action')),
          findsOneWidget);
      expect(find.descendant(of: compact, matching: find.text('First track')),
          findsOneWidget);
    }
  });
}
