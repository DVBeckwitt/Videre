import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'player_modal_back_handler.dart';

Future<void> showPlaybackSpeedSheet(
  BuildContext context, {
  required double initialSpeed,
  required ValueChanged<double> onChanged,
  int initialPitchSemitones = 0,
  ValueChanged<int>? onPitchChanged,
}) async {
  await showSafeModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => PlayerModalBackHandler(
      child: SingleChildScrollView(
        child: PlaybackSpeedControls(
          initialSpeed: initialSpeed,
          onChanged: onChanged,
          initialPitchSemitones: initialPitchSemitones,
          onPitchChanged: onPitchChanged,
        ),
      ),
    ),
  );
}

/// Speed and independent pitch controls for video, background audio, and TV.
/// Keeps the selected value locally so fine adjustments do not depend on the
/// timing of native player events. Playback and persistence stay with the caller.
class PlaybackSpeedControls extends StatefulWidget {
  final double initialSpeed;
  final ValueChanged<double> onChanged;
  final int initialPitchSemitones;
  final ValueChanged<int>? onPitchChanged;
  final bool compact;

  const PlaybackSpeedControls({
    super.key,
    required this.initialSpeed,
    required this.onChanged,
    this.initialPitchSemitones = 0,
    this.onPitchChanged,
    this.compact = false,
  });

  @override
  State<PlaybackSpeedControls> createState() => _PlaybackSpeedControlsState();
}

