import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Common speeds stay one drag away, with an explicit path to fine controls.
class PlaybackSpeedQuickControls extends StatefulWidget {
  final double initialSpeed;
  final ValueChanged<double> onChanged;
  final VoidCallback onAdvanced;

  const PlaybackSpeedQuickControls({
    super.key,
    required this.initialSpeed,
    required this.onChanged,
    required this.onAdvanced,
  });

  @override
  State<PlaybackSpeedQuickControls> createState() =>
      _PlaybackSpeedQuickControlsState();
}

class _PlaybackSpeedQuickControlsState
    extends State<PlaybackSpeedQuickControls> {
  static const _speeds = [0.5, 1.0, 2.0, 3.0, 4.0];
  late double _speed = _validSpeed(widget.initialSpeed);

  static double _validSpeed(double value) =>
      value.isFinite && value > 0 ? value : 1;

  @override
  void didUpdateWidget(covariant PlaybackSpeedQuickControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSpeed != oldWidget.initialSpeed) {
      _speed = _validSpeed(widget.initialSpeed);
    }
  }

  // Interpolate between detents without changing an advanced/custom speed.
  double get _sliderValue {
    if (_speed <= _speeds.first) return 0;
    for (var i = 1; i < _speeds.length; i++) {
      if (_speed <= _speeds[i]) {
        return i -
            1 +
            (_speed - _speeds[i - 1]) / (_speeds[i] - _speeds[i - 1]);
      }
    }
    return (_speeds.length - 1).toDouble();
  }

  void _select(double position) {
    final next = _speeds[position.round().clamp(0, _speeds.length - 1)];
    if (next == _speed) return;
    setState(() => _speed = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final format =
        NumberFormat('0.##', Localizations.localeOf(context).toString());
    String speed(double value) => '${format.format(value)}×';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MergeSemantics(
          child: Semantics(
            button: true,
            child: InkWell(
              key: const ValueKey('playback-speed-quick-advanced'),
              onTap: widget.onAdvanced,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 40,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Icon(Icons.speed),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text(locals.playbackSpeed,
                              style: theme.textTheme.bodyLarge),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                speed(_speed),
                                key: const ValueKey(
                                    'playback-speed-quick-value'),
                                style: theme.textTheme.bodyLarge,
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Semantics(
            label: locals.playbackSpeed,
            child: Slider(
              key: const ValueKey('playback-speed-quick-slider'),
              min: 0,
              max: (_speeds.length - 1).toDouble(),
              divisions: _speeds.length - 1,
              value: _sliderValue,
              label: speed(_speeds[_sliderValue.round()]),
              semanticFormatterCallback: (value) =>
                  speed(_speeds[value.round()]),
              onChanged: _select,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: ExcludeSemantics(
            child: Row(
              children: _speeds
                  .map((value) => Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(speed(value),
                              style: theme.textTheme.labelMedium),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: OutlinedButton.icon(
            key: const ValueKey('playback-speed-advanced-button'),
            onPressed: widget.onAdvanced,
            icon: const Icon(Icons.tune),
            label: Text(locals.advancedPlaybackSpeed),
          ),
        ),
      ],
    );
  }
}
