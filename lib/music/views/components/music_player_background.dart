import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../utils/motion.dart';
import '../../../utils/views/components/artwork_image_builder.dart';
import '../../models/music_player_appearance.dart';

/// The decorative layer behind the full player and its transport controls.
class MusicPlayerBackgroundView extends StatelessWidget {
  const MusicPlayerBackgroundView({
    super.key,
    required this.style,
    required this.artwork,
    required this.visible,
  });

  final MusicPlayerBackground style;
  final Widget Function(ArtworkImageBuilder?) artwork;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (style == MusicPlayerBackground.solid) return const SizedBox.shrink();
    final surface = Theme.of(context).colorScheme.surface;
    final gradient = style == MusicPlayerBackground.gradient;
    final imageBuilder = switch (style) {
      MusicPlayerBackground.gradient => _gradientArtwork,
      MusicPlayerBackground.movingArtwork => _movingArtwork,
      _ => null,
    };
    final fittedArtwork = FittedBox(
      fit: gradient ? BoxFit.fill : BoxFit.cover,
      child: SizedBox.square(dimension: 180, child: artwork(imageBuilder)),
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: surface),
                if (style == MusicPlayerBackground.artwork)
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 52, sigmaY: 52),
                    child: fittedArtwork,
                  )
                else
                  fittedArtwork,
                if (!gradient)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          surface,
                          surface.withAlpha(0xbc),
                          surface.withAlpha(0xcf),
                          surface,
                        ],
                        stops: const [0, 0.27, 0.76, 1],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _gradientArtwork(
    BuildContext context,
    ImageProvider<Object> provider,
    Widget child,
  ) =>
      _ArtworkGradient(key: ValueKey(provider), provider: provider);

  Widget _movingArtwork(
    BuildContext context,
    ImageProvider<Object> provider,
    Widget child,
  ) =>
      _MovingArtwork(
        visible: visible,
        // Blur the small cover once so the transform can reuse the layer.
        child: RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: child,
          ),
        ),
      );
}

class _ArtworkGradient extends StatefulWidget {
  const _ArtworkGradient({super.key, required this.provider});

  final ImageProvider<Object> provider;

  @override
  State<_ArtworkGradient> createState() => _ArtworkGradientState();
}

class _ArtworkGradientState extends State<_ArtworkGradient> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _requested = false;
  (Color, Color)? _palette;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    // The artwork source has already loaded this provider. Share its decoded
    // frame through the image cache and detach as soon as it arrives.
    final stream = _stream =
        widget.provider.resolve(createLocalImageConfiguration(context));
    final listener = _listener =
        ImageStreamListener(_extract, onError: (_, __) => _detach());
    stream.addListener(listener);
  }

  void _detach() {
    if (_listener case final listener?) _stream?.removeListener(listener);
    _listener = null;
    _stream = null;
  }

  Future<void> _extract(ImageInfo frame, bool synchronous) async {
    _detach();
    try {
      final palette = await _sampleArtwork(frame.image);
      if (mounted && palette != null) setState(() => _palette = palette);
    } catch (_) {
      // Keep the surface color if the engine cannot read a decorative frame.
    } finally {
      frame.dispose();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palette;
    if (palette == null) return const SizedBox.expand();
    final surface = Theme.of(context).colorScheme.surface;
    // Limit the tint to the same brightness range as the artwork scrim.
    return DecoratedBox(
      key: const ValueKey('music-player-artwork-gradient'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(surface, palette.$1, 0.25)!,
            Color.lerp(surface, palette.$2, 0.18)!,
            surface,
          ],
          stops: const [0, 0.6, 1],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

Future<(Color, Color)?> _sampleArtwork(ui.Image image) async {
  const extent = 16;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    const Rect.fromLTWH(0, 0, extent * 1.0, extent * 1.0),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  try {
    final sample = await picture.toImage(extent, extent);
    try {
      final pixels =
          await sample.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (pixels == null) return null;
      final midpoint = pixels.lengthInBytes ~/ 2;
      final top = _averageColor(pixels, 0, midpoint);
      final bottom = _averageColor(pixels, midpoint, pixels.lengthInBytes);
      if (top == null && bottom == null) return null;
      return (top ?? bottom!, bottom ?? top!);
    } finally {
      sample.dispose();
    }
  } finally {
    picture.dispose();
  }
}

Color? _averageColor(ByteData pixels, int start, int end) {
  var red = 0;
  var green = 0;
  var blue = 0;
  var weight = 0;
  for (var i = start; i < end; i += 4) {
    final alpha = pixels.getUint8(i + 3);
    red += pixels.getUint8(i) * alpha;
    green += pixels.getUint8(i + 1) * alpha;
    blue += pixels.getUint8(i + 2) * alpha;
    weight += alpha;
  }
  if (weight == 0) return null;
  return Color.fromARGB(255, red ~/ weight, green ~/ weight, blue ~/ weight);
}

class _MovingArtwork extends StatefulWidget {
  const _MovingArtwork({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_MovingArtwork> createState() => _MovingArtworkState();
}

class _MovingArtworkState extends State<_MovingArtwork>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
    value: 0.5,
  );
  bool _foreground = true;
  bool _motionAllowed = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed = TickerMode.of(context) &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        AppMotion.allowsMovement(context);
    _updateMotion();
  }

  @override
  void didUpdateWidget(_MovingArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() => _foreground = foreground);
    _updateMotion();
  }

  void _updateMotion() {
    final animate = widget.visible && _foreground && _motionAllowed;
    if (animate == _drift.isAnimating) return;
    if (animate) {
      _drift.repeat(reverse: true);
    } else {
      _drift.stop();
      _drift.value = 0.5;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 1.10,
      child: AnimatedBuilder(
        animation: _drift,
        child: widget.child,
        builder: (context, child) {
          if (!_drift.isAnimating) return child!;
          final drift = Curves.easeInOutSine.transform(_drift.value) - 0.5;
          return FractionalTranslation(
            key: const ValueKey('music-player-moving-artwork'),
            translation: Offset(0.06 * drift, -0.04 * drift),
            child: child,
          );
        },
      ),
    );
  }
}