class _PlaybackSpeedControlsState extends State<PlaybackSpeedControls> {
  static const _min = 10;
  static const _max = 600;
  static const _presets = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];
  static const _steps = [0.01, 0.05, 0.1, 0.25];

  late int _hundredths = _normalize(widget.initialSpeed);
  late int _pitchSemitones = widget.initialPitchSemitones.clamp(-12, 12);
  int _step = 5;

  // Integer hundredths avoid accumulating floating point error on repeated taps.
  static int _normalize(double value) => value.isFinite
      ? (value.clamp(_min / 100, _max / 100) * 100).round()
      : 100;

  @override
  void didUpdateWidget(covariant PlaybackSpeedControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSpeed != oldWidget.initialSpeed) {
      _hundredths = _normalize(widget.initialSpeed);
    }
    if (widget.initialPitchSemitones != oldWidget.initialPitchSemitones) {
      _pitchSemitones = widget.initialPitchSemitones.clamp(-12, 12);
    }
  }

  void _select(int value) {
    final next = value.clamp(_min, _max);
    if (next == _hundredths) {
      return;
    }
    setState(() => _hundredths = next);
    widget.onChanged(next / 100);
  }

  void _selectPitch(int value) {
    final next = value.clamp(-12, 12);
    if (next == _pitchSemitones || widget.onPitchChanged == null) return;
    setState(() => _pitchSemitones = next);
    widget.onPitchChanged!(next);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final locale = Localizations.localeOf(context).toString();
    final format = NumberFormat('0.##', locale);
    String speed(double value) => '${format.format(value)}×';
    final current =
        '${NumberFormat('0.00', locale).format(_hundredths / 100)}×';
    final stepLabel = speed(_step / 100);
    String pitch(int value) =>
        '${value > 0 ? '+' : ''}${NumberFormat('0', locale).format(value)}';
    final currentPitch = pitch(_pitchSemitones);

    final controls = Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: FocusTraversalGroup(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, widget.compact ? 8 : 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.compact) ...[
                Text(
                    widget.onPitchChanged == null
                        ? locals.playbackSpeed
                        : locals.playbackSpeedAndPitch,
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 20),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      key: const ValueKey('playback-speed-decrease'),
                      tooltip: locals.decreasePlaybackSpeed(stepLabel),
                      onPressed: _hundredths > _min
                          ? () => _select(_hundredths - _step)
                          : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Expanded(
                      child: Semantics(
                        label: locals.playbackSpeed,
                        value: current,
                        liveRegion: true,
                        excludeSemantics: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                current,
                                key: const ValueKey('playback-speed-value'),
                                style: theme.textTheme.headlineLarge?.copyWith(
                                    color: colors.onSecondaryContainer,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            Text(
                              '−$stepLabel / +$stepLabel',
                              style: theme.textTheme.labelMedium?.copyWith(
                                  color: colors.onSecondaryContainer),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton.filledTonal(
                      key: const ValueKey('playback-speed-increase'),
                      tooltip: locals.increasePlaybackSpeed(stepLabel),
                      onPressed: _hundredths < _max
                          ? () => _select(_hundredths + _step)
                          : null,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
              Semantics(
                label: locals.playbackSpeed,
                child: Slider(
                  key: const ValueKey('playback-speed-slider'),
                  min: _min / 100,
                  max: _max / 100,
                  divisions: _max - _min,
                  value: _hundredths / 100,
                  label: current,
                  semanticFormatterCallback: speed,
                  onChanged: (value) => _select(_normalize(value)),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(speed(_min / 100), style: theme.textTheme.labelMedium),
                  Text(speed(_max / 100), style: theme.textTheme.labelMedium),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: _presets.map((value) {
                  final selected = _hundredths == (value * 100).round();
                  return ChoiceChip(
                    key: ValueKey('playback-speed-preset-$value'),
                    label: Text(speed(value)),
                    selected: selected,
                    showCheckmark: false,
                    onSelected: (_) => _select((value * 100).round()),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              Text(locals.playbackSpeedStep,
                  style: theme.textTheme.labelLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: _steps.map((value) {
                  return ChoiceChip(
                    key: ValueKey('playback-speed-step-$value'),
                    label: Text(speed(value)),
                    selected: _step == (value * 100).round(),
                    showCheckmark: false,
                    onSelected: (_) =>
                        setState(() => _step = (value * 100).round()),
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  key: const ValueKey('playback-speed-reset'),
                  onPressed: _hundredths == 100 ? null : () => _select(100),
                  icon: const Icon(Icons.restore),
                  label: Text(locals.resetPlaybackSpeed),
                ),
              ),
              if (widget.onPitchChanged != null) ...[
                const Divider(height: 32),
                Text(locals.playbackPitch,
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(locals.playbackPitchHelp,
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      IconButton.filledTonal(
                        key: const ValueKey('playback-pitch-decrease'),
                        tooltip: locals.decreasePlaybackPitch,
                        onPressed: _pitchSemitones > -12
                            ? () => _selectPitch(_pitchSemitones - 1)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      Expanded(
                        child: Semantics(
                          label: locals.playbackPitch,
                          value: locals.playbackPitchValue(currentPitch),
                          liveRegion: true,
                          excludeSemantics: true,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  currentPitch,
                                  key: const ValueKey('playback-pitch-value'),
                                  style: theme.textTheme.headlineLarge
                                      ?.copyWith(
                                          color: colors.onSecondaryContainer,
                                          fontWeight: FontWeight.w600),
                                ),
                              ),
                              Text(locals.playbackPitchUnit,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                      color: colors.onSecondaryContainer)),
                            ],
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        key: const ValueKey('playback-pitch-increase'),
                        tooltip: locals.increasePlaybackPitch,
                        onPressed: _pitchSemitones < 12
                            ? () => _selectPitch(_pitchSemitones + 1)
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                Semantics(
                  label: locals.playbackPitch,
                  child: Slider(
                    key: const ValueKey('playback-pitch-slider'),
                    min: -12,
                    max: 12,
                    divisions: 24,
                    value: _pitchSemitones.toDouble(),
                    label: locals.playbackPitchValue(currentPitch),
                    semanticFormatterCallback: (value) =>
                        locals.playbackPitchValue(pitch(value.round())),
                    onChanged: (value) => _selectPitch(value.round()),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(pitch(-12), style: theme.textTheme.labelMedium),
                    Text(pitch(12), style: theme.textTheme.labelMedium),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    key: const ValueKey('playback-pitch-reset'),
                    onPressed:
                        _pitchSemitones == 0 ? null : () => _selectPitch(0),
                    icon: const Icon(Icons.restore),
                    label: Text(locals.resetPlaybackPitch),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return widget.compact
        ? MediaQuery(
            data: MediaQuery.of(context).copyWith(
              navigationMode: NavigationMode.directional,
            ),
            child: controls,
          )
        : controls;
  }
}
