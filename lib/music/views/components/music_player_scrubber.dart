import 'dart:ui' show clampDouble;

import 'package:clipious/music/models/music_player_appearance.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';

/// The position slider changes its track and thumb with the player's style.
/// Flutter owns pointer gestures, focus, keyboard input, and slider semantics.
class MusicPlayerScrubber extends StatelessWidget {
  const MusicPlayerScrubber({
    super.key,
    required this.style,
    required this.semanticLabel,
    required this.maxPosition,
    required this.position,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final MusicScrubberStyle style;
  final String semanticLabel;
  final double maxPosition;
  final double position;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    final theme = SliderTheme.of(context).copyWith(
      activeTrackColor: foreground,
      inactiveTrackColor: foreground.withValues(alpha: 0.16),
      thumbColor: foreground,
    );
    final scrubberTheme = switch (style) {
      MusicScrubberStyle.gapped => theme.copyWith(
          trackHeight: 12,
          trackShape: const GappedSliderTrackShape(),
          thumbShape: const HandleThumbShape(),
          thumbSize: const WidgetStatePropertyAll(Size(4, 32)),
          trackGap: 6,
        ),
      MusicScrubberStyle.continuous => theme.copyWith(
          trackHeight: 5,
          trackShape: const RoundedRectSliderTrackShape(),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
      MusicScrubberStyle.wave => theme.copyWith(
          trackHeight: 4,
          trackShape: const _WaveTrackShape(),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
    };

    return MergeSemantics(
      child: Semantics(
        label: semanticLabel,
        child: SliderTheme(
          data: scrubberTheme,
          child: Slider(
            key: const ValueKey('music-player-progress'),
            max: maxPosition,
            value: position,
            semanticFormatterCallback: (value) =>
                prettyDurationCustom(Duration(milliseconds: value.round())),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ),
    );
  }
}

class _WaveTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _WaveTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (track.isEmpty) return;

    final rtl = textDirection == TextDirection.rtl;
    final start = rtl ? track.right : track.left;
    final end = rtl ? track.left : track.right;
    final playhead = clampDouble(thumbCenter.dx, track.left, track.right);
    final center = track.center.dy;
    final canvas = context.canvas;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = track.height;

    if (playhead != end) {
      stroke.color = Color.lerp(
        sliderTheme.disabledInactiveTrackColor,
        sliderTheme.inactiveTrackColor,
        enableAnimation.value,
      )!;
      canvas.drawLine(Offset(playhead, center), Offset(end, center), stroke);
    }

    final played = (playhead - start).abs();
    if (played == 0) return;

    const halfWave = 8.0;
    const amplitude = 2.5;
    final wave = Path()..moveTo(0, 0);
    var crest = -amplitude;
    for (var distance = 0.0; distance < played; distance += halfWave) {
      wave.relativeQuadraticBezierTo(halfWave / 2, 2 * crest, halfWave, 0);
      crest = -crest;
    }
    stroke.color = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    canvas.save();
    canvas.translate(start, center);
    if (rtl) canvas.scale(-1, 1);
    // Let the fixed wave end under the thumb as the playhead moves.
    final padding = track.height + amplitude;
    canvas.clipRect(Rect.fromLTRB(-padding, -padding, played, padding));
    canvas.drawPath(wave, stroke);
    canvas.restore();
  }
}
