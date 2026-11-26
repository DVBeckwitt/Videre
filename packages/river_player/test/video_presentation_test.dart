import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/core/better_player_with_controls.dart';
import 'package:river_player/src/video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

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

  testWidgets('the surface builder transforms only the clipped video texture', (
    tester,
  ) async {
    final visibility = VisibilityDetectorController.instance;
    final updateInterval = visibility.updateInterval;
    visibility.updateInterval = Duration.zero;
    addTearDown(() => visibility.updateInterval = updateInterval);

    final controller = _Controller();
    final native = _PausedVideo();
    controller.videoPlayerController = native;
    const overlayKey = ValueKey('overlay');
    const transformKey = ValueKey('video-surface-transform');
    (Size, BoxFit)? surface;

    Future<void> show(BoxFit fit, double scale, {double? ratio}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 500,
              height: 250,
              child: BetterPlayer(
                controller: controller,
                fit: fit,
                videoAspectRatio: ratio,
                videoSurfaceBuilder: (fittedVideo, sourceSize, fit) {
                  surface = (sourceSize, fit);
                  return Transform.scale(
                    key: transformKey,
                    scale: scale,
                    child: fittedVideo,
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    await show(BoxFit.contain, 1);
    final video = find.byType(VideoPlayer);
    final overlay = tester.getRect(find.byKey(overlayKey));
    final textureState = tester.state(video);
    expect(surface, (const Size(400, 300), BoxFit.contain));

    await show(BoxFit.cover, 2, ratio: 3 / 2);
    final frame = tester.getRect(video);
    expect(surface, (const Size(450, 300), BoxFit.cover));
    expect(frame.width, closeTo(1000, 0.01));
    expect(frame.height, closeTo(2000 / 3, 0.01));
    expect(frame.center, overlay.center);
    expect(tester.getRect(find.byKey(overlayKey)), overlay);
    expect(tester.state(video), same(textureState));

    final clip = find.ancestor(
      of: find.byKey(transformKey),
      matching: find.byType(ClipRect),
    );
    expect(tester.widget<ClipRect>(clip).clipBehavior, Clip.hardEdge);
    expect(tester.getRect(clip), overlay);

    await tester.pumpWidget(const SizedBox());
    controller.videoPlayerController = null;
    controller.dispose();
    await native.dispose();
  });
}
