import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils.dart';
import '../../../utils/models/pair.dart';

/// Flutter translation of Flow's PlayerBottomBar, PlayerTimePill and
/// edge-aligned PlayerSeekbarRow from revision 565d1f7a.
class FlowWatchTransport extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final List<Pair<int>> sponsorIntervals;
  final bool showActions;
  final bool showTime;
  final bool isLive;
  final bool muted;
  final VoidCallback onToggleMute;
  final VoidCallback onFullscreen;
  final VoidCallback onInteract;
  final ValueChanged<double> onScrub;
  final ValueChanged<double> onScrubFinished;

  const FlowWatchTransport({
    super.key,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.sponsorIntervals,
    required this.showActions,
    required this.showTime,
    required this.isLive,
    required this.muted,
    required this.onToggleMute,
    required this.onFullscreen,
    required this.onInteract,
    required this.onScrub,
    required this.onScrubFinished,
  });

  @override
  State<FlowWatchTransport> createState() => _FlowWatchTransportState();
}

class _FlowWatchTransportState extends State<FlowWatchTransport> {
  bool _remaining = false;

  @override
  Widget build(BuildContext context) {
    final duration = widget.duration.inMilliseconds.toDouble();
    final visible = widget.showActions || widget.showTime;
    final format = Theme.of(context).textTheme.labelMedium;
    final locals = AppLocalizations.of(context)!;
    final current = prettyDurationCustom(widget.position);
    final remaining = widget.duration - widget.position;
    final elapsed = _remaining
        ? '-${prettyDurationCustom(remaining.isNegative ? Duration.zero : remaining)}'
        : current;
    final total = prettyDurationCustom(widget.duration);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (visible)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              if (widget.isLive || duration > 0)
                Flexible(
                  child: Material(
                    color: Colors.black54,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      key: const ValueKey('flow-watch-time-pill'),
                      customBorder: const StadiumBorder(),
                      onTap: widget.isLive
                          ? null
                          : () {
                              setState(() => _remaining = !_remaining);
                              widget.onInteract();
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        child: Text(
                          widget.isLive
                              ? '$current · ${locals.streamIsLive}'
                              : '$elapsed / $total',
                          style: format?.copyWith(color: Colors.white),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.showActions) ...[
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onToggleMute,
                  icon: Icon(widget.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onFullscreen,
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
              ],
            ]),
          ),
        if (widget.isLive)
          const ColoredBox(color: Colors.redAccent, child: SizedBox(height: 3))
        else if (duration > 0)
          SizedBox(
            height: 34,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: visible ? 5 : 3,
                padding: EdgeInsets.zero,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: visible
                    ? const RoundSliderThumbShape(enabledThumbRadius: 5)
                    : SliderComponentShape.noThumb,
                thumbColor: Colors.white,
                trackShape: _FlowSeekTrack(duration, widget.sponsorIntervals),
              ),
              // Media time increases left to right independently from text.
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Slider(
                  key: const ValueKey('flow-watch-seekbar'),
                  value: widget.position.inMilliseconds
                      .clamp(0, duration)
                      .toDouble(),
                  secondaryTrackValue: widget.buffer.inMilliseconds
                      .clamp(0, duration)
                      .toDouble(),
                  max: duration,
                  onChangeStart: widget.onScrub,
                  onChanged: widget.onScrub,
                  onChangeEnd: widget.onScrubFinished,
                  semanticFormatterCallback: (milliseconds) =>
                      prettyDurationCustom(
                          Duration(milliseconds: milliseconds.round())),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The illustrated band hugs the edge while the larger Slider target remains
/// accessible. Flow overlays mark admitted sponsor ranges above played bytes.
class _FlowSeekTrack extends RectangularSliderTrackShape {
  final double durationMs;
  final List<Pair<int>> sponsorIntervals;

  const _FlowSeekTrack(this.durationMs, this.sponsorIntervals);

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final height = sliderTheme.trackHeight ?? 3;
    final thumbRadius =
        sliderTheme.thumbShape!.getPreferredSize(isEnabled, isDiscrete).width /
            2;
    return Rect.fromLTWH(
      offset.dx + thumbRadius,
      offset.dy + parentBox.size.height - height - thumbRadius,
      (parentBox.size.width - 2 * thumbRadius)
          .clamp(0.0, parentBox.size.width)
          .toDouble(),
      height,
    );
  }

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
    final canvas = context.canvas;
    final brush = Paint();
    void band(double from, double to, Color color) {
      if (to <= from) return;
      canvas.drawRect(Rect.fromLTRB(from, track.top, to, track.bottom),
          brush..color = color);
    }

    double at(int ms) =>
        track.left + track.width * (ms / durationMs).clamp(0, 1);
    band(track.left, track.right, Colors.white24);
    if (secondaryOffset != null) {
      band(track.left, secondaryOffset.dx, Colors.white54);
    }
    band(track.left, thumbCenter.dx, Colors.white);
    for (final interval in sponsorIntervals) {
      band(at(interval.first), at(interval.last), const Color(0xff42bba9));
    }
  }
}
