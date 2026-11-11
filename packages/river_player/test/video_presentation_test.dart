import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/core/better_player_with_controls.dart';
import 'package:river_player/src/video_player/video_player.dart';

class _PausedVideo extends ValueNotifier<VideoPlayerValue>
    implements VideoPlayerController {
  _PausedVideo()
      : super(VideoPlayerValue(
          duration: const Duration(seconds: 20),
          position: const Duration(seconds: 5),
          size: const Size(400, 300),
        ));

  @override
  int? get textureId => null;

  @override
  Future<void> dispose() async => super.dispose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends BetterPlayerController {
  _Controller()
      : super(const BetterPlayerConfiguration(
          controlsConfiguration:
              BetterPlayerControlsConfiguration(showControls: false),
          overlay: SizedBox.expand(key: ValueKey('overlay')),
        ));

  @override
  BetterPlayerDataSource get betterPlayerDataSource => BetterPlayerDataSource(
        BetterPlayerDataSourceType.file,
        'unused.mp4',
      );
}

void main() {
  testWidgets('display changes reshape a paused texture inside the same player',
      (tester) async {
    final controller = _Controller();
    final native = _PausedVideo();
    controller.videoPlayerController = native;

    Future<void> show(BoxFit fit, {double? ratio}) {
      return tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 500,
            height: 250,
            child: BetterPlayerControllerProvider(
              controller: controller,
              child: BetterPlayerWithControls(
                controller: controller,
                fit: fit,
                videoAspectRatio: ratio,
              ),
            ),
          ),
        ),
      ));
    }

    await show(BoxFit.contain);
    final video = find.byType(VideoPlayer);
    final textureState = tester.state(video);
    final overlay = tester.getRect(find.byKey(const ValueKey('overlay')));
    expect(overlay.size, const Size(500, 250));

    void expectFrame(double width, double height) {
      final rect = tester.getRect(video);
      expect(rect.width, closeTo(width, 0.01));
      expect(rect.height, closeTo(height, 0.01));
      expect(rect.center, overlay.center);
      expect(tester.getRect(find.byKey(const ValueKey('overlay'))), overlay);
      expect(tester.state(video), same(textureState));
    }

    expectFrame(1000 / 3, 250);
    await show(BoxFit.cover);
    expectFrame(500, 375);
    expect(
        tester.getRect(find.ancestor(
          of: video,
          matching: find.byType(ClipRect),
        )),
        overlay);
    await show(BoxFit.fill);
    expectFrame(500, 250);
    await show(BoxFit.contain, ratio: 3 / 2);
    expectFrame(375, 250);
    await show(BoxFit.contain);
    native.value = native.value.copyWith(size: const Size(160, 90));
    await tester.pump();
    expectFrame(4000 / 9, 250);
    expect(native.value.isPlaying, isFalse);
    expect(native.value.position, const Duration(seconds: 5));

    await tester.pumpWidget(const SizedBox());
    controller.videoPlayerController = null;
    controller.dispose();
    await native.dispose();
  });
}
