import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/subtitles/better_player_subtitles_drawer.dart';
import 'package:river_player/src/video_player/video_player.dart';

class _PausedController extends ValueNotifier<VideoPlayerValue>
    implements VideoPlayerController {
  _PausedController()
      : super(VideoPlayerValue(
          duration: const Duration(seconds: 20),
          position: const Duration(seconds: 1),
          isPlaying: false,
        ));

  @override
  Future<void> dispose() async => super.dispose();

  void release() => super.dispose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('adjacent captions change at their shared boundary',
      (tester) async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    final native = _PausedController();
    controller.videoPlayerController = native;
    final visible = StreamController<bool>();
    await controller.setupSubtitleSource(BetterPlayerSubtitlesSource(
      type: BetterPlayerSubtitlesSourceType.memory,
      content: 'WEBVTT\n\n'
          '00:00:00.000 --> 00:00:01.000\nFirst line\n\n'
          '00:00:01.000 --> 00:00:02.000\nNext line\n\n',
    ));
    try {
      await tester.pumpWidget(MaterialApp(
        home: BetterPlayerSubtitlesDrawer(
          subtitles: controller.subtitlesLines,
          betterPlayerController: controller,
          playerVisibilityStream: visible.stream,
        ),
      ));
      expect(controller.renderedSubtitle?.texts, ['Next line']);
      native.value =
          native.value.copyWith(position: const Duration(seconds: 2));
      await tester.pump();
      expect(controller.renderedSubtitle, isNull);
      expect(native.value.isPlaying, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.videoPlayerController = null;
      controller.dispose();
      unawaited(visible.close());
      native.release();
    }
  });

  testWidgets('remembered captions render after loading while paused',
      (tester) async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    final native = _PausedController();
    controller.videoPlayerController = native;
    final visible = StreamController<bool>();
    final pending = Completer<String>();
    final loading = controller.setupSubtitleSource(
      BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.memory,
        contentLoader: () => pending.future,
      ),
      sourceInitialize: true,
    );
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 400,
        height: 240,
        child: BetterPlayerSubtitlesDrawer(
          subtitles: controller.subtitlesLines,
          betterPlayerController: controller,
          playerVisibilityStream: visible.stream,
        ),
      ),
    ));
    expect(controller.renderedSubtitle, isNull);
    pending.complete(
        'WEBVTT\n\n00:00:00.200 --> 00:00:05.000\nWorking captions\n\n');
    await loading;
    await tester.pump();
    expect(controller.renderedSubtitle?.texts, ['Working captions']);
    expect(native.value.isPlaying, isFalse);
    expect(native.value.position, const Duration(seconds: 1));

    List<double?> cueFontSizes() => tester
        .widgetList<HtmlWidget>(find.byType(HtmlWidget))
        .map((cue) => cue.textStyle?.fontSize)
        .toList();

    expect(cueFontSizes(), [14, 14]);
    final cue = controller.renderedSubtitle;
    final track = controller.betterPlayerSubtitlesSource;
    controller.setSubtitleFontSize(24);
    await tester.pump();
    expect(cueFontSizes(), [24, 24]);
    expect(controller.renderedSubtitle, same(cue));
    expect(controller.betterPlayerSubtitlesSource, same(track));
    expect(native.value.isPlaying, isFalse);
    expect(native.value.position, const Duration(seconds: 1));

    await controller.setupSubtitleSource(BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.none));
    await tester.pump();
    expect(controller.renderedSubtitle, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.videoPlayerController = null;
    controller.dispose();
    unawaited(visible.close());
    native.release();
  });

  testWidgets(
      'caption sizing follows a replacement controller and configuration',
      (tester) async {
    final original = BetterPlayerController(const BetterPlayerConfiguration());
    final replacement =
        BetterPlayerController(const BetterPlayerConfiguration());
    final originalNative = _PausedController();
    final replacementNative = _PausedController();
    original.videoPlayerController = originalNative;
    replacement.videoPlayerController = replacementNative;
    final visible = StreamController<bool>();
    final drawerKey = GlobalKey();

    Future<void> show(BetterPlayerController controller, double fontSize) =>
        tester.pumpWidget(MaterialApp(
          home: BetterPlayerSubtitlesDrawer(
            key: drawerKey,
            subtitles: controller.subtitlesLines,
            betterPlayerController: controller,
            betterPlayerSubtitlesConfiguration:
                BetterPlayerSubtitlesConfiguration(fontSize: fontSize),
            playerVisibilityStream: visible.stream,
          ),
        ));

    List<double?> cueFontSizes() => tester
        .widgetList<HtmlWidget>(find.byType(HtmlWidget))
        .map((cue) => cue.textStyle?.fontSize)
        .toList();

    try {
      for (final controller in [original, replacement]) {
        await controller.setupSubtitleSource(BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.memory,
          content: 'WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nA caption\n\n',
        ));
      }
      await show(original, 16);
      final drawerState = drawerKey.currentState;
      expect(cueFontSizes(), [16, 16]);

      await show(original, 22);
      expect(drawerKey.currentState, same(drawerState));
      expect(cueFontSizes(), [22, 22]);
      original.setSubtitleFontSize(24);
      await tester.pump();
      expect(cueFontSizes(), [24, 24]);

      await show(replacement, 18);
      await tester.pumpAndSettle();
      expect(drawerKey.currentState, same(drawerState));
      expect(cueFontSizes(), [18, 18]);

      original.setSubtitleFontSize(30);
      originalNative.value =
          originalNative.value.copyWith(position: const Duration(seconds: 6));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pump();
      expect(cueFontSizes(), [18, 18]);

      replacement.setSubtitleFontSize(26);
      await tester.pump();
      expect(cueFontSizes(), [26, 26]);
      expect(replacement.renderedSubtitle?.texts, ['A caption']);
      expect(replacementNative.value.position, const Duration(seconds: 1));
      expect(replacementNative.value.isPlaying, isFalse);

      await tester.pumpWidget(const SizedBox());
      replacement.setSubtitleFontSize(28);
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      original.videoPlayerController = null;
      replacement.videoPlayerController = null;
      original.dispose();
      replacement.dispose();
      unawaited(visible.close());
      originalNative.release();
      replacementNative.release();
    }
  });
}
