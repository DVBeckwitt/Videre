import 'dart:math' as math;

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
    this.waveformPeaks,
  });

  final MusicScrubberStyle style;
  final String semanticLabel;
  final double maxPosition;
  final double position;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Absolute amplitude peaks from 0 to 1 in playback order.
  final List<double>? waveformPeaks;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    final theme = SliderTheme.of(context).copyWith(
      activeTrackColor: foreground,
      inactiveTrackColor: foreground.withValues(alpha: 0.16),
      thumbColor: foreground,
    );
    const SliderTrackShape regularTrack = RoundedRectSliderTrackShape();
    final peaks = waveformPeaks;
    final hasWaveform = peaks != null && peaks.isNotEmpty;
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
          trackShape: regularTrack,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
      MusicScrubberStyle.wave => theme.copyWith(
          trackHeight: 4,
          trackShape: hasWaveform ? _WaveformTrackShape(peaks) : regularTrack,
          inactiveTrackColor:
              hasWaveform ? foreground.withValues(alpha: 0.45) : null,
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

class _WaveformTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _WaveformTrackShape(this.peaks);

  final List<double> peaks;

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

    final barCount = math.min(peaks.length, math.max(1, track.width ~/ 3));
    final spacing = track.width / barCount;
    final barWidth = math.min(2.0, spacing * 0.65);
    final maxHalfHeight = math.min(
      12.0,
      (parentBox.size.height - barWidth) / 2,
    );
    if (maxHalfHeight <= 0) return;
    final minHalfHeight = math.min(1.0, maxHalfHeight);
    final active = Paint()
      ..color = Color.lerp(
        sliderTheme.disabledActiveTrackColor,
        sliderTheme.activeTrackColor,
        enableAnimation.value,
      )!
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;
    final inactive = Paint()
      ..color = Color.lerp(
        sliderTheme.disabledInactiveTrackColor,
        sliderTheme.inactiveTrackColor,
        enableAnimation.value,
      )!
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    final rtl = textDirection == TextDirection.rtl;
    final centerY = track.center.dy;
    for (var bar = 0; bar < barCount; bar++) {
      // Retain short transients when several peaks share a bar at this width.
      final begin = bar * peaks.length ~/ barCount;
      final end = (bar + 1) * peaks.length ~/ barCount;
      var peak = 0.0;
      for (var sample = begin; sample < end; sample++) {
        peak = math.max(peak, peaks[sample]);
      }
      final distance = (bar + 0.5) * spacing;
      final x = rtl ? track.right - distance : track.left + distance;
      final played = rtl ? x >= thumbCenter.dx : x <= thumbCenter.dx;
      final halfHeight = minHalfHeight + (maxHalfHeight - minHalfHeight) * peak;
      context.canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        played ? active : inactive,
      );
    }
  }
}
