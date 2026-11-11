import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
